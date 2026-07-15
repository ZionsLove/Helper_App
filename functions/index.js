const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {onDocumentCreated, onDocumentUpdated} = require("firebase-functions/v2/firestore");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {defineSecret} = require("firebase-functions/params");
const {getCatalogItem} = require("./catalog");

const stripeSecretKey = defineSecret("STRIPE_SECRET_KEY");
const googleMapsApiKey = defineSecret("GOOGLE_MAPS_API_KEY");
const driverSearchRadiusMeters = 24140;
const maxEligibleDrivers = 10;
const pickupRadiusMeters = 16093;
const maxDriverLocationAgeMs = 2 * 60 * 1000;
const motorVehicleTypes = new Set(["car", "pickup_truck_van"]);
const minDeliveryFeeCents = 1700;
const driverBasePayCents = 1200;
const taxRate = 0.08875;
const ownerAdminEmails = new Set(["chrisl2000@thehelpersapp.com"]);

function dollarsFromCents(cents) {
  return Math.round(cents) / 100;
}

function centsFromAmount(amount) {
  const value = Number(amount);
  if (!Number.isFinite(value)) {
    return 0;
  }

  return Math.max(0, Math.round(value * 100));
}

function formatDistanceImperial(meters) {
  const feet = meters * 3.28084;

  if (feet < 5280) {
    return `${Math.round(feet)} ft`;
  }

  return `${(feet / 5280).toFixed(1)} mi`;
}

function driverPayCentsForOrder(order) {
  const cents =
    Number(order.driverPayCents) ||
    Math.round(Number(order.driverPay || 0) * 100);

  return Number.isFinite(cents) ? cents : 0;
}

async function getDriverPayoutSummary(driverId) {
  const snapshot = await admin
    .firestore()
    .collection("orders")
    .where("driverId", "==", driverId)
    .limit(100)
    .get();

  let availableCents = 0;
  let reviewCents = 0;
  let pendingWithdrawalCount = 0;
  let reviewCount = 0;
  let payoutErrorCount = 0;

  snapshot.docs.forEach((doc) => {
    const order = doc.data() || {};
    const status = order.driverPayoutStatus?.toString() || "";
    const payCents = driverPayCentsForOrder(order);
    const hasPaymentReference =
      typeof order.stripePaymentIntentId === "string" &&
      order.stripePaymentIntentId.length > 0;

    if (status === "pending_withdrawal") {
      pendingWithdrawalCount += 1;

      if (payCents > 0 && hasPaymentReference) {
        availableCents += payCents;
      } else {
        reviewCents += Math.max(0, payCents);
        reviewCount += 1;
      }
    } else if (status === "payout_error") {
      reviewCents += Math.max(0, payCents);
      reviewCount += 1;
      payoutErrorCount += 1;
    }
  });

  return {
    availableCents,
    available: dollarsFromCents(availableCents),
    reviewCents,
    review: dollarsFromCents(reviewCents),
    pendingWithdrawalCount,
    reviewCount,
    payoutErrorCount,
  };
}

async function assertAdmin(request) {
  const uid = request.auth?.uid;
  const email = request.auth?.token?.email?.toString().toLowerCase();

  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in to access admin tools.");
  }

  if (email && ownerAdminEmails.has(email)) {
    return {uid, email};
  }

  const adminDoc = await admin
    .firestore()
    .collection("adminUsers")
    .doc(uid)
    .get();

  if (adminDoc.data()?.active === true) {
    return {uid, email};
  }

  throw new HttpsError("permission-denied", "Admin access is required.");
}

function timestampText(value) {
  if (!value) return null;
  if (typeof value.toDate === "function") {
    return value.toDate().toISOString();
  }
  if (typeof value === "string") return value;
  return null;
}

function getStripe() {
  const secretKey = stripeSecretKey.value();

  if (!secretKey) {
    throw new HttpsError(
      "failed-precondition",
      "Missing STRIPE_SECRET_KEY for Stripe Cloud Functions."
    );
  }

  return require("stripe")(secretKey);
}

function currentStripeMode() {
  return stripeSecretKey.value()?.startsWith("sk_live_") ? "live" : "test";
}

async function createStripeCustomerForUser(stripe, userRef, userId, email) {
  const customer = await stripe.customers.create({
    email: email || undefined,
    metadata: {firebaseUID: userId},
  });

  await userRef.set(
    {
      stripeCustomerId: customer.id,
      stripeCustomerMode: currentStripeMode(),
    },
    {merge: true}
  );

  return customer.id;
}

async function getStripeCustomerForUser(stripe, userRef, userId, email) {
  const userDoc = await userRef.get();
  const userData = userDoc.data() || {};
  const storedCustomerId = userData.stripeCustomerId;
  const storedMode = userData.stripeCustomerMode;
  const mode = currentStripeMode();

  if (storedCustomerId && storedMode === mode) {
    try {
      await stripe.customers.retrieve(storedCustomerId);
      return storedCustomerId;
    } catch (error) {
      const code = error?.code || "";
      const message = error?.message || "";

      if (code !== "resource_missing" && !message.includes("No such customer")) {
        throw error;
      }
    }
  }

  return createStripeCustomerForUser(stripe, userRef, userId, email);
}
const admin = require("firebase-admin");

admin.initializeApp();

exports.searchStorePlaces = onCall(
  {secrets: [googleMapsApiKey]},
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "User is not authenticated.");
    }

    const query = request.data?.query?.toString().trim();
    if (!query || query.length < 3 || query.length > 160) {
      throw new HttpsError(
        "invalid-argument",
        "Enter at least 3 characters to search for a store."
      );
    }

    const body = {
      textQuery: query,
      pageSize: 6,
      includedType: "store",
      strictTypeFiltering: false,
    };

    const latitude = Number(request.data?.latitude);
    const longitude = Number(request.data?.longitude);

    if (Number.isFinite(latitude) && Number.isFinite(longitude)) {
      body.locationBias = {
        circle: {
          center: {latitude, longitude},
          radius: 50000,
        },
      };
    }

    const response = await fetch(
      "https://places.googleapis.com/v1/places:searchText",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Goog-Api-Key": googleMapsApiKey.value(),
          "X-Goog-FieldMask": [
            "places.id",
            "places.displayName",
            "places.formattedAddress",
            "places.location",
            "places.regularOpeningHours",
            "places.utcOffsetMinutes",
          ].join(","),
        },
        body: JSON.stringify(body),
      }
    );

    const result = await response.json();

    if (!response.ok) {
      console.error("Google Places search failed", result);
      throw new HttpsError(
        "internal",
        "Store search is temporarily unavailable."
      );
    }

    return {
      places: (result.places || []).map((place) => ({
        placeId: place.id,
        name: place.displayName?.text || "Store",
        address: place.formattedAddress || "",
        latitude: place.location?.latitude,
        longitude: place.location?.longitude,
        hours: place.regularOpeningHours?.weekdayDescriptions || [],
        hoursPeriods: place.regularOpeningHours?.periods || [],
        utcOffsetMinutes: place.utcOffsetMinutes,
      })),
    };
  }
);

exports.findClosestSupplyStore = onCall(
  {secrets: [googleMapsApiKey]},
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "User is not authenticated.");
    }

    const latitude = Number(request.data?.latitude);
    const longitude = Number(request.data?.longitude);
    const tradeType = request.data?.tradeType?.toString().trim();

    if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) {
      throw new HttpsError(
        "invalid-argument",
        "A valid customer location is required."
      );
    }

    const tradeKeywords = {
      Plumbing: "plumbing supply store",
      Electrical: "electrical supply store",
      HVAC: "hvac supply store",
    };
    const keyword = tradeKeywords[tradeType] || "supply store";

    const response = await fetch(
      "https://places.googleapis.com/v1/places:searchText",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Goog-Api-Key": googleMapsApiKey.value(),
          "X-Goog-FieldMask": [
            "places.id",
            "places.displayName",
            "places.formattedAddress",
            "places.location",
            "places.regularOpeningHours",
          ].join(","),
        },
        body: JSON.stringify({
          textQuery: keyword,
          pageSize: 10,
          includedType: "store",
          strictTypeFiltering: false,
          locationBias: {
            circle: {
              center: {latitude, longitude},
              radius: 50000,
            },
          },
        }),
      }
    );

    const result = await response.json();

    if (!response.ok) {
      console.error("Google Places checkout search failed", result);
      throw new HttpsError(
        "internal",
        "Store search is temporarily unavailable."
      );
    }

    const places = (result.places || [])
      .map((place) => {
        const storeLat = Number(place.location?.latitude);
        const storeLng = Number(place.location?.longitude);

        if (!Number.isFinite(storeLat) || !Number.isFinite(storeLng)) {
          return null;
        }

        return {
          id: place.id,
          placeId: place.id,
          storeName: place.displayName?.text || "Supply Store",
          address: place.formattedAddress || "",
          lat: storeLat,
          lng: storeLng,
          openNow: place.regularOpeningHours?.openNow === true,
          distanceMeters: distanceBetweenMeters(
            latitude,
            longitude,
            storeLat,
            storeLng
          ),
        };
      })
      .filter(Boolean)
      .sort((a, b) => {
        if (a.openNow !== b.openNow) {
          return a.openNow ? -1 : 1;
        }

        return a.distanceMeters - b.distanceMeters;
      });

    return {store: places[0] || null};
  }
);

