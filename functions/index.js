const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {onDocumentCreated, onDocumentUpdated} = require("firebase-functions/v2/firestore");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {defineSecret} = require("firebase-functions/params");

const stripeSecretKey = defineSecret("STRIPE_SECRET_KEY");
const driverSearchRadiusMeters = 24140;
const maxEligibleDrivers = 10;
const pickupRadiusMeters = 300;
const maxDriverLocationAgeMs = 2 * 60 * 1000;
const motorVehicleTypes = new Set(["car", "pickup_truck_van"]);

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
const admin = require("firebase-admin");

admin.initializeApp();

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
        `You must be within ${pickupRadiusMeters} meters of the store to mark this order picked up.`
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

exports.createSetupIntent = onCall({secrets: [stripeSecretKey]}, async (request) => {
  const userId = request.auth?.uid;
  const stripe = getStripe();

  if (!userId) {
    throw new Error("User not authenticated");
  }

  const userRef = admin.firestore().collection("users").doc(userId);
  const userDoc = await userRef.get();

  let customerId;

  // ✅ Check if user already has Stripe customer
  if (userDoc.exists && userDoc.data().stripeCustomerId) {
    customerId = userDoc.data().stripeCustomerId;
  } else {
    // ❌ If not → create one
    const customer = await stripe.customers.create({
      metadata: { firebaseUID: userId },
    });

    customerId = customer.id;

    // ✅ Save it to Firestore
    await userRef.set(
      { stripeCustomerId: customerId },
      { merge: true }
    );
  }

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
    throw new Error("User not authenticated");
  }

  const userDoc = await admin
    .firestore()
    .collection("users")
    .doc(userId)
    .get();

  const customerId = userDoc.data()?.stripeCustomerId;

  if (!customerId) {
    return {
      hasPaymentMethod: false,
      paymentMethods: [],
    };
  }

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
    throw new Error("User not authenticated");
  }

  const { amount } = request.data;
  const paymentMethodId = request.data.paymentMethodId;

  const userRef = admin.firestore().collection("users").doc(userId);
  const userDoc = await userRef.get();

  const customerId = userDoc.data()?.stripeCustomerId;

  if (!customerId) {
    throw new Error("No Stripe customer found");
  }

  if (!paymentMethodId) {
    throw new Error("No payment method selected");
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
    };
  } catch (error) {
    console.error("❌ STRIPE ERROR:", error);
    throw new Error(error.message);
  }
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

  if (!account.details_submitted || !account.payouts_enabled) {
    const accountLink = await stripe.accountLinks.create({
      account: stripeAccountId,
      refresh_url: "https://example.com/stripe-refresh",
      return_url: "https://example.com/stripe-return",
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
  });

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
