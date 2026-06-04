const {onCall, HttpsError} = require("firebase-functions/v2/https");
const stripe = require("stripe")(process.env.STRIPE_SECRET_KEY);
const admin = require("firebase-admin");

admin.initializeApp();

exports.createSetupIntent = onCall(async (request) => {
  const userId = request.auth?.uid;

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

exports.getPaymentMethods = onCall(async (request) => {
  const userId = request.auth?.uid;

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

exports.createPaymentIntent = onCall(async (request) => {
  const userId = request.auth?.uid;

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

exports.deletePaymentMethod = onCall(async (request) => {
  const userId = request.auth?.uid;

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

exports.createDriverDashboardLink = onCall(async (request) => {
  const userId = request.auth?.uid;

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