exports.retryOrderAtNextStore = onCall(
  {secrets: [googleMapsApiKey]},
  async (request) => {
    const userId = request.auth?.uid;
    const orderId = request.data?.orderId;

    if (!userId) {
      throw new HttpsError("unauthenticated", "User is not authenticated.");
    }

    if (typeof orderId !== "string" || orderId.length === 0) {
      throw new HttpsError("invalid-argument", "Missing order ID.");
    }

    const orderRef = admin.firestore().collection("orders").doc(orderId);
    const orderSnapshot = await orderRef.get();

    if (!orderSnapshot.exists) {
      throw new HttpsError("not-found", "Order was not found.");
    }

    const order = orderSnapshot.data() || {};

    if (order.userId !== userId) {
      throw new HttpsError(
        "permission-denied",
        "You can only update your own order."
      );
    }

    if (order.status !== "Store Issue") {
      throw new HttpsError(
        "failed-precondition",
        "This order is not waiting for a new store."
      );
    }

    const latitude = Number(order.customerLat);
    const longitude = Number(order.customerLng);

    if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) {
      throw new HttpsError(
        "failed-precondition",
        "This order is missing a customer location."
      );
    }

    const tradeKeywords = {
      Plumbing: "plumbing supply store",
      Electrical: "electrical supply store",
      HVAC: "hvac supply store",
    };
    const keyword = tradeKeywords[order.tradeType] || "supply store";
    const excludedStoreIds = new Set(
      Array.isArray(order.unavailableStoreIds) ? order.unavailableStoreIds : []
    );

    if (order.storeId) {
      excludedStoreIds.add(order.storeId);
    }

    const response = await fetch(
      "https://places.googleapis.com/v1/places:searchText",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Goog-Api-Key": googleMapsApiKey.value(),
          "X-Goog-FieldMask": [
            "places.id",
            "places.displayName",
            "places.formattedAddress",
            "places.location",
            "places.regularOpeningHours",
          ].join(","),
        },
        body: JSON.stringify({
          textQuery: keyword,
          pageSize: 20,
          includedType: "store",
          strictTypeFiltering: false,
          locationBias: {
            circle: {
              center: {latitude, longitude},
              radius: 50000,
            },
          },
        }),
      }
    );

    const result = await response.json();

    if (!response.ok) {
      console.error("Google Places retry search failed", result);
      throw new HttpsError(
        "internal",
        "Store search is temporarily unavailable."
      );
    }

    const stores = (result.places || [])
      .map((place) => {
        const storeLat = Number(place.location?.latitude);
        const storeLng = Number(place.location?.longitude);

        if (
          excludedStoreIds.has(place.id) ||
          !Number.isFinite(storeLat) ||
          !Number.isFinite(storeLng)
        ) {
          return null;
        }

        return {
          id: place.id,
          placeId: place.id,
          storeName: place.displayName?.text || "Supply Store",
          address: place.formattedAddress || "",
          lat: storeLat,
          lng: storeLng,
          openNow: place.regularOpeningHours?.openNow === true,
          distanceMeters: distanceBetweenMeters(
            latitude,
            longitude,
            storeLat,
            storeLng
          ),
        };
      })
      .filter(Boolean)
      .sort((a, b) => {
        if (a.openNow !== b.openNow) {
          return a.openNow ? -1 : 1;
        }

        return a.distanceMeters - b.distanceMeters;
      });

    if (stores.length === 0) {
      throw new HttpsError(
        "not-found",
        "No other nearby supply store was found for this order."
      );
    }

    const nextStore = stores[0];

    await orderRef.set(
      {
        status: order.driverId ? "Accepted" : "Pending",
        dispatchStatus: order.driverId ? "driver_continuing" : "queued",
        dispatchReason: "customer_selected_next_store",
        driverId: order.driverId || null,
        storeId: nextStore.id,
        storeName: nextStore.storeName,
        storeLat: nextStore.lat,
        storeLng: nextStore.lng,
        previousStoreIssues: admin.firestore.FieldValue.arrayUnion({
          storeId: order.storeId || null,
          storeName: order.storeName || null,
          reason: order.driverCancelReason || "Not in stock",
          reasonCode: order.driverCancelReasonCode || "not_in_stock",
          reportedAt: admin.firestore.Timestamp.now(),
        }),
        customerActionResolvedAt:
          admin.firestore.FieldValue.serverTimestamp(),
      },
      {merge: true}
    );

    if (!order.driverId) {
      await dispatchPendingOrder(orderRef, "customer_selected_next_store");
    }

    return {store: nextStore};
  }
);

exports.getDirectionsRoute = onCall(
  {secrets: [googleMapsApiKey]},
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "User is not authenticated.");
    }

    const originLat = Number(request.data?.originLat);
    const originLng = Number(request.data?.originLng);
    const destinationLat = Number(request.data?.destinationLat);
    const destinationLng = Number(request.data?.destinationLng);

    if (
      !Number.isFinite(originLat) ||
      !Number.isFinite(originLng) ||
      !Number.isFinite(destinationLat) ||
      !Number.isFinite(destinationLng)
    ) {
      throw new HttpsError("invalid-argument", "A valid route is required.");
    }

    const params = new URLSearchParams({
      origin: `${originLat},${originLng}`,
      destination: `${destinationLat},${destinationLng}`,
      key: googleMapsApiKey.value(),
    });

    const response = await fetch(
      `https://maps.googleapis.com/maps/api/directions/json?${params}`
    );
    const result = await response.json();

    if (!response.ok || result.status !== "OK") {
      console.error("Google Directions failed", result);
      throw new HttpsError(
        "internal",
        result.error_message || "Route is temporarily unavailable."
      );
    }

    const route = result.routes?.[0];
    const leg = route?.legs?.[0];

    if (!route || !leg) {
      throw new HttpsError("not-found", "No route was found.");
    }

    return {
      distanceText: leg.distance?.text || "",
      distanceMeters: leg.distance?.value || 0,
      durationText: leg.duration?.text || "",
      durationSeconds: leg.duration?.value || 0,
      polyline: route.overview_polyline?.points || "",
    };
  }
);

exports.autocompleteAddress = onCall(
  {secrets: [googleMapsApiKey]},
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "User is not authenticated.");
    }

    const input = request.data?.input?.toString().trim();

    if (!input) {
      return {predictions: []};
    }

    if (input.length > 120) {
      throw new HttpsError("invalid-argument", "Address search is too long.");
    }

    const params = new URLSearchParams({
      input,
      components: "country:us",
      key: googleMapsApiKey.value(),
    });

    const response = await fetch(
      `https://maps.googleapis.com/maps/api/place/autocomplete/json?${params}`
    );
    const result = await response.json();

    if (!response.ok || !["OK", "ZERO_RESULTS"].includes(result.status)) {
      console.error("Google Autocomplete failed", result);
      throw new HttpsError(
        "internal",
        result.error_message || "Address search is temporarily unavailable."
      );
    }

    return {
      predictions: (result.predictions || []).map((prediction) => ({
        place_id: prediction.place_id,
        description: prediction.description,
        structured_formatting: prediction.structured_formatting || {},
      })),
    };
  }
);

exports.getPlaceDetails = onCall(
  {secrets: [googleMapsApiKey]},
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "User is not authenticated.");
    }

    const placeId = request.data?.placeId?.toString().trim();

    if (!placeId) {
      throw new HttpsError("invalid-argument", "Missing place ID.");
    }

    const params = new URLSearchParams({
      place_id: placeId,
      fields: "geometry,formatted_address",
      key: googleMapsApiKey.value(),
    });

    const response = await fetch(
      `https://maps.googleapis.com/maps/api/place/details/json?${params}`
    );
    const result = await response.json();

    if (!response.ok || result.status !== "OK") {
      console.error("Google Place Details failed", result);
      throw new HttpsError(
        "internal",
        result.error_message || "Place details are temporarily unavailable."
      );
    }

    const location = result.result?.geometry?.location;
    const lat = Number(location?.lat);
    const lng = Number(location?.lng);

    if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
      throw new HttpsError("not-found", "This place has no usable location.");
    }

    return {
      lat,
      lng,
      address: result.result?.formatted_address || "",
    };
  }
);

exports.acceptOrder = onCall(async (request) => {
  const driverId = request.auth?.uid;
  const orderId = request.data?.orderId;

  if (!driverId) {
    throw new HttpsError("unauthenticated", "Driver is not authenticated.");
  }

  if (typeof orderId !== "string" || orderId.length === 0) {
    throw new HttpsError("invalid-argument", "Missing order ID.");
  }

  const orderRef = admin.firestore().collection("orders").doc(orderId);
  const driverRef = admin.firestore().collection("drivers").doc(driverId);

  return admin.firestore().runTransaction(async (transaction) => {
    const [orderSnapshot, driverSnapshot] = await Promise.all([
      transaction.get(orderRef),
      transaction.get(driverRef),
    ]);

    if (!orderSnapshot.exists) {
      throw new HttpsError("not-found", "Order was not found.");
    }

    if (!driverSnapshot.exists) {
      throw new HttpsError("failed-precondition", "Driver profile was not found.");
    }

    const order = orderSnapshot.data() || {};
    const driver = driverSnapshot.data() || {};

    if (order.status !== "Pending" || order.driverId) {
      throw new HttpsError(
        "already-exists",
        "Order was already accepted by another driver."
      );
    }

    const eligibleDrivers = Array.isArray(order.eligibleDrivers)
      ? order.eligibleDrivers
      : [];

    if (!eligibleDrivers.includes(driverId)) {
      throw new HttpsError(
        "permission-denied",
        "This order is not available to your driver account."
      );
    }

    if (driver.active !== true) {
      throw new HttpsError(
        "failed-precondition",
        "Go online before accepting deliveries."
      );
    }

    if (driver.isBusy === true) {
      throw new HttpsError(
        "failed-precondition",
        "Finish your active delivery before accepting another order."
      );
    }

    if (
      order.requiresCarDelivery === true &&
      !motorVehicleTypes.has(driver.vehicleType)
    ) {
      throw new HttpsError(
        "permission-denied",
        "This order requires a car, pickup truck, or van."
      );
    }

    const driverLat = Number(driver.lat);
    const driverLng = Number(driver.lng);

    transaction.update(orderRef, {
      status: "Accepted",
      driverId,
      acceptedAt: admin.firestore.FieldValue.serverTimestamp(),
      dispatchStatus: "accepted",
      ...(Number.isFinite(driverLat) && Number.isFinite(driverLng)
        ? {
            acceptedDriverLocation: new admin.firestore.GeoPoint(
              driverLat,
              driverLng
            ),
          }
        : {}),
    });

    transaction.set(
      driverRef,
      {
        isBusy: true,
        activeOrderId: orderId,
        activeOrderAcceptedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      {merge: true}
    );

    eligibleDrivers.forEach((eligibleDriverId) => {
      transaction.delete(driverAvailableOrderRef(eligibleDriverId, orderId));
    });

    return {
      success: true,
      orderId,
      storeLat: order.storeLat ?? null,
      storeLng: order.storeLng ?? null,
    };
  });
});

exports.markOrderPickedUp = onCall(async (request) => {
  const driverId = request.auth?.uid;
  const orderId = request.data?.orderId;

  if (!driverId) {
    throw new HttpsError("unauthenticated", "Driver is not authenticated.");
  }

  if (typeof orderId !== "string" || orderId.length === 0) {
    throw new HttpsError("invalid-argument", "Missing order ID.");
  }

  const orderRef = admin.firestore().collection("orders").doc(orderId);
  const driverRef = admin.firestore().collection("drivers").doc(driverId);

  return admin.firestore().runTransaction(async (transaction) => {
    const [orderSnapshot, driverSnapshot] = await Promise.all([
      transaction.get(orderRef),
      transaction.get(driverRef),
    ]);

    if (!orderSnapshot.exists) {
      throw new HttpsError("not-found", "Order was not found.");
    }

    if (!driverSnapshot.exists) {
      throw new HttpsError("failed-precondition", "Driver profile was not found.");
    }

    const order = orderSnapshot.data() || {};
    const driver = driverSnapshot.data() || {};

    if (order.driverId !== driverId) {
      throw new HttpsError(
        "permission-denied",
        "This order is assigned to another driver."
      );
    }

    if (order.status !== "Accepted") {
      throw new HttpsError(
        "failed-precondition",
        "This order is not ready to be marked picked up."
      );
    }

    const storeLat = Number(order.storeLat);
    const storeLng = Number(order.storeLng);
    const driverLat = Number(driver.lat);
    const driverLng = Number(driver.lng);
    const lastUpdated = driver.lastUpdated;

    if (
      !Number.isFinite(storeLat) ||
      !Number.isFinite(storeLng) ||
      !Number.isFinite(driverLat) ||
      !Number.isFinite(driverLng)
    ) {
      throw new HttpsError(
        "failed-precondition",
        "A current driver or store location is unavailable."
      );
    }

    if (
      !lastUpdated ||
      typeof lastUpdated.toMillis !== "function" ||
      Date.now() - lastUpdated.toMillis() > maxDriverLocationAgeMs
    ) {
      throw new HttpsError(
        "failed-precondition",
        "Your location is out of date. Refresh GPS and try again."
      );
    }

    const distanceMeters = distanceBetweenMeters(
      storeLat,
      storeLng,
      driverLat,
      driverLng
    );

    if (distanceMeters > pickupRadiusMeters) {
      throw new HttpsError(
        "failed-precondition",
        `You must be within ${formatDistanceImperial(pickupRadiusMeters)} of the store to mark this order picked up.`
      );
    }

    transaction.update(orderRef, {
      status: "Picked Up",
      pickedUpAt: admin.firestore.FieldValue.serverTimestamp(),
      pickupLocation: new admin.firestore.GeoPoint(driverLat, driverLng),
      pickupDistanceMeters: Math.round(distanceMeters),
    });

    return {
      success: true,
      distanceMeters: Math.round(distanceMeters),
    };
  });
});

exports.markOrderDelivered = onCall({secrets: [stripeSecretKey]}, async (request) => {
  const driverId = request.auth?.uid;
  const orderId = request.data?.orderId;
  const deliveryPin = request.data?.deliveryPin?.toString().trim();

  if (!driverId) {
    throw new HttpsError("unauthenticated", "Driver is not authenticated.");
  }

  if (typeof orderId !== "string" || orderId.length === 0) {
    throw new HttpsError("invalid-argument", "Missing order ID.");
  }

  if (!/^\d{4}$/.test(deliveryPin || "")) {
    throw new HttpsError("invalid-argument", "Enter the customer's 4-digit delivery PIN.");
  }

  const orderRef = admin.firestore().collection("orders").doc(orderId);
  const driverRef = admin.firestore().collection("drivers").doc(driverId);

  await admin.firestore().runTransaction(async (transaction) => {
    const [orderSnapshot, driverSnapshot] = await Promise.all([
      transaction.get(orderRef),
      transaction.get(driverRef),
    ]);

    if (!orderSnapshot.exists) {
      throw new HttpsError("not-found", "Order was not found.");
    }

    if (!driverSnapshot.exists) {
      throw new HttpsError("failed-precondition", "Driver profile was not found.");
    }

    const order = orderSnapshot.data() || {};
    const driver = driverSnapshot.data() || {};
    const customerId = order.userId;

    if (typeof customerId !== "string" || customerId.length === 0) {
      throw new HttpsError(
        "failed-precondition",
        "This order is missing customer delivery PIN details."
      );
    }

    const customerRef = admin.firestore().collection("users").doc(customerId);
    const customerSnapshot = await transaction.get(customerRef);
    const customer = customerSnapshot.data() || {};
    const expectedPin = customer.deliveryPin?.toString();

    if (!/^\d{4}$/.test(expectedPin || "")) {
      throw new HttpsError(
        "failed-precondition",
        "The customer does not have a delivery PIN yet."
      );
    }

    if (deliveryPin !== expectedPin) {
      throw new HttpsError("permission-denied", "Incorrect delivery PIN.");
    }

    if (order.driverId !== driverId) {
      throw new HttpsError(
        "permission-denied",
        "This order is assigned to another driver."
      );
    }

    const pickupProofPhotoUrl = order.pickupProofPhotoUrl?.toString() || "";
    const pickupProofPhotoPath = order.pickupProofPhotoPath?.toString() || "";
    const expectedProofPathPrefix = `pickup_proofs/${orderId}/`;

    if (
      !pickupProofPhotoUrl ||
      !pickupProofPhotoPath.startsWith(expectedProofPathPrefix) ||
      order.pickupProofUploadedBy !== driverId
    ) {
      throw new HttpsError(
        "failed-precondition",
        "Upload a photo of the item or receipt before marking this order delivered."
      );
    }

    if (order.status !== "Picked Up") {
      throw new HttpsError(
        "failed-precondition",
        "This order is not ready to be marked delivered."
      );
    }

    const driverTipCents =
      Number(order.tipCents) ||
      Math.round(Number(order.tip || 0) * 100);
    const safeDriverTipCents = Number.isFinite(driverTipCents) ?
      Math.max(0, driverTipCents) :
      0;
    const driverPayCents = driverBasePayCents + safeDriverTipCents;

    transaction.update(orderRef, {
      status: "Delivered",
      deliveredAt: admin.firestore.FieldValue.serverTimestamp(),
      deliveryPinVerifiedAt: admin.firestore.FieldValue.serverTimestamp(),
      deliveryPinVerifiedBy: driverId,
      driverBasePay: driverBasePayCents / 100,
      driverBasePayCents,
      driverTip: safeDriverTipCents / 100,
      driverTipCents: safeDriverTipCents,
      driverPay: driverPayCents / 100,
      driverPayCents,
      driverPayoutStatus: "pending_withdrawal",
    });

    transaction.set(
      driverRef,
      {
        earnings: admin.firestore.FieldValue.increment(driverPayCents / 100),
        careerEarnings: admin.firestore.FieldValue.increment(driverPayCents / 100),
        isBusy: false,
      },
      {merge: true}
    );
  });

  return {
    success: true,
    payoutStatus: "pending_withdrawal",
    driverPayCents,
  };
});

exports.driverCancelOrder = onCall(async (request) => {
  const driverId = request.auth?.uid;
  const orderId = request.data?.orderId;
  const reasonCode = request.data?.reasonCode?.toString();

  const cancelReasons = {
    vehicle_broke_down: "Vehicle broke down",
    payment_problem: "Payment problem",
    not_in_stock: "Not in stock",
  };

  if (!driverId) {
    throw new HttpsError("unauthenticated", "Driver is not authenticated.");
  }

  if (typeof orderId !== "string" || orderId.length === 0) {
    throw new HttpsError("invalid-argument", "Missing order ID.");
  }

  if (!Object.prototype.hasOwnProperty.call(cancelReasons, reasonCode)) {
    throw new HttpsError(
      "invalid-argument",
      "Choose a cancellation reason before cancelling this order."
    );
  }

  const orderRef = admin.firestore().collection("orders").doc(orderId);
  const driverRef = admin.firestore().collection("drivers").doc(driverId);
  const isNotInStock = reasonCode === "not_in_stock";
  let shouldDispatch = false;

  await admin.firestore().runTransaction(async (transaction) => {
    const [orderSnapshot, driverSnapshot] = await Promise.all([
      transaction.get(orderRef),
      transaction.get(driverRef),
    ]);

    if (!orderSnapshot.exists) {
      throw new HttpsError("not-found", "Order was not found.");
    }

    if (!driverSnapshot.exists) {
      throw new HttpsError("failed-precondition", "Driver profile was not found.");
    }

    const order = orderSnapshot.data() || {};
    const status = order.status?.toString() || "";

    if (order.driverId !== driverId) {
      throw new HttpsError(
        "permission-denied",
        "This order is assigned to another driver."
      );
    }

    if (status === "Picked Up") {
      throw new HttpsError(
        "failed-precondition",
        "This order has already been picked up. Contact support if there is a problem."
      );
    }

    if (status !== "Accepted" && status !== "Store Issue") {
      throw new HttpsError(
        "failed-precondition",
        "This order can no longer be cancelled here."
      );
    }

    const unavailableStoreId = order.storeId?.toString();
    const cancellationEntry = {
      driverId,
      reason: cancelReasons[reasonCode],
      reasonCode,
      cancelledAt: admin.firestore.Timestamp.now(),
    };

    const orderUpdate = {
      status: isNotInStock ? "Store Issue" : "Pending",
      driverId: isNotInStock ? driverId : null,
      dispatchStatus: isNotInStock ? "waiting_for_customer" : "queued",
      dispatchReason: isNotInStock ? "store_issue" : "driver_cancelled",
      driverCancelReason: cancelReasons[reasonCode],
      driverCancelReasonCode: reasonCode,
      driverCancelledBy: driverId,
      driverCancelledAt: admin.firestore.FieldValue.serverTimestamp(),
      driverCancellationHistory:
        admin.firestore.FieldValue.arrayUnion(cancellationEntry),
      ...(isNotInStock && unavailableStoreId
        ? {
            unavailableStoreIds:
              admin.firestore.FieldValue.arrayUnion(unavailableStoreId),
          }
        : {}),
      ...(!isNotInStock
        ? {
            eligibleDrivers:
              admin.firestore.FieldValue.arrayRemove(driverId),
            cancelledDriverIds:
              admin.firestore.FieldValue.arrayUnion(driverId),
          }
        : {}),
    };

    transaction.update(orderRef, orderUpdate);
    transaction.set(
      driverRef,
      {
        isBusy: isNotInStock,
        ...(isNotInStock
          ? {
              activeOrderId: orderId,
            }
          : {
              activeOrderId: admin.firestore.FieldValue.delete(),
              activeOrderAcceptedAt: admin.firestore.FieldValue.delete(),
            }),
      },
      {merge: true}
    );

    shouldDispatch = !isNotInStock;
  });

  if (shouldDispatch) {
    await dispatchPendingOrder(orderRef, "driver_cancelled");
  }

  return {
    success: true,
    status: isNotInStock ? "Store Issue" : "Pending",
    isWaitingForCustomer: isNotInStock,
  };
});

exports.syncDriverAvailability = onCall(async (request) => {
  const driverId = request.auth?.uid;

  if (!driverId) {
    throw new HttpsError("unauthenticated", "Driver is not authenticated.");
  }

  const activeOrders = await admin
    .firestore()
    .collection("orders")
    .where("driverId", "==", driverId)
    .where("status", "in", ["Accepted", "Picked Up", "Store Issue"])
    .limit(1)
    .get();

  if (!activeOrders.empty) {
    return {
      isBusy: true,
      activeOrderId: activeOrders.docs[0].id,
    };
  }

  await admin
    .firestore()
    .collection("drivers")
    .doc(driverId)
    .set(
      {
        isBusy: false,
        activeOrderId: admin.firestore.FieldValue.delete(),
        activeOrderAcceptedAt: admin.firestore.FieldValue.delete(),
      },
      {merge: true}
    );

  return {
    isBusy: false,
    activeOrderId: null,
  };
});

exports.updateDriverOnlineStatus = onCall(async (request) => {
  const driverId = request.auth?.uid;
  const active = request.data?.active === true;

  if (!driverId) {
    throw new HttpsError("unauthenticated", "Driver is not authenticated.");
  }

  const db = admin.firestore();
  const driverRef = db.collection("drivers").doc(driverId);

  if (active) {
    await driverRef.set(
      {
        active: true,
        lastOnlineUpdate: admin.firestore.FieldValue.serverTimestamp(),
      },
      {merge: true}
    );

    return {
      success: true,
      active: true,
      removedOrderCount: 0,
    };
  }

  const activeOrders = await db
    .collection("orders")
    .where("driverId", "==", driverId)
    .where("status", "in", ["Accepted", "Picked Up", "Store Issue"])
    .limit(1)
    .get();

  if (!activeOrders.empty) {
    throw new HttpsError(
      "failed-precondition",
      "Cannot go offline when an order is active."
    );
  }

  const pendingOrders = await db
    .collection("orders")
    .where("status", "==", "Pending")
    .where("eligibleDrivers", "array-contains", driverId)
    .limit(50)
    .get();

  const batch = db.batch();
  batch.set(
    driverRef,
    {
      active: false,
      isBusy: false,
      activeOrderId: admin.firestore.FieldValue.delete(),
      activeOrderAcceptedAt: admin.firestore.FieldValue.delete(),
      lastOnlineUpdate: admin.firestore.FieldValue.serverTimestamp(),
      lastWentOfflineAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    {merge: true}
  );

  pendingOrders.docs.forEach((doc) => {
    batch.set(
      doc.ref,
      {
        eligibleDrivers: admin.firestore.FieldValue.arrayRemove(driverId),
        offlineDriverIds: admin.firestore.FieldValue.arrayUnion(driverId),
        dispatchStatus: "queued",
        dispatchReason: "driver_offline",
        lastDriverWentOfflineAt:
          admin.firestore.FieldValue.serverTimestamp(),
      },
      {merge: true}
    );
    batch.delete(driverAvailableOrderRef(driverId, doc.id));
  });

  await batch.commit();

  await Promise.all(
    pendingOrders.docs.map(async (doc) => {
      try {
        await dispatchPendingOrder(doc.ref, "driver_offline");
      } catch (error) {
        console.error(
          `Dispatch after driver offline failed for order ${doc.id}`,
          error
        );
      }
    })
  );

  return {
    success: true,
    active: false,
    removedOrderCount: pendingOrders.size,
  };
});

exports.createSetupIntent = onCall({secrets: [stripeSecretKey]}, async (request) => {
  const userId = request.auth?.uid;
  const stripe = getStripe();

  if (!userId) {
    throw new HttpsError("unauthenticated", "User not authenticated");
  }

  const userRef = admin.firestore().collection("users").doc(userId);
  const customerId = await getStripeCustomerForUser(
    stripe,
    userRef,
    userId,
    request.auth.token.email
  );

  // ✅ Create setup intent
  const setupIntent = await stripe.setupIntents.create({
    customer: customerId,
    automatic_payment_methods: { enabled: true },
  });

  return {
    clientSecret: setupIntent.client_secret,
    customerId: customerId,
  };
});

exports.getPaymentMethods = onCall({secrets: [stripeSecretKey]}, async (request) => {
  const userId = request.auth?.uid;
  const stripe = getStripe();

  if (!userId) {
    throw new HttpsError("unauthenticated", "User not authenticated");
  }

  const userRef = admin.firestore().collection("users").doc(userId);
  const customerId = await getStripeCustomerForUser(
    stripe,
    userRef,
    userId,
    request.auth.token.email
  );

  const paymentMethods = await stripe.paymentMethods.list({
    customer: customerId,
    type: "card",
  });

  return {
    hasPaymentMethod: paymentMethods.data.length > 0,

    paymentMethods: paymentMethods.data.map((pm) => ({
      id: pm.id,
      brand: pm.card.brand,
      last4: pm.card.last4,
    })),
  };
});

exports.createPaymentIntent = onCall({secrets: [stripeSecretKey]}, async (request) => {
  const userId = request.auth?.uid;
  const stripe = getStripe();

  if (!userId) {
    throw new HttpsError("unauthenticated", "User not authenticated");
  }

  const { amount } = request.data;
  const paymentMethodId = request.data.paymentMethodId;

  const userRef = admin.firestore().collection("users").doc(userId);
  const customerId = await getStripeCustomerForUser(
    stripe,
    userRef,
    userId,
    request.auth.token.email
  );

  if (!paymentMethodId) {
    throw new HttpsError("invalid-argument", "No payment method selected");
  }

  try {
    const paymentIntent = await stripe.paymentIntents.create({
      amount,
      currency: "usd",
      customer: customerId,
      payment_method: paymentMethodId,
      off_session: true,
      confirm: true,
      payment_method_types: ["card"],
    });

    return {
      success: true,
      paymentIntentId: paymentIntent.id,
      amount: paymentIntent.amount,
      currency: paymentIntent.currency,
    };
  } catch (error) {
    console.error("❌ STRIPE ERROR:", error);
    throw new HttpsError("internal", error.message || "Payment failed.");
  }
});

exports.placeOrder = onCall({secrets: [stripeSecretKey]}, async (request) => {
  const userId = request.auth?.uid;
  const stripe = getStripe();

  if (!userId) {
    throw new HttpsError("unauthenticated", "User is not authenticated.");
  }

  const paymentMethodId = request.data?.paymentMethodId?.toString();
  const items = Array.isArray(request.data?.items) ? request.data.items : [];
  const store = request.data?.store || {};
  const tradeType = request.data?.tradeType?.toString().trim() || "Trade";
  const customerLat = Number(request.data?.customerLat);
  const customerLng = Number(request.data?.customerLng);
  const customerAddress =
    request.data?.customerAddress?.toString().trim() || "Customer location";
  const customerName =
    request.data?.customerName?.toString().trim() || "Unknown";
  const tipCents = centsFromAmount(request.data?.tip);

  if (!paymentMethodId) {
    throw new HttpsError("invalid-argument", "Select a payment method.");
  }

  if (!Number.isFinite(customerLat) || !Number.isFinite(customerLng)) {
    throw new HttpsError(
      "invalid-argument",
      "A valid customer location is required."
    );
  }

  if (items.length === 0) {
    throw new HttpsError("invalid-argument", "Add items before checkout.");
  }

  const storeLat = Number(store.lat);
  const storeLng = Number(store.lng);

  if (!Number.isFinite(storeLat) || !Number.isFinite(storeLng)) {
    throw new HttpsError(
      "invalid-argument",
      "A valid supply store is required."
    );
  }

  const sanitizedItems = items.map((item) => {
    const itemId = item?.itemId?.toString().trim();
    const catalogItem = itemId ? getCatalogItem(itemId) : null;
    const quantity = Number.parseInt(item?.quantity, 10);

    if (
      !catalogItem ||
      catalogItem.tradeType !== tradeType ||
      !Number.isInteger(quantity) ||
      quantity <= 0
    ) {
      throw new HttpsError(
        "invalid-argument",
        "One or more cart items could not be checked out."
      );
    }

    const priceCents = catalogItem.priceCents;

    return {
      itemId,
      name: catalogItem.name,
      price: dollarsFromCents(priceCents),
      image: catalogItem.image,
      description: catalogItem.description || "",
      quantity,
      categories: catalogItem.categories || [],
      specialtyStoreTag: catalogItem.specialtyStoreTag || null,
      requiresCarDelivery: catalogItem.requiresCarDelivery === true,
      priceCents,
      lineTotalCents: priceCents * quantity,
    };
  });

  const subtotalCents = sanitizedItems.reduce(
    (sum, item) => sum + item.lineTotalCents,
    0
  );
  const taxCents = Math.round(subtotalCents * taxRate);
  const deliveryFeeCents = minDeliveryFeeCents;
  const totalCents =
    subtotalCents + deliveryFeeCents + taxCents + tipCents;
  const requiresCarDelivery = sanitizedItems.some(
    (item) => item.requiresCarDelivery
  );

  const userRef = admin.firestore().collection("users").doc(userId);
  const customerId = await getStripeCustomerForUser(
    stripe,
    userRef,
    userId,
    request.auth.token.email
  );

  const orderRef = admin.firestore().collection("orders").doc();
  const baseOrder = {
    customerLat,
    customerLng,
    customerAddress,
    customerName,
    date: new Date().toISOString(),
    createdAt: admin.firestore.FieldValue.serverTimestamp(),

    storeLat,
    storeLng,
    storeId: store.id?.toString() || store.placeId?.toString() || null,
    storeName: store.storeName?.toString() || store.name?.toString() || "Store",
    storeAddress: store.address?.toString() || "",

    items: sanitizedItems.map((item) => ({
      itemId: item.itemId,
      name: item.name,
      price: item.price,
      image: item.image,
      description: item.description,
      quantity: item.quantity,
      categories: item.categories,
      specialtyStoreTag: item.specialtyStoreTag,
      requiresCarDelivery: item.requiresCarDelivery,
    })),

    subtotal: dollarsFromCents(subtotalCents),
    subtotalCents,
    deliveryFee: dollarsFromCents(deliveryFeeCents),
    deliveryFeeCents,
    tax: dollarsFromCents(taxCents),
    taxCents,
    tip: dollarsFromCents(tipCents),
    tipCents,
    total: dollarsFromCents(totalCents),
    paymentAmountCents: totalCents,
    paymentStatus: "payment_pending",

    status: "Payment Pending",
    dispatchStatus: "payment_pending",
    dispatchAttempts: 0,
    tradeType,
    requiresCarDelivery,
    eligibleDrivers: [],
    userId,
  };

  const eligibleDrivers = await findEligibleDrivers(baseOrder);

  if (eligibleDrivers.length === 0) {
    throw new HttpsError(
      "failed-precondition",
      "No nearby drivers available right now."
    );
  }

  await orderRef.set({
    ...baseOrder,
    eligibleDrivers,
  });

  let paymentIntent;

  try {
    paymentIntent = await stripe.paymentIntents.create(
      {
        amount: totalCents,
        currency: "usd",
        customer: customerId,
        payment_method: paymentMethodId,
        off_session: true,
        confirm: true,
        payment_method_types: ["card"],
        metadata: {
          orderId: orderRef.id,
          userId,
          tradeType,
        },
      },
      {idempotencyKey: `place-order-${orderRef.id}`}
    );
  } catch (error) {
    await orderRef.set(
      {
        status: "Payment Failed",
        paymentStatus: "payment_failed",
        paymentError: error.message || "Stripe payment failed.",
        paymentFailedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      {merge: true}
    );

    console.error("❌ STRIPE PLACE ORDER ERROR:", error);
    throw new HttpsError(
      "internal",
      error.message || "Payment could not be completed."
    );
  }

  await orderRef.set(
    {
      status: "Pending",
      dispatchStatus: "queued",
      paymentStatus: "paid",
      stripePaymentIntentId: paymentIntent.id,
      paymentAmountCents: paymentIntent.amount,
      paymentPaidAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    {merge: true}
  );

  await dispatchPendingOrder(orderRef, "order_created");

  return {
    success: true,
    orderId: orderRef.id,
    paymentIntentId: paymentIntent.id,
    amount: paymentIntent.amount,
    currency: paymentIntent.currency,
    eligibleDriverCount: eligibleDrivers.length,
  };
});

exports.cancelStoreIssueOrder = onCall({secrets: [stripeSecretKey]}, async (request) => {
  const userId = request.auth?.uid;
  const orderId = request.data?.orderId;
  const stripe = getStripe();

  if (!userId) {
    throw new HttpsError("unauthenticated", "User is not authenticated.");
  }

  if (typeof orderId !== "string" || orderId.length === 0) {
    throw new HttpsError("invalid-argument", "Missing order ID.");
  }

  const orderRef = admin.firestore().collection("orders").doc(orderId);
  const cancellationFeeCents = 1200;

  const orderForRefund = await admin.firestore().runTransaction(async (transaction) => {
    const orderSnapshot = await transaction.get(orderRef);

    if (!orderSnapshot.exists) {
      throw new HttpsError("not-found", "Order was not found.");
    }

    const order = orderSnapshot.data() || {};

    if (order.userId !== userId) {
      throw new HttpsError(
        "permission-denied",
        "You can only cancel your own order."
      );
    }

    if (order.status !== "Store Issue") {
      throw new HttpsError(
        "failed-precondition",
        "This order can no longer be cancelled here."
      );
    }

    if (order.customerCancellationRefundId) {
      throw new HttpsError(
        "already-exists",
        "This order was already refunded."
      );
    }

    if (order.refundInProgress === true) {
      throw new HttpsError(
        "aborted",
        "This cancellation is already being processed."
      );
    }

    const paymentIntentId = order.stripePaymentIntentId;
    const chargedAmountCents =
      Number(order.paymentAmountCents) || Math.round(Number(order.total || 0) * 100);

    if (!paymentIntentId) {
      throw new HttpsError(
        "failed-precondition",
        "This order is missing its Stripe payment reference."
      );
    }

    if (!Number.isFinite(chargedAmountCents) || chargedAmountCents <= 0) {
      throw new HttpsError(
        "failed-precondition",
        "This order is missing its payment amount."
      );
    }

    transaction.update(orderRef, {
      refundInProgress: true,
      refundRequestedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return {
      driverId: order.driverId || null,
      paymentIntentId,
      chargedAmountCents,
      alreadyPaid: order.customerCancellationFeePaid === true,
    };
  });

  const refundAmountCents = Math.max(
    orderForRefund.chargedAmountCents - cancellationFeeCents,
    0
  );

  let refund = null;

  try {
    if (refundAmountCents > 0) {
      refund = await stripe.refunds.create(
        {
          payment_intent: orderForRefund.paymentIntentId,
          amount: refundAmountCents,
          reason: "requested_by_customer",
          metadata: {
            orderId,
            cancellationFeeCents: cancellationFeeCents.toString(),
          },
        },
        {idempotencyKey: `store-issue-cancel-${orderId}`}
      );
    }
  } catch (error) {
    await orderRef.set(
      {
        refundInProgress: false,
        refundError: error.message || "Stripe refund failed.",
      },
      {merge: true}
    );

    console.error("❌ STRIPE REFUND ERROR:", error);
    throw new HttpsError("internal", "Could not refund this order.");
  }

  await admin.firestore().runTransaction(async (transaction) => {
    const orderSnapshot = await transaction.get(orderRef);
    const order = orderSnapshot.data() || {};

    if (order.customerCancellationRefundId) {
      return;
    }

    const driverId = order.driverId || orderForRefund.driverId;
    const shouldPayDriver = driverId && order.customerCancellationFeePaid !== true;

    transaction.update(orderRef, {
      status: "Customer Cancelled",
      dispatchStatus: "customer_cancelled",
      customerCancellationFee: cancellationFeeCents / 100,
      customerCancellationFeeCents: cancellationFeeCents,
      customerCancellationFeePaid: true,
      customerCancellationConfirmed: true,
      customerCancelledAt: admin.firestore.FieldValue.serverTimestamp(),
      customerCancellationReason: "Store item not in stock",
      customerCancellationRefundAmountCents: refundAmountCents,
      customerCancellationRefundId: refund?.id || null,
      refundInProgress: false,
      ...(shouldPayDriver
        ? {
            driverPay: cancellationFeeCents / 100,
            driverPayCents: cancellationFeeCents,
            driverPayoutStatus: "pending_withdrawal",
          }
        : {}),
    });

    if (driverId) {
      const driverRef = admin.firestore().collection("drivers").doc(driverId);
      transaction.set(
        driverRef,
        {
          isBusy: false,
          ...(shouldPayDriver
            ? {
                earnings: admin.firestore.FieldValue.increment(
                  cancellationFeeCents / 100
                ),
                careerEarnings: admin.firestore.FieldValue.increment(
                  cancellationFeeCents / 100
                ),
              }
            : {}),
        },
        {merge: true}
      );
    }
  });

  return {
    success: true,
    refundAmountCents,
    cancellationFeeCents,
  };
});

exports.deletePaymentMethod = onCall({secrets: [stripeSecretKey]}, async (request) => {
  const userId = request.auth?.uid;
  const stripe = getStripe();

  if (!userId) {
    throw new Error("User not authenticated");
  }

  const paymentMethodId = request.data.paymentMethodId;

  if (!paymentMethodId) {
    throw new Error("Missing paymentMethodId");
  }

  // Detach payment method from customer
  await stripe.paymentMethods.detach(paymentMethodId);

  return {
    success: true,
  };
});

exports.createDriverDashboardLink = onCall({secrets: [stripeSecretKey]}, async (request) => {
  const userId = request.auth?.uid;
  const stripe = getStripe();

  if (!userId) {
    throw new HttpsError("unauthenticated", "User not authenticated");
  }

  const driverRef = admin.firestore().collection("drivers").doc(userId);
  const driverDoc = await driverRef.get();
  const driverData = driverDoc.data() || {};

  let stripeAccountId = driverData.stripeAccountId;

  if (!stripeAccountId) {
    const account = await stripe.accounts.create({
      type: "express",
      country: "US",
      email: request.auth.token.email,
      capabilities: {
        transfers: {requested: true},
      },
      metadata: {
        firebaseUID: userId,
      },
    });

    stripeAccountId = account.id;

    await driverRef.set(
      {
        stripeAccountId: stripeAccountId,
      },
      {merge: true}
    );
  }

  const account = await stripe.accounts.retrieve(stripeAccountId);
  const transfersActive = account.capabilities?.transfers === "active";

  if (!account.details_submitted || !account.payouts_enabled || !transfersActive) {
    const accountLink = await stripe.accountLinks.create({
      account: stripeAccountId,
      refresh_url: "https://thehelpersapp.com/stripe-refresh",
      return_url: "https://thehelpersapp.com/stripe-return",
      type: "account_onboarding",
    });

    return {
      url: accountLink.url,
      type: "onboarding",
    };
  }

  const loginLink = await stripe.accounts.createLoginLink(stripeAccountId);

  return {
    url: loginLink.url,
    type: "dashboard",
  };
});

exports.getDriverPayoutStatus = onCall({secrets: [stripeSecretKey]}, async (request) => {
  const userId = request.auth?.uid;
  const stripe = getStripe();

  if (!userId) {
    throw new HttpsError("unauthenticated", "User not authenticated");
  }

  const driverDoc = await admin
    .firestore()
    .collection("drivers")
    .doc(userId)
    .get();
  const driver = driverDoc.data() || {};
  const payoutSummary = await getDriverPayoutSummary(userId);
  const legacyBalanceCents = Math.max(
    0,
    Math.round(Number(driver.earnings || 0) * 100) -
      payoutSummary.availableCents -
      payoutSummary.reviewCents
  );

  const stripeAccountId = driver.stripeAccountId;

  if (!stripeAccountId) {
    return {
      ready: false,
      reason: "missing_account",
      ...payoutSummary,
      legacyBalanceCents,
      legacyBalance: dollarsFromCents(legacyBalanceCents),
    };
  }

  const account = await stripe.accounts.retrieve(stripeAccountId);
  const transfersActive = account.capabilities?.transfers === "active";
  const ready =
    account.details_submitted === true &&
    account.payouts_enabled === true &&
    transfersActive;
  const externalAccounts = await stripe.accounts.listExternalAccounts(
    stripeAccountId,
    {
      object: "bank_account",
      limit: 1,
    }
  );
  const bankAccount = externalAccounts.data[0] || null;

  return {
    ready,
    reason: ready ? "ready" : "incomplete",
    detailsSubmitted: account.details_submitted === true,
    payoutsEnabled: account.payouts_enabled === true,
    transfersActive,
    bankName: bankAccount?.bank_name || null,
    bankLast4: bankAccount?.last4 || null,
    ...payoutSummary,
    legacyBalanceCents,
    legacyBalance: dollarsFromCents(legacyBalanceCents),
  };
});

exports.getAdminDashboard = onCall(async (request) => {
  await assertAdmin(request);

  const db = admin.firestore();
  const [
    recentOrdersSnapshot,
    payoutIssuesSnapshot,
    storeIssuesSnapshot,
    usersSnapshot,
    driversSnapshot,
  ] = await Promise.all([
    db.collection("orders").orderBy("createdAt", "desc").limit(25).get(),
    db.collection("orders").where("driverPayoutStatus", "==", "payout_error").limit(25).get(),
    db.collection("orders").where("status", "==", "Store Issue").limit(25).get(),
    db.collection("users").limit(25).get(),
    db.collection("drivers").limit(25).get(),
  ]);

  const serializeOrder = (doc) => {
    const data = doc.data() || {};
    return {
      id: doc.id,
      status: data.status || "Unknown",
      dispatchStatus: data.dispatchStatus || null,
      paymentStatus: data.paymentStatus || null,
      storeName: data.storeName || "Store",
      customerName: data.customerName || "Customer",
      driverId: data.driverId || null,
      userId: data.userId || null,
      total: Number(data.total || 0),
      driverPay: Number(data.driverPay || 0),
      driverPayoutStatus: data.driverPayoutStatus || null,
      driverPayoutError: data.driverPayoutError || null,
      createdAt: timestampText(data.createdAt) || data.date || null,
    };
  };

  const serializeUser = (doc) => {
    const data = doc.data() || {};
    return {
      id: doc.id,
      email: data.email || null,
      name: data.name || data.storeName || null,
      role: data.role || null,
      phone: data.phone || data.phoneNumber || null,
      createdAt: timestampText(data.createdAt) || null,
    };
  };

  const serializeDriver = (doc) => {
    const data = doc.data() || {};
    return {
      id: doc.id,
      name: data.name || null,
      phone: data.phone || data.phoneNumber || null,
      isOnline: data.isOnline === true,
      isBusy: data.isBusy === true,
      onboardingComplete: data.onboardingComplete === true,
      payoutStatus: data.stripeAccountStatus || null,
      earnings: Number(data.earnings || 0),
      careerEarnings: Number(data.careerEarnings || 0),
      vehicleType: data.vehicleType || null,
      lastUpdated: timestampText(data.lastUpdated) || null,
    };
  };

  return {
    recentOrders: recentOrdersSnapshot.docs.map(serializeOrder),
    payoutIssues: payoutIssuesSnapshot.docs.map(serializeOrder),
    storeIssues: storeIssuesSnapshot.docs.map(serializeOrder),
    users: usersSnapshot.docs.map(serializeUser),
    drivers: driversSnapshot.docs.map(serializeDriver),
    counts: {
      recentOrders: recentOrdersSnapshot.size,
      payoutIssues: payoutIssuesSnapshot.size,
      storeIssues: storeIssuesSnapshot.size,
      usersLoaded: usersSnapshot.size,
      driversLoaded: driversSnapshot.size,
    },
  };
});

exports.withdrawDriverBalance = onCall({secrets: [stripeSecretKey]}, async (request) => {
  const driverId = request.auth?.uid;
  const stripe = getStripe();

  if (!driverId) {
    throw new HttpsError("unauthenticated", "Driver is not authenticated.");
  }

  const driverRef = admin.firestore().collection("drivers").doc(driverId);
  const driverDoc = await driverRef.get();
  const driver = driverDoc.data() || {};
  const stripeAccountId = driver.stripeAccountId;

  if (!stripeAccountId) {
    throw new HttpsError(
      "failed-precondition",
      "Set up Stripe Express before withdrawing."
    );
  }

  const account = await stripe.accounts.retrieve(stripeAccountId);
  const transfersActive = account.capabilities?.transfers === "active";

  if (
    account.details_submitted !== true ||
    account.payouts_enabled !== true ||
    !transfersActive
  ) {
    throw new HttpsError(
      "failed-precondition",
      "Finish Stripe Express setup before withdrawing."
    );
  }

  const pendingSnapshot = await admin
    .firestore()
    .collection("orders")
    .where("driverId", "==", driverId)
    .limit(50)
    .get();
  const pendingOrders = pendingSnapshot.docs.filter((doc) => {
    const order = doc.data() || {};
    return order.driverPayoutStatus === "pending_withdrawal";
  });
  const withdrawableOrders = pendingOrders.filter((doc) => {
    const order = doc.data() || {};
    return (
      driverPayCentsForOrder(order) > 0 &&
      typeof order.stripePaymentIntentId === "string" &&
      order.stripePaymentIntentId.length > 0
    );
  });

  if (withdrawableOrders.length === 0) {
    const availableCents = Math.round(Number(driver.earnings || 0) * 100);
    if (pendingOrders.length > 0 || availableCents > 0) {
      throw new HttpsError(
        "failed-precondition",
        "This balance needs review before it can be withdrawn."
      );
    }

    throw new HttpsError(
      "failed-precondition",
      "There is no available balance to withdraw."
    );
  }

  let transferredCents = 0;
  let failedCount = 0;
  const transferIds = [];
  const batch = admin.firestore().batch();

  for (const doc of pendingOrders) {
    const order = doc.data() || {};
    const orderId = doc.id;
    const driverPayCents = driverPayCentsForOrder(order);

    if (!Number.isFinite(driverPayCents) || driverPayCents <= 0) {
      failedCount += 1;
      batch.set(
        doc.ref,
        {
          driverPayoutStatus: "payout_error",
          driverPayoutError: "Missing driver pay amount.",
        },
        {merge: true}
      );
      continue;
    }

    try {
      const paymentIntentId = order.stripePaymentIntentId;

      if (!paymentIntentId) {
        throw new Error("Missing Stripe payment reference.");
      }

      const paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentId);
      const latestCharge =
        typeof paymentIntent.latest_charge === "string"
          ? paymentIntent.latest_charge
          : paymentIntent.latest_charge?.id;

      if (!latestCharge) {
        throw new Error("Missing Stripe charge reference.");
      }

      const transfer = await stripe.transfers.create(
        {
          amount: driverPayCents,
          currency: "usd",
          destination: stripeAccountId,
          source_transaction: latestCharge,
          transfer_group: `order_${orderId}`,
          metadata: {
            orderId,
            driverId,
          },
        },
        {idempotencyKey: `driver-withdrawal-${orderId}-${driverId}`}
      );

      transferredCents += driverPayCents;
      transferIds.push(transfer.id);

      batch.set(
        doc.ref,
        {
          driverTransferId: transfer.id,
          driverPayoutStatus: "transferred",
          driverTransferredAt: admin.firestore.FieldValue.serverTimestamp(),
          driverPayoutError: admin.firestore.FieldValue.delete(),
        },
        {merge: true}
      );
    } catch (error) {
      failedCount += 1;
      const errorMessage = error.message || "Stripe transfer failed.";
      batch.set(
        doc.ref,
        {
          driverPayoutStatus: "payout_error",
          driverPayoutError: errorMessage,
        },
        {merge: true}
      );
      console.error("❌ DRIVER WITHDRAWAL ORDER ERROR:", orderId, error);
    }
  }

  if (transferredCents <= 0) {
    await batch.commit();
    const onlyMissingPaymentRefs = pendingOrders.every((doc) => {
      const order = doc.data() || {};
      return !order.stripePaymentIntentId;
    });

    if (onlyMissingPaymentRefs) {
      throw new HttpsError(
        "failed-precondition",
        "This balance is missing its Stripe payment reference. It may be from an older test order."
      );
    }

    throw new HttpsError(
      "internal",
      "Could not withdraw this balance. Check payout errors and try again."
    );
  }

  const withdrawalRef = driverRef.collection("withdrawals").doc();
  batch.set(withdrawalRef, {
    amount: transferredCents / 100,
    amountCents: transferredCents,
    transferIds,
    failedCount,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  if (failedCount === 0) {
    batch.set(
      driverRef,
      {
        earnings: 0,
        lastWithdrawalAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      {merge: true}
    );
  } else {
    batch.set(
      driverRef,
      {
        earnings: admin.firestore.FieldValue.increment(-(transferredCents / 100)),
        lastWithdrawalAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      {merge: true}
    );
  }

  await batch.commit();

  return {
    success: true,
    amountCents: transferredCents,
    transferIds,
    failedCount,
  };
});

function tokensFromDoc(doc) {
  if (!doc.exists) {
    return [];
  }

  const data = doc.data() || {};
  const tokens = new Set();

  if (typeof data.fcmToken === "string" && data.fcmToken.length > 0) {
    tokens.add(data.fcmToken);
  }

  if (Array.isArray(data.fcmTokens)) {
    data.fcmTokens.forEach((token) => {
      if (typeof token === "string" && token.length > 0) {
        tokens.add(token);
      }
    });
  }

  return Array.from(tokens);
}

async function getUserTokens(userId) {
  if (!userId) {
    return [];
  }

  const doc = await admin.firestore().collection("users").doc(userId).get();
  return tokensFromDoc(doc);
}

async function getDriverTokens(driverIds) {
  const ids = Array.isArray(driverIds) ? driverIds : [];
  const tokens = new Set();

  await Promise.all(ids.map(async (driverId) => {
    const driverDoc = await admin
      .firestore()
      .collection("drivers")
      .doc(driverId)
      .get();

    tokensFromDoc(driverDoc).forEach((token) => tokens.add(token));

    const userDoc = await admin
      .firestore()
      .collection("users")
      .doc(driverId)
      .get();

    tokensFromDoc(userDoc).forEach((token) => tokens.add(token));
  }));

  return Array.from(tokens);
}

async function sendPush(tokens, payload) {
  const uniqueTokens = Array.from(new Set(tokens)).filter(Boolean);

  if (uniqueTokens.length === 0) {
    return {successCount: 0, failureCount: 0};
  }

  const result = await admin.messaging().sendEachForMulticast({
    tokens: uniqueTokens,
    notification: {
      title: payload.title,
      body: payload.body,
    },
    data: payload.data || {},
    android: {
      priority: "high",
      notification: {
        sound: "default",
      },
    },
    apns: {
      payload: {
        aps: {
          sound: "default",
        },
      },
    },
  });

  return {
    successCount: result.successCount,
    failureCount: result.failureCount,
  };
}

function distanceBetweenMeters(lat1, lng1, lat2, lng2) {
  const earthRadiusMeters = 6371000;
  const toRadians = (degrees) => degrees * Math.PI / 180;
  const latDelta = toRadians(lat2 - lat1);
  const lngDelta = toRadians(lng2 - lng1);
  const a =
    Math.sin(latDelta / 2) * Math.sin(latDelta / 2) +
    Math.cos(toRadians(lat1)) *
      Math.cos(toRadians(lat2)) *
      Math.sin(lngDelta / 2) *
      Math.sin(lngDelta / 2);

  return earthRadiusMeters * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

async function findEligibleDrivers(order) {
  const storeLat = Number(order.storeLat);
  const storeLng = Number(order.storeLng);
  const cancelledDriverIds = new Set(
    Array.isArray(order.cancelledDriverIds) ? order.cancelledDriverIds : []
  );

  if (!Number.isFinite(storeLat) || !Number.isFinite(storeLng)) {
    return [];
  }

  const snapshot = await admin
    .firestore()
    .collection("drivers")
    .where("active", "==", true)
    .get();

  return snapshot.docs
    .map((doc) => {
      const data = doc.data() || {};
      const lat = Number(data.lat);
      const lng = Number(data.lng);

      if (cancelledDriverIds.has(doc.id)) {
        return null;
      }

      if (
        data.isBusy === true ||
        !Number.isFinite(lat) ||
        !Number.isFinite(lng)
      ) {
        return null;
      }

      if (
        order.requiresCarDelivery === true &&
        !motorVehicleTypes.has(data.vehicleType)
      ) {
        return null;
      }

      const distance = distanceBetweenMeters(storeLat, storeLng, lat, lng);

      if (distance > driverSearchRadiusMeters) {
        return null;
      }

      return {driverId: doc.id, distance};
    })
    .filter(Boolean)
    .sort((a, b) => a.distance - b.distance)
    .slice(0, maxEligibleDrivers)
    .map((driver) => driver.driverId);
}

function driverAvailableOrderRef(driverId, orderId) {
  return admin
    .firestore()
    .collection("drivers")
    .doc(driverId)
    .collection("availableOrders")
    .doc(orderId);
}

function availableOrderQueueData(orderId, order) {
  return {
    orderId,
    status: order.status || "Pending",
    customerLat: order.customerLat ?? null,
    customerLng: order.customerLng ?? null,
    customerAddress: order.customerAddress || "",
    customerName: order.customerName || "Customer",
    storeLat: order.storeLat ?? null,
    storeLng: order.storeLng ?? null,
    storeId: order.storeId || null,
    storeName: order.storeName || "Supply store",
    storeAddress: order.storeAddress || "",
    items: Array.isArray(order.items) ? order.items : [],
    subtotal: order.subtotal ?? 0,
    deliveryFee: order.deliveryFee ?? 0,
    tax: order.tax ?? 0,
    tip: order.tip ?? 0,
    total: order.total ?? 0,
    tradeType: order.tradeType || "Trade",
    requiresCarDelivery: order.requiresCarDelivery === true,
    createdAt: order.createdAt || null,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

async function syncAvailableOrderQueues(orderRef, order, eligibleDrivers, previousDriverIds = []) {
  const currentDriverIds = Array.isArray(eligibleDrivers) ? eligibleDrivers : [];
  const allDriverIds = new Set([...previousDriverIds, ...currentDriverIds]);

  if (allDriverIds.size === 0) {
    return;
  }

  const batch = admin.firestore().batch();
  const queueData = availableOrderQueueData(orderRef.id, {
    ...order,
    status: "Pending",
  });

  allDriverIds.forEach((driverId) => {
    const queueRef = driverAvailableOrderRef(driverId, orderRef.id);

    if (currentDriverIds.includes(driverId)) {
      batch.set(queueRef, queueData, {merge: true});
    } else {
      batch.delete(queueRef);
    }
  });

  await batch.commit();
}

async function refreshDriverAvailableOrdersFor(driverId) {
  const db = admin.firestore();
  const queueRef = db
    .collection("drivers")
    .doc(driverId)
    .collection("availableOrders");

  const [existingQueueSnapshot, pendingSnapshot] = await Promise.all([
    queueRef.get(),
    db.collection("orders").where("status", "==", "Pending").limit(50).get(),
  ]);

  const batch = db.batch();
  let writeCount = 0;
  let orderCount = 0;

  existingQueueSnapshot.docs.forEach((doc) => {
    batch.delete(doc.ref);
    writeCount += 1;
  });

  pendingSnapshot.docs.forEach((doc) => {
    const order = doc.data() || {};
    const eligibleDrivers = Array.isArray(order.eligibleDrivers)
      ? order.eligibleDrivers
      : [];

    if (!order.driverId && eligibleDrivers.includes(driverId)) {
      batch.set(
        driverAvailableOrderRef(driverId, doc.id),
        availableOrderQueueData(doc.id, order),
        {merge: true}
      );
      writeCount += 1;
      orderCount += 1;
    }
  });

  if (writeCount > 0) {
    await batch.commit();
  }

  return orderCount;
}

async function dispatchPendingOrder(orderRef, reason) {
  const initialSnapshot = await orderRef.get();
  const initialOrder = initialSnapshot.data();

  if (
    !initialSnapshot.exists ||
    initialOrder?.status !== "Pending" ||
    initialOrder?.driverId
  ) {
    return {dispatched: false, reason: "not-pending"};
  }

  const eligibleDrivers = await findEligibleDrivers(initialOrder);
  const previousEligibleDrivers = new Set(
    Array.isArray(initialOrder.eligibleDrivers)
      ? initialOrder.eligibleDrivers
      : []
  );
  const shouldRetryPush = initialOrder.dispatchStatus === "visible_no_push";
  const driversToNotify =
    reason === "order_created" || shouldRetryPush
      ? eligibleDrivers
      : eligibleDrivers.filter(
        (driverId) => !previousEligibleDrivers.has(driverId)
      );
  let shouldNotify = false;
  let didUpdate = false;

  await admin.firestore().runTransaction(async (transaction) => {
    const freshSnapshot = await transaction.get(orderRef);
    const freshOrder = freshSnapshot.data();

    if (
      !freshSnapshot.exists ||
      freshOrder?.status !== "Pending" ||
      freshOrder?.driverId
    ) {
      return;
    }

    transaction.set(
      orderRef,
      {
        eligibleDrivers,
        dispatchStatus:
          driversToNotify.length > 0
            ? "notifying"
            : eligibleDrivers.length > 0
              ? "available"
              : "waiting_for_driver",
        dispatchReason: reason,
        dispatchAttempts: admin.firestore.FieldValue.increment(1),
        lastDispatchAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      {merge: true}
    );
    shouldNotify = driversToNotify.length > 0;
    didUpdate = true;
  });

  if (!didUpdate) {
    return {dispatched: false, reason: "not-pending"};
  }

  await syncAvailableOrderQueues(
    orderRef,
    initialOrder,
    eligibleDrivers,
    Array.from(previousEligibleDrivers)
  );

  if (!shouldNotify) {
    return {
      dispatched: false,
      reason: eligibleDrivers.length > 0 ? "no-new-drivers" : "no-drivers",
    };
  }

  const tokens = await getDriverTokens(driversToNotify);
  const storeName = initialOrder.storeName || "Supply store";
  const total = Number(initialOrder.total || 0).toFixed(2);
  const pushResult = await sendPush(tokens, {
    title: "New delivery available",
    body: `${storeName} order • $${total}`,
    data: {
      type: "driver_new_order",
      orderId: orderRef.id,
    },
  });

  const finalSnapshot = await orderRef.get();
  const finalOrder = finalSnapshot.data();

  if (finalOrder?.status === "Pending" && !finalOrder?.driverId) {
    await orderRef.set(
      {
        dispatchStatus:
          pushResult.successCount > 0 ? "notified" : "visible_no_push",
        lastDriverNotificationAt:
          pushResult.successCount > 0
            ? admin.firestore.FieldValue.serverTimestamp()
            : null,
        lastNotificationSuccessCount: pushResult.successCount,
        lastNotificationFailureCount: pushResult.failureCount,
        notifiedDriverIds:
          admin.firestore.FieldValue.arrayUnion(...driversToNotify),
      },
      {merge: true}
    );
  }

  return {
    dispatched: true,
    eligibleDriverCount: eligibleDrivers.length,
    notifiedDriverCount: driversToNotify.length,
    notificationSuccessCount: pushResult.successCount,
  };
}

exports.refreshDriverAvailableOrders = onCall(async (request) => {
  const driverId = request.auth?.uid;

  if (!driverId) {
    throw new HttpsError("unauthenticated", "Driver is not authenticated.");
  }

  const orderCount = await refreshDriverAvailableOrdersFor(driverId);

  return {
    success: true,
    orderCount,
  };
});

exports.notifyDriversForNewOrder = onDocumentCreated(
  "orders/{orderId}",
  async (event) => {
    const orderRef = event.data?.ref;

    if (!orderRef) {
      return;
    }

    await dispatchPendingOrder(orderRef, "order_created");
  }
);

exports.retryPendingOrderDispatch = onSchedule(
  {
    schedule: "every 2 minutes",
    timeZone: "America/New_York",
  },
  async () => {
    const pendingSnapshot = await admin
      .firestore()
      .collection("orders")
      .where("status", "==", "Pending")
      .limit(50)
      .get();

    const retryCutoff = Date.now() - 90 * 1000;
    const ordersToRetry = pendingSnapshot.docs.filter((doc) => {
      const lastDispatchAt = doc.data().lastDispatchAt;
      return !lastDispatchAt || lastDispatchAt.toMillis() <= retryCutoff;
    });

    await Promise.all(ordersToRetry.map(async (doc) => {
      try {
        await dispatchPendingOrder(doc.ref, "scheduled_retry");
      } catch (error) {
        console.error(`Dispatch retry failed for order ${doc.id}`, error);
      }
    }));
  }
);

exports.notifyCustomerForOrderUpdate = onDocumentUpdated("orders/{orderId}", async (event) => {
  const before = event.data?.before.data();
  const after = event.data?.after.data();
  const orderId = event.params.orderId;

  if (!before || !after || before.status === after.status) {
    return;
  }

  const status = after.status || "Pending";
  const userId = after.userId;
  const tokens = await getUserTokens(userId);
  const storeName = after.storeName || "the supply store";

  const messages = {
    Accepted: {
      title: "Driver accepted your order",
      body: `Your driver is heading to ${storeName}.`,
    },
    "Picked Up": {
      title: "Parts picked up",
      body: "Your driver is heading to you now.",
    },
    Delivered: {
      title: "Order delivered",
      body: "Your parts have arrived.",
    },
    Rejected: {
      title: "Order update",
      body: "Your order could not be completed.",
    },
    Pending: {
      title: "Order reopened",
      body: "Your order is waiting for another driver.",
    },
    "Store Issue": {
      title: "Store issue with your order",
      body: `${storeName} reported an item was not in stock. Open the app to try the next nearest store.`,
    },
  };

  const message = messages[status];

  if (!message) {
    return;
  }

  await sendPush(tokens, {
    title: message.title,
    body: message.body,
    data: {
      type: "customer_order_update",
      orderId,
      status,
    },
  });
});
