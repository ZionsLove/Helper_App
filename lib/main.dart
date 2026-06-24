import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'confirm_location_screen.dart';
import 'driver_onboarding_screen.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_stripe/flutter_stripe.dart' as stripe;

import 'package:url_launcher/url_launcher.dart';

part 'HVACScreen.dart';
//com.example.apprentice_app
//C7:C8:50:2F:DD:1F:8A:51:43:7A:58:00:E0:57:E4:F8:73:00:77:61

//Jesus Christ is The Way

const double minDeliveryFee = 17.0;
const double taxRate = 0.08875;
const String requiresCarDeliveryKey = "requiresCarDelivery";
const Set<String> motorVehicleTypes = {"car", "pickup_truck_van"};

Future<Position?> requestLocation() async {
  bool serviceEnabled;
  LocationPermission permission;

  // 🔍 Check if location services are enabled
  serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) {
    print("❌ Location services disabled");
    return null;
  }

  // 🔍 Check permission
  permission = await Geolocator.checkPermission();

  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();

    if (permission == LocationPermission.denied) {
      print("❌ Permission denied");
      return null;
    }
  }

  if (permission == LocationPermission.deniedForever) {
    print("❌ Permission permanently denied");
    return null;
  }

  // ✅ Get current position
  return await Geolocator.getCurrentPosition();
}

double getDistance(double lat1, double lng1, double lat2, double lng2) {
  return Geolocator.distanceBetween(lat1, lng1, lat2, lng2);
}

//Find closest store
Future<Map<String, dynamic>?> findClosestStore(Position userPosition) async {
  final snapshot = await FirebaseFirestore.instance
      .collection('users')
      .where('role', isEqualTo: 'store')
      .get();

  double? shortestDistance;
  Map<String, dynamic>? closestStore;

  for (var doc in snapshot.docs) {
    final data = doc.data();

    if (data['lat'] == null || data['lng'] == null) continue;

    final distance = getDistance(
      userPosition.latitude,
      userPosition.longitude,
      data['lat'],
      data['lng'],
    );

    if (shortestDistance == null || distance < shortestDistance) {
      shortestDistance = distance;
      closestStore = {"id": doc.id, ...data};
    }
  }

  return closestStore;
}

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> appScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  // 🔥 STEP 1 — ADD YOUR PUBLISHABLE KEY HERE
  if (!kIsWeb) {
    stripe.Stripe.publishableKey =
        "pk_test_51TQWNvROBLc14B5hkhpybYHZ2wQSL6MjKJynFQsRkl1fsMMCniENxjgz3ZNTkTR3ByhTXoUzau9EI56QWEiPsxoW00LrgMgzp4";
  }

  await PushNotificationService.setup();

  runApp(MyApp());
}

class PushNotificationService {
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  static Future<void> setup() async {
    if (kIsWeb) return;

    await _messaging.requestPermission(alert: true, badge: true, sound: true);

    FirebaseAuth.instance.authStateChanges().listen((user) async {
      if (user == null) return;
      await saveCurrentToken(user.uid);
    });

    FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      await saveToken(user.uid, token);
    });

    FirebaseMessaging.onMessage.listen(showForegroundMessage);
    FirebaseMessaging.onMessageOpenedApp.listen(handleNotificationTap);

    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        handleNotificationTap(initialMessage);
      });
    }
  }

  static Future<void> saveCurrentToken(String userId) async {
    final token = await _messaging.getToken();
    if (token == null || token.isEmpty) return;
    await saveToken(userId, token);
  }

  static Future<void> saveToken(String userId, String token) async {
    final userRef = FirebaseFirestore.instance.collection('users').doc(userId);

    await userRef.set({
      'fcmToken': token,
      'fcmTokens': FieldValue.arrayUnion([token]),
    }, SetOptions(merge: true));

    final userDoc = await userRef.get();
    final data = userDoc.data();

    if (data?['role'] == 'driver') {
      await FirebaseFirestore.instance.collection('drivers').doc(userId).set({
        'fcmToken': token,
        'fcmTokens': FieldValue.arrayUnion([token]),
      }, SetOptions(merge: true));
    }
  }

  static void showForegroundMessage(RemoteMessage message) {
    final title = message.notification?.title ?? message.data['title'];
    final body = message.notification?.body ?? message.data['body'];

    if (title == null && body == null) return;

    final messenger = appScaffoldMessengerKey.currentState;
    if (messenger == null) return;

    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        duration: Duration(seconds: 4),
        showCloseIcon: true,
        content: InkWell(
          onTap: () {
            messenger.hideCurrentSnackBar();
            handleNotificationTap(message);
          },
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text(
              body == null ? title.toString() : "${title ?? 'Update'}\n$body",
            ),
          ),
        ),
      ),
    );
  }

  static void handleNotificationTap(RemoteMessage message) {
    final data = message.data;
    final type = data['type'];
    final orderId = data['orderId'];
    final navigator = appNavigatorKey.currentState;

    if (navigator == null) return;

    if (type == 'customer_order_update' && orderId is String) {
      navigator.push(
        MaterialPageRoute(
          builder: (_) => CustomerOrderTrackingScreen(orderId: orderId),
        ),
      );
      return;
    }

    if (type == 'driver_new_order') {
      navigator.push(MaterialPageRoute(builder: (_) => DriverScreen()));
    }
  }
}

typedef AddToCart = void Function(int quantity);

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Plumbing Parts',
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: appScaffoldMessengerKey,
      home: SplashScreen(),
    );
  }
}

class CartItem {
  final String name;
  final double price;
  final String image;
  final String description;
  final String? specialtyStoreTag;
  final bool requiresCarDelivery;
  int quantity;

  CartItem({
    required this.name,
    required this.price,
    required this.image,
    required this.description,
    this.specialtyStoreTag,
    this.requiresCarDelivery = false,
    this.quantity = 1,
  });

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'price': price,
      'image': image,
      'quantity': quantity,
      'specialtyStoreTag': specialtyStoreTag,
      requiresCarDeliveryKey: requiresCarDelivery,
    };
  }
}

bool cartRequiresCarDelivery(List<CartItem> cart) {
  return cart.any((item) => item.requiresCarDelivery);
}

class Order {
  final List<CartItem> items;
  final double total;
  final DateTime date;
  String status;
  String? id;

  Order({
    required this.items,
    required this.total,
    required this.date,
    required this.status,
  });

  Map<String, dynamic> toJson() {
    return {
      "items": items.map((item) {
        return {
          "name": item.name,
          "price": item.price,
          "image": item.image,
          "quantity": item.quantity,
          "status": status,
          "description": item.description,
          requiresCarDeliveryKey: item.requiresCarDelivery,
        };
      }).toList(),
      "total": total,
      "date": date.toIso8601String(),
      "status": status,
    };
  }

  factory Order.fromJson(Map<String, dynamic> json) {
    return Order(
      items: (json["items"] as List).map((item) {
        return CartItem(
          name: item["name"],
          price: item["price"],
          image: item["image"],
          quantity: (item["quantity"] ?? 1),
          description: item["description"] ?? "",
          requiresCarDelivery: item[requiresCarDeliveryKey] == true,
        );
      }).toList(),
      total: json["total"],
      date: DateTime.parse(json["date"]),
      status: json["status"] ?? "Pending",
    );
  }
}

class OrderStatus {
  static const pending = "Pending";
  static const accepted = "Accepted";
  static const outForDelivery = "Out for Delivery";
  static const delivered = "Delivered";
}

class DetailScreen extends StatefulWidget {
  final String name;
  final double price;
  final String description;
  final String image;
  final AddToCart onAdd;

  DetailScreen({
    required this.name,
    required this.price,
    required this.description,
    required this.image,
    required this.onAdd,
  });

  @override
  _DetailScreenState createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  int quantity = 1;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      body: Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          children: [
            Image.asset(widget.image, height: 220, fit: BoxFit.contain),
            Text(
              widget.name,
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 10),

            Text("\$${(widget.price as num).toStringAsFixed(2)}"),
            SizedBox(height: 10),

            Text(widget.description),
            SizedBox(height: 20),

            // 🔥 Quantity selector
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: Icon(Icons.remove),
                  onPressed: () {
                    if (quantity > 1) {
                      setState(() {
                        quantity--;
                      });
                    }
                  },
                ),

                Container(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    border: Border.all(),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    quantity.toString(),
                    style: TextStyle(fontSize: 18),
                  ),
                ),

                IconButton(
                  icon: Icon(Icons.add),
                  onPressed: () {
                    setState(() {
                      quantity++;
                    });
                  },
                ),
              ],
            ),

            SizedBox(height: 20),

            ElevatedButton(
              onPressed: () {
                widget.onAdd(quantity);
                Navigator.pop(context);
              },
              child: Text("Add to Cart"),
            ),
          ],
        ),
      ),
    );
  }
}

class CartScreen extends StatefulWidget {
  final List<CartItem> cart;
  final String tradeType;
  final VoidCallback onUpdate;
  final List<Order> orders;
  final VoidCallback onSaveOrders;

  CartScreen({
    required this.cart,
    required this.onUpdate,
    required this.orders,
    required this.onSaveOrders,
    required this.tradeType,
  });

  @override
  _CartScreenState createState() => _CartScreenState();
}

class SearchScreen extends StatefulWidget {
  final List<Map<String, dynamic>> parts;
  final Function addToCart;

  SearchScreen({required this.parts, required this.addToCart});

  @override
  _SearchScreenState createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  String query = "";

  bool showAddedMessage = false;

  void showAddedToCartMessage() {
    setState(() {
      showAddedMessage = true;
    });

    Future.delayed(Duration(seconds: 2), () {
      setState(() {
        showAddedMessage = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    List<Map<String, dynamic>> results = widget.parts.where((item) {
      return item["name"].toLowerCase().contains(query.toLowerCase());
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          decoration: InputDecoration(
            hintText: "Search...",
            border: InputBorder.none,
          ),
          onChanged: (value) {
            setState(() {
              query = value;
            });
          },
        ),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Divider(height: 1, thickness: 1.2, color: Colors.grey[400]),

              Expanded(
                child: ListView.separated(
                  itemCount: results.length,
                  separatorBuilder: (context, index) => Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Divider(
                      height: 1,
                      thickness: 0.5,
                      color: Colors.grey[300],
                    ),
                  ),
                  itemBuilder: (context, index) {
                    return ListTile(
                      leading: Image.asset(
                        results[index]["image"],
                        width: 50,
                        height: 50,
                        fit: BoxFit.cover,
                      ),
                      title: Text(results[index]["name"]),
                      subtitle: Text(
                        "\$${(results[index]["price"] as num).toDouble().toStringAsFixed(2)}",
                      ),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => DetailScreen(
                              name: results[index]["name"],
                              price: results[index]["price"],
                              description:
                                  results[index]["description"], // ✅ comma
                              image: results[index]["image"],
                              onAdd: (qty) {
                                widget.addToCart(results[index], qty);
                                showAddedToCartMessage();
                              },
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
          Positioned(
            bottom: 50,
            left: 0,
            right: 0,
            child: Center(
              child: AnimatedOpacity(
                duration: Duration(milliseconds: 500),
                opacity: showAddedMessage ? 1.0 : 0.0,
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.green,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check, color: Colors.white),
                      SizedBox(width: 8),
                      Text(
                        "Added to cart",
                        style: TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      resizeToAvoidBottomInset: true,
    );
  }
}

class _CartScreenState extends State<CartScreen> {
  @override
  Widget build(BuildContext context) {
    double total = 0;

    for (var item in widget.cart) {
      total += item.price * item.quantity;
    }

    return Scaffold(
      appBar: AppBar(title: Text("Your Cart")),
      body: Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          children: [
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('users')
                    .doc(FirebaseAuth.instance.currentUser!.uid)
                    .collection('cart')
                    .snapshots(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return Center(child: CircularProgressIndicator());
                  }

                  final items = snapshot.data!.docs;

                  if (items.isEmpty) {
                    return Center(child: Text("Cart is empty"));
                  }

                  return ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final data = items[index].data() as Map<String, dynamic>;

                      final qty = data["quantity"] ?? 1;

                      return ListTile(
                        key: ValueKey(data["name"]),
                        title: Text(data["name"]),
                        subtitle: Text(
                          "\$${(data["price"] as num).toDouble().toStringAsFixed(2)} x $qty",
                        ),

                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // ➖ REMOVE
                            IconButton(
                              icon: Icon(Icons.remove),
                              onPressed: () async {
                                final docRef = FirebaseFirestore.instance
                                    .collection('users')
                                    .doc(FirebaseAuth.instance.currentUser!.uid)
                                    .collection('cart')
                                    .doc(data["name"]);

                                if (qty <= 1) {
                                  await docRef.delete();
                                } else {
                                  await docRef.update({"quantity": qty - 1});
                                }
                              },
                            ),

                            Text("$qty"),

                            // ➕ ADD
                            IconButton(
                              icon: Icon(Icons.add),
                              onPressed: () async {
                                final docRef = FirebaseFirestore.instance
                                    .collection('users')
                                    .doc(FirebaseAuth.instance.currentUser!.uid)
                                    .collection('cart')
                                    .doc(data["name"]);

                                await docRef.update({"quantity": qty + 1});
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(FirebaseAuth.instance.currentUser!.uid)
                  .collection('cart')
                  .snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return SizedBox();

                double total = 0;

                for (var doc in snapshot.data!.docs) {
                  final data = doc.data() as Map<String, dynamic>;
                  total += data["price"] * data["quantity"];
                }

                return Text(
                  "Total: \$${(total as num).toDouble().toStringAsFixed(2)}",
                  style: TextStyle(fontSize: 20),
                );
              },
            ),

            SizedBox(height: 20),

            ElevatedButton(
              style: ElevatedButton.styleFrom(
                minimumSize: Size(double.infinity, 50),
                backgroundColor: Colors.green,
              ),
              onPressed: () {
                showCheckoutModal(context);
              },
              child: Text("Proceed to Checkout"),
            ),
          ],
        ),
      ),
    );
  }

  void showCheckoutModal(BuildContext context) {
    bool useSavedAddressLocal = true;

    showModalBottomSheet(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "Confirm Location",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),

                  SizedBox(height: 10),

                  SwitchListTile(
                    title: Text("Use Saved Address"),
                    subtitle: Text("Turn off to use current location"),
                    value: useSavedAddressLocal,
                    onChanged: (value) {
                      setModalState(() {
                        useSavedAddressLocal = value;
                      });
                    },
                  ),

                  SizedBox(height: 10),

                  ElevatedButton(
                    onPressed: () async {
                      Navigator.pop(context);

                      final snapshot = await FirebaseFirestore.instance
                          .collection('users')
                          .doc(FirebaseAuth.instance.currentUser!.uid)
                          .collection('cart')
                          .get();

                      final cartItems = snapshot.docs.map((doc) {
                        final data = doc.data();

                        return CartItem(
                          name: data["name"],
                          price: (data["price"] as num).toDouble(),
                          image: data["image"],
                          description: data["description"],
                          specialtyStoreTag: data["specialtyStoreTag"],
                          requiresCarDelivery:
                              data[requiresCarDeliveryKey] == true,
                          quantity: (data["quantity"] ?? 1) as int,
                        );
                      }).toList();

                      final result = await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => CheckoutScreen(
                            cart: cartItems,
                            tradeType: widget.tradeType,
                            useSavedAddress: useSavedAddressLocal,
                          ),
                        ),
                      );

                      print("📦 RESULT FROM CHECKOUT: $result");

                      if (result == "orderPlaced") {
                        print("🧹 clearing Firestore cart");

                        final user = FirebaseAuth.instance.currentUser;

                        final cartSnapshot = await FirebaseFirestore.instance
                            .collection('users')
                            .doc(user!.uid)
                            .collection('cart')
                            .get();

                        final batch = FirebaseFirestore.instance.batch();

                        for (var doc in cartSnapshot.docs) {
                          batch.delete(doc.reference);
                        }

                        await batch.commit();
                      }
                    },
                    child: Text("Continue"),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class CheckoutScreen extends StatefulWidget {
  final List<CartItem> cart;
  final bool useSavedAddress;
  final String tradeType;

  CheckoutScreen({
    required this.cart,
    required this.useSavedAddress,
    required this.tradeType,
  });

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  bool hasPaymentMethod = false;
  bool isPlacingOrder = false;
  bool isAddingPaymentMethod = false;
  bool isLoadingPayment = true;
  String? last4;
  String? brand;

  List<dynamic> paymentMethods = [];
  String? selectedPaymentMethodId;
  String? selectedLast4;
  String? selectedBrand;

  @override
  void initState() {
    super.initState();
    loadPaymentMethod();
  }

  Future<void> addPaymentMethod() async {
    if (isAddingPaymentMethod || paymentMethods.length >= 5) return;

    setState(() => isAddingPaymentMethod = true);

    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'createSetupIntent',
      );
      final response = await callable.call();
      final clientSecret = response.data['clientSecret'] as String?;

      if (clientSecret == null || clientSecret.isEmpty) {
        throw StateError("Stripe setup did not return a client secret.");
      }

      await stripe.Stripe.instance.initPaymentSheet(
        paymentSheetParameters: stripe.SetupPaymentSheetParameters(
          setupIntentClientSecret: clientSecret,
          merchantDisplayName: 'Apprentice App',
        ),
      );

      await stripe.Stripe.instance.presentPaymentSheet();
      await loadPaymentMethod();

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Payment method added")));
    } on stripe.StripeException catch (error) {
      if (!mounted) return;

      final message =
          error.error.localizedMessage ??
          "Stripe could not add this payment method.";

      if (message.toLowerCase().contains("cancel")) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } on FirebaseFunctionsException catch (error) {
      if (!mounted) return;

      final message = error.code == "failed-precondition"
          ? "Payment setup is temporarily unavailable. Stripe is not configured on the server."
          : error.message ?? "Could not start payment setup.";

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      debugPrint("Add payment method error: $error");
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Could not add payment method. Please try again."),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => isAddingPaymentMethod = false);
      }
    }
  }

  Future<void> loadPaymentMethod() async {
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'getPaymentMethods',
      );

      final result = await callable.call();

      setState(() {
        paymentMethods = result.data['paymentMethods'] ?? [];

        if (paymentMethods.isNotEmpty) {
          hasPaymentMethod = true;

          selectedPaymentMethodId ??= paymentMethods[0]['id'];

          final selectedCard = paymentMethods.firstWhere(
            (pm) => pm['id'] == selectedPaymentMethodId,
            orElse: () => paymentMethods[0],
          );

          selectedLast4 = selectedCard['last4'];
          selectedBrand = selectedCard['brand'];
        } else {
          hasPaymentMethod = false;

          selectedPaymentMethodId = null;
          selectedLast4 = null;
          selectedBrand = null;
        }

        isLoadingPayment = false;
      });
    } catch (e) {
      print("Error loading payment method: $e");

      setState(() {
        isLoadingPayment = false; // still stop loading
      });
    }
  }

  void showPaymentMethodSelector() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: paymentMethods.map((pm) {
              final cardBrand =
                  pm['brand'][0].toUpperCase() + pm['brand'].substring(1);

              return Column(
                children: [
                  if (paymentMethods.first == pm) SizedBox(height: 10),

                  ListTile(
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),

                    leading: getCardLogo(pm['brand']),

                    title: Text(
                      "$cardBrand •••• ${pm['last4']}",
                      style: TextStyle(fontWeight: FontWeight.w500),
                    ),

                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (pm['id'] == selectedPaymentMethodId)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Icon(
                              Icons.check_circle,
                              color: Colors.green,
                            ),
                          ),

                        if (paymentMethods.length > 1)
                          IconButton(
                            icon: Icon(Icons.delete, color: Colors.red),
                            onPressed: () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (context) {
                                  return AlertDialog(
                                    title: Text("Delete Payment Method"),
                                    content: Text(
                                      "Remove $cardBrand •••• ${pm['last4']}?",
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () {
                                          Navigator.pop(context, false);
                                        },
                                        child: Text("Cancel"),
                                      ),

                                      TextButton(
                                        onPressed: () {
                                          Navigator.pop(context, true);
                                        },
                                        child: Text(
                                          "Delete",
                                          style: TextStyle(color: Colors.red),
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              );

                              if (confirmed == true) {
                                await deletePaymentMethod(pm['id']);
                              }
                            },
                          ),
                      ],
                    ),

                    onTap: () {
                      setState(() {
                        selectedPaymentMethodId = pm['id'];
                        selectedLast4 = pm['last4'];
                        selectedBrand = pm['brand'];
                      });

                      Navigator.pop(context);
                    },
                  ),

                  Divider(
                    height: 1,
                    thickness: 1,
                    color: Colors.grey.shade300,
                    indent: 16,
                    endIndent: 16,
                  ),
                ],
              );
            }).toList(),
          ),
        );
      },
    );
  }

  Future<void> deletePaymentMethod(String paymentMethodId) async {
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'deletePaymentMethod',
      );

      await callable.call({"paymentMethodId": paymentMethodId});

      Navigator.pop(context);

      await loadPaymentMethod();

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Payment method deleted")));
    } catch (e) {
      print("Delete error: $e");

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed to delete payment method")),
      );
    }
  }

  Widget getCardLogo(String? brand) {
    switch (brand) {
      case "visa":
        return Image.asset("assets/images/visa.png", height: 20);
      case "mastercard":
        return Image.asset("assets/images/mastercard.png", height: 20);
      case "discover":
        return Image.asset("assets/images/discover.png", height: 20);
      default:
        return Icon(Icons.credit_card, size: 20);
    }
  }

  final List<Map<String, dynamic>> manualTradeStores = [
    // Add stores here when you want checkout to prefer a known supplier.
    // Example:
    // {
    //   "id": "ferguson-downtown",
    //   "storeName": "Ferguson Plumbing Supply",
    //   "tradeType": "Plumbing",
    //   "lat": 40.7128,
    //   "lng": -74.0060,
    //   "address": "Store address here",
    //   "specialtyTags": ["propress", "noHub", "blackIron"],
    // },
    //BRONX
    {
      "id": "allparts-plumbing+heating",
      "storeName": "All Parts Plumbing and Heating Supplies",
      "tradeType": "Plumbing", //HVAC
      "lat": 40.891181,
      "lng": -73.850857,
      "address": "920 E 233rd St, Bronx, NY 10466",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "fwwebb-bronx",
      "storeName": "F.W. Webb Company - Bronx",
      "tradeType": "Plumbing", //HVAC
      "lat": 40.820117,
      "lng": -73.892596,
      "address": "919 Southern Blvd, Bronx, NY 10459",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
        "turbotorch",
      ],
    },
    {
      "id": "gunhill-plumbing",
      "storeName": "Gunhill Plumbing Supply",
      "tradeType": "Plumbing",
      "lat": 40.877085,
      "lng": -73.867263,
      "address": "3463 White Plains Rd, Bronx, NY 10467",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
        "turbotorch",
      ],
    },
    {
      "id": "h&h-hardware",
      "storeName": "H & H Hardware",
      "tradeType": "Plumbing",
      "lat": 40.831501,
      "lng": -73.851128,
      "address": "1711 Castle Hill Ave, Bronx, NY 10462",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "homedepot-exterior",
      "storeName": "The Home Depot",
      "tradeType": "Plumbing",
      "lat": 40.823992,
      "lng": -73.929745,
      "address": "600 Exterior St, Bronx, NY 10451",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    {
      "id": "levins-supply",
      "storeName": "Levin's Crosstown Supply Corporation",
      "tradeType": "Plumbing",
      "lat": 40.832300,
      "lng": -73.899068,
      "address": "1347 Boston Rd, Bronx, NY 10456",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "mikespipeyard&plumbing",
      "storeName": "Mike's Pipe Yard & Plumbing",
      "tradeType": "Plumbing",
      "lat": 40.867101,
      "lng": -73.860049,
      "address": "2816 Boston Rd, Bronx, NY 10469",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "monarch-supply",
      "storeName": "Monarch Supply Corporation",
      "tradeType": "Plumbing",
      "lat": 40.810846,
      "lng": -73.883834,
      "address": "1335 Oak Point Ave, Bronx, NY 10474",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "pelhambay-homecenter",
      "storeName": "Pelham Bay Home Center",
      "tradeType": "Plumbing",
      "lat": 40.849079,
      "lng": -73.830809,
      "address": "3073 Westchester Ave, Bronx, NY 10461",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    {
      "id": "ranger-supply",
      "storeName": "Ranger Supply Company Inc.",
      "tradeType": "Plumbing",
      "lat": 40.879375,
      "lng": -73.901773,
      "address": "3137 Bailey Ave, Bronx, NY 10463",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "rim-supply",
      "storeName": "RIM Plumbing & Heating Supply",
      "tradeType": "Plumbing",
      "lat": 40.817894,
      "lng": -73.862783,
      "address": "623 Soundview Ave, Bronx, NY 10473",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "shyman-plumbing",
      "storeName": "S Hyman Plumbing Supplies",
      "tradeType": "Plumbing",
      "lat": 40.839159,
      "lng": -73.904260,
      "address": "432 Claremont Pkwy, Bronx, NY 10457",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "washington-plumbingspecco",
      "storeName": "Washington Plumbing Spec Co",
      "tradeType": "Plumbing",
      "lat": 40.848642,
      "lng": -73.894798,
      "address": "4290 3rd Ave, Bronx, NY 10457",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "webster-plumbing",
      "storeName": "Webster Plumbing Supply Inc",
      "tradeType": "Plumbing",
      "lat": 40.85267,
      "lng": -73.901968,
      "address": "1758 Webster Ave, Bronx, NY 10457",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    //BROOKLYN
    {
      "id": "apex-plumbing",
      "storeName": "Apex Plumbing Supply Corporation",
      "tradeType": "Plumbing",
      "lat": 40.637390,
      "lng": -73.968450,
      "address": "822 Coney Island Ave, Brooklyn, NY 11218",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "bmwplumbingsupply",
      "storeName": "Bmw Plumbing Supply",
      "tradeType": "Plumbing",
      "lat": 40.703927,
      "lng": -73.933832,
      "address": "232 Varet St, Brooklyn, NY 11206",
      "specialtyTags": ["propress", "noHub", "blackIron", "pvc"],
    },
    {
      "id": "brooklynplumbing+heating",
      "storeName": "Brooklyn Plumbing & Heating Supply",
      "tradeType": "Plumbing",
      "lat": 40.627455,
      "lng": -73.941737,
      "address": "1747 Flatbush Ave, Brooklyn, NY 11210",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
        "turbotorch",
      ],
    },
    {
      "id": "charliej-plumbing",
      "storeName": "Charlie J Plumbing & Hardware",
      "tradeType": "Plumbing",
      "lat": 40.678690,
      "lng": -73.888467,
      "address": "2878 Fulton St, Brooklyn, NY 11207",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "ferguson-3rdave",
      "storeName": "Ferguson",
      "tradeType": "Plumbing",
      "lat": 40.646495,
      "lng": -74.016258,
      "address": "5202 3rd Ave, Brooklyn, NY 11220",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    {
      "id": "ferguson-18thave",
      "storeName": "Ferguson",
      "tradeType": "Plumbing",
      "lat": 40.602919,
      "lng": -74.006587,
      "address": "8805 18th Ave, Brooklyn, NY 11214",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    {
      "id": "grainger-sunsetpark",
      "storeName": "Grainger Industrial Supply",
      "tradeType": "Plumbing",
      "lat": 40.659646,
      "lng": -74.001743,
      "address": "815 3rd Ave, Brooklyn, NY 11232",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    {
      "id": "homedepot-norstrand",
      "storeName": "The Home Depot",
      "tradeType": "Plumbing",
      "lat": 40.691961,
      "lng": -73.952487,
      "address": "230 Nortstrand Ave, Brooklyn, NY 11205",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    {
      "id": "homedepot-sunsetpark",
      "storeName": "The Home Depot",
      "tradeType": "Plumbing",
      "lat": 40.667724,
      "lng": -73.998208,
      "address": "550 Hamilton Ave, Brooklyn, NY 11232",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    {
      "id": "homedepot-gatewaydr",
      "storeName": "The Home Depot",
      "tradeType": "Plumbing",
      "lat": 40.653874,
      "lng": -73.868471,
      "address": "579 Gateway Dr, Brooklyn, NY 11239",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    {
      "id": "homedepot-avenueu",
      "storeName": "The Home Depot",
      "tradeType": "Plumbing",
      "lat": 40.612386,
      "lng": -73.916360,
      "address": "5700 Avenue U, Brooklyn, NY 11234",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    {
      "id": "kevin+richard",
      "storeName": "Kevin & Richard Plumbing & Heating Supplies",
      "tradeType": "Plumbing",
      "lat": 40.722446,
      "lng": -73.938490,
      "address": "93 Emerson Pl, Brooklyn, NY 11205",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "lmbuilding+plumbing",
      "storeName": "L&M BUILDING & PLUMBING SUPPLY INC.",
      "tradeType": "Plumbing",
      "lat": 40.722446,
      "lng": -73.938490,
      "address": "57 Lombardy St, Brooklyn, NY 11222",
      "specialtyTags": ["propress", "noHub", "blackIron", "pvc"],
    },
    {
      "id": "muhenhardware+plumbing",
      "storeName": "Muhen Hardware And Plumbing",
      "tradeType": "Plumbing",
      "lat": 40.663433,
      "lng": -73.924806,
      "address": "1050 Rutland Rd, Brooklyn, NY 11212",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
        "turbotorch",
      ],
    },
    {
      "id": "parkplumbing+heatingsupply",
      "storeName": "Park Plumbing & Heating Supply",
      "tradeType": "Plumbing",
      "lat": 40.627825,
      "lng": -73.997251,
      "address": "1350 60th St, Brooklyn, NY 11219",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "parkslope-plumbing",
      "storeName": "Park Slope Plumbing Supply",
      "tradeType": "Plumbing",
      "lat": 40.664232,
      "lng": -73.990269,
      "address": "601 5th Ave, Brooklyn, NY 11215",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "sunset-plumbing",
      "storeName": "SUNSET PLUMBING SUPPLY INC.",
      "tradeType": "Plumbing",
      "lat": 40.640603,
      "lng": -74.018295,
      "address": "6001 4th Ave, Brooklyn, NY 11220",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "williamsburgplumbingsupply",
      "storeName": "Williamsburg Plumbing Supply",
      "tradeType": "Plumbing",
      "lat": 40.699304,
      "lng": -73.955751,
      "address": "485 Flushing Ave, Brooklyn, NY 11205",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "worldwide-plumbing",
      "storeName": "World Wide Plumbing Supply",
      "tradeType": "Plumbing",
      "lat": 40.637416,
      "lng": -73.982931,
      "address": "4002 15th Ave, Brooklyn, NY 11218",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
        "turbotorch",
      ],
    },
    {
      "id": "ysplumbing+heating",
      "storeName": "YS Plumbing & Heating Supply",
      "tradeType": "Plumbing",
      "lat": 40.667688,
      "lng": -73.953655,
      "address": "244 Rogers Ave, Brooklyn, NY 11225",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    //MANHATTAN
    {
      "id": "73rdst-hardware",
      "storeName": "73rd Street Hardware, Inc",
      "tradeType": "Plumbing",
      "lat": 40.778142,
      "lng": -73.977947,
      "address": "65 W 73rd St #1, New York, NY 10023",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "148suppliescorp",
      "storeName": "148 Supplies Corporation",
      "tradeType": "Plumbing",
      "lat": 40.720223,
      "lng": -73.995029,
      "address": "148 Elizabeth St, New York, NY 10012",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "acehardware-audubonave",
      "storeName": "Ace Hardware Audubon Ave",
      "tradeType": "Plumbing",
      "lat": 40.845003,
      "lng": -73.934791,
      "address": "199 Audubon Ave, New York, NY 10033",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "ajplumbing",
      "storeName": "AJ Plumbing Supplies",
      "tradeType": "Plumbing",
      "lat": 40.717573,
      "lng": -73.993129,
      "address": "86 Forsynth St, New York, NY 10002",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "apex-supplycompany",
      "storeName": "Apex Supply Company, Inc.",
      "tradeType": "Plumbing",
      "lat": 40.859998,
      "lng": -73.930864,
      "address": "4580 Broadway, New York, NY 10040",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "central-plumbingspecialities",
      "storeName": "Central Plumbing Specialities",
      "tradeType": "Plumbing",
      "lat": 40.787084,
      "lng": -73.952483,
      "address": "1250 Park Ave, New York, NY 10029",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "chp-hardware",
      "storeName": "CHP Hardware",
      "tradeType": "Plumbing",
      "lat": 40.724462,
      "lng": -73.978397,
      "address": "120 Loisada Ave, New York, NY 10009",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "columbus-hardware",
      "storeName": "Columbus Hardware",
      "tradeType": "Plumbing",
      "lat": 40.766612,
      "lng": -73.986231,
      "address": "842 9th Ave, New York, NY 10019",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "c&s-truevalue",
      "storeName": "C & S True Value Hardware",
      "tradeType": "Plumbing",
      "lat": 40.795779,
      "lng": -73.969346,
      "address": "788 Amsterdam Ave, New York, NY 10025",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "ferguson-55thst",
      "storeName": "Ferguson Plumbing Supply",
      "tradeType": "Plumbing",
      "lat": 40.769850,
      "lng": -73.993471,
      "address": "625-35 W 55th St, New York, NY 10019",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    {
      "id": "firstavenue-supplyhouse",
      "storeName": "First Avenue Supply House",
      "tradeType": "Plumbing",
      "lat": 40.774737,
      "lng": -73.951165,
      "address": "1587 1st Ave, New York, NY 10028",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "fwwebb-manhattan",
      "storeName": "F.W. Webb Company - Manhattan",
      "tradeType": "Plumbing", //HVAC
      "lat": 40.742922,
      "lng": -73.990139,
      "address": "13 W 24th St, New York, NY 10010",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
        "turbotorch",
      ],
    },
    {
      "id": "fwwebb-westharlem",
      "storeName": "F.W. Webb Company - West Harlem",
      "tradeType": "Plumbing", //HVAC
      "lat": 40.820514,
      "lng": -73.958802,
      "address": "2350 12th Ave, New York, NY 10031",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
        "turbotorch",
      ],
    },
    {
      "id": "greenwichhardware",
      "storeName": "GREENWICH HARDWARE",
      "tradeType": "Plumbing",
      "lat": 40.736186,
      "lng": -73.997314,
      "address": "494 6th Ave, New York, NY 10011",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "homedepot-1stave",
      "storeName": "The Home Depot",
      "tradeType": "Plumbing",
      "lat": 40.760517,
      "lng": -73.961010,
      "address": "410 E 61st St, New York, NY 10065",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    {
      "id": "homedepot-23rdst",
      "storeName": "The Home Depot",
      "tradeType": "Plumbing",
      "lat": 40.741883,
      "lng": -73.991182,
      "address": "40 W 23rd St, New York, NY 10010",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    {
      "id": "howard-supply",
      "storeName": "Howard Supply",
      "tradeType": "Plumbing",
      "lat": 40.750592,
      "lng": -73.998083,
      "address": "344 9th Ave, New York, NY 10001",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "nuthouse-hardware",
      "storeName": "Nuthouse Hardware",
      "tradeType": "Plumbing",
      "lat": 40.742309,
      "lng": -73.979965,
      "address": "202 E 29th St, New York, NY 10016",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "unionsquare-supply",
      "storeName": "Union Square Supply",
      "tradeType": "Plumbing",
      "lat": 40.733242,
      "lng": -73.990141,
      "address": "130 4th Ave, New York, NY 10003",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "valuecentric-hardware",
      "storeName": "Value Centric Hardware Inc",
      "tradeType": "Plumbing",
      "lat": 40.801043,
      "lng": -73.935089,
      "address": "2383 2nd Ave, New York, NY 10035",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
        "turbotorch",
      ],
    },
    //QUEENS
    {
      "id": "burtonplumbing+heating",
      "storeName": "Burton Plumbing & Heating Supply Co",
      "tradeType": "Plumbing",
      "lat": 40.727415,
      "lng": -73.892402,
      "address": "70-14 Grand Ave, Maspeth, NY 11378",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "coronaplumbing+hvac",
      "storeName": "Corona Plumbing Heating and Cooling",
      "tradeType": "Plumbing",
      "lat": 40.750455,
      "lng": -73.859308,
      "address": "104-66 Roosevelt Ave, Corona, NY 11368",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "coronaplumbingsupplyinc",
      "storeName": "CORONA PLUMBING SUPPLY INC",
      "tradeType": "Plumbing",
      "lat": 40.741407,
      "lng": -73.864109,
      "address": "50-30 98th St, Corona, NY 11368",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "cypressplumbing+heating",
      "storeName": "Cypress Plumbing & Heating Supplies",
      "tradeType": "Plumbing",
      "lat": 40.683223,
      "lng": -73.873449,
      "address": "3304 Fulton St, Brooklyn, NY 11208",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "ferguson-maspeth",
      "storeName": "Ferguson Plumbing Supply",
      "tradeType": "Plumbing",
      "lat": 40.724691,
      "lng": -73.921606,
      "address": "57-22 49th St, Maspeth, NY 11378",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    {
      "id": "grainger-queens",
      "storeName": "Grainger Industrial Supply",
      "tradeType": "Plumbing",
      "lat": 40.720180,
      "lng": -73.909900,
      "address": "58-45 Grand Ave, Maspeth, NY 11378",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    {
      "id": "homedepot-mauriceave",
      "storeName": "The Home Depot",
      "tradeType": "Plumbing",
      "lat": 40.726896,
      "lng": -73.909314,
      "address": "59-15 Maurice Ave, Maspeth, NY 11378",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    {
      "id": "homedepot-northernboulevardlic",
      "storeName": "The Home Depot",
      "tradeType": "Plumbing",
      "lat": 40.752232,
      "lng": -73.912160,
      "address": "50-10 Northern Blvd, Long Island City, NY 11101",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    {
      "id": "homedepot-eastelmhurst",
      "storeName": "The Home Depot",
      "tradeType": "Plumbing",
      "lat": 40.763022,
      "lng": -73.894596,
      "address": "73-01 25th Ave, East Elmhurst, NY 11370",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    {
      "id": "homedepot-woodhaven",
      "storeName": "The Home Depot",
      "tradeType": "Plumbing",
      "lat": 40.708408,
      "lng": -73.858002,
      "address": "75-09 Woodhaven Blvd, Glendale, NY 11385",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    {
      "id": "homedepot-flushingavery",
      "storeName": "The Home Depot",
      "tradeType": "Plumbing",
      "lat": 40.752671,
      "lng": -73.835099,
      "address": "131-35 Avery Ave, Flushing, NY 11355",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    {
      "id": "homedepot-flushing31st",
      "storeName": "The Home Depot",
      "tradeType": "Plumbing",
      "lat": 40.767114,
      "lng": -73.843416,
      "address": "124-04 31st Ave, Flushing, NY 11354",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    {
      "id": "homedepot-jamaica168st",
      "storeName": "The Home Depot",
      "tradeType": "Plumbing",
      "lat": 40.705095,
      "lng": -73.792765,
      "address": "92-30 168th St, Jamaica, NY 11433",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    {
      "id": "homedepot-rockawayblvd",
      "storeName": "The Home Depot",
      "tradeType": "Plumbing",
      "lat": 40.675951,
      "lng": -73.826652,
      "address": "112-20 Rockaway Blvd, South Ozone Park, NY 11420",
      "specialtyTags": ["propress", "noHub", "blackIron"],
    },
    {
      "id": "libertyplumbing",
      "storeName": "Liberty Plumbing Supplies",
      "tradeType": "Plumbing",
      "lat": 40.697934,
      "lng": -73.801938,
      "address": "150-08 Liberty Ave, Jamaica, NY 11435",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "nyplumbingsupply-astoria",
      "storeName": "NY Plumbing Supply Astoria",
      "tradeType": "Plumbing",
      "lat": 40.765871,
      "lng": -73.915117,
      "address": "37-08 28th Ave, Astoria, NY 11103",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "soudeshplumbing+heating",
      "storeName": "Soudesh Plumbing & Heating Supplies Corp",
      "tradeType": "Plumbing",
      "lat": 40.713653,
      "lng": -73.761554,
      "address": "197-29 Jamaica Ave, Hollis, NY 11423",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "springfieldplumbing+heating",
      "storeName": "Springfield Plumbing & Heating Supply",
      "tradeType": "Plumbing",
      "lat": 40.726009,
      "lng": -73.740303,
      "address": "90-41 Springfield Blvd, Queens Villiage, NY 11428",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "superplumbing+building",
      "storeName": "Super Plumbing & Building Supply",
      "tradeType": "Plumbing",
      "lat": 40.725239,
      "lng": -73.912696,
      "address": "56-12 58th St, Maspeth, NY 11378",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
    {
      "id": "queensplumbing",
      "storeName": "Queens Plumbing Supply",
      "tradeType": "Plumbing",
      "lat": 40.745760,
      "lng": -73.927390,
      "address": "43-01 37th St, Long Island City, NY 11101",
      "specialtyTags": [
        "propress",
        "noHub",
        "blackIron",
        "pvc",
        "copperFittings",
      ],
    },
  ];
  //lalamove
  Map<String, dynamic>? findClosestManualTradeStore(
    Position position,
    String tradeType,
    List<String> specialtyTags,
  ) {
    if (specialtyTags.isEmpty) return null;

    final stores = manualTradeStores.where((store) {
      final storeTags = ((store["specialtyTags"] as List?) ?? [])
          .map((tag) => tag.toString())
          .toList();

      final hasMatchingTag = specialtyTags.any(storeTags.contains);

      return store["tradeType"] == tradeType &&
          store["lat"] != null &&
          store["lng"] != null &&
          hasMatchingTag;
    }).toList();

    if (stores.isEmpty) return null;

    Map<String, dynamic>? closestStore;
    double? shortestDistance;

    for (final store in stores) {
      final distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        (store["lat"] as num).toDouble(),
        (store["lng"] as num).toDouble(),
      );

      if (shortestDistance == null || distance < shortestDistance) {
        shortestDistance = distance;
        closestStore = store;
      }
    }

    return closestStore;
  }

  Future<Map<String, dynamic>?> findClosestTradeStore(
    Position position,
    String tradeType,
    List<CartItem> cartItems,
  ) async {
    final specialtyTags = cartItems
        .map((item) => item.specialtyStoreTag)
        .whereType<String>()
        .toSet()
        .toList();

    final manualStore = findClosestManualTradeStore(
      position,
      tradeType,
      specialtyTags,
    );

    if (manualStore != null) {
      print(
        "Manual Store Selected: " +
            (manualStore["storeName"] ?? "Manual Store").toString(),
      );
      return manualStore;
    }

    String keyword;

    if (tradeType == "Plumbing") {
      keyword = "plumbing supply store";
    } else if (tradeType == "Electrical") {
      keyword = "electrical supply store";
    } else {
      keyword = "hvac supply store";
    }

    final apiKey = "AIzaSyDSfFnud2nPQy9FHcJlqOBKDhbMrYrWP0E";

    final url =
        "https://maps.googleapis.com/maps/api/place/nearbysearch/json"
        "?location=${position.latitude},${position.longitude}"
        "&rankby=distance"
        "&keyword=$keyword"
        "&key=$apiKey";

    final response = await http.get(Uri.parse(url));

    if (response.statusCode != 200) {
      print("Places API failed");
      return null;
    }

    final data = jsonDecode(response.body);

    print("🌍 STORE SEARCH RESPONSE: ${response.body}");

    if (data["results"] == null || data["results"].isEmpty) {
      print("No trade stores found");
      return null;
    }

    Map<String, dynamic>? fallbackStore;

    for (final store in data["results"]) {
      final isOpen = store["opening_hours"]?["open_now"] ?? false;

      if (isOpen) {
        return {
          "id": store["place_id"],
          "storeName": store["name"],
          "lat": store["geometry"]["location"]["lat"],
          "lng": store["geometry"]["location"]["lng"],
          "address": store["vicinity"] ?? "",
        };
      }

      fallbackStore ??= store;
    }

    if (fallbackStore != null) {
      return {
        "id": fallbackStore["place_id"],
        "storeName": fallbackStore["name"],
        "lat": fallbackStore["geometry"]["location"]["lat"],
        "lng": fallbackStore["geometry"]["location"]["lng"],
        "address": fallbackStore["vicinity"] ?? "",
      };
    }

    return null;
  }

  Future<List<String>> findNearbyDrivers(
    double customerLat,
    double customerLng, {
    bool requiresCarDelivery = false,
  }) async {
    final snapshot = await FirebaseFirestore.instance
        .collection('drivers')
        .get();

    List<Map<String, dynamic>> driversWithDistance = [];

    for (var doc in snapshot.docs) {
      final data = doc.data();
      if (data["active"] != true) {
        continue;
      }
      if (data["isBusy"] == true) {
        continue;
      }
      if (requiresCarDelivery &&
          !motorVehicleTypes.contains(data["vehicleType"])) {
        continue;
      }

      if (data["lat"] == null || data["lng"] == null) {
        continue;
      }

      double driverLat = data["lat"];
      double driverLng = data["lng"];

      double distance = Geolocator.distanceBetween(
        customerLat,
        customerLng,
        driverLat,
        driverLng,
      );

      if (distance > 24140) {
        continue;
      }

      driversWithDistance.add({"driverId": doc.id, "distance": distance});
    }

    driversWithDistance.sort((a, b) => a["distance"].compareTo(b["distance"]));

    return driversWithDistance
        .take(5) // 🔥 nearest 5 drivers
        .map((driver) => driver["driverId"] as String)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final subtotal = widget.cart.fold(
      0.0,
      (sum, item) => sum + (item.price * item.quantity),
    );

    double deliveryFee = minDeliveryFee;

    double tax = subtotal * taxRate;

    double total = subtotal + deliveryFee + tax;

    String formattedBrand = brand != null && brand!.isNotEmpty
        ? "${brand![0].toUpperCase()}${brand!.substring(1)}"
        : "Card";

    return Scaffold(
      appBar: AppBar(title: Text("Checkout")),
      body: Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                itemCount: widget.cart.length,
                itemBuilder: (context, index) {
                  return ListTile(
                    title: Text(widget.cart[index].name),
                    subtitle: Text(
                      "\$${(widget.cart[index].price as num).toDouble().toStringAsFixed(2)} x ${widget.cart[index].quantity} = \$${((widget.cart[index].price * widget.cart[index].quantity) as num).toDouble().toStringAsFixed(2)}",
                    ),
                  );
                },
              ),
            ),

            if (isLoadingPayment)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("Subtotal: \$${subtotal.toStringAsFixed(2)}"),
                        SizedBox(height: 4),

                        Text(
                          "Delivery Fee: \$${deliveryFee.toStringAsFixed(2)}",
                        ),
                        SizedBox(height: 4),

                        Text("Tax: \$${tax.toStringAsFixed(2)}"),
                        SizedBox(height: 8),

                        Divider(),

                        Text(
                          "Total: \$${total.toStringAsFixed(2)}",
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                      ],
                    ),
                  ),

                  if (hasPaymentMethod && selectedLast4 != null)
                    GestureDetector(
                      onTap: showPaymentMethodSelector,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Container(
                          width: double.infinity,
                          padding: EdgeInsets.symmetric(
                            vertical: 12,
                            horizontal: 12,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.grey[100],
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.grey.shade400),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              getCardLogo(selectedBrand),
                              SizedBox(width: 10),

                              Expanded(
                                child: Text(
                                  "Payment to ${selectedBrand![0].toUpperCase()}${selectedBrand!.substring(1)} •••• $selectedLast4",
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),

                              Icon(Icons.arrow_drop_down),
                            ],
                          ),
                        ),
                      ),
                    ),

                  SizedBox(height: 20),

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed:
                          (!isAddingPaymentMethod && paymentMethods.length < 5)
                          ? addPaymentMethod
                          : null,
                      child: isAddingPaymentMethod
                          ? SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              paymentMethods.length >= 5
                                  ? "Maximum of 5 payment methods reached"
                                  : "Add Payment Method",
                            ),
                    ),
                  ),

                  SizedBox(height: 12),

                  // 🔻 PLACE ORDER BUTTON (below it)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: (hasPaymentMethod && !isPlacingOrder)
                          ? () async {
                              setState(() {
                                isPlacingOrder = true;
                              });

                              try {
                                final user = FirebaseAuth.instance.currentUser;

                                final userDoc = await FirebaseFirestore.instance
                                    .collection('users')
                                    .doc(user!.uid)
                                    .get();

                                final userData = userDoc.data();

                                double lat;
                                double lng;
                                String address;

                                if (widget.useSavedAddress &&
                                    userData?['lat'] != null &&
                                    userData?['lng'] != null) {
                                  lat = (userData?['lat'] as num).toDouble();
                                  lng = (userData?['lng'] as num).toDouble();
                                  address =
                                      userData?['address'] ?? "Saved Address";
                                } else {
                                  final position =
                                      await Geolocator.getCurrentPosition();

                                  lat = position.latitude;
                                  lng = position.longitude;
                                  address = "Current Location";

                                  await FirebaseFirestore.instance
                                      .collection('users')
                                      .doc(user.uid)
                                      .update({
                                        "lat": lat,
                                        "lng": lng,
                                        "address": address,
                                      });
                                }

                                final position = Position(
                                  latitude: lat,
                                  longitude: lng,
                                  timestamp: DateTime.now(),
                                  accuracy: 0,
                                  altitude: 0,
                                  heading: 0,
                                  speed: 0,
                                  speedAccuracy: 0,
                                  altitudeAccuracy: 0,
                                  headingAccuracy: 0,
                                );

                                final closestStore =
                                    await findClosestTradeStore(
                                      position,
                                      widget.tradeType,
                                      widget.cart,
                                    );
                                print(
                                  "🏪 Nearest Store: ${closestStore?["storeName"]}",
                                );
                                print(
                                  "📍 Address: ${closestStore?["address"]}",
                                );
                                print("🌎 Lat: ${closestStore?["lat"]}");
                                print("🌎 Lng: ${closestStore?["lng"]}");

                                if (closestStore == null) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        "No nearby supply store found for this trade",
                                      ),
                                    ),
                                  );
                                  return;
                                }

                                if (selectedPaymentMethodId == null) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        "Please select a payment method",
                                      ),
                                    ),
                                  );
                                  return;
                                }

                                final nearbyDrivers = await findNearbyDrivers(
                                  (closestStore["lat"] as num).toDouble(),
                                  (closestStore["lng"] as num).toDouble(),
                                  requiresCarDelivery: cartRequiresCarDelivery(
                                    widget.cart,
                                  ),
                                );

                                print(
                                  "🚗 Nearby Drivers Found: ${nearbyDrivers.length}",
                                );

                                if (nearbyDrivers.isEmpty) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        "No nearby drivers available right now",
                                      ),
                                    ),
                                  );
                                  return;
                                }

                                double subtotal = widget.cart.fold(
                                  0.0,
                                  (sum, item) =>
                                      sum + (item.price * item.quantity),
                                );

                                double deliveryFee = minDeliveryFee;
                                double tax = subtotal * taxRate;
                                double total = subtotal + deliveryFee + tax;

                                final callable = FirebaseFunctions.instance
                                    .httpsCallable('createPaymentIntent');

                                await callable.call({
                                  "amount": (total * 100).toInt(),
                                  "paymentMethodId": selectedPaymentMethodId,
                                });

                                print("💰 PAYMENT SUCCESS");

                                // 🧾 SAVE ORDER
                                final orderRef = await FirebaseFirestore
                                    .instance
                                    .collection('orders')
                                    .add({
                                      "customerLat": lat,
                                      "customerLng": lng,
                                      "customerAddress": address,
                                      "customerName":
                                          userData?['name'] ?? "Unknown",
                                      "date": DateTime.now().toIso8601String(),
                                      "createdAt": FieldValue.serverTimestamp(),

                                      "storeLat": closestStore["lat"],
                                      "storeLng": closestStore["lng"],
                                      "storeId": closestStore["id"],
                                      "storeName":
                                          closestStore["storeName"] ?? "Store",

                                      "items": widget.cart
                                          .map(
                                            (item) => {
                                              "name": item.name,
                                              "price": item.price,
                                              "image": item.image,
                                              "quantity": item.quantity,
                                              requiresCarDeliveryKey:
                                                  item.requiresCarDelivery,
                                            },
                                          )
                                          .toList(),

                                      "subtotal": subtotal,
                                      "deliveryFee": deliveryFee,
                                      "tax": tax,
                                      "total": total,

                                      "status": "Pending",
                                      "dispatchStatus": "queued",
                                      "dispatchAttempts": 0,
                                      "tradeType": widget.tradeType,
                                      requiresCarDeliveryKey:
                                          cartRequiresCarDelivery(widget.cart),
                                      "eligibleDrivers": nearbyDrivers,
                                      "userId": user.uid,
                                    });

                                final savedOrder = await orderRef.get(
                                  const GetOptions(source: Source.server),
                                );

                                if (!savedOrder.exists) {
                                  throw StateError(
                                    "Order was not confirmed by the server.",
                                  );
                                }

                                final result = await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => OrderSuccessScreen(),
                                  ),
                                );

                                if (result == "orderPlaced") {
                                  Navigator.pop(context, "orderPlaced");
                                }
                              } catch (e) {
                                print("❌ ERROR: $e");

                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text("Something went wrong"),
                                  ),
                                );
                              } finally {
                                setState(() {
                                  isPlacingOrder = false;
                                });
                              }
                            }
                          : null,
                      child: isPlacingOrder
                          ? SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              hasPaymentMethod
                                  ? "Place Order"
                                  : "Add payment method first",
                            ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class OrderSuccessScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle, color: Colors.green, size: 80),
            SizedBox(height: 20),
            Text(
              "Order Placed!",
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 10),
            Text("Your order has been successfully placed."),

            SizedBox(height: 30),

            ElevatedButton(
              onPressed: () {
                Navigator.pop(context, "orderPlaced");
              },
              child: Text("Back to Home"),
            ),
          ],
        ),
      ),
    );
  }
}

class NotificationsScreen extends StatelessWidget {
  IconData iconForStatus(String status) {
    switch (status) {
      case "Accepted":
        return Icons.check_circle;
      case "Picked Up":
        return Icons.inventory_2;
      case "Delivered":
        return Icons.done_all;
      case "Rejected":
        return Icons.cancel;
      default:
        return Icons.receipt_long;
    }
  }

  Color colorForStatus(String status) {
    switch (status) {
      case "Accepted":
        return Colors.blue;
      case "Picked Up":
        return Colors.orange;
      case "Delivered":
        return Colors.green;
      case "Rejected":
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  String messageForOrder(Map<String, dynamic> order) {
    final status = order['status'] ?? 'Pending';
    final storeName = order['storeName'] ?? 'the supply store';

    switch (status) {
      case "Accepted":
        return "A driver accepted your order from $storeName.";
      case "Picked Up":
        return "Your order was picked up from $storeName.";
      case "Delivered":
        return "Your order was delivered.";
      case "Rejected":
        return "Your order could not be completed.";
      default:
        return "Your order was placed and is waiting for a driver.";
    }
  }

  DateTime orderDate(Map<String, dynamic> order) {
    final createdAt = order['createdAt'];
    final date = order['date'];

    if (createdAt is Timestamp) {
      return createdAt.toDate();
    }

    if (date is String) {
      return DateTime.tryParse(date) ?? DateTime.fromMillisecondsSinceEpoch(0);
    }

    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  String formatDate(DateTime date) {
    if (date.millisecondsSinceEpoch == 0) return "";

    final hour = date.hour > 12
        ? date.hour - 12
        : date.hour == 0
        ? 12
        : date.hour;
    final minute = date.minute.toString().padLeft(2, '0');
    final period = date.hour >= 12 ? "PM" : "AM";

    return "${date.month}/${date.day}/${date.year} $hour:$minute $period";
  }

  void openOrderTracker(BuildContext context, String orderId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CustomerOrderTrackingScreen(orderId: orderId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: Text("Notifications")),
        body: Center(child: Text("Log in to view notifications")),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text("Notifications")),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('orders')
            .where('userId', isEqualTo: user.uid)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Center(child: CircularProgressIndicator());
          }

          final orders = snapshot.data!.docs.toList();

          orders.sort((a, b) {
            final aData = a.data() as Map<String, dynamic>;
            final bData = b.data() as Map<String, dynamic>;
            return orderDate(bData).compareTo(orderDate(aData));
          });

          if (orders.isEmpty) {
            return Center(child: Text("No notifications yet"));
          }

          return ListView.separated(
            itemCount: orders.length,
            separatorBuilder: (context, index) => Divider(height: 1),
            itemBuilder: (context, index) {
              final orderDoc = orders[index];
              final order = orderDoc.data() as Map<String, dynamic>;
              final status = order['status'] ?? 'Pending';
              final total = ((order['total'] ?? 0) as num).toDouble();
              final dateText = formatDate(orderDate(order));

              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: colorForStatus(status).withOpacity(0.12),
                  child: Icon(
                    iconForStatus(status),
                    color: colorForStatus(status),
                  ),
                ),
                title: Text(
                  messageForOrder(order),
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  dateText.isEmpty
                      ? "Order total: \$${total.toStringAsFixed(2)}"
                      : "$dateText\nOrder total: \$${total.toStringAsFixed(2)}",
                ),
                isThreeLine: dateText.isNotEmpty,
                trailing: Icon(Icons.map),
                onTap: () => openOrderTracker(context, orderDoc.id),
              );
            },
          );
        },
      ),
    );
  }
}

class CustomerOrderTrackingScreen extends StatelessWidget {
  final String orderId;

  CustomerOrderTrackingScreen({required this.orderId});

  Color colorForStatus(String status) {
    switch (status) {
      case "Accepted":
        return Colors.blue;
      case "Picked Up":
        return Colors.orange;
      case "Delivered":
        return Colors.green;
      case "Rejected":
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  String trackingMessage(String status, bool hasDriver) {
    if (!hasDriver) return "Waiting for a driver to accept this order.";

    switch (status) {
      case "Accepted":
        return "Driver is heading to the supply store.";
      case "Picked Up":
        return "Driver picked up the parts and is heading to you.";
      case "Delivered":
        return "This order was delivered.";
      default:
        return "Tracking will update when the driver starts moving.";
    }
  }

  LatLng? latLngFromOrder(
    Map<String, dynamic> order,
    String latKey,
    String lngKey,
  ) {
    final lat = order[latKey];
    final lng = order[lngKey];

    if (lat is num && lng is num) {
      return LatLng(lat.toDouble(), lng.toDouble());
    }

    return null;
  }

  LatLng? driverLatLng(Map<String, dynamic>? driver) {
    if (driver == null) return null;

    final lat = driver['lat'];
    final lng = driver['lng'];

    if (lat is num && lng is num) {
      return LatLng(lat.toDouble(), lng.toDouble());
    }

    return null;
  }

  LatLng mapCenter(LatLng? driver, LatLng? store, LatLng? customer) {
    return driver ?? store ?? customer ?? LatLng(40.7128, -74.0060);
  }

  Set<Marker> buildMarkers({
    required LatLng? driver,
    required LatLng? store,
    required LatLng? customer,
  }) {
    return {
      if (driver != null)
        Marker(
          markerId: MarkerId("driver"),
          position: driver,
          infoWindow: InfoWindow(title: "Driver"),
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueAzure,
          ),
        ),
      if (store != null)
        Marker(
          markerId: MarkerId("store"),
          position: store,
          infoWindow: InfoWindow(title: "Supply Store"),
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueGreen,
          ),
        ),
      if (customer != null)
        Marker(
          markerId: MarkerId("customer"),
          position: customer,
          infoWindow: InfoWindow(title: "Delivery Address"),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        ),
    };
  }

  Set<Polyline> buildPolylines({
    required LatLng? driver,
    required LatLng? store,
    required LatLng? customer,
    required String status,
  }) {
    return {
      if (driver != null && store != null && status == "Accepted")
        Polyline(
          polylineId: PolylineId("driverToStore"),
          points: [driver, store],
          color: Colors.blue,
          width: 5,
        ),
      if (driver != null && customer != null && status == "Picked Up")
        Polyline(
          polylineId: PolylineId("driverToCustomer"),
          points: [driver, customer],
          color: Colors.green,
          width: 5,
        ),
      if (store != null && customer != null && status != "Delivered")
        Polyline(
          polylineId: PolylineId("storeToCustomer"),
          points: [store, customer],
          color: Colors.green.withOpacity(0.25),
          width: 4,
        ),
    };
  }

  Widget infoTile(IconData icon, String title, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Colors.grey.shade700),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                SizedBox(height: 2),
                Text(value, style: TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget itemImage(String? imagePath) {
    if (imagePath == null || imagePath.isEmpty) {
      return Container(
        width: 48,
        height: 48,
        color: Colors.grey.shade200,
        alignment: Alignment.center,
        child: Icon(Icons.inventory_2, color: Colors.grey),
      );
    }

    return Image.asset(
      imagePath,
      width: 48,
      height: 48,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) {
        return Container(
          width: 48,
          height: 48,
          color: Colors.grey.shade200,
          alignment: Alignment.center,
          child: Icon(Icons.inventory_2, color: Colors.grey),
        );
      },
    );
  }

  Widget buildOrderPanel(
    Map<String, dynamic> order,
    Map<String, dynamic>? driver,
  ) {
    final status = order['status'] ?? 'Pending';
    final items = (order['items'] as List?) ?? [];
    final total = ((order['total'] ?? 0) as num).toDouble();
    final driverName =
        driver?['name'] ?? driver?['driverName'] ?? 'Assigned driver';
    final hasDriver = order['driverId'] != null;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.12),
            blurRadius: 12,
            offset: Offset(0, -3),
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: colorForStatus(status).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      color: colorForStatus(status),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Spacer(),
                Text(
                  "\$${total.toStringAsFixed(2)}",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            SizedBox(height: 12),
            Text(
              trackingMessage(status, hasDriver),
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 8),
            infoTile(
              Icons.store,
              "Store",
              order['storeName'] ?? 'Supply store',
            ),
            infoTile(
              Icons.person,
              "Driver",
              hasDriver ? driverName : 'Not assigned yet',
            ),
            infoTile(Icons.inventory_2, "Parts", "${items.length} items"),
            SizedBox(height: 8),
            Text(
              "Order Items",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            ...items.take(4).map((item) {
              final itemMap = item is Map ? item : <String, dynamic>{};
              final name = (itemMap['name'] ?? 'Part').toString();
              final quantity = itemMap['quantity'] ?? 1;
              final imagePath = itemMap['image'] as String?;
              final canOpenImage = imagePath != null && imagePath.isNotEmpty;

              return Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: canOpenImage
                      ? () {
                          appNavigatorKey.currentState?.push(
                            MaterialPageRoute(
                              builder: (_) => FullScreenPartImageScreen(
                                imagePath: imagePath,
                                title: name,
                              ),
                            ),
                          );
                        }
                      : null,
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: itemImage(imagePath),
                            ),
                            if (canOpenImage)
                              Positioned(
                                right: 3,
                                bottom: 3,
                                child: Container(
                                  padding: EdgeInsets.all(2),
                                  decoration: BoxDecoration(
                                    color: Colors.black54,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.zoom_in,
                                    color: Colors.white,
                                    size: 13,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text("x$quantity"),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
            if (items.length > 4)
              Text(
                "+${items.length - 4} more items",
                style: TextStyle(color: Colors.grey.shade600),
              ),
          ],
        ),
      ),
    );
  }

  Widget buildTracker(
    Map<String, dynamic> order,
    Map<String, dynamic>? driver,
  ) {
    final status = order['status'] ?? 'Pending';
    final store = latLngFromOrder(order, 'storeLat', 'storeLng');
    final customer = latLngFromOrder(order, 'customerLat', 'customerLng');
    final driverPosition = driverLatLng(driver);

    return Column(
      children: [
        Expanded(
          flex: 5,
          child: GoogleMap(
            initialCameraPosition: CameraPosition(
              target: mapCenter(driverPosition, store, customer),
              zoom: 13,
            ),
            markers: buildMarkers(
              driver: driverPosition,
              store: store,
              customer: customer,
            ),
            polylines: buildPolylines(
              driver: driverPosition,
              store: store,
              customer: customer,
              status: status,
            ),
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
          ),
        ),
        Expanded(flex: 4, child: buildOrderPanel(order, driver)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Track Order")),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('orders')
            .doc(orderId)
            .snapshots(),
        builder: (context, orderSnapshot) {
          if (!orderSnapshot.hasData) {
            return Center(child: CircularProgressIndicator());
          }

          if (!orderSnapshot.data!.exists) {
            return Center(child: Text("Order not found"));
          }

          final order = orderSnapshot.data!.data() as Map<String, dynamic>;
          final driverId = order['driverId'];

          if (driverId is! String || driverId.isEmpty) {
            return buildTracker(order, null);
          }

          return StreamBuilder<DocumentSnapshot>(
            stream: FirebaseFirestore.instance
                .collection('drivers')
                .doc(driverId)
                .snapshots(),
            builder: (context, driverSnapshot) {
              final driver =
                  driverSnapshot.data?.data() as Map<String, dynamic>?;
              return buildTracker(order, driver);
            },
          );
        },
      ),
    );
  }
}

class OrderHistoryScreen extends StatelessWidget {
  final List<Order> orders;

  OrderHistoryScreen({required this.orders});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Order History")),
      body: orders.isEmpty
          ? Center(child: Text("No orders yet"))
          : ListView.builder(
              itemCount: orders.length,
              itemBuilder: (context, index) {
                final order = orders[index];

                return Card(
                  margin: EdgeInsets.all(10),
                  child: ListTile(
                    title: Text(
                      "Order \$${(order.total as num).toDouble().toStringAsFixed(2)}",
                    ),
                    subtitle: Text(order.date.toString()),
                    trailing: Icon(Icons.arrow_forward_ios),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              OrderDetailsScreen(order: order),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
    );
  }
}

class OrderDetailsScreen extends StatefulWidget {
  final Order order;

  OrderDetailsScreen({required this.order});

  @override
  _OrderDetailsScreenState createState() => _OrderDetailsScreenState();
}

//customers order details screen
class _OrderDetailsScreenState extends State<OrderDetailsScreen> {
  Widget buildTimeline(String status) {
    List<String> steps = [
      OrderStatus.pending,
      OrderStatus.accepted,
      OrderStatus.outForDelivery,
      OrderStatus.delivered,
    ];

    int currentIndex = steps.indexOf(status);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: List.generate(steps.length, (index) {
        bool isCompleted = index <= currentIndex;

        return Expanded(
          child: Column(
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: isCompleted ? Colors.green : Colors.grey[300],
                  shape: BoxShape.circle,
                ),
              ),

              if (index != steps.length - 1)
                Container(
                  height: 4,
                  color: index < currentIndex ? Colors.green : Colors.grey[300],
                ),

              SizedBox(height: 6),

              Text(
                steps[index],
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10,
                  color: isCompleted ? Colors.green : Colors.grey,
                ),
              ),
            ],
          ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;

    return Scaffold(
      appBar: AppBar(title: Text("Order Details")),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('orders')
            .doc(widget.order.id)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Center(child: CircularProgressIndicator());
          }

          final data = snapshot.data!.data() as Map<String, dynamic>;

          final status = data['status'] ?? "Pending";
          final total = data['total'] ?? 0;
          final items = data['items'] as List;

          return Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                buildTimeline(status),

                SizedBox(height: 25),

                Text(
                  "Total: \$${(total as num).toString()}",
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),

                SizedBox(height: 20),

                // 🔥 STATUS BADGE (updated)
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: status == "Pending"
                        ? Colors.orange.withOpacity(0.2)
                        : status == "Accepted"
                        ? Colors.green.withOpacity(0.2)
                        : status == "Rejected"
                        ? Colors.red.withOpacity(0.2)
                        : Colors.blue.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      color: status == "Pending"
                          ? Colors.orange
                          : status == "Accepted"
                          ? Colors.green
                          : status == "Rejected"
                          ? Colors.red
                          : Colors.blue,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),

                SizedBox(height: 30),

                Text(
                  "Items",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),

                SizedBox(height: 10),

                Expanded(
                  child: ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];

                      return Card(
                        margin: EdgeInsets.symmetric(vertical: 6),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ListTile(
                          leading: Image.asset(
                            item['image'],
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                          ),
                          title: Text(item['name']),
                          subtitle: Text(
                            "Qty: ${item['quantity']}\n"
                            "\$${(item['price'] as num).toDouble().toStringAsFixed(2)}\n"
                            "${item['description'] ?? ''}",
                          ),
                          trailing: Text(
                            "\$${(item['price'] as num).toDouble().toStringAsFixed(2)}",
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class AuthScreen extends StatefulWidget {
  @override
  _AuthScreenState createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool isLogin = true;
  bool obscurePassword = true;
  bool isLoading = false;

  String? errorMessage;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 900), // smoother
    );

    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut, // smoother than easeIn
    );

    _slideAnimation = Tween<Offset>(
      begin: Offset(0, 0.2), // start slightly lower
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _controller.forward();
  }

  Future<void> submit() async {
    FocusScope.of(context).unfocus();

    setState(() {
      isLoading = true;
    });

    try {
      if (isLogin) {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: emailController.text.trim(),
          password: passwordController.text.trim(),
        );

        if (!mounted) return;

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => RoleRouter()),
        );
      } else {
        setState(() {
          isLoading = false;
        });

        try {
          final credential = await FirebaseAuth.instance
              .createUserWithEmailAndPassword(
                email: emailController.text.trim(),
                password: passwordController.text.trim(),
              );

          print("✅ USER CREATED");

          if (!mounted) return;

          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => RoleRouter()),
          );
        } catch (e) {
          print("❌ ERROR: $e");
        }

        return;
      }
      setState(() {
        errorMessage = null;
      });
    } catch (e) {
      String message = "Something went wrong";

      if (e is FirebaseAuthException) {
        print("ERROR CODE: ${e.code}"); // 👈 debug line

        switch (e.code) {
          case 'user-not-found':
            message = "No user found for that email";
            break;

          case 'wrong-password':
            message = "Incorrect password";
            break;

          case 'invalid-credential': // 🔥 VERY COMMON (new Firebase)
            message = "Incorrect email or password";
            break;

          case 'email-already-in-use':
            message = "Email already in use";
            break;

          case 'invalid-email':
            message = "Invalid email format";
            break;

          case 'weak-password':
            message = "Password must be at least 6 characters";
            break;

          default:
            message = e.message ?? "Login failed";
        }
      }

      setState(() {
        errorMessage = message;
      });
    }

    setState(() {
      isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 👇 BACKGROUND IMAGE
          Positioned.fill(
            child: Image.asset(
              "assets/images/APPRENTICEAPPLOGO.png",
              fit: BoxFit.cover,
            ),
          ),

          // 👇 DARK OVERLAY (important)
          Positioned.fill(
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: Container(color: Colors.black.withOpacity(0.4)),
            ),
          ),

          // 👇 LOGIN FORM
          Align(
            alignment: Alignment(0, 0.7),
            child: SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: FadeTransition(
                  opacity: _fadeAnimation,
                  child: SlideTransition(
                    position: _slideAnimation,
                    child: Container(
                      padding: EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.90),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black26,
                            blurRadius: 15,
                            offset: Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (errorMessage != null)
                            Container(
                              width: double.infinity,
                              margin: EdgeInsets.only(bottom: 15),
                              padding: EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.red[100],
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.red),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.error, color: Colors.red),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      errorMessage!,
                                      style: TextStyle(color: Colors.red[900]),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          Text(
                            isLogin ? "Login" : "Sign Up",
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),

                          SizedBox(height: 20),

                          TextField(
                            controller: emailController,
                            decoration: InputDecoration(
                              hintText: "Email",
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),

                          SizedBox(height: 15),

                          TextField(
                            controller: passwordController,
                            obscureText: obscurePassword,
                            decoration: InputDecoration(
                              hintText: "Password",
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),

                              // 👇 ADD THIS
                              suffixIcon: IconButton(
                                icon: Icon(
                                  obscurePassword
                                      ? Icons.visibility
                                      : Icons.visibility_off,
                                ),
                                onPressed: () {
                                  setState(() {
                                    obscurePassword = !obscurePassword;
                                  });
                                },
                              ),
                            ),
                          ),

                          SizedBox(height: 20),

                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: isLoading ? null : submit,
                              child: isLoading
                                  ? SizedBox(
                                      height: 20,
                                      width: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Text(isLogin ? "Login" : "Sign Up"),
                            ),
                          ),

                          TextButton(
                            onPressed: () {
                              setState(() {
                                isLogin = !isLogin;
                              });
                            },
                            child: Text(
                              isLogin
                                  ? "Create account"
                                  : "Already have an account?",
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class ProfileScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(title: Text("Profile")),
      body: Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "User Info",
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),

            SizedBox(height: 20),

            Text(
              "Email: ${user?.email ?? "No email"}",
              style: TextStyle(fontSize: 18),
            ),

            SizedBox(height: 30),

            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () async {
                await FirebaseAuth.instance.signOut();

                if (!context.mounted) return;

                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (_) => RoleRouter()),
                  (route) => false,
                );
              },
              child: Text("Logout"),
            ),
          ],
        ),
      ),
    );
  }
}

class SplashScreen extends StatefulWidget {
  @override
  _SplashScreenState createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: Duration(seconds: 2),
    );

    _fadeAnimation = CurvedAnimation(parent: _controller, curve: Curves.easeIn);

    _controller.forward();

    // ✅ STEP 1 GOES RIGHT HERE
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startAppFlow();
    });
  }

  Future<void> _startAppFlow() async {
    // 🔥 TEMP reset(resets User on Mobile Device Cache)
    await FirebaseAuth.instance.signOut();

    await Future.delayed(Duration(seconds: 3));

    final user = FirebaseAuth.instance.currentUser;

    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => user == null ? AuthScreen() : RoleRouter(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 👇 FULL SCREEN IMAGE
          Positioned.fill(
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: Image.asset(
                "assets/images/APPRENTICEAPPLOGO.png",
                fit: BoxFit.cover,
              ),
            ),
          ),

          // 👇 DARK OVERLAY (adjust opacity here)
          Positioned.fill(
            child: Container(color: Colors.black.withOpacity(0.3)),
          ),
        ],
      ),
    );
  }

  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class RoleSelectionScreen extends StatefulWidget {
  final Function(String) onRoleSelected;

  const RoleSelectionScreen({required this.onRoleSelected});

  @override
  State<RoleSelectionScreen> createState() => _RoleSelectionScreenState();
}

class _RoleSelectionScreenState extends State<RoleSelectionScreen> {
  String? selectedRole;
  bool isLoading = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Choose your role",
              style: TextStyle(
                fontSize: 20, // smaller for AppBar
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              "How will you use the app?",
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
      ),
      body: SingleChildScrollView(
        child: AbsorbPointer(
          absorbing: isLoading,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                SizedBox(height: 20),

                Text(
                  "How will you use the app?",
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),

                SizedBox(height: 30),

                _roleCard("Customer", Icons.person, Colors.blue),
                _roleCard("Store", Icons.store, Colors.green),
                _roleCard("Driver", Icons.local_shipping, Colors.orange),

                SizedBox(height: 20),

                AnimatedOpacity(
                  duration: Duration(milliseconds: 200),
                  opacity: selectedRole == null ? 0.5 : 1,
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: selectedRole == null || isLoading
                          ? null
                          : () async {
                              setState(() => isLoading = true);

                              HapticFeedback.mediumImpact();

                              final user = FirebaseAuth.instance.currentUser;

                              String? storeName;

                              if (selectedRole == "store") {
                                storeName = await showDialog<String>(
                                  context: context,
                                  barrierDismissible: false,
                                  builder: (context) {
                                    final controller = TextEditingController();

                                    return AlertDialog(
                                      title: Text("Store Name"),
                                      content: TextField(
                                        controller: controller,
                                        textCapitalization:
                                            TextCapitalization.words,
                                        decoration: InputDecoration(
                                          hintText: "Enter your store name",
                                          border: OutlineInputBorder(),
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context),
                                          child: Text("Cancel"),
                                        ),
                                        ElevatedButton(
                                          onPressed: () {
                                            final name = controller.text.trim();
                                            if (name.isEmpty) return;
                                            Navigator.pop(context, name);
                                          },
                                          child: Text("Save"),
                                        ),
                                      ],
                                    );
                                  },
                                );

                                if (storeName == null || storeName.isEmpty) {
                                  setState(() => isLoading = false);
                                  return;
                                }
                              }

                              // 🔥 SHOW DIALOG FIRST (instant)
                              /*if (selectedRole == "store") {
                                storeName = await showDialog<String>(
                                  context: context,
                                  barrierDismissible:
                                      false, // 👈 prevents tapping outside
                                  builder: (context) {
                                    String name = "";

                                    return Dialog(
                                      insetPadding: EdgeInsets.all(20),
                                      child: Padding(
                                        padding: EdgeInsets.all(20),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              "Enter Store Name",
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),

                                            SizedBox(height: 16),

                                            TextField(
                                              onChanged: (value) =>
                                                  name = value,
                                              decoration: InputDecoration(
                                                hintText: "Store Name",
                                              ),
                                            ),

                                            SizedBox(height: 20),

                                            Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.end,
                                              children: [
                                                TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(context),
                                                  child: Text("Cancel"),
                                                ),
                                                ElevatedButton(
                                                  onPressed: () =>
                                                      Navigator.pop(
                                                        context,
                                                        name,
                                                      ),
                                                  child: Text("Save"),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                );

                                if (storeName == null || storeName.isEmpty) {
                                  setState(() => isLoading = false);
                                  return;
                                }
                              }*/

                              await FirebaseFirestore.instance
                                  .collection('users')
                                  .doc(user!.uid)
                                  .set({
                                    "email": user.email,
                                    "role": selectedRole,
                                    "storeName": storeName,
                                  }, SetOptions(merge: true));

                              // 🔥 CUSTOMER NAME CHECK
                              if (selectedRole == "customer") {
                                final user = FirebaseAuth.instance.currentUser;

                                final userDoc = await FirebaseFirestore.instance
                                    .collection('users')
                                    .doc(user!.uid)
                                    .get();

                                final name = userDoc.data()?['name'];

                                if (name == null ||
                                    name.toString().trim().isEmpty) {
                                  setState(() => isLoading = false);

                                  Navigator.pushReplacement(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => CustomerNameScreen(),
                                    ),
                                  );

                                  return;
                                }
                              }

                              // THEN save role
                              await FirebaseFirestore.instance
                                  .collection('users')
                                  .doc(user!.uid)
                                  .set({
                                    "email": user.email,
                                    "role": selectedRole,
                                    "storeName": storeName,
                                  }, SetOptions(merge: true));

                              await PushNotificationService.saveCurrentToken(
                                user.uid,
                              );

                              setState(() => isLoading = false);

                              widget.onRoleSelected(selectedRole!);
                            },
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: isLoading
                          ? SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : Text("Continue", style: TextStyle(fontSize: 18)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _roleCard(String role, IconData icon, Color color) {
    final isSelected = selectedRole == role.toLowerCase();

    return GestureDetector(
      onTap: () {
        setState(() {
          selectedRole = role.toLowerCase();
        });
      },
      child: AnimatedContainer(
        duration: Duration(milliseconds: 200),
        margin: EdgeInsets.only(bottom: 16),
        padding: EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isSelected ? color.withOpacity(0.15) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? color : Colors.grey.shade300,
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        transform: isSelected
            ? (Matrix4.identity()..scale(1.02))
            : Matrix4.identity(),
        child: Row(
          children: [
            if (role == "Driver") ...[
              Icon(Icons.local_shipping, size: 28, color: color),
              SizedBox(width: 6),
              Text("/", style: TextStyle(fontSize: 18)),
              SizedBox(width: 6),
              Icon(Icons.pedal_bike, size: 28, color: color),
            ] else ...[
              Icon(icon, size: 36, color: color),
            ],

            SizedBox(width: 20),

            Text(
              role,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),

            Spacer(),

            if (isSelected) Icon(Icons.check_circle, color: color),
          ],
        ),
      ),
    );
  }
}

class RoleRouter extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return AuthScreen();
    }

    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        final data = snapshot.data!.data() as Map<String, dynamic>?;

        // 📍 NO LOCATION → go to permission screen
        if (data == null || data['lat'] == null) {
          return LocationPermissionScreen();
        }

        // ✅ Location exists → continue app
        return _RoleRouterContent();
      },
    );
  }
}

class _RoleRouterContent extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(user!.uid)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        final doc = snapshot.data;

        if (doc == null || !doc.exists) {
          return _buildRoleSelection();
        }

        final data = doc.data() as Map<String, dynamic>?;

        // 🔥 1. LOCATION FIRST (moved up)
        if (data == null || data['lat'] == null) {
          return LocationPermissionScreen();
        }

        // 🔥 2. ROLE
        if (data['role'] == null) {
          return _buildRoleSelection();
        }

        final role = data['role'];

        // 🔥 3. CUSTOMER NAME
        if (role == "customer") {
          final name = data['name'];

          if (name == null || name.toString().trim().isEmpty) {
            return CustomerNameScreen();
          }
        }

        // 🔥 4. FINAL ROUTING
        if (role == "store") {
          final storeName = data['storeName'] ?? "My Store";
          return StoreDashboardScreen(storeName: storeName);
        } else if (role == "driver") {
          return FutureBuilder<DocumentSnapshot>(
            future: FirebaseFirestore.instance
                .collection('drivers')
                .doc(user.uid)
                .get(),
            builder: (context, driverSnapshot) {
              if (!driverSnapshot.hasData) {
                return Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }

              final driverDoc = driverSnapshot.data;

              if (driverDoc == null || !driverDoc.exists) {
                // 🔥 NO DRIVER PROFILE → SHOW ONBOARDING
                return DriverOnboardingScreen();
              }

              final driverData = driverDoc.data() as Map<String, dynamic>?;

              if (driverData?['onboardingComplete'] != true) {
                return DriverOnboardingScreen();
              }

              // ✅ HAS PROFILE → GO TO DRIVER SCREEN
              return DriverScreen();
            },
          );
        } else {
          return TradeStoreScreen();
        }
      },
    );
  }

  Widget _buildRoleSelection() {
    return RoleSelectionScreen(
      onRoleSelected: (selectedRole) async {
        final user = FirebaseAuth.instance.currentUser;

        print("🔥 ROLE SAVED");
      },
    );
  }
}

class StoreDashboardScreen extends StatefulWidget {
  final String storeName;

  const StoreDashboardScreen({required this.storeName});

  @override
  State<StoreDashboardScreen> createState() => _StoreDashboardScreenState();
}

class _StoreDashboardScreenState extends State<StoreDashboardScreen> {
  Future<void> updateStoreName() async {
    final user = FirebaseAuth.instance.currentUser;
    final controller = TextEditingController(text: widget.storeName);

    final newName = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text("Update Store Name"),
          content: TextField(
            controller: controller,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              hintText: "Store name",
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isEmpty) return;
                Navigator.pop(context, name);
              },
              child: Text("Save"),
            ),
          ],
        );
      },
    );

    if (user == null || newName == null || newName.isEmpty) return;

    await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
      "storeName": newName,
    }, SetOptions(merge: true));
  }

  Widget dashboardTile({
    required IconData icon,
    required String title,
    required String value,
    required Color color,
  }) {
    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  value,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: Text(widget.storeName),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: "Inventory",
            icon: Icon(Icons.assignment),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => StoreInventoryScreen()),
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: user == null
            ? null
            : FirebaseFirestore.instance
                  .collection('users')
                  .doc(user.uid)
                  .snapshots(),
        builder: (context, snapshot) {
          final data = snapshot.data?.data() as Map<String, dynamic>?;
          final storeName = data?['storeName'] ?? widget.storeName;
          final address = data?['address'] ?? 'No store address saved yet';

          return ListView(
            padding: EdgeInsets.all(16),
            children: [
              Container(
                padding: EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.green.shade700,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.store, color: Colors.white, size: 34),
                    SizedBox(height: 12),
                    Text(
                      storeName,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      "Store profile only. Orders are currently routed directly to drivers.",
                      style: TextStyle(color: Colors.white70, height: 1.3),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 16),
              dashboardTile(
                icon: Icons.badge,
                title: "Role",
                value: "Store account",
                color: Colors.green,
              ),
              dashboardTile(
                icon: Icons.location_on,
                title: "Location",
                value: address,
                color: Colors.blue,
              ),
              dashboardTile(
                icon: Icons.inventory_2,
                title: "Order Flow",
                value: "Store confirmation is off for launch",
                color: Colors.orange,
              ),
              SizedBox(height: 8),
              SizedBox(
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: updateStoreName,
                  icon: Icon(Icons.edit),
                  label: Text("Update Store Name"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade700,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              SizedBox(height: 10),
              SizedBox(
                height: 50,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => AddressSearchScreen()),
                    );
                  },
                  icon: Icon(Icons.location_on),
                  label: Text("Update Store Location"),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.green.shade800,
                    side: BorderSide(color: Colors.green.shade700),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class StoreInventoryScreen extends StatefulWidget {
  @override
  State<StoreInventoryScreen> createState() => _StoreInventoryScreenState();
}

class _StoreInventoryScreenState extends State<StoreInventoryScreen> {
  String selectedTrade = "All";
  String selectedCategory = "All";
  String searchText = "";
  bool isSaving = false;

  final List<String> trades = ["All", "Plumbing", "HVAC"];

  String inventoryKey(Map<String, dynamic> item) {
    final raw = "${item['trade']}|${item['name']}";
    return base64Url.encode(utf8.encode(raw));
  }

  List<Map<String, dynamic>> inventoryParts() {
    final plumbingParts = _PlumbingScreenState().parts.map((item) {
      return {
        "trade": "Plumbing",
        "name": item["name"] ?? "Part",
        "image": item["image"],
        "categories": item["categories"] ?? [],
      };
    });

    final hvacParts = _HVACScreenState().parts.map((item) {
      return {
        "trade": "HVAC",
        "name": item["name"] ?? "Part",
        "image": item["image"],
        "categories": item["categories"] ?? [],
      };
    });

    final seen = <String>{};
    final combined = [...plumbingParts, ...hvacParts].where((item) {
      final key = inventoryKey(item);
      if (seen.contains(key)) return false;
      seen.add(key);
      return true;
    }).toList();

    combined.sort((a, b) {
      final tradeCompare = a['trade'].toString().compareTo(
        b['trade'].toString(),
      );
      if (tradeCompare != 0) return tradeCompare;
      return a['name'].toString().compareTo(b['name'].toString());
    });

    return combined;
  }

  List<String> categoryTabs(List<Map<String, dynamic>> parts) {
    final categories = <String>{"All"};

    for (final item in parts) {
      if (selectedTrade != "All" && item['trade'] != selectedTrade) {
        continue;
      }

      final itemCategories = (item['categories'] as List?) ?? [];
      for (final category in itemCategories) {
        final label = category.toString().trim();
        if (label.isNotEmpty) {
          categories.add(label);
        }
      }
    }

    final sorted = categories.toList();
    sorted.sort((a, b) {
      if (a == "All") return -1;
      if (b == "All") return 1;
      return a.compareTo(b);
    });

    return sorted;
  }

  List<Map<String, dynamic>> filteredParts(List<Map<String, dynamic>> parts) {
    final query = searchText.trim().toLowerCase();

    return parts.where((item) {
      final tradeMatches =
          selectedTrade == "All" || item['trade'] == selectedTrade;
      final itemCategories = (item['categories'] as List?) ?? [];
      final categoryMatches =
          selectedCategory == "All" ||
          itemCategories.any(
            (category) => category.toString().trim() == selectedCategory,
          );
      final name = item['name'].toString().toLowerCase();
      final categories = itemCategories
          .map((category) => category.toString().toLowerCase())
          .join(' ');
      final searchMatches =
          query.isEmpty || name.contains(query) || categories.contains(query);

      return tradeMatches && categoryMatches && searchMatches;
    }).toList();
  }

  Widget partImage(String? imagePath) {
    if (imagePath == null || imagePath.isEmpty) {
      return Container(
        width: 48,
        height: 48,
        color: Colors.grey.shade200,
        alignment: Alignment.center,
        child: Icon(Icons.inventory_2, color: Colors.grey),
      );
    }

    return Image.asset(
      imagePath,
      width: 48,
      height: 48,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) {
        return Container(
          width: 48,
          height: 48,
          color: Colors.grey.shade200,
          alignment: Alignment.center,
          child: Icon(Icons.inventory_2, color: Colors.grey),
        );
      },
    );
  }

  Future<void> updateInventory({
    required Map<String, dynamic> item,
    required Map<String, dynamic> currentInventory,
    required bool carries,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || isSaving) return;

    setState(() => isSaving = true);

    final updatedInventory = Map<String, dynamic>.from(currentInventory);
    updatedInventory[inventoryKey(item)] = {
      "carries": carries,
      "name": item['name'],
      "trade": item['trade'],
      "image": item['image'],
      "updatedAt": DateTime.now().toIso8601String(),
    };

    await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
      "storeInventory": updatedInventory,
    }, SetOptions(merge: true));

    if (mounted) {
      setState(() => isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final allParts = inventoryParts();

    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(title: Text("Inventory"), centerTitle: true),
      body: user == null
          ? Center(child: Text("Log in to manage inventory"))
          : StreamBuilder<DocumentSnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(user.uid)
                  .snapshots(),
              builder: (context, snapshot) {
                final data = snapshot.data?.data() as Map<String, dynamic>?;
                final inventory = Map<String, dynamic>.from(
                  (data?['storeInventory'] as Map?) ?? {},
                );
                final categoryOptions = categoryTabs(allParts);
                if (!categoryOptions.contains(selectedCategory)) {
                  selectedCategory = "All";
                }
                final shownParts = filteredParts(allParts);
                final carriedCount = inventory.values.where((entry) {
                  return entry is Map && entry['carries'] == true;
                }).length;

                return Column(
                  children: [
                    Container(
                      color: Colors.white,
                      padding: EdgeInsets.fromLTRB(14, 12, 14, 10),
                      child: Column(
                        children: [
                          TextField(
                            decoration: InputDecoration(
                              hintText: "Search parts",
                              prefixIcon: Icon(Icons.search),
                              filled: true,
                              fillColor: Colors.grey.shade100,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide.none,
                              ),
                            ),
                            onChanged: (value) {
                              setState(() {
                                searchText = value;
                              });
                            },
                          ),
                          SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    children: trades.map((trade) {
                                      final selected = selectedTrade == trade;
                                      return Padding(
                                        padding: EdgeInsets.only(right: 8),
                                        child: ChoiceChip(
                                          label: Text(trade),
                                          selected: selected,
                                          selectedColor: Colors.green.shade700,
                                          labelStyle: TextStyle(
                                            color: selected
                                                ? Colors.white
                                                : Colors.black87,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          onSelected: (_) {
                                            setState(() {
                                              selectedTrade = trade;
                                              selectedCategory = "All";
                                            });
                                          },
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                ),
                              ),
                              Text(
                                "$carriedCount carried",
                                style: TextStyle(
                                  color: Colors.grey.shade700,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 8),
                          SizedBox(
                            height: 44,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              children: categoryOptions.map((category) {
                                final selected = selectedCategory == category;
                                return Padding(
                                  padding: EdgeInsets.only(right: 8),
                                  child: ChoiceChip(
                                    label: Text(
                                      category,
                                      style: TextStyle(
                                        color: selected
                                            ? Colors.white
                                            : Colors.black87,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    selected: selected,
                                    selectedColor: Colors.orange,
                                    backgroundColor: Colors.grey.shade200,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    onSelected: (_) {
                                      setState(() {
                                        selectedCategory = category;
                                      });
                                    },
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.separated(
                        padding: EdgeInsets.all(12),
                        itemCount: shownParts.length,
                        separatorBuilder: (context, index) =>
                            SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final item = shownParts[index];
                          final key = inventoryKey(item);
                          final saved = inventory[key];
                          final carries =
                              saved is Map && saved['carries'] == true;
                          final markedNo =
                              saved is Map && saved['carries'] == false;
                          final categories =
                              ((item['categories'] as List?) ?? [])
                                  .take(2)
                                  .join(' • ');

                          return Container(
                            padding: EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: carries
                                    ? Colors.green.shade200
                                    : markedNo
                                    ? Colors.red.shade100
                                    : Colors.grey.shade200,
                              ),
                            ),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: partImage(item['image'] as String?),
                                ),
                                SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item['name'].toString(),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      SizedBox(height: 3),
                                      Text(
                                        "${item['trade']}${categories.isEmpty ? '' : ' • $categories'}",
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Colors.grey.shade600,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                SizedBox(width: 8),
                                IconButton(
                                  tooltip: "Carry item",
                                  icon: Icon(
                                    carries
                                        ? Icons.check_circle
                                        : Icons.check_circle_outline,
                                    color: carries ? Colors.green : Colors.grey,
                                  ),
                                  onPressed: () => updateInventory(
                                    item: item,
                                    currentInventory: inventory,
                                    carries: true,
                                  ),
                                ),
                                IconButton(
                                  tooltip: "Do not carry",
                                  icon: Icon(
                                    markedNo
                                        ? Icons.cancel
                                        : Icons.cancel_outlined,
                                    color: markedNo ? Colors.red : Colors.grey,
                                  ),
                                  onPressed: () => updateInventory(
                                    item: item,
                                    currentInventory: inventory,
                                    carries: false,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

class StoreOrdersScreen extends StatefulWidget {
  final String storeName;

  const StoreOrdersScreen({required this.storeName});

  @override
  State<StoreOrdersScreen> createState() => _StoreOrdersScreenState();
}

class _StoreOrdersScreenState extends State<StoreOrdersScreen> {
  void showUpdateStoreNameDialog(BuildContext context) {
    final TextEditingController nameController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text("Update Store Name"),
          content: TextField(
            controller: nameController,
            decoration: InputDecoration(
              hintText: "Enter store name",
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () async {
                final user = FirebaseAuth.instance.currentUser;

                if (user == null || nameController.text.trim().isEmpty) {
                  return;
                }

                await FirebaseFirestore.instance
                    .collection('users')
                    .doc(user.uid)
                    .set({
                      "storeName": nameController.text.trim(),
                    }, SetOptions(merge: true));

                Navigator.pop(context);

                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text("Store name updated")));
              },
              child: Text("Save"),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Container(
              height: 70,
              color: Colors.blue,
              alignment: Alignment.bottomLeft, // 👈 moves text lower
              padding: EdgeInsets.only(
                left: 16,
                bottom: 12,
              ), // 👈 controls how low
              child: Text(
                "Store Menu",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Column(
              children: [
                ListTile(
                  leading: Icon(Icons.location_on),
                  title: Text("Update Location"),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => AddressSearchScreen()),
                    );
                  },
                ),

                // 👇 THIN GRAY LINE
                Divider(height: 1, thickness: 1, color: Colors.grey.shade300),

                ListTile(
                  leading: Icon(Icons.store),
                  title: Text("Update Store Name"),
                  onTap: () {
                    showUpdateStoreNameDialog(context);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
      appBar: AppBar(
        title: Text(
          widget.storeName,
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,

        leading: Builder(
          builder: (context) => IconButton(
            icon: Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),

        actions: [
          IconButton(
            icon: Icon(Icons.history),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => StoreOrderHistoryScreen()),
              );
            },
          ),
        ],
      ),

      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 🔵 INCOMING TITLE
            Text(
              "Incoming Orders",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),

            SizedBox(height: 10),

            // 🔵 INCOMING LIST
            Expanded(
              child: Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('orders')
                      .where(
                        'storeId',
                        isEqualTo: FirebaseAuth.instance.currentUser!.uid,
                      )
                      .where('status', isEqualTo: 'Pending')
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return Center(child: CircularProgressIndicator());
                    }

                    final orders = snapshot.data!.docs;

                    if (orders.isEmpty) {
                      return Center(child: Text("No incoming orders"));
                    }

                    return ListView.builder(
                      itemCount: orders.length,
                      itemBuilder: (context, index) {
                        final order =
                            orders[index].data() as Map<String, dynamic>;

                        return Padding(
                          padding: EdgeInsets.symmetric(vertical: 6),
                          child: _realOrderCard(
                            order,
                            orders[index].id,
                            context,
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ),

            SizedBox(height: 15),

            // 🟢 ACCEPTED BOX
            Container(
              height: 250,
              padding: EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Accepted Orders",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),

                  SizedBox(height: 10),

                  Expanded(
                    child: StreamBuilder<QuerySnapshot>(
                      stream: FirebaseFirestore.instance
                          .collection('orders')
                          .where(
                            'storeId',
                            isEqualTo: FirebaseAuth.instance.currentUser!.uid,
                          )
                          .where('status', isEqualTo: 'Accepted')
                          .snapshots(),
                      builder: (context, snapshot) {
                        if (!snapshot.hasData) {
                          return Center(child: CircularProgressIndicator());
                        }

                        final orders = snapshot.data!.docs;

                        if (orders.isEmpty) {
                          return Center(child: Text("No accepted orders"));
                        }

                        return ListView.builder(
                          itemCount: orders.length,
                          itemBuilder: (context, index) {
                            final order =
                                orders[index].data() as Map<String, dynamic>;

                            return _realOrderCard(
                              order,
                              orders[index].id,
                              context,
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class StoreOrderHistoryScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(title: Text("Order History")),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('orders')
            .where('storeId', isEqualTo: user!.uid)
            .where('status', isEqualTo: 'Delivered')
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Center(child: CircularProgressIndicator());
          }

          final orders = snapshot.data!.docs;

          if (orders.isEmpty) {
            return Center(child: Text("No completed orders"));
          }

          return ListView.builder(
            itemCount: orders.length,
            itemBuilder: (context, index) {
              final order = orders[index].data() as Map<String, dynamic>;

              return ListTile(
                title: Text(
                  "Order \$${(order['total'] as num).toDouble().toStringAsFixed(2)}",
                ),
                subtitle: Text("Delivered"),
              );
            },
          );
        },
      ),
    );
  }
}

Widget _realOrderCard(
  Map<String, dynamic> order,
  String orderId,
  BuildContext context,
) {
  return GestureDetector(
    onTap: () {
      Navigator.push(
        context, // ⚠️ we’ll fix this below
        MaterialPageRoute(
          builder: (_) =>
              StoreOrderDetailScreen(order: order, orderId: orderId),
        ),
      );
    },
    child: Container(
      margin: EdgeInsets.all(12),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Customer: ${order['customerName'] ?? 'Unknown'}",
            style: TextStyle(fontWeight: FontWeight.w500),
          ),

          SizedBox(height: 4),

          Text(
            "Order \$${((order['total'] ?? 0) as num).toDouble().toStringAsFixed(2)}",
            style: TextStyle(fontWeight: FontWeight.bold),
          ),

          SizedBox(height: 4),

          Text("Status: ${order['status'] ?? 'Pending'}"),
        ],
      ),
    ),
  );
}

class StoreOrderDetailScreen extends StatelessWidget {
  final Map<String, dynamic> order;
  final String orderId;

  const StoreOrderDetailScreen({required this.order, required this.orderId});

  @override
  Widget build(BuildContext context) {
    final items = (order['items'] as List?) ?? [];
    final status = order['status'] ?? "Pending";

    return Scaffold(
      appBar: AppBar(title: Text("Order Details")),
      body: Column(
        children: [
          // 🔽 ITEMS LIST
          Expanded(
            child: ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index] as Map<String, dynamic>;

                return Card(
                  margin: EdgeInsets.all(10),
                  child: ListTile(
                    leading: item['image'] != null
                        ? Image.asset(
                            item['image'],
                            width: 50,
                            height: 50,
                            fit: BoxFit.cover,
                          )
                        : Icon(Icons.image), // fallback

                    title: Text(item['name'] ?? "Item"),

                    subtitle: Text(
                      "Qty: ${item['quantity'] ?? 0}\n\$${((item['price'] ?? 0) as num).toDouble().toStringAsFixed(2)}",
                    ),
                  ),
                );
              },
            ),
          ),

          // 🔽 TOTAL + BUTTONS
          Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              children: [
                Text(
                  "Total: \$${((order['total'] ?? 0) as num).toDouble().toStringAsFixed(2)}",
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),

                SizedBox(height: 20),

                Row(
                  children: [
                    // 🟡 IF PENDING → show Accept + Reject
                    if (status == "Pending") ...[
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange,
                          ),
                          onPressed: () async {
                            await FirebaseFirestore.instance
                                .collection('orders')
                                .doc(orderId)
                                .update({"status": "Rejected"});

                            Navigator.pop(context);
                          },
                          child: Text("Reject"),
                        ),
                      ),

                      SizedBox(width: 10),

                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                          ),
                          onPressed: () async {
                            await FirebaseFirestore.instance
                                .collection('orders')
                                .doc(orderId)
                                .update({"status": "Accepted"});

                            Navigator.pop(context);
                          },
                          child: Text("Accept"),
                        ),
                      ),
                    ],

                    // 🔵 IF ACCEPTED → show Cancel
                    if (status == "Accepted")
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                          ),
                          onPressed: () async {
                            await FirebaseFirestore.instance
                                .collection('orders')
                                .doc(orderId)
                                .update({"status": "Pending"});

                            Navigator.pop(context);
                          },
                          child: Text("Cancel Order"),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Widget _orderCard(int index) {
  return Container(
    margin: EdgeInsets.all(12),
    padding: EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.05),
          blurRadius: 6,
          offset: Offset(0, 3),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "Order #$index",
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),

        SizedBox(height: 6),

        Text("Items: Pipes, Valves"),

        SizedBox(height: 6),

        Text("Status: Pending", style: TextStyle(color: Colors.orange)),
      ],
    ),
  );
}

class DriverOrderDetailsScreen extends StatelessWidget {
  final Map<String, dynamic> order;
  final String orderId;

  DriverOrderDetailsScreen({required this.order, required this.orderId});

  Widget itemImage(String? imagePath) {
    if (imagePath == null || imagePath.isEmpty) {
      return Container(
        width: 72,
        height: 72,
        color: Colors.grey.shade200,
        alignment: Alignment.center,
        child: Icon(Icons.inventory_2, color: Colors.grey),
      );
    }

    return Image.asset(
      imagePath,
      width: 72,
      height: 72,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) {
        return Container(
          width: 72,
          height: 72,
          color: Colors.grey.shade200,
          alignment: Alignment.center,
          child: Icon(Icons.inventory_2, color: Colors.grey),
        );
      },
    );
  }

  Color statusColor(String status) {
    switch (status) {
      case "Picked Up":
        return Colors.orange;
      case "Delivered":
        return Colors.green;
      case "Accepted":
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }

  int totalQuantity(List items) {
    int total = 0;

    for (final item in items) {
      if (item is Map<String, dynamic>) {
        total += (item['quantity'] ?? 1) as int;
      }
    }

    return total;
  }

  @override
  Widget build(BuildContext context) {
    final items = (order['items'] as List?) ?? [];
    final customerName = order['customerName'] ?? 'Customer';
    final storeName = order['storeName'] ?? 'Store';
    final status = order['status'] ?? 'Pending';
    final total = ((order['total'] ?? 0) as num).toDouble();
    final color = statusColor(status);

    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: Text("Order Parts"),
        actions: [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: color),
                ),
                child: Text(
                  status,
                  style: TextStyle(color: color, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(16, 14, 16, 16),
            color: Colors.white,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "$customerName's Order",
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 10),
                Row(
                  children: [
                    Icon(Icons.store, size: 18, color: Colors.grey.shade700),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        storeName,
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "PARTS",
                              style: TextStyle(
                                color: Colors.grey.shade700,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              "${totalQuantity(items)}",
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: Container(
                        padding: EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "TOTAL",
                              style: TextStyle(
                                color: Colors.grey.shade700,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              "\$${total.toStringAsFixed(2)}",
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? Center(child: Text("No parts listed for this order"))
                : ListView.builder(
                    padding: EdgeInsets.all(12),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index] as Map<String, dynamic>;
                      final quantity = item['quantity'] ?? 1;
                      final price = ((item['price'] ?? 0) as num).toDouble();
                      final lineTotal = price * (quantity as int);
                      final imagePath = item['image'] as String?;
                      final itemName = (item['name'] ?? 'Part').toString();
                      final canOpenImage =
                          imagePath != null && imagePath.isNotEmpty;

                      return Card(
                        margin: EdgeInsets.only(bottom: 10),
                        elevation: 1,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: canOpenImage
                              ? () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => FullScreenPartImageScreen(
                                        imagePath: imagePath,
                                        title: itemName,
                                      ),
                                    ),
                                  );
                                }
                              : null,
                          child: Padding(
                            padding: EdgeInsets.all(10),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Stack(
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: itemImage(imagePath),
                                    ),
                                    if (canOpenImage)
                                      Positioned(
                                        right: 4,
                                        bottom: 4,
                                        child: Container(
                                          padding: EdgeInsets.all(3),
                                          decoration: BoxDecoration(
                                            color: Colors.black54,
                                            shape: BoxShape.circle,
                                          ),
                                          child: Icon(
                                            Icons.zoom_in,
                                            color: Colors.white,
                                            size: 16,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        itemName,
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                        ),
                                      ),
                                      SizedBox(height: 8),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 6,
                                        children: [
                                          Container(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.blue.withOpacity(
                                                0.1,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                            ),
                                            child: Text(
                                              "Qty $quantity",
                                              style: TextStyle(
                                                color: Colors.blue.shade800,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                          Text(
                                            "\$${price.toStringAsFixed(2)} each",
                                            style: TextStyle(
                                              color: Colors.grey.shade700,
                                            ),
                                          ),
                                        ],
                                      ),
                                      SizedBox(height: 8),
                                      Text(
                                        canOpenImage
                                            ? "Tap item to view image"
                                            : "Image not available",
                                        style: TextStyle(
                                          color: canOpenImage
                                              ? Colors.green.shade700
                                              : Colors.grey,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                SizedBox(width: 8),
                                Text(
                                  "\$${lineTotal.toStringAsFixed(2)}",
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class FullScreenPartImageScreen extends StatelessWidget {
  final String imagePath;
  final String title;

  FullScreenPartImageScreen({required this.imagePath, required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: Image.asset(
                  imagePath,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) {
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.broken_image, color: Colors.white, size: 64),
                        SizedBox(height: 12),
                        Text(
                          "Image unavailable",
                          style: TextStyle(color: Colors.white),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: Colors.white, size: 30),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 🚚 DRIVER SCREEN

class DriverScreen extends StatefulWidget {
  @override
  State<DriverScreen> createState() => _DriverScreenState();
}

class _DriverScreenState extends State<DriverScreen> {
  StreamSubscription<Position>? positionStream;

  GoogleMapController? mapController;
  LatLng currentPosition = LatLng(0, 0);
  Timer? locationTimer;

  final ScrollController _scrollController = ScrollController();

  double? currentStoreLat;
  double? currentStoreLng;

  String? previewOrderId;
  double? previewStoreLat;
  double? previewStoreLng;
  double? previewCustomerLat;
  double? previewCustomerLng;
  String? previewDistance;
  String? previewDuration;

  Set<Polyline> polylines = {};

  bool isOnline = false;

  bool routeLoaded = false;
  bool isFetchingRoute = false;
  bool isPreviewingOrder = false;
  bool isOnActiveDelivery = false;
  bool isPickedUp = false;

  bool isUpdatingStatus = false;

  double customerRouteOpacity = 1.0;

  List<LatLng> storeRoutePoints = [];
  List<LatLng> customerRoutePoints = [];

  DateTime? lastRouteUpdate;
  LatLng? lastRoutePosition;

  DateTime? lastFirestoreUpdate;
  DateTime? lastCameraMove;

  String? distanceText;
  String? eta;

  bool shouldUpdateRoute(LatLng newPosition) {
    if (lastRouteUpdate == null || lastRoutePosition == null) {
      return true;
    }

    final timeDiff = DateTime.now().difference(lastRouteUpdate!).inSeconds;

    final distance = Geolocator.distanceBetween(
      lastRoutePosition!.latitude,
      lastRoutePosition!.longitude,
      newPosition.latitude,
      newPosition.longitude,
    );

    return timeDiff > 10 && distance > 30;
  }

  Future<void> getRoute() async {
    if (isFetchingRoute) return; // 👈 prevent overlap

    isFetchingRoute = true;

    try {
      if (currentStoreLat == null || currentStoreLng == null) return;

      final apiKey =
          "AIzaSyBO3ngDiG6UqOfAXcOeZ9TJiVbbwTsOGGo"; //Web for testing change later

      final url =
          "https://maps.googleapis.com/maps/api/directions/json?"
          "origin=${currentPosition.latitude},${currentPosition.longitude}"
          "&destination=$currentStoreLat,$currentStoreLng"
          "&key=$apiKey";

      final response = await http.get(Uri.parse(url));
      final data = jsonDecode(response.body);
      final status = data['status'];

      if (status != "OK") {
        print("❌ ROUTE ERROR: $status ${data['error_message'] ?? ''}");
        return;
      }

      final routes = data['routes'] as List?;
      if (routes == null || routes.isEmpty) {
        print("❌ ROUTE ERROR: Google returned no routes");
        return;
      }

      final leg = routes[0]['legs'][0];

      final distance = leg['distance']['text']; // "5.2 mi"
      final duration = leg['duration']['text']; // "12 mins"
      print("📦 ROUTE DATA: ${data['routes'][0]['legs'][0]}");

      final points = routes[0]['overview_polyline']['points'];
      final decoded = decodePolyline(points);

      if (!mounted) return;

      setState(() {
        storeRoutePoints = decoded;

        isOnActiveDelivery = true;

        distanceText = distance;
        eta = duration;
      });
    } finally {
      isFetchingRoute = false;
    }
  }

  Future<void> previewRoute() async {
    if (previewStoreLat == null ||
        previewStoreLng == null ||
        previewCustomerLat == null ||
        previewCustomerLng == null)
      return;

    final apiKey = "AIzaSyAekQ_K5c2zzW_wmDxZySFehntN1v2YVhU";

    try {
      // 🔹 DRIVER → STORE
      final url1 =
          "https://maps.googleapis.com/maps/api/directions/json?"
          "origin=${currentPosition.latitude},${currentPosition.longitude}"
          "&destination=$previewStoreLat,$previewStoreLng"
          "&key=$apiKey";

      // 🔹 STORE → CUSTOMER
      final url2 =
          "https://maps.googleapis.com/maps/api/directions/json?"
          "origin=$previewStoreLat,$previewStoreLng"
          "&destination=$previewCustomerLat,$previewCustomerLng"
          "&key=$apiKey";

      final res1 = await http.get(Uri.parse(url1));
      final res2 = await http.get(Uri.parse(url2));

      final data1 = jsonDecode(res1.body);
      final data2 = jsonDecode(res2.body);
      final status1 = data1['status'];
      final status2 = data2['status'];

      if (status1 != "OK" || status2 != "OK") {
        print(
          "❌ PREVIEW ROUTE ERROR: toStore=$status1 ${data1['error_message'] ?? ''} | toCustomer=$status2 ${data2['error_message'] ?? ''}",
        );
        return;
      }

      final routes1 = data1['routes'] as List?;
      final routes2 = data2['routes'] as List?;

      if (routes1 == null ||
          routes1.isEmpty ||
          routes2 == null ||
          routes2.isEmpty) {
        print("❌ PREVIEW ROUTE ERROR: Google returned no routes");
        return;
      }

      final leg1 = routes1[0]['legs'][0];
      final leg2 = routes2[0]['legs'][0];

      final distance1 = leg1['distance']['value']; // meters
      final distance2 = leg2['distance']['value'];

      final duration1 = leg1['duration']['value']; // seconds
      final duration2 = leg2['duration']['value'];

      final totalDistanceMeters = distance1 + distance2;
      final totalDurationSeconds = duration1 + duration2;

      final distanceMiles = (totalDistanceMeters / 1609).toStringAsFixed(1);

      final durationMinutes = (totalDurationSeconds / 60).round();

      final points1 = routes1[0]['overview_polyline']['points'];
      final points2 = routes2[0]['overview_polyline']['points'];

      final decoded1 = decodePolyline(points1);
      final decoded2 = decodePolyline(points2);

      // 🔥 STEP 6 — AUTO ZOOM
      final allPoints = [...decoded1, ...decoded2];
      zoomToFitRoute(allPoints);

      setState(() {
        storeRoutePoints = decoded1;
        customerRoutePoints = decoded2;

        customerRouteOpacity = 1.0;
        isOnActiveDelivery = false;

        previewDistance = "$distanceMiles mi";
        previewDuration = "$durationMinutes mins";
      });
    } catch (e) {
      print("❌ ERROR: $e");
    }
  }

  void zoomToFitRoute(List<LatLng> points) {
    if (points.isEmpty || mapController == null) return;

    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;

    for (var p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );

    mapController!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 80));
  }

  List<LatLng> decodePolyline(String encoded) {
    List<LatLng> poly = [];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;

    while (index < len) {
      int b, shift = 0, result = 0;

      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);

      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;

      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);

      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      poly.add(LatLng(lat / 1E5, lng / 1E5));
    }

    return poly;
  }

  Future<void> fadeOutCustomerRoute() async {
    for (double i = 1.0; i >= 0.2; i -= 0.1) {
      await Future.delayed(Duration(milliseconds: 30));

      if (!mounted) return;

      setState(() {
        customerRouteOpacity = i;
      });
    }

    setState(() {
      customerRoutePoints = [];
    });
  }

  void zoomToStoreRoute() {
    if (storeRoutePoints.isEmpty) return;
    zoomToFitRoute(storeRoutePoints);
  }

  void startTracking() {
    positionStream =
        Geolocator.getPositionStream(
          locationSettings: LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 25,
          ),
        ).listen((Position position) async {
          final user = FirebaseAuth.instance.currentUser;

          if (lastFirestoreUpdate == null ||
              DateTime.now().difference(lastFirestoreUpdate!).inSeconds > 10) {
            lastFirestoreUpdate = DateTime.now();

            await FirebaseFirestore.instance
                .collection('users')
                .doc(user!.uid)
                .update({
                  "lat": position.latitude,
                  "lng": position.longitude,
                  "lastUpdated": FieldValue.serverTimestamp(),
                });

            await FirebaseFirestore.instance
                .collection('drivers')
                .doc(user.uid)
                .set({
                  "lat": position.latitude,
                  "lng": position.longitude,
                  "lastUpdated": FieldValue.serverTimestamp(),
                }, SetOptions(merge: true));
          }

          final newPosition = LatLng(position.latitude, position.longitude);

          if (currentPosition.latitude != newPosition.latitude ||
              currentPosition.longitude != newPosition.longitude) {
            setState(() {
              currentPosition = newPosition;
            });
          }

          if (lastCameraMove == null ||
              DateTime.now().difference(lastCameraMove!).inSeconds > 3) {
            lastCameraMove = DateTime.now();

            mapController?.animateCamera(
              CameraUpdate.newCameraPosition(
                CameraPosition(
                  target: currentPosition,
                  zoom: 16,
                  tilt: 45,
                  bearing: 0,
                ),
              ),
            );
          }

          final newLatLng = LatLng(position.latitude, position.longitude);

          if (currentStoreLat != null &&
              currentStoreLng != null &&
              currentPosition.latitude != 0 &&
              shouldUpdateRoute(newLatLng)) {
            lastRouteUpdate = DateTime.now();
            lastRoutePosition = newLatLng;

            print("📍 TRYING ROUTE UPDATE");

            getRoute();
          }
        });
  }

  @override
  void initState() {
    super.initState();
    resetDriverBusyIfNoActiveOrder();

    // 🔥 RESET PREVIEW STATE
    previewOrderId = null;
    previewStoreLat = null;
    previewStoreLng = null;
    previewCustomerLat = null;
    previewCustomerLng = null;

    loadDriverStatus();
    startTracking();
  }

  Future<void> resetDriverBusyIfNoActiveOrder() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) return;

    final activeOrders = await FirebaseFirestore.instance
        .collection('orders')
        .where("driverId", isEqualTo: user.uid)
        .where("status", whereIn: ["Accepted", "Picked Up"])
        .get();

    if (activeOrders.docs.isEmpty) {
      await FirebaseFirestore.instance.collection('drivers').doc(user.uid).set({
        "isBusy": false,
      }, SetOptions(merge: true));

      print("✅ No active orders — Driver marked available");
    } else {
      print("🚗 Active order found — Driver remains busy");
    }
  }

  @override
  void dispose() {
    positionStream?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> loadDriverStatus() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) return;

    final doc = await FirebaseFirestore.instance
        .collection('drivers')
        .doc(user.uid)
        .get();

    if (!doc.exists) return;

    final data = doc.data();

    setState(() {
      isOnline = data?["active"] ?? false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser;
    debugPrint("🔥 isPreviewingOrder: $isPreviewingOrder");
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isOnline ? "🟢 Online" : "⚪ Offline",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SizedBox(width: 10),
            Switch(
              value: isOnline,
              activeColor: Colors.green,
              onChanged: (value) async {
                final user = FirebaseAuth.instance.currentUser;

                setState(() {
                  isOnline = value;

                  if (!isOnline) {
                    // 🔥 CLEAR ORDER UI STATE
                    previewOrderId = null;
                    isPreviewingOrder = false;
                  }
                });

                await FirebaseFirestore.instance
                    .collection('drivers')
                    .doc(user!.uid)
                    .set({
                      "active": isOnline,
                      "lastOnlineUpdate": FieldValue.serverTimestamp(),
                    }, SetOptions(merge: true));
              },
            ),
          ],
        ),

        leading: Builder(
          builder: (context) => IconButton(
            icon: Icon(Icons.person),
            onPressed: () {
              Scaffold.of(context).openDrawer();
            },
          ),
        ),

        actions: [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => DriverEarningsScreen()),
                );
              },
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(20),
                ),

                // 🔥 LIVE EARNINGS
                child: StreamBuilder<DocumentSnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('drivers')
                      .doc(FirebaseAuth.instance.currentUser!.uid)
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return Text(
                        "\$0.00",
                        style: TextStyle(color: Colors.white),
                      );
                    }

                    final data = snapshot.data!.data() as Map<String, dynamic>?;

                    final earnings = (data?['earnings'] ?? 0).toDouble();

                    return Text(
                      "\$${earnings.toStringAsFixed(2)}",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            // 🔵 HEADER
            DrawerHeader(
              decoration: BoxDecoration(color: Colors.blue),
              child: Text(
                "Driver Menu",
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
            ),

            // 👤 ACCOUNT
            ListTile(
              leading: Icon(Icons.person),
              title: Text("Account"),
              onTap: () {
                // navigate later
              },
            ),

            // 📦 ORDER HISTORY
            ListTile(
              leading: Icon(Icons.attach_money),
              title: Text("Earnings History"),
              onTap: () {
                Navigator.pop(context); // close drawer

                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => DriverEarningsHistoryScreen(),
                  ),
                );
              },
            ),
          ],
        ),
      ),

      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('orders')
            .where(
              "driverId",
              isEqualTo: FirebaseAuth.instance.currentUser!.uid,
            )
            .where("status", whereIn: ["Accepted", "Picked Up"])
            .snapshots(),
        builder: (context, activeSnapshot) {
          if (!activeSnapshot.hasData) return SizedBox();

          final activeOrders = activeSnapshot.data?.docs ?? [];

          final hasActiveOrder = activeOrders.isNotEmpty;

          return Column(
            children: [
              Container(
                height: 1,
                width: double.infinity,
                color: Colors.grey.shade300,
              ),
              // 🟢 ACTIVE DELIVERY
              if (hasActiveOrder)
                Builder(
                  builder: (context) {
                    final orderDoc = activeOrders.first;
                    final order = orderDoc.data() as Map<String, dynamic>;
                    final storeLat = (order['storeLat'] as num?)?.toDouble();
                    final storeLng = (order['storeLng'] as num?)?.toDouble();

                    if (storeLat != null && storeLng != null) {
                      final storeChanged =
                          currentStoreLat != storeLat ||
                          currentStoreLng != storeLng;

                      currentStoreLat = storeLat;
                      currentStoreLng = storeLng;

                      if ((storeChanged || storeRoutePoints.isEmpty) &&
                          !isFetchingRoute) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) {
                            getRoute();
                          }
                        });
                      }
                    }

                    final status = order['status'];

                    final customerName = order['customerName'] ?? "Customer";
                    final storeName = order['storeName'] ?? "Store";
                    final items = order['items'] as List? ?? [];

                    int totalQuantity = 0;

                    for (var item in items) {
                      totalQuantity += (item['quantity'] ?? 1) as int;
                    }

                    return Align(
                      alignment: Alignment.centerLeft,
                      child: GestureDetector(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DriverOrderDetailsScreen(
                                order: order,
                                orderId: orderDoc.id,
                              ),
                            ),
                          );
                        },
                        child: Container(
                          width: double.infinity,
                          padding: EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Color(0xFFE8F5E9),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "Active Delivery at $storeName",
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              Text(
                                "$customerName's Order: \$${((order['total'] ?? 0) as num).toDouble().toStringAsFixed(2)}",
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              Text("$totalQuantity items"),
                              SizedBox(height: 4),
                              Row(
                                children: [
                                  Icon(
                                    Icons.touch_app,
                                    size: 16,
                                    color: Colors.green[800],
                                  ),
                                  SizedBox(width: 4),
                                  Text(
                                    "Tap to view parts",
                                    style: TextStyle(
                                      color: Colors.green[800],
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 10),

                              if (distanceText != null && eta != null)
                                Padding(
                                  padding: EdgeInsets.only(top: 6),
                                  child: Text(
                                    "$distanceText • $eta",
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.green[800],
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                              Row(
                                children: [
                                  // ✅ GREEN BUTTON
                                  Expanded(
                                    child: ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.green,
                                      ),
                                      onPressed: isUpdatingStatus
                                          ? null
                                          : () async {
                                              setState(
                                                () => isUpdatingStatus = true,
                                              );

                                              startLocationUpdates();

                                              final freshDoc =
                                                  await FirebaseFirestore
                                                      .instance
                                                      .collection('orders')
                                                      .doc(orderDoc.id)
                                                      .get();

                                              final freshData =
                                                  freshDoc.data()
                                                      as Map<String, dynamic>;
                                              final currentStatus =
                                                  freshData['status'];

                                              String newStatus;

                                              if (currentStatus == "Accepted") {
                                                final pickupStoreLat =
                                                    (freshData['storeLat']
                                                            as num?)
                                                        ?.toDouble();
                                                final pickupStoreLng =
                                                    (freshData['storeLng']
                                                            as num?)
                                                        ?.toDouble();

                                                if (pickupStoreLat == null ||
                                                    pickupStoreLng == null) {
                                                  ScaffoldMessenger.of(
                                                    context,
                                                  ).showSnackBar(
                                                    SnackBar(
                                                      content: Text(
                                                        "Store location is unavailable for this order.",
                                                      ),
                                                    ),
                                                  );
                                                  setState(
                                                    () => isUpdatingStatus =
                                                        false,
                                                  );
                                                  return;
                                                }

                                                final markedPickedUp =
                                                    await markOrderPickedUp(
                                                      orderId: orderDoc.id,
                                                      storeLat: pickupStoreLat,
                                                      storeLng: pickupStoreLng,
                                                    );

                                                if (markedPickedUp) {
                                                  setState(() {
                                                    isPickedUp = true;
                                                  });
                                                  switchToCustomerRoute();
                                                }

                                                if (mounted) {
                                                  setState(
                                                    () => isUpdatingStatus =
                                                        false,
                                                  );
                                                }
                                                return;
                                              } else if (currentStatus ==
                                                  "Picked Up") {
                                                newStatus = "Delivered";
                                              } else {
                                                setState(
                                                  () =>
                                                      isUpdatingStatus = false,
                                                );
                                                return;
                                              }

                                              if (newStatus == "Delivered") {
                                                final driverId = FirebaseAuth
                                                    .instance
                                                    .currentUser!
                                                    .uid;
                                                final driverPay = 12.00;

                                                await FirebaseFirestore.instance
                                                    .collection('orders')
                                                    .doc(orderDoc.id)
                                                    .update({
                                                      "status": "Delivered",
                                                      "driverPay": driverPay,
                                                      "createdAt":
                                                          FieldValue.serverTimestamp(),
                                                    });

                                                await FirebaseFirestore.instance
                                                    .collection('drivers')
                                                    .doc(driverId)
                                                    .update({
                                                      "earnings":
                                                          FieldValue.increment(
                                                            driverPay,
                                                          ),
                                                      "isBusy": false,
                                                    });
                                              }

                                              if (newStatus == "Delivered") {
                                                setState(() {
                                                  isPickedUp = false;
                                                  isOnActiveDelivery = false;
                                                  isPreviewingOrder = false;

                                                  storeRoutePoints = [];
                                                  customerRoutePoints = [];

                                                  currentStoreLat = null;
                                                  currentStoreLng = null;
                                                  previewStoreLat = null;
                                                  previewStoreLng = null;

                                                  customerRouteOpacity = 1.0;

                                                  distanceText = null;
                                                  eta = null;
                                                });

                                                locationTimer?.cancel();
                                              }

                                              setState(
                                                () => isUpdatingStatus = false,
                                              );
                                            },
                                      child: Text(
                                        status == "Accepted"
                                            ? "Mark Picked Up"
                                            : status == "Picked Up"
                                            ? "Mark Delivered"
                                            : "",
                                      ),
                                    ),
                                  ),

                                  SizedBox(width: 10),

                                  // ❌ RED BUTTON
                                  Expanded(
                                    child: ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.red,
                                      ),
                                      onPressed: () async {
                                        await FirebaseFirestore.instance
                                            .collection('orders')
                                            .doc(orderDoc.id)
                                            .update({
                                              "status": "Pending",
                                              "driverId": null,
                                            });

                                        await FirebaseFirestore.instance
                                            .collection('drivers')
                                            .doc(
                                              FirebaseAuth
                                                  .instance
                                                  .currentUser!
                                                  .uid,
                                            )
                                            .set({
                                              "isBusy": false,
                                            }, SetOptions(merge: true));

                                        // 🔥 RESET MAP + STATE
                                        setState(() {
                                          isOnActiveDelivery = false;
                                          isPreviewingOrder = false;

                                          // 🔥 CLEAR ROUTES
                                          storeRoutePoints = [];
                                          customerRoutePoints = [];

                                          // 🔥 RESET FADE
                                          customerRouteOpacity = 1.0;

                                          // 🔥 CLEAR STORE TARGET
                                          currentStoreLat = null;
                                          currentStoreLng = null;

                                          // 🔥 CLEAR DISTANCE TEXT
                                          distanceText = null;
                                          eta = null;
                                        });

                                        locationTimer?.cancel();
                                      },
                                      child: Text(
                                        status == "Picked Up"
                                            ? "Cancel Delivery"
                                            : "Cancel Pickup",
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),

              // 🔵 AVAILABLE ORDERS (ONLY if no active job, and pending order exists)
              if (!hasActiveOrder && isOnline)
                StreamBuilder<QuerySnapshot>(
                  stream: isOnline
                      ? FirebaseFirestore.instance
                            .collection('orders')
                            .where("status", isEqualTo: "Pending")
                            .where(
                              "eligibleDrivers",
                              arrayContains:
                                  FirebaseAuth.instance.currentUser!.uid,
                            )
                            .snapshots()
                      : null,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return SizedBox();
                    }

                    final orders = snapshot.data!.docs;

                    if (orders.isEmpty) {
                      return Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min, // 👈 IMPORTANT
                          children: [
                            Icon(
                              Icons.local_shipping,
                              size: 28,
                              color: isOnline ? Colors.green : Colors.grey,
                            ),
                            SizedBox(height: 6),
                            Text(
                              isOnline
                                  ? "Waiting for deliveries..."
                                  : "Go online to receive deliveries",
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    return AnimatedContainer(
                      duration: Duration(milliseconds: 250),
                      height: previewOrderId != null ? 235 : 220,
                      child: ListView.builder(
                        controller: _scrollController,
                        scrollDirection: Axis.horizontal,

                        physics: previewOrderId != null
                            ? NeverScrollableScrollPhysics()
                            : BouncingScrollPhysics(),

                        itemCount: orders.length,
                        itemBuilder: (context, index) {
                          final order =
                              orders[index].data() as Map<String, dynamic>;
                          return _driverOrderCard(
                            order,
                            orders[index].id,
                            index,
                          );
                        },
                      ),
                    );
                  },
                ),

              // 🗺️ MAP
              Expanded(
                child: GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: currentPosition,
                    zoom: 15,
                  ),
                  onMapCreated: (controller) {
                    mapController = controller;
                  },
                  myLocationEnabled: true,
                  myLocationButtonEnabled: true,

                  // 🔥 ADD THIS PART
                  markers: {
                    // 🚗 DRIVER (always show)
                    Marker(
                      markerId: MarkerId("driver"),
                      position: currentPosition,
                      icon: BitmapDescriptor.defaultMarkerWithHue(
                        BitmapDescriptor.hueAzure, // 🔵 BLUE
                      ),
                      infoWindow: InfoWindow(title: "You"),
                    ),

                    // 🏪 STORE (preview OR active)
                    if ((isPreviewingOrder || isOnActiveDelivery) &&
                        previewStoreLat != null &&
                        previewStoreLng != null)
                      Marker(
                        markerId: MarkerId("store"),
                        position: LatLng(previewStoreLat!, previewStoreLng!),
                        infoWindow: InfoWindow(title: "Store"),
                        icon: BitmapDescriptor.defaultMarkerWithHue(
                          BitmapDescriptor.hueGreen,
                        ),
                      )
                    else if (currentStoreLat != null && currentStoreLng != null)
                      Marker(
                        markerId: MarkerId("store"),
                        position: LatLng(currentStoreLat!, currentStoreLng!),
                        infoWindow: InfoWindow(title: "Store"),
                        icon: BitmapDescriptor.defaultMarkerWithHue(
                          BitmapDescriptor.hueGreen,
                        ),
                      ),

                    // 🏠 CUSTOMER (preview OR active)
                    if (isPreviewingOrder &&
                        previewCustomerLat != null &&
                        previewCustomerLng != null)
                      Marker(
                        markerId: MarkerId("customer"),
                        position: LatLng(
                          previewCustomerLat!,
                          previewCustomerLng!,
                        ),
                        infoWindow: InfoWindow(title: "Customer"),
                        icon: BitmapDescriptor.defaultMarkerWithHue(
                          BitmapDescriptor.hueRed,
                        ),
                      ),
                  },
                  polylines: {
                    // 🔵 DRIVER → STORE
                    if (storeRoutePoints.isNotEmpty)
                      Polyline(
                        polylineId: PolylineId("toStore"),
                        points: storeRoutePoints,
                        color: Colors.blue,
                        width: 5,
                      ),

                    // 🟢 STORE → CUSTOMER (FADEABLE)
                    if ((isPreviewingOrder || isOnActiveDelivery) &&
                        customerRoutePoints.isNotEmpty)
                      Polyline(
                        polylineId: PolylineId("toCustomer"),
                        points: customerRoutePoints,
                        color: isPickedUp
                            ? Colors.green
                            : isOnActiveDelivery
                            ? Colors.green.withOpacity(0.25)
                            : Colors.green, // 👈 full brightness in preview
                        width: 5,
                      ),
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _driverOrderCard(
    Map<String, dynamic> order,
    String orderId,
    int index,
  ) {
    final isSelected = previewOrderId == orderId;
    final items = (order['items'] as List?) ?? [];
    final total = ((order['total'] ?? 0) as num).toDouble();
    final tradeType = order['tradeType'] ?? 'Trade';
    final customerName = order['customerName'] ?? 'Customer';
    final storeName = order['storeName'] ?? 'Store';

    int totalQuantity = 0;
    for (final item in items) {
      if (item is Map<String, dynamic>) {
        totalQuantity += (item['quantity'] ?? 1) as int;
      }
    }

    return GestureDetector(
      onTap: () {
        setState(() {
          previewOrderId = orderId;

          previewStoreLat = (order['storeLat'] as num?)?.toDouble();
          previewStoreLng = (order['storeLng'] as num?)?.toDouble();
          previewCustomerLat = (order['customerLat'] as num?)?.toDouble();
          previewCustomerLng = (order['customerLng'] as num?)?.toDouble();

          isPreviewingOrder = true;
        });

        print("STORE: ${order['storeLat']}, ${order['storeLng']}");
        debugPrint(
          "🔥 CUSTOMER: ${order['customerLat']}, ${order['customerLng']}",
        );
        debugPrint(
          "🔥 DRIVER: ${currentPosition.latitude}, ${currentPosition.longitude}",
        );

        Future.delayed(Duration(milliseconds: 50), () {
          _scrollController.animateTo(
            index * 280.0,
            duration: Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        });

        previewRoute();
      },
      child: AnimatedContainer(
        duration: Duration(milliseconds: 250),
        width: isSelected ? MediaQuery.of(context).size.width * 0.9 : 265,
        height: isSelected ? 215 : 200,
        margin: EdgeInsets.fromLTRB(10, 10, 6, 10),
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? Colors.blue : Colors.grey.shade200,
            width: isSelected ? 2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 8,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Stack(
          children: [
            Positioned.fill(
              bottom: 50,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          storeName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: 90),
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.blue.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            tradeType,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.blue.shade800,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      if (isSelected) ...[
                        SizedBox(width: 4),
                        SizedBox(
                          width: 34,
                          height: 34,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            tooltip: "Close preview",
                            icon: Icon(Icons.close, size: 20),
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.grey.shade100,
                              foregroundColor: Colors.grey.shade700,
                            ),
                            onPressed: () {
                              setState(() {
                                previewOrderId = null;
                                previewStoreLat = null;
                                previewStoreLng = null;
                                previewCustomerLat = null;
                                previewCustomerLng = null;

                                isPreviewingOrder = false;
                                isOnActiveDelivery = false;

                                storeRoutePoints = [];
                                customerRoutePoints = [];
                                customerRouteOpacity = 1.0;
                                previewDistance = null;
                                previewDuration = null;
                              });
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                  SizedBox(height: 4),
                  Text(
                    customerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                  SizedBox(height: 10),
                  Row(
                    children: [
                      _smallDriverStat(
                        Icons.inventory_2,
                        "$totalQuantity items",
                      ),
                      SizedBox(width: 8),
                      _smallDriverStat(
                        Icons.attach_money,
                        total.toStringAsFixed(2),
                      ),
                    ],
                  ),
                  if (isSelected &&
                      previewDistance != null &&
                      previewDuration != null)
                    Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Row(
                        children: [
                          Icon(Icons.route, size: 16, color: Colors.green[700]),
                          SizedBox(width: 5),
                          Text(
                            "$previewDistance • $previewDuration",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: Colors.green[700],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: SizedBox(
                height: 44,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isSelected ? Colors.blue : Colors.grey,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: isSelected
                      ? () async {
                          final user = FirebaseAuth.instance.currentUser;

                          final orderRef = FirebaseFirestore.instance
                              .collection('orders')
                              .doc(orderId);

                          final freshOrder = await orderRef.get();

                          final freshData = freshOrder.data();

                          if (freshData == null ||
                              freshData["status"] != "Pending") {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text("Order was already accepted"),
                              ),
                            );
                            return;
                          }

                          await orderRef.update({
                            "status": "Accepted",
                            "driverId": user!.uid,
                          });

                          await FirebaseFirestore.instance
                              .collection('drivers')
                              .doc(user.uid)
                              .set({"isBusy": true}, SetOptions(merge: true));

                          setState(() {
                            currentStoreLat = previewStoreLat;
                            currentStoreLng = previewStoreLng;
                            isOnActiveDelivery = true;
                            isPreviewingOrder = false;
                          });

                          startLocationUpdates();

                          await getRoute();
                          zoomToStoreRoute();
                        }
                      : null,
                  icon: Icon(Icons.local_shipping, size: 18),
                  label: Text(isSelected ? "Accept Delivery" : "Preview Route"),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _smallDriverStat(IconData icon, String label) {
    return Expanded(
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: Colors.grey.shade700),
            SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> markOrderPickedUp({
    required String orderId,
    required double storeLat,
    required double storeLng,
  }) async {
    const pickupRadiusMeters = 300.0;
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) return false;

    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw StateError("Turn on location services before marking pickup.");
      }

      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw StateError(
          "Location permission is required before marking pickup.",
        );
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      );

      final distanceMeters = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        storeLat,
        storeLng,
      );

      if (distanceMeters > pickupRadiusMeters) {
        final distanceText = distanceMeters >= 1000
            ? "${(distanceMeters / 1000).toStringAsFixed(1)} km"
            : "${distanceMeters.round()} m";

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                "You are $distanceText from the store. Move within 300 m to mark this order picked up.",
              ),
            ),
          );
        }
        return false;
      }

      setState(() {
        currentPosition = LatLng(position.latitude, position.longitude);
      });

      await FirebaseFirestore.instance.collection('drivers').doc(user.uid).set({
        "lat": position.latitude,
        "lng": position.longitude,
        "lastUpdated": FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      final callable = FirebaseFunctions.instance.httpsCallable(
        'markOrderPickedUp',
      );
      await callable.call({"orderId": orderId});

      return true;
    } on FirebaseFunctionsException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.message ?? "Could not verify pickup location."),
          ),
        );
      }
      return false;
    } catch (error) {
      if (mounted) {
        final message = error is StateError
            ? error.message.toString()
            : "Could not verify your location. Please try again.";
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
      return false;
    }
  }

  void startLocationUpdates() {
    locationTimer?.cancel(); // prevent duplicates

    locationTimer = Timer.periodic(Duration(seconds: 30), (timer) async {
      if (!isOnActiveDelivery) return;

      final position = await Geolocator.getCurrentPosition();

      setState(() {
        currentPosition = LatLng(position.latitude, position.longitude);
      });

      // 🔥 OPTIONAL: update Firestore (live tracking)
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await FirebaseFirestore.instance
            .collection('drivers')
            .doc(user.uid)
            .set({
              "lat": position.latitude,
              "lng": position.longitude,
              "lastUpdated": FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
      }

      // 🔥 OPTIONAL: refresh route
      await getRoute();
    });
  }

  void switchToCustomerRoute() {
    if (customerRoutePoints.isEmpty) return;

    setState(() {
      // 🔥 remove store route
      storeRoutePoints = [];

      // 🔥 make customer route bold
      customerRouteOpacity = 1.0;
    });

    // 🔥 zoom into customer route
    zoomToFitRoute(customerRoutePoints);
  }
}

class DriverEarningsScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(title: Text("Earnings")),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('drivers')
            .doc(user!.uid)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Center(child: CircularProgressIndicator());
          }

          final data = snapshot.data!.data() as Map<String, dynamic>?;

          final earnings = (data?['earnings'] ?? 0).toDouble();

          return Padding(
            padding: EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: 20),

                Text(
                  "Available Balance",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, color: Colors.grey[700]),
                ),

                SizedBox(height: 10),

                Text(
                  "\$${earnings.toStringAsFixed(2)}",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 42, fontWeight: FontWeight.bold),
                ),

                SizedBox(height: 30),

                Container(
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Payout Method",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),

                      SizedBox(height: 8),

                      Text(
                        "Stripe payout setup will go here.",
                        style: TextStyle(color: Colors.grey[700]),
                      ),
                    ],
                  ),
                ),

                SizedBox(height: 20),

                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    minimumSize: Size(double.infinity, 52),
                    backgroundColor: Colors.green,
                  ),
                  onPressed: earnings > 0
                      ? () async {
                          try {
                            final callable = FirebaseFunctions.instance
                                .httpsCallable('createDriverDashboardLink');

                            final result = await callable.call();

                            final url = result.data['url'];

                            if (url == null) {
                              throw Exception("No Stripe link returned");
                            }

                            final uri = Uri.parse(url);

                            await launchUrl(
                              uri,
                              mode: LaunchMode.externalApplication,
                            );
                          } catch (e) {
                            print("Withdraw error: $e");

                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  "Could not open Stripe withdrawal page",
                                ),
                              ),
                            );
                          }
                        }
                      : null,
                  child: Text("Withdraw"),
                ),

                SizedBox(height: 12),

                TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => DriverEarningsHistoryScreen(),
                      ),
                    );
                  },
                  child: Text("View Earnings History"),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class DriverEarningsHistoryScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(title: Text("Earnings History")),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('orders')
            .where('driverId', isEqualTo: user!.uid)
            .where('status', isEqualTo: "Delivered")
            .orderBy('createdAt', descending: true) // 🔥 newest first
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Center(child: CircularProgressIndicator());
          }

          final orders = snapshot.data!.docs;

          if (orders.isEmpty) {
            return Center(child: Text("No earnings yet"));
          }

          return ListView.builder(
            itemCount: orders.length,
            itemBuilder: (context, index) {
              final data = orders[index].data() as Map<String, dynamic>;

              final store = data['storeName'] ?? "Store";
              final payout = (data['driverPay'] ?? 0).toDouble();

              final timestamp = data['createdAt'];
              String dateText = "";

              if (timestamp != null) {
                final date = (timestamp as Timestamp).toDate();
                dateText = "${date.month}/${date.day}/${date.year}";
              }

              return Card(
                margin: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: ListTile(
                  leading: Icon(Icons.receipt_long),
                  title: Text(store),
                  subtitle: Text(dateText),
                  trailing: Text(
                    "\$${payout.toStringAsFixed(2)}",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.green,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class LocationPermissionScreen extends StatefulWidget {
  @override
  State<LocationPermissionScreen> createState() =>
      _LocationPermissionScreenState();
}

class _LocationPermissionScreenState extends State<LocationPermissionScreen> {
  bool isLoading = false;

  Future<void> handleLocation() async {
    setState(() => isLoading = true);

    final user = FirebaseAuth.instance.currentUser;

    // 🔍 CHECK PERMISSION FIRST
    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    // ❌ Still denied
    if (permission == LocationPermission.denied) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Please allow location access to continue")),
      );
      setState(() => isLoading = false);
      return;
    }

    // 🚫 Denied forever → send to settings
    if (permission == LocationPermission.deniedForever) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text("Location Required"),
          content: Text(
            "Location access is turned off. Please enable it in Settings to continue.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () async {
                await Geolocator.openAppSettings();
              },
              child: Text("Open Settings"),
            ),
          ],
        ),
      );

      setState(() => isLoading = false);
      return;
    }

    // ✅ Permission granted → get location
    final position = await Geolocator.getCurrentPosition();

    if (position != null && user != null) {
      // 🔥 SAVE LOCATION
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        "lat": position.latitude,
        "lng": position.longitude,
        "lastUpdated": FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // 🔥 MOVE FORWARD
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => RoleRouter()),
      );
    }

    setState(() => isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.location_on, size: 80, color: Colors.blue),

            SizedBox(height: 20),

            Text(
              "Enable Location",
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
            ),

            SizedBox(height: 10),

            Text(
              "We use your location to connect you with nearby stores and deliveries.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),

            SizedBox(height: 40),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: isLoading ? null : handleLocation,
                child: isLoading
                    ? CircularProgressIndicator(color: Colors.white)
                    : Text("Enable Location"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CustomerNameScreen extends StatefulWidget {
  @override
  _CustomerNameScreenState createState() => _CustomerNameScreenState();
}

class _CustomerNameScreenState extends State<CustomerNameScreen> {
  final TextEditingController nameController = TextEditingController();

  Future<void> saveName() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null || nameController.text.trim().isEmpty) return;

    await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
      "name": nameController.text.trim(),
      "role": "customer",
    }, SetOptions(merge: true));

    // 🔥 GO TO HOME
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => TradeStoreScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          "Enter your name",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: false,
      ),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: 20),

              SizedBox(height: 8),

              Text(
                "We’ll use this for your orders",
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),

              SizedBox(height: 30),

              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.08),
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: TextField(
                  controller: nameController,
                  style: TextStyle(fontSize: 18),
                  decoration: InputDecoration(
                    hintText: "Your full name",
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 18,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.blue, width: 2),
                    ),
                  ),
                ),
              ),

              SizedBox(height: 30),

              GestureDetector(
                onTap: saveName,
                child: AnimatedContainer(
                  duration: Duration(milliseconds: 200),
                  width: double.infinity,
                  padding: EdgeInsets.symmetric(vertical: 18, horizontal: 20),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.blue, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 10,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        "Continue",
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.blue,
                        ),
                      ),

                      SizedBox(width: 10),

                      Icon(Icons.arrow_forward, color: Colors.blue),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AddressSearchScreen extends StatefulWidget {
  @override
  State<AddressSearchScreen> createState() => _AddressSearchScreenState();
}

class _AddressSearchScreenState extends State<AddressSearchScreen> {
  final TextEditingController controller = TextEditingController();

  List<dynamic> predictions = [];

  Future<void> searchPlaces(String input) async {
    print("⌨️ INPUT: $input");
    if (input.isEmpty) {
      setState(() => predictions = []);
      return;
    }

    final apiKey = "AIzaSyAekQ_K5c2zzW_wmDxZySFehntN1v2YVhU";

    final url =
        "https://maps.googleapis.com/maps/api/place/autocomplete/json?input=$input&key=$apiKey";

    try {
      final response = await http.get(Uri.parse(url));
      final data = jsonDecode(response.body);

      if (data['status'] == "OK") {
        setState(() {
          predictions = data['predictions'];
        });
      } else {
        print("❌ AUTOCOMPLETE ERROR: ${data['status']}");
      }
    } catch (e) {
      print("❌ ERROR: $e");
    }
  }

  Future<void> selectPlace(dynamic place) async {
    final placeId = place['place_id'];
    final selectedAddress = place['description']; // 👈 LOCK USER TEXT

    final apiKey = "AIzaSyAekQ_K5c2zzW_wmDxZySFehntN1v2YVhU";

    print("👉 USER SELECTED: $selectedAddress");

    final detailsUrl =
        "https://maps.googleapis.com/maps/api/place/details/json?place_id=$placeId&key=$apiKey";

    try {
      final response = await http.get(Uri.parse(detailsUrl));
      final data = jsonDecode(response.body);

      if (data['status'] != "OK") {
        print("❌ DETAILS ERROR: ${data['status']}");
        return;
      }

      final result = data['result'];
      final location = result['geometry']['location'];

      final lat = (location['lat'] as num).toDouble();
      final lng = (location['lng'] as num).toDouble();

      print("📍 COORDS: $lat, $lng");

      // 🚀 GO TO MAP CONFIRM SCREEN
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ConfirmLocationScreen(
            lat: lat,
            lng: lng,
            address: selectedAddress, // 👈 KEEP USER VERSION
          ),
        ),
      );
    } catch (e) {
      print("❌ ERROR: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Search Address")),
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.all(16),
            child: TextField(
              controller: controller,
              onChanged: (value) {
                searchPlaces(value);
              },
              decoration: InputDecoration(
                hintText: "Enter address",
                border: OutlineInputBorder(),
              ),
            ),
          ),

          Expanded(
            child: ListView.builder(
              itemCount: predictions.length,
              itemBuilder: (context, index) {
                final place = predictions[index];

                return ListTile(
                  title: Text(
                    place['structured_formatting']?['main_text'] ?? "",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    place['structured_formatting']?['secondary_text'] ?? "",
                  ),
                  onTap: () => selectPlace(place),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class TradeStoreScreen extends StatelessWidget {
  Widget tradeCard(
    BuildContext context,
    String trade,
    IconData icon,
    Color color,
  ) {
    return GestureDetector(
      onTap: () {
        if (trade == "Plumbing") {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => PlumbingScreen()),
          );
        } else if (trade == "Electrical") {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => ElectricalScreen()),
          );
        } else if (trade == "HVAC") {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => HVACScreen()),
          );
        }
      },
      child: AnimatedContainer(
        duration: Duration(milliseconds: 200),
        margin: EdgeInsets.only(bottom: 16),
        padding: EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color, width: 2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(icon, size: 36, color: color),

            SizedBox(width: 20),

            Text(
              trade,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),

            Spacer(),

            Icon(Icons.arrow_forward_ios, color: color),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: false, toolbarHeight: 0),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              "Choose Your Trade",
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),

            SizedBox(height: 40),

            tradeCard(context, "Plumbing", Icons.plumbing, Colors.blue),

            SizedBox(height: 20),

            tradeCard(
              context,
              "Electrical",
              Icons.electrical_services,
              Colors.green,
            ),

            SizedBox(height: 20),

            tradeCard(context, "HVAC", Icons.ac_unit, Colors.orange),
          ],
        ),
      ),
    );
  }
}

class ElectricalScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Electrical Parts")),
      body: Center(child: Text("Electrical inventory here")),
    );
  }
}

class PlumbingScreen extends StatefulWidget {
  @override
  _PlumbingScreenState createState() => _PlumbingScreenState();
}

class _PlumbingScreenState extends State<PlumbingScreen>
    with SingleTickerProviderStateMixin {
  final List<Map<String, dynamic>> parts = [
    {
      "name": "8 oz. Lead-Free Solder Wire",
      "price": 48.00,
      "description": "Soldering wire for copper pipe (Brand may vary)",
      "image": "assets/images/LeadFreeSolder.jpg",
      "categories": ["Soldering"],
      "specialtyStoreTag": "soldering",
    },
    {
      "name": "8 oz. Flux",
      "price": 6.00,
      "description":
          "Flux paste used before soldering to clean metal surface (Brand may vary)",
      "image": "assets/images/Flux.jpg",
      "categories": ["Soldering"],
      "specialtyStoreTag": "soldering",
    },
    {
      "name": "Flux Brush",
      "price": 5.00,
      "description": "Brush used to apply flux paste to pipe (Brand may vary)",
      "image": "assets/images/FluxBrush.jpg",
      "categories": ["Soldering"],
      "specialtyStoreTag": "soldering",
    },
    {
      "name": "Plumbers Sanding Cloth 1-1/2 in. x 2 yd.",
      "price": 5.00,
      "description":
          "Sanding cloth for prepping pipe for solder (Brand may vary)",
      "image": "assets/images/PlumbersCloth2yd.jpg",
      "categories": ["Soldering"],
      "specialtyStoreTag": "soldering",
    },
    {
      "name": "14.1 oz. Propane cyliner",
      "price": 6.00,
      "description":
          "Propane cylinder for soldering copper pipe (Brand may vary)",
      "image": "assets/images/BluePropaneTank.png",
      "categories": ["Soldering"],
      "specialtyStoreTag": "soldering",
    },
    {
      "name": "Adjustable Propane Gas Torch",
      "price": 22.00,
      "description":
          "Adjustable propane cylinder torch for soldering copper pipe (Brand may vary)",
      "image": "assets/images/PropaneTorch.png",
      "categories": ["Soldering"],
      "specialtyStoreTag": "soldering",
    },
    {
      "name": "Pipe Cutter",
      "price": 22.00,
      "description": "Adjustable tool for cutting pipe (Brand may vary)",
      "image": "assets/images/AdjustablePipeCutter.png",
      "categories": ["Tools"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "Baby Pipe Cutter",
      "price": 22.00,
      "description": "Small adjustable tool for cutting pipe (Brand may vary)",
      "image": "assets/images/BabyAdjustablePipeCutter.png",
      "categories": ["Tools"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "Pipe Prepping Tool",
      "price": 13.00,
      "description":
          "Pipe prepping tool for pipes 1/2 in. to 3/4 in. (Brand may vary)",
      "image": "assets/images/PipePreppingTool.jpg",
      "categories": ["Soldering"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "2 in. Copper Pressure Coupling With Stop",
      "price": 5.00,
      "description":
          "Copper coupling for connecting 2 in. pipe with internal stops (Brand may vary)",
      "image": "assets/images/CopperNonSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. Copper Slip Coupling",
      "price": 7.50,
      "description":
          "Copper coupling for connecting 2 in. pipe without internal stops (Brand may vary)",
      "image": "assets/images/CopperSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. Copper ProPress Coupling With Stop",
      "price": 12.00,
      "description":
          "Copper coupling for propress connecting 2 in. pipe with internal stops (Brand may vary)",
      "image": "assets/images/CopperProPressNonSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "2 in. Copper ProPress Coupling Without Stop",
      "price": 16.50,
      "description":
          "Copper coupling for propress connecting 2 in. pipe without internal stops (Brand may vary)",
      "image": "assets/images/CopperProPressSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "2 in. Copper Tee Fitting",
      "price": 24.00,
      "description":
          "Copper all cup tee fitting for connecting 2 in. pipe (Brand may vary)",
      "image": "assets/images/CopperTee.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. Copper ProPress Tee Fitting",
      "price": 21.50,
      "description":
          "Copper tee fitting for connecting 2 in. pipe with propress (Brand may vary)",
      "image": "assets/images/CopperProPressTee.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "2 in. Copper 45-Degree Fitting",
      "price": 15.00,
      "description":
          "Copper 45-degree fitting for connecting 2 in. pipe (Brand may vary)",
      "image": "assets/images/Copper45.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. Copper 45-Degree Street Fitting",
      "price": 20.00,
      "description":
          "Copper 45-degree fitting with one male end for connecting 2 in. pipe (Brand may vary)",
      "image": "assets/images/CopperStreet45.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. Copper 45-Degree ProPress Fitting",
      "price": 20.00,
      "description":
          "Copper 45-degree fitting for connecting 2 in. pipe with propress (Brand may vary)",
      "image": "assets/images/CopperProPress45.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "2 in. Copper 90-Degree Elbow",
      "price": 9.00,
      "description":
          "Copper 90-degree Non-slip fitting for connecting 2 in. pipe (Brand may vary)",
      "image": "assets/images/Copper90.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. Copper 90-Degree Street Elbow",
      "price": 15.50,
      "description":
          "Copper 90-degree street fitting for connecting 2 in. pipe (Brand may vary)",
      "image": "assets/images/CopperStreet90.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. Copper 90-Degree ProPress Elbow",
      "price": 14.00,
      "description":
          "Copper 90-degree fitting for connecting 2 in. pipe with propress(Brand may vary)",
      "image": "assets/images/CopperProPress90.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "propress",
    },
    /*{
      "name": "1 in. Copper 90-Degree ProPress Street Elbow",
      "price": 20.00,
      "description":
          "Copper 90-degree street fitting for connecting 1 in. pipe with propress(Brand may vary)",
      "image": "assets/images/CopperCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },*/
    {
      "name": "2 in. Copper Female to Male Pipe Thread Adapter",
      "price": 14.00,
      "description":
          "2 in. Copper female to Male Pipe Thread adapter (Brand may vary)",
      "image": "assets/images/CopperFemaleToMPT.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. Copper Female Threaded Adapter",
      "price": 3.00,
      "description": "2 in. Copper female threaded adapter (Brand may vary)",
      "image": "assets/images/CopperThreadedFemaleAdapter.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. Brass Cap",
      "price": 15.00,
      "description": "2 in. brass threaded cap (Brand may vary)",
      "image": "assets/images/BrassCap.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "2 in. Brass Coupling",
      "price": 17.00,
      "description": "2 in. brass threaded coupling (Brand may vary)",
      "image": "assets/images/BrassCoupling.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "2 in. Brass 90",
      "price": 42.00,
      "description": "2 in. brass threaded elbow fitting (Brand may vary)",
      "image": "assets/images/Brass90.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "2 in. Brass 45",
      "price": 24.00,
      "description": "1 in. brass threaded 45 fitting (Brand may vary)",
      "image": "assets/images/Brass45.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "2 in. Brass Street 90",
      "price": 57.50,
      "description":
          "2 in. brass threaded street elbow fitting (Brand may vary)",
      "image": "assets/images/BrassStreet90.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "2 in. Brass Street 45",
      "price": 31.50,
      "description": "2 in. brass threaded street 45 fitting (Brand may vary)",
      "image": "assets/images/BrassStreet45.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "2 in. Brass Ball Valve(Threaded)",
      "price": 35.00,
      "description":
          "2 Full port brass ball valve with threading on both ends (Brand may vary)",
      "image": "assets/images/ThreadedBallValve.jpg",
      "categories": ["Valves", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "2 in. Brass Ball Valve(Non-Threaded)",
      "price": 25.00,
      "description":
          "1 Full port brass ball valve with female port on both ends (Brand may very)",
      "image": "assets/images/NonThreadedBallValve.jpg",
      "categories": ["Valves", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "1 in. Copper Pressure Coupling With Stop",
      "price": 5.00,
      "description":
          "Copper coupling for connecting 1 in. pipe with internal stops (Brand may vary)",
      "image": "assets/images/CopperNonSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1 in. Copper Slip Coupling",
      "price": 7.50,
      "description":
          "Copper coupling for connecting 1 in. pipe without internal stops (Brand may vary)",
      "image": "assets/images/CopperSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1 in. Copper ProPress Coupling With Stop",
      "price": 12.00,
      "description":
          "Copper coupling for propress connecting 1 in. pipe with internal stops (Brand may vary)",
      "image": "assets/images/CopperProPressNonSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "1 in. Copper ProPress Coupling Without Stop",
      "price": 16.50,
      "description":
          "Copper coupling for propress connecting 1 in. pipe without internal stops (Brand may vary)",
      "image": "assets/images/CopperProPressSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "1 in. Copper Tee Fitting",
      "price": 24.00,
      "description":
          "Copper all cup tee fitting for connecting 1 in. pipe (Brand may vary)",
      "image": "assets/images/CopperTee.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1 in. Copper ProPress Tee Fitting",
      "price": 21.50,
      "description":
          "Copper tee fitting for connecting 1 in. pipe with propress (Brand may vary)",
      "image": "assets/images/CopperProPressTee.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "1 in. Copper 45-Degree Fitting",
      "price": 15.00,
      "description":
          "Copper 45-degree fitting for connecting 1 in. pipe (Brand may vary)",
      "image": "assets/images/Copper45.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1 in. Copper 45-Degree Street Fitting",
      "price": 20.00,
      "description":
          "Copper 45-degree fitting with one male end for connecting 1 in. pipe (Brand may vary)",
      "image": "assets/images/CopperStreet45.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1 in. Copper 45-Degree ProPress Fitting",
      "price": 20.00,
      "description":
          "Copper 45-degree fitting for connecting 1 in. pipe with propress (Brand may vary)",
      "image": "assets/images/CopperProPress45.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "1 in. Copper 90-Degree Elbow",
      "price": 9.00,
      "description":
          "Copper 90-degree Non-slip fitting for connecting 1 in. pipe (Brand may vary)",
      "image": "assets/images/Copper90.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1 in. Copper 90-Degree Street Elbow",
      "price": 15.50,
      "description":
          "Copper 90-degree street fitting for connecting 1 in. pipe (Brand may vary)",
      "image": "assets/images/CopperStreet90.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1 in. Copper 90-Degree ProPress Elbow",
      "price": 14.00,
      "description":
          "Copper 90-degree fitting for connecting 1 in. pipe with propress(Brand may vary)",
      "image": "assets/images/CopperProPress90.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "propress",
    },
    /*{
      "name": "1 in. Copper 90-Degree ProPress Street Elbow",
      "price": 20.00,
      "description":
          "Copper 90-degree street fitting for connecting 1 in. pipe with propress(Brand may vary)",
      "image": "assets/images/CopperCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },*/
    {
      "name": "1 in. Copper Female to Male Pipe Thread Adapter",
      "price": 14.00,
      "description":
          "1 in. Copper female to Male Pipe Thread adapter (Brand may vary)",
      "image": "assets/images/CopperFemaleToMPT.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1 in. Copper Female Threaded Adapter",
      "price": 3.00,
      "description": "1 in. Copper female threaded adapter (Brand may vary)",
      "image": "assets/images/CopperThreadedFemaleAdapter.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1 in. Brass Cap",
      "price": 15.00,
      "description": "1 in. brass threaded cap (Brand may vary)",
      "image": "assets/images/BrassCap.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "1 in. Brass Coupling",
      "price": 17.00,
      "description": "1 in. brass threaded coupling (Brand may vary)",
      "image": "assets/images/BrassCoupling.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "1 in. Brass 90",
      "price": 42.00,
      "description": "1 in. brass threaded elbow fitting (Brand may vary)",
      "image": "assets/images/Brass90.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "1 in. Brass 45",
      "price": 24.00,
      "description": "1 in. brass threaded 45 fitting (Brand may vary)",
      "image": "assets/images/Brass45.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "1 in. Brass Street 90",
      "price": 57.50,
      "description":
          "1 in. brass threaded street elbow fitting (Brand may vary)",
      "image": "assets/images/BrassStreet90.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "1 in. Brass Street 45",
      "price": 31.50,
      "description": "1 in. brass threaded street 45 fitting (Brand may vary)",
      "image": "assets/images/BrassStreet45.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "1 in. Brass Ball Valve(Threaded)",
      "price": 35.00,
      "description":
          "1 Full port brass ball valve with threading on both ends (Brand may vary)",
      "image": "assets/images/ThreadedBallValve.jpg",
      "categories": ["Valves", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "1 in. Brass Ball Valve(Non-Threaded)",
      "price": 25.00,
      "description":
          "1 Full port brass ball valve with female port on both ends (Brand may very)",
      "image": "assets/images/NonThreadedBallValve.jpg",
      "categories": ["Valves", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "3/4 in. Copper Pressure Coupling With Stop",
      "price": 2.50,
      "description":
          "Copper coupling for connecting 3/4 in. pipe with internal stops (Brand may vary)",
      "image": "assets/images/CopperNonSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "3/4 in. Copper Slip Coupling",
      "price": 3.00,
      "description":
          "Copper coupling for connecting 3/4 in. pipe without internal stops (Brand may vary)",
      "image": "assets/images/CopperCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "3/4 in. Copper ProPress Coupling With Stop",
      "price": 6.00,
      "description":
          "Copper coupling for propress connecting 3/4 in. pipe with internal stops (Brand may vary)",
      "image": "assets/images/CopperProPressNonSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "3/4 in. Copper ProPress Coupling Without Stop",
      "price": 13.00,
      "description":
          "Copper coupling for propress connecting 3/4 in. pipe without internal stops (Brand may vary)",
      "image": "assets/images/CopperProPressSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "3/4 in. Copper Tee Fitting",
      "price": 6.00,
      "description":
          "Copper all cup tee fitting for connecting 3/4 in. pipe (Brand may vary)",
      "image": "assets/images/CopperTee.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "3/4 in. Copper ProPress Tee Fitting",
      "price": 12.00,
      "description":
          "Copper tee fitting for connecting 3/4 in. pipe with propress (Brand may vary)",
      "image": "assets/images/CopperProPressTee.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "3/4 in. Copper 45-Degree Fitting",
      "price": 5.00,
      "description":
          "Copper 45-degree fitting for connecting 3/4 in. pipe (Brand may vary)",
      "image": "assets/images/Copper45.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "3/4 in. Copper 45-Degree Street Fitting",
      "price": 5.50,
      "description":
          "Copper 45-degree fitting with one male end for connecting 3/4 in. pipe (Brand may vary)",
      "image": "assets/images/CopperStreet45.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "3/4 in. Copper 45-Degree ProPress Fitting",
      "price": 6.50,
      "description":
          "Copper 45-degree fitting for connecting 3/4 in. pipe with propress (Brand may vary)",
      "image": "assets/images/CopperProPress45.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "3/4 in. Copper 90-Degree Elbow",
      "price": 3.50,
      "description":
          "Copper 90-degree Non-slip fitting for connecting 3/4 in. pipe (Brand may vary)",
      "image": "assets/images/Copper90.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "3/4 in. Copper 90-Degree Street Elbow",
      "price": 5.50,
      "description":
          "Copper 90-degree street fitting for connecting 3/4 in. pipe (Brand may vary)",
      "image": "assets/images/CopperStreet90.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "3/4 in. Copper 90-Degree ProPress Elbow",
      "price": 7.00,
      "description":
          "Copper 90-degree fitting for connecting 3/4 in. pipe with propress (Brand may vary)",
      "image": "assets/images/CopperProPress90.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "propress",
    },
    /*{
      "name": "3/4 in. Copper 90-Degree ProPress Street Elbow",
      "price": 8.00,
      "description":
          "Copper 90-degree street fitting for connecting 3/4 in. pipe with propress(Brand may vary)",
      "image": "assets/images/CopperCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },*/
    {
      "name": "3/4 in. Copper Female to Male Pipe Thread Adapter",
      "price": 5.00,
      "description":
          "3/4 in. Copper female to Male Pipe Thread adapter (Brand may vary)",
      "image": "assets/images/CopperFemaleToMPT.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "3/4 in. Copper Female Threaded Adapter",
      "price": 3.00,
      "description": "3/4 in. Copper female threaded adapter (Brand may vary)",
      "image": "assets/images/CopperThreadedFemaleAdapter.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "3/4 in. Brass Cap",
      "price": 9.50,
      "description": "3/4 in. brass threaded cap (Brand may vary)",
      "image": "assets/images/BrassCap.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "3/4 in. Brass Coupling",
      "price": 11.50,
      "description": "3/4 in. brass threaded coupling(Brand may vary)",
      "image": "assets/images/BrassCoupling.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "3/4 in. Brass 90",
      "price": 13.00,
      "description": "3/4 in. brass threaded elbow fitting (Brand may vary)",
      "image": "assets/images/Brass90.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "3/4 in. Brass 45",
      "price": 3.00,
      "description": "3/4 in. brass threaded 45 fitting (Brand may vary)",
      "image": "assets/images/Brass45.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "3/4 in. Brass Street 90",
      "price": 18.00,
      "description":
          "3/4 in. brass threaded street elbow fitting (Brand may vary)",
      "image": "assets/images/BrassStreet90.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "3/4 in. Brass Street 45",
      "price": 19.00,
      "description":
          "3/4 in. brass threaded street 45 fitting (Brand may vary)",
      "image": "assets/images/BrassStreet45.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "3/4 in. Brass Ball Valve(Threaded)",
      "price": 25.00,
      "description":
          "3/4 Full port brass ball valve with threading on both ends (Brand may vary)",
      "image": "assets/images/ThreadedBallValve.jpg",
      "categories": ["Valves", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "3/4 in. Brass Ball Valve(Non-Threaded)",
      "price": 20.00,
      "description":
          "3/4 Full port brass ball valve with female port on both ends (Brand may very)",
      "image": "assets/images/NonThreadedBallValve.jpg",
      "categories": ["Valves", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "1/2 in. Copper Pressure Coupling With Stop",
      "price": 1.50,
      "description":
          "Copper coupling for connecting 1/2 in. pipe with internal stops (Brand may vary)",
      "image": "assets/images/CopperNonSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1/2 in. Copper Slip Coupling",
      "price": 1.50,
      "description":
          "Copper coupling for connecting 1/2 in. pipe without internal stops (Brand may vary)",
      "image": "assets/images/CopperSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1/2 in. Copper ProPress Coupling With Stop",
      "price": 4.00,
      "description":
          "Copper coupling for propress connecting 1/2 in. pipe with internal stops (Brand may vary)",
      "image": "assets/images/CopperProPressNonSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "1/2 in. Copper ProPress Coupling Without Stop",
      "price": 10.00,
      "description":
          "Copper coupling for propress connecting 1/2 in. pipe without internal stops (Brand may vary)",
      "image": "assets/images/CopperProPressSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "1/2 in. Copper Tee Fitting",
      "price": 2.50,
      "description":
          "Copper all cup tee fitting for connecting 1/2 in. pipe (Brand may vary)",
      "image": "assets/images/CopperTee.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1/2 in. Copper ProPress Tee Fitting",
      "price": 7.00,
      "description":
          "Copper tee fitting for connecting 1/2 in. pipe with propress (Brand may vary)",
      "image": "assets/images/CopperProPressTee.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "1/2 in. Copper 45-Degree Fitting",
      "price": 3.00,
      "description":
          "Copper 45-degree fitting for connecting 1/2 in. pipe (Brand may vary)",
      "image": "assets/images/Copper45.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1/2 in. Copper 45-Degree Street Fitting",
      "price": 3.50,
      "description":
          "Copper 45-degree fitting with one male end for connecting 1/2 in. pipe (Brand may vary)",
      "image": "assets/images/CopperStreet45.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1/2 in. Copper 45-Degree ProPress Fitting",
      "price": 5.50,
      "description":
          "Copper 45-degree fitting for connecting 1/2 in. pipe with propress (Brand may vary)",
      "image": "assets/images/CopperProPress45.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "1/2 in. Copper 90-Degree Elbow",
      "price": 2.00,
      "description":
          "Copper 90-degree Non-slip fitting for connecting 1/2 in. pipe (Brand may vary)",
      "image": "assets/images/Copper90.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1/2 in. Copper 90-Degree Street Elbow",
      "price": 2.50,
      "description":
          "Copper 90-degree street fitting for connecting 1/2 in. pipe (Brand may vary)",
      "image": "assets/images/CopperStreet90.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1/2 in. Copper 90-Degree ProPress Elbow",
      "price": 4.50,
      "description":
          "Copper 90-degree fitting for connecting 1/2 in. pipe with propress (Brand may vary)",
      "image": "assets/images/CopperProPress90.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "propress",
    },
    /*{
      "name": "1/2 in. Copper 90-Degree ProPress Street Elbow",
      "price": 4.50,
      "description":
          "Copper 90-degree street fitting for connecting 1/2 in. pipe with propress(Brand may vary)",
      "image": "assets/images/CopperCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },*/
    {
      "name": "1/2 in. Copper Female to Male Pipe Thread Adapter",
      "price": 3.00,
      "description":
          "1/2 in. Copper female to Male Pipe Thread adapter (Brand may vary)",
      "image": "assets/images/CopperFemaleToMPT.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1/2 in. Copper Female Threaded Adapter",
      "price": 3.00,
      "description": "1/2 in. Copper female threaded adapter (Brand may vary)",
      "image": "assets/images/CopperThreadedFemaleAdapter.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1/2 in. Brass Cap",
      "price": 3.00,
      "description": "1/2 in. brass threaded cap (Brand may vary)",
      "image": "assets/images/BrassCap.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "1/2 in. Brass Coupling",
      "price": 8.50,
      "description": "1/2 in. brass threaded coupling (Brand may vary)",
      "image": "assets/images/BrassCoupling.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "1/2 in. Brass 90",
      "price": 19.50,
      "description": "1/2 in. brass threaded elbow fitting (Brand may vary)",
      "image": "assets/images/Brass90.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "1/2 in. Brass 45",
      "price": 10.00,
      "description": "1/2 in. brass threaded 45 fitting (Brand may vary)",
      "image": "assets/images/Brass45.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "1/2 in. Brass Street 90",
      "price": 13.00,
      "description":
          "1/2 in. brass threaded street elbow fitting (Brand may vary)",
      "image": "assets/images/BrassStreet90.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "1/2 in. Brass Street 45",
      "price": 14.00,
      "description":
          "1/2 in. brass threaded street 45 fitting (Brand may vary)",
      "image": "assets/images/BrassStreet45.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "1/2 in. Brass Ball Valve(Threaded)",
      "price": 16.00,
      "description":
          "1/2 Full port brass ball valve with threading on both ends (Brand may vary)",
      "image": "assets/images/ThreadedBallValve.jpg",
      "categories": ["Valves", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "1/2 in. Brass Ball Valve(Non-Threaded)",
      "price": 20.00,
      "description":
          "1/2 in. Full port brass ball valve with female port on both ends (Brand may very)",
      "image": "assets/images/NonThreadedBallValve.jpg",
      "categories": ["Valves", "Bathroom", "Kitchen"],
      "specialtyStoreTag": "valves",
    },
    //Reducers
    {
      "name": "2 in. x 1 1/2 in. Copper Reducer",
      "price": 20.00,
      "description":
          "Copper Fitting for reducing from 2in. copper pipe to 1 1/2in. copper pipe (Brand may very)",
      "image": "assets/images/Copper1inTo.75inReducer.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. x 1 in. Copper Reducer",
      "price": 20.00,
      "description":
          "Copper Fitting for reducing from 2in. copper pipe to 1in. copper pipe (Brand may very)",
      "image": "assets/images/Copper2inTo1inReducer.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1 1/2 in. x 3/4 in. Copper Reducer",
      "price": 20.00,
      "description":
          "Copper Fitting for reducing from 1 1/2in. copper pipe to 3/4in. copper pipe (Brand may very)",
      "image": "assets/images/Copper2inTo1inReducer.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1 in. x 3/4 in. Copper Reducer",
      "price": 20.00,
      "description":
          "Copper Fitting for reducing from 1in. copper pipe to 3/4in. copper pipe (Brand may very)",
      "image": "assets/images/Copper1inTo.75inReducer.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1 in. x 1/2 in. Copper Reducer",
      "price": 20.00,
      "description":
          "Copper Fitting for reducing from 1in. copper pipe to 1/2in. copper pipe (Brand may very)",
      "image": "assets/images/Copper2inTo1inReducer.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    //Reducing Tees
    {
      "name": "2 in. x 2 in. x 1 in. Copper Reducing Tee",
      "price": 20.00,
      "description":
          "2in. x 2in. x 1in. Copper Fitting for reducing from 2in. copper pipe to 1in. pipe (Brand may very)",
      "image": "assets/images/Copper1inx1inx.5inTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. x 2 in. x 1 in. ProPress Copper Reducing Tee",
      "price": 20.00,
      "description":
          "2in. x 2in. x 1in. Copper Fitting for reducing from 2in. copper pipe to 1in. pipe with a propress (Brand may very)",
      "image": "assets/images/Copper1inx1inx.5inProPressTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "2 in. x 1 in. x 2 in. Copper Reducing Tee",
      "price": 20.00,
      "description":
          "2in. x 1in. x 2in. Copper Fitting for reducing from 2in. copper pipe to 1in. pipe (Brand may very)",
      "image": "assets/images/Copper1inx.5inx1inTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. x 1 in. x 2 in. ProPress Copper Reducing Tee",
      "price": 20.00,
      "description":
          "2in. x 1in. x 2in. Copper Fitting for reducing from 2in. copper pipe to 1in. pipe with a propress (Brand may very)",
      "image": "assets/images/Copper1inx.5inx1inProPressTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "2 in. x 1 in. x 1 in. Copper Reducing Tee",
      "price": 20.00,
      "description":
          "2in. x 1in. x 1in. Copper Fitting for reducing from 2in. copper pipe to 1in. pipe (Brand may very)",
      "image": "assets/images/Copper1inx.5inx.5inTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. x 1 in. x 1 in. ProPress Copper Reducing Tee",
      "price": 20.00,
      "description":
          "2in. x 1in. x 1in. Copper Fitting for reducing from 2in. copper pipe to 1in. pipe with a propress (Brand may very)",
      "image": "assets/images/Copper1inx.5inx.5inProPressTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "1 in. x 1 in. x 2 in. Copper Reducing Tee",
      "price": 20.00,
      "description":
          "1in. x 1in. x 2in. Copper Fitting for reducing from 2in. copper pipe to 1in. pipe (Brand may very)",
      "image": "assets/images/Copper.5inx.5inx1inTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1 in. x 1 in. x 2 in. ProPress Copper Reducing Tee",
      "price": 20.00,
      "description":
          "1in. x 1in. x 2in. Copper Fitting for reducing from 2in. copper pipe to 1in. pipe with a propress (Brand may very)",
      "image": "assets/images/Copper.5inx.5inx1inProPressTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "2 in. x 2 in. x 1/2 in. Copper Reducing Tee",
      "price": 20.00,
      "description":
          "2in. x 2in. x 1/2in. Copper Fitting for reducing from 2in. copper pipe to 1/2in. pipe (Brand may very)",
      "image": "assets/images/Copper2inx2inx.5inTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. x 2 in. x 1/2 in. ProPress Copper Reducing Tee",
      "price": 20.00,
      "description":
          "2in. x 2in. x 1/2in. Copper Fitting for reducing from 2in. copper pipe to 1/2in. pipe with a propress (Brand may very)",
      "image": "assets/images/Copper2inx2inx.5inProPressTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "1 in. x 1 in. x 3/4 in. Copper Reducing Tee",
      "price": 20.00,
      "description":
          "2in. x 2in. x 2/4in. Copper Fitting for reducing from 1in. copper pipe to 3/4in. pipe (Brand may very)",
      "image": "assets/images/Copper1inx1inx.75inTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1 in. x 1 in. x 3/4 in. ProPress Copper Reducing Tee",
      "price": 20.00,
      "description":
          "1in. x 1in. x 3/4in. Copper Fitting for reducing from 1in. copper pipe to 3/4in. pipe with a propress (Brand may very)",
      "image": "assets/images/Copper1inx1inx.75inProPressTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "3/4 in. x 3/4 in. x 1 in.  Copper Reducing Tee",
      "price": 20.00,
      "description":
          "3/4in. x 3/4in. x 1in. Copper Fitting for reducing from 1in. copper pipe to 3/4in. pipe (Brand may very)",
      "image": "assets/images/Copper.75inx.75inx1inTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "3/4 in. x 3/4 in. x 1 in. ProPress Copper Reducing Tee",
      "price": 20.00,
      "description":
          "3/4in. x 3/4in. x 1in. Copper Fitting for reducing from 1in. copper pipe to 3/4in. pipe with a propress (Brand may very)",
      "image": "assets/images/Copper.75inx.75inx1inProPressTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "1 in. x 1 in. x 1/2 in. Copper Reducing Tee",
      "price": 20.00,
      "description":
          "1in. x 1in. x 1/2in. Copper Fitting for reducing from 1in. copper pipe to 1/2in. pipe (Brand may very)",
      "image": "assets/images/Copper1inx1inx.5inTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1 in. x 1 in. x 1/2 in. ProPress Copper Reducing Tee",
      "price": 20.00,
      "description":
          "1in. x 1in. x 1/2in. Copper Fitting for reducing from 1in. copper pipe to 1/2in. pipe with a propress (Brand may very)",
      "image": "assets/images/Copper1inx1inx.5inProPressTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "1 in. x 1/2 in. x 1/2 in. Copper Reducing Tee",
      "price": 20.00,
      "description":
          "1in. x 1/2in. x 1/2in. Copper Fitting for reducing from 1in. copper pipe to 1/2in. pipe (Brand may very)",
      "image": "assets/images/Copper1inx.5inx.5inTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1 in. x 1/2 in. x 1/2 in. ProPress Copper Reducing Tee",
      "price": 20.00,
      "description":
          "1in. x 1/2in. x 1/2in. Copper Fitting for reducing from 1in. copper pipe to 1/2in. pipe with a propress (Brand may very)",
      "image": "assets/images/Copper1inx.5inx.5inProPressTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "1/2 in. x 1/2 in. x 1 in. Copper Reducing Tee",
      "price": 20.00,
      "description":
          "1/2in. x 1/2in. x 1in. Copper Fitting for reducing from 1in. copper pipe to 1/2in. pipe (Brand may very)",
      "image": "assets/images/Copper.5inx.5inx1inTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "1/2 in. x 1/2 in. x 1 in. ProPress Copper Reducing Tee",
      "price": 20.00,
      "description":
          "1/2in. x 1/2in. x 1in. Copper Fitting for reducing from 1in. copper pipe to 1/2in. pipe with a propress (Brand may very)",
      "image": "assets/images/Copper.5inx.5inx1inProPressTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "3/4 in. x 1/2 in. x 3/4 in. Copper Reducing Tee",
      "price": 20.00,
      "description":
          "3/4in. x 1/2in. x 3/4in. Copper Fitting for reducing from 3/4in. copper pipe to 1/2in. pipe (Brand may very)",
      "image": "assets/images/Copper1inx.75inx1inTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. Swing Check Valve (Non-Threaded)",
      "price": 20.00,
      "description": "2in. swing check valve (Brand may very)",
      "image": "assets/images/SwingCheckValve(NonThreaded).jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "2 in. Swing Check Valve (Threaded)",
      "price": 20.00,
      "description": "2in. swing check valve (Brand may very)",
      "image": "assets/images/SwingCheckValve(Threaded).jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "1 1/2 in. Swing Check Valve (Non-Threaded)",
      "price": 20.00,
      "description": "1 1/2 in. swing check valve (Brand may very)",
      "image": "assets/images/SwingCheckValve(NonThreaded).jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "1 1/2 in. Swing Check Valve (Threaded)",
      "price": 20.00,
      "description": "1 1/2 in. swing check valve (Brand may very)",
      "image": "assets/images/SwingCheckValve(Threaded).jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "1 in. Swing Check Valve (Non-Threaded)",
      "price": 20.00,
      "description": "1in. swing check valve (Brand may very)",
      "image": "assets/images/SwingCheckValve(NonThreaded).jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "1 in. Swing Check Valve (Threaded)",
      "price": 20.00,
      "description": "1in. swing check valve (Brand may very)",
      "image": "assets/images/SwingCheckValve(Threaded).jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "3/4 in. Swing Check Valve (Non-Threaded)",
      "price": 20.00,
      "description": "3/4 in. swing check valve (Brand may very)",
      "image": "assets/images/SwingCheckValve(NonThreaded).jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "3/4 in. Swing Check Valve (Threaded)",
      "price": 20.00,
      "description": "3/4 in. swing check valve (Brand may very)",
      "image": "assets/images/SwingCheckValve(Threaded).jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "1/2 in. Swing Check Valve (Non-Threaded)",
      "price": 20.00,
      "description": "1/2 in. swing check valve (Brand may very)",
      "image": "assets/images/SwingCheckValve(NonThreaded).jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "1/2 in. Swing Check Valve (Threaded)",
      "price": 20.00,
      "description": "1/2 in. swing check valve (Brand may very)",
      "image": "assets/images/SwingCheckValve(Threaded).jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "2 in. Spring Check Valve (Non-Threaded)",
      "price": 20.00,
      "description": "2in. swing check valve (Brand may very)",
      "image": "assets/images/SpringCheckValve(NonThreaded).jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "2 in. Spring Check Valve (Threaded)",
      "price": 20.00,
      "description": "2in. swing check valve (Brand may very)",
      "image": "assets/images/SpringCheckValve(Threaded).jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "1 1/2 in. Spring Check Valve (Non-Threaded)",
      "price": 20.00,
      "description": "1 1/2 in. swing check valve (Brand may very)",
      "image": "assets/images/SpringCheckValve(NonThreaded).jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "1 1/2 in. Spring Check Valve (Threaded)",
      "price": 20.00,
      "description": "1 1/2 in. swing check valve (Brand may very)",
      "image": "assets/images/SpringCheckValve(Threaded).jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "1 in. Spring Check Valve (Non-Threaded)",
      "price": 20.00,
      "description": "1in. swing check valve (Brand may very)",
      "image": "assets/images/SpringCheckValve(NonThreaded).jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "1 in. Spring Check Valve (Threaded)",
      "price": 20.00,
      "description": "1in. swing check valve (Brand may very)",
      "image": "assets/images/SpringCheckValve(Threaded).jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "3/4 in. Spring Check Valve (Non-Threaded)",
      "price": 20.00,
      "description": "3/4 in. swing check valve (Brand may very)",
      "image": "assets/images/SpringCheckValve(NonThreaded).jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "3/4 in. Spring Check Valve (Threaded)",
      "price": 20.00,
      "description": "3/4 in. swing check valve (Brand may very)",
      "image": "assets/images/SpringCheckValve(Threaded).jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "1/2 in. Spring Check Valve (Non-Threaded)",
      "price": 20.00,
      "description": "1/2 in. swing check valve (Brand may very)",
      "image": "assets/images/SpringCheckValve(NonThreaded).jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "1/2 in. Spring Check Valve (Threaded)",
      "price": 20.00,
      "description": "1/2 in. swing check valve (Brand may very)",
      "image": "assets/images/SpringCheckValve(Threaded).jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "Shower Valve(Threaded)",
      "price": 20.00,
      "description": "1/2 in. threaded port shower valve (Brand may very)",
      "image": "assets/images/ShowerValve(Threaded).jpg",
      "categories": ["Valves", "Bathroom"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "Shower Valve(Non-Threaded)",
      "price": 20.00,
      "description": "1/2 in. non threaded port shower valve (Brand may very)",
      "image": "assets/images/ShowerValve(NonThreaded).jpg",
      "categories": ["Valves", "Bathroom"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "Speedy Valve 1/2 in. Compression Outlet",
      "price": 10.00,
      "description":
          "Toilet water supply shut off valve with compression fittings and 1/2 in. outlet to tank (Brand may very)",
      "image": "assets/images/SpeedyValve.jpg",
      "categories": ["Bathroom", "Valves"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "Speedy Valve 3/8 in. Compression Outlet",
      "price": 10.00,
      "description":
          "Toilet water supply shut off valve with compression fittings and 3/8 in. outlet to tank (Brand may very)",
      "image": "assets/images/SpeedyValve.jpg",
      "categories": ["Bathroom", "Valves"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "Sink Supply Line (3/8 in. x 1/2 in. FIP)",
      "price": 10.00,
      "description":
          "3/8 in. compression x 1/2 in. FIP sink supply line 9 or 12 inches long depending on stock (Brand may very)",
      "image": "assets/images/SinkSupplyLineFIP.jpg",
      "categories": ["Bathroom", "Kitchen"],
      "specialtyStoreTag": "supplyLines",
    },
    {
      "name": "Sink Supply Line (3/8 in. x 1/2 in. FIP x 20 in.)",
      "price": 12.00,
      "description":
          "3/8 in. compression x 1/2 in. FIP sink supply line 20 in. long (Brand may very)",
      "image": "assets/images/SinkSupplyLineFIP.jpg",
      "categories": ["Bathroom", "Kitchen"],
      "specialtyStoreTag": "supplyLines",
    },
    {
      "name": "Sink Supply Line (3/8 in. x 3/8 in.)",
      "price": 10.00,
      "description":
          "3/8 in. compression x 3/8 in. compression sink supply line 9 or 12 inches long depending on stock (Brand may very)",
      "image": "assets/images/SinkSupplyLine.jpg",
      "categories": ["Bathroom", "Kitchen"],
      "specialtyStoreTag": "supplyLines",
    },
    {
      "name": "Sink Supply Line (3/8 in. x 3/8 in. x 20 in.)",
      "price": 12.00,
      "description":
          "3/8 in. compression x 3/8 in. compression sink supply line 20 in. long (Brand may very)",
      "image": "assets/images/SinkSupplyLine.jpg",
      "categories": ["Bathroom", "Kitchen"],
      "specialtyStoreTag": "supplyLines",
    },
    {
      "name": "0 Washers (Pack of 10)",
      "price": 5.00,
      "description":
          "Washers for hot/cold water valves on a sink (Brand may very)",
      "image": "assets/images/0Washers.jpg",
      "categories": ["Sinks"],
      "specialtyStoreTag": "sinkRepair",
    },
    {
      "name": "00 Washers (Pack of 10)",
      "price": 5.00,
      "description":
          "Washers for hot/cold water valves on a sink (Brand may very)",
      "image": "assets/images/00Washers.jpg",
      "categories": ["Sinks"],
      "specialtyStoreTag": "sinkRepair",
    },
    {
      "name": "Toilet Supply Line (1/2 in. x 7/8 in.)",
      "price": 10.00,
      "description":
          "1/2 in. compression connector x 7/8 in. Toilet supply line 9 or 12 inches long depending on stock (Brand may very)",
      "image": "assets/images/CompressionToiletSupplyLine.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "Toilet Supply Line (1/2 in. FIP x 7/8 in.)",
      "price": 10.00,
      "description":
          "1/2 in. FIP  x 7/8 in. Toilet supply line 9 or 12 inches long depending on stock (Brand may very)",
      "image": "assets/images/FIPToiletSupplyLine.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "Toilet Supply Line (1/2 in. x 7/8 in. x 20 in.)",
      "price": 12.00,
      "description":
          "1/2 in. compression x 7/8 in. Toilet supply line 20 in. long (Brand may very)",
      "image": "assets/images/CompressionToiletSupplyLine.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "Toilet Supply Line (1/2 in. FIP x 7/8 in. x 20 in.)",
      "price": 12.00,
      "description":
          "1/2 in. FIP x 7/8 in. Toilet supply line 20 in. long (Brand may very)",
      "image": "assets/images/FIPToiletSupplyLine.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "Toilet Supply Line (3/8 in. x 7/8 in.)",
      "price": 10.00,
      "description":
          "3/8 in. compression x 7/8 in. Toilet supply line 9 or 12 inches long depending on stock (Brand may very)",
      "image": "assets/images/ToiletSupplyLine.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "Toilet Supply Line (3/8 in. x 7/8 in. x 20 in.)",
      "price": 12.00,
      "description":
          "3/8 in. compression x 7/8 in. Toilet supply line 20 in. long (Brand may very)",
      "image": "assets/images/ToiletSupplyLine.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "Toilet Handle With Chain",
      "price": 12.00,
      "description":
          "Handle with chain mechanism for toilet with flapper (Brand may very)",
      "image": "assets/images/ToiletHandle.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "Toilet Flapper",
      "price": 12.00,
      "description": "Rubber flapper for toilet flush  (Brand may very)",
      "image": "assets/images/Flapper.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "3 in. Black Iron Pipe Coupling",
      "price": 2.50,
      "description": "3 in. Black iron coupling for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCoupling.jpg",
      "categories": ["Couplings", "Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3 in. Black Iron Pipe Cap",
      "price": 2.50,
      "description":
          "3 in. Threaded black iron cap for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCap.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3 in. Black Iron Pipe 45 degree Elbow",
      "price": 4.00,
      "description":
          "3 in. black iron 45 degree fitting for gas line (Brand may very)",
      "image": "assets/images/BlackPipe45.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3 in. Black Iron Pipe 90 degree Elbow",
      "price": 4.00,
      "description":
          "3 in. black iron 90 degree elbow for gas line (Brand may very)",
      "image": "assets/images/BlackPipe90.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3 in. Black Iron Pipe Nipple",
      "price": 2.50,
      "description": "3 in. black steel nipple for gas line (Brand may very)",
      "image": "assets/images/BlackPipeNipple.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3 in. Black Iron Pipe Tee",
      "price": 2.50,
      "description":
          "3 in. black iron tee for connecting threaded steel pipe (Brand may very)",
      "image": "assets/images/BlackPipeTee.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3 in. Black Iron Pipe Union Fiting",
      "price": 11.00,
      "description":
          "3 in. black iron Union fitting for connecting two threaded steel pipes (Brand may very)",
      "image": "assets/images/BlackPipeUnion.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 1/2  in. Black Iron Pipe Coupling",
      "price": 2.50,
      "description":
          "2 1/2  in. Black iron coupling for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCoupling.jpg",
      "categories": ["Couplings", "Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 1/2  in. Black Iron Pipe Cap",
      "price": 2.50,
      "description":
          "2 1/2  in. Threaded black iron cap for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCap.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 1/2  in. Black Iron Pipe 45 degree Elbow",
      "price": 4.00,
      "description":
          "2 1/2  in. black iron 45 degree fitting for gas line (Brand may very)",
      "image": "assets/images/BlackPipe45.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 1/2  in. Black Iron Pipe 90 degree Elbow",
      "price": 4.00,
      "description":
          "2 1/2  in. black iron 90 degree elbow for gas line (Brand may very)",
      "image": "assets/images/BlackPipe90.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 1/2  in. Black Iron Pipe Nipple",
      "price": 2.50,
      "description":
          "2 1/2  in. black steel nipple for gas line (Brand may very)",
      "image": "assets/images/BlackPipeNipple.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 1/2  in. Black Iron Pipe Tee",
      "price": 2.50,
      "description":
          "2 1/2  in. black iron tee for connecting threaded steel pipe (Brand may very)",
      "image": "assets/images/BlackPipeTee.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 1/2  in. Black Iron Pipe Union Fiting",
      "price": 11.00,
      "description":
          "2 1/2 in. black iron Union fitting for connecting two threaded steel pipes (Brand may very)",
      "image": "assets/images/BlackPipeUnion.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 in. Black Iron Pipe Coupling",
      "price": 2.50,
      "description": "2 in. Black iron coupling for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCoupling.jpg",
      "categories": ["Couplings", "Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 in. Black Iron Pipe Cap",
      "price": 2.50,
      "description":
          "2 in. Threaded black iron cap for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCap.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 in. Black Iron Pipe 45 degree Elbow",
      "price": 4.00,
      "description":
          "2 in. black iron 45 degree fitting for gas line (Brand may very)",
      "image": "assets/images/BlackPipe45.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 in. Black Iron Pipe 90 degree Elbow",
      "price": 4.00,
      "description":
          "2 in. black iron 90 degree elbow for gas line (Brand may very)",
      "image": "assets/images/BlackPipe90.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 in. Black Iron Pipe Nipple",
      "price": 2.50,
      "description": "2 in. black steel nipple for gas line (Brand may very)",
      "image": "assets/images/BlackPipeNipple.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 in. Black Iron Pipe Tee",
      "price": 2.50,
      "description":
          "2 in. black iron tee for connecting threaded steel pipe (Brand may very)",
      "image": "assets/images/BlackPipeTee.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 in. Black Iron Pipe Union Fiting",
      "price": 11.00,
      "description":
          "2 in. black iron Union fitting for connecting two threaded steel pipes (Brand may very)",
      "image": "assets/images/BlackPipeUnion.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/2 in. Black Iron Pipe Coupling",
      "price": 2.50,
      "description":
          "1 1/2 in. Black iron coupling for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCoupling.jpg",
      "categories": ["Couplings", "Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/2 in. Black Iron Pipe Cap",
      "price": 2.50,
      "description":
          "1 1/2 in. Threaded black iron cap for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCap.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/2 in. Black Iron Pipe 45 degree Elbow",
      "price": 4.00,
      "description":
          "1 1/2 in. black iron 45 degree fitting for gas line (Brand may very)",
      "image": "assets/images/BlackPipe45.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/2 in. Black Iron Pipe 90 degree Elbow",
      "price": 4.00,
      "description":
          "1 1/2 in. black iron 90 degree elbow for gas line (Brand may very)",
      "image": "assets/images/BlackPipe90.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/2 in. Black Iron Pipe Nipple",
      "price": 2.50,
      "description":
          "1 1/2 in. black steel nipple for gas line (Brand may very)",
      "image": "assets/images/BlackPipeNipple.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/2 in. Black Iron Pipe Tee",
      "price": 2.50,
      "description":
          "1 1/2 in. black iron tee for connecting threaded steel pipe (Brand may very)",
      "image": "assets/images/BlackPipeTee.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/2 in. Black Iron Pipe Union Fiting",
      "price": 11.00,
      "description":
          "1 1/2 in. black iron Union fitting for connecting two threaded steel pipes (Brand may very)",
      "image": "assets/images/BlackPipeUnion.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/4 in. Black Iron Pipe Coupling",
      "price": 2.50,
      "description":
          "1 1/4 in. Black iron coupling for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCoupling.jpg",
      "categories": ["Couplings", "Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/4 in. Black Iron Pipe Cap",
      "price": 2.50,
      "description":
          "1 1/4 in. Threaded black iron cap for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCap.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/4 in. Black Iron Pipe 45 degree Elbow",
      "price": 4.00,
      "description":
          "1 1/4 in. black iron 45 degree fitting for gas line (Brand may very)",
      "image": "assets/images/BlackPipe45.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/4 in. Black Iron Pipe 90 degree Elbow",
      "price": 4.00,
      "description":
          "1 1/4 in. black iron 90 degree elbow for gas line (Brand may very)",
      "image": "assets/images/BlackPipe90.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/4 in. Black Iron Pipe Nipple",
      "price": 2.50,
      "description":
          "1 1/4 in. black steel nipple for gas line (Brand may very)",
      "image": "assets/images/BlackPipeNipple.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/4 in. Black Iron Pipe Tee",
      "price": 2.50,
      "description":
          "1 1/4 in. black iron tee for connecting threaded steel pipe (Brand may very)",
      "image": "assets/images/BlackPipeTee.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/4 in. Black Iron Pipe Union Fiting",
      "price": 11.00,
      "description":
          "1 1/4 in. black iron Union fitting for connecting two threaded steel pipes (Brand may very)",
      "image": "assets/images/BlackPipeUnion.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 in. Black Iron Pipe Coupling",
      "price": 2.50,
      "description": "1 in. Black iron coupling for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCoupling.jpg",
      "categories": ["Couplings", "Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 in. Black Iron Pipe Cap",
      "price": 2.50,
      "description":
          "1 in. Threaded black iron cap for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCap.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 in. Black Iron Pipe 45 degree Elbow",
      "price": 4.00,
      "description":
          "1 in. black iron 45 degree fitting for gas line (Brand may very)",
      "image": "assets/images/BlackPipe45.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 in. Black Iron Pipe 90 degree Elbow",
      "price": 4.00,
      "description":
          "1 in. black iron 90 degree elbow for gas line (Brand may very)",
      "image": "assets/images/BlackPipe90.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 in. Black Iron Pipe Nipple",
      "price": 2.50,
      "description": "1 in. black steel nipple for gas line (Brand may very)",
      "image": "assets/images/BlackPipeNipple.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 in. Black Iron Pipe Tee",
      "price": 2.50,
      "description":
          "1 in. black iron tee for connecting threaded steel pipe (Brand may very)",
      "image": "assets/images/BlackPipeTee.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 in. Black Iron Pipe Union Fiting",
      "price": 11.00,
      "description":
          "1 in. black iron Union fitting for connecting two threaded steel pipes (Brand may very)",
      "image": "assets/images/BlackPipeUnion.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3/4 in. Black Iron Pipe Coupling",
      "price": 2.50,
      "description":
          "3/4 in. Black iron coupling for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCoupling.jpg",
      "categories": ["Couplings", "Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1/2 in. Black Iron Pipe Cap",
      "price": 2.50,
      "description":
          "3/4 in. Threaded black iron cap for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCap.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3/4 in. Black Iron Pipe 45 degree Elbow",
      "price": 4.00,
      "description":
          "3/4 in. black iron 45 degree fitting for gas line (Brand may very)",
      "image": "assets/images/BlackPipe45.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3/4 in. Black Iron Pipe 90 degree Elbow",
      "price": 4.00,
      "description":
          "3/4 in. black iron 90 degree elbow for gas line (Brand may very)",
      "image": "assets/images/BlackPipe90.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3/4 in. Black Iron Pipe Nipple",
      "price": 2.50,
      "description": "3/4 in. black steel nipple for gas line (Brand may very)",
      "image": "assets/images/BlackPipeNipple.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3/4 in. Black Iron Pipe Tee",
      "price": 2.50,
      "description":
          "3/4 in. black iron tee for connecting threaded steel pipe (Brand may very)",
      "image": "assets/images/BlackPipeTee.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3/4 in. Black Iron Pipe Union Fiting",
      "price": 11.00,
      "description":
          "3/4 in. black iron Union fitting for connecting two threaded steel pipes (Brand may very)",
      "image": "assets/images/BlackPipeUnion.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1/2 in. Black Iron Pipe Coupling",
      "price": 2.50,
      "description":
          "1/2 in. Black iron coupling for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCoupling.jpg",
      "categories": ["Couplings", "Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1/2 in. Black Iron Pipe Cap",
      "price": 2.50,
      "description":
          "1/2 in. Threaded black iron cap for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCap.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1/2 in. Black Iron Pipe 45 degree Elbow",
      "price": 4.00,
      "description":
          "1/2 in. black iron 45 degree fitting for gas line (Brand may very)",
      "image": "assets/images/BlackPipe45.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1/2 in. Black Iron Pipe 90 degree Elbow",
      "price": 4.00,
      "description":
          "1/2 in. black iron 90 degree elbow for gas line (Brand may very)",
      "image": "assets/images/BlackPipe90.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1/2 in. Black Iron Pipe Nipple",
      "price": 2.50,
      "description": "1/2 in. black steel nipple for gas line (Brand may very)",
      "image": "assets/images/BlackPipeNipple.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1/2 in. Black Iron Pipe Tee",
      "price": 2.50,
      "description":
          "1/2 in. black iron tee for connecting threaded steel pipe (Brand may very)",
      "image": "assets/images/BlackPipeTee.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1/2 in. Black Iron Pipe Union Fiting",
      "price": 11.00,
      "description":
          "1/2 in. black iron Union fitting for connecting two threaded steel pipes (Brand may very)",
      "image": "assets/images/BlackPipeUnion.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
      "specialtyStoreTag": "blackIron",
    },
    //REDUCERS + Bushings
    {
      "name": "3 in. to 2 1/2 in. Black Iron Reducer Fitting",
      "price": 93.00,
      "description":
          "Black iron fitting for reducing from 3 in. to 2 1/2 in. pipe (Brand may very)",
      "image": "assets/images/BlackPipe3inTo2.5inReducer.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3 in. to 2 in. Black Iron Reducer Fitting",
      "price": 79.50,
      "description":
          "3Black iron fitting for reducing from 3 in. to 2 in. pipe (Brand may very)",
      "image": "assets/images/BlackPipe3inTo2inReducer.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 in. to 1 1/2 in. Black Iron Reducer Fitting",
      "price": 27.00,
      "description":
          "Black iron fitting for reducing from 2 in. to 2 1/2 in. pipe (Brand may very)",
      "image": "assets/images/BlackPipe2inTo1.5inReducer.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 in. to 1 in. Black Iron Reducer Fitting",
      "price": 29.00,
      "description":
          "Black iron fitting for reducing from 2 in. to 1 in. pipe (Brand may very)",
      "image": "assets/images/BlackPipe2inTo1inReducer.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/2 in. to 1 in. Black Iron Reducer Fitting",
      "price": 21.50,
      "description":
          "Black iron fitting for reducing from 1 1/2 in. to 1 in. pipe (Brand may very)",
      "image": "assets/images/BlackPipe1.5inTo1inReducer.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/4 in. to 3/4 in. Black Iron Reducer Fitting",
      "price": 15.00,
      "description":
          "Black iron fitting for reducing from 1 1/4 in. to 3/4 in. pipe (Brand may very)",
      "image": "assets/images/BlackPipe1.25inTo.75inReducer.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 in. to 1/2 in. Black Iron Reducer Fitting",
      "price": 12.00,
      "description":
          "Black iron fitting for reducing from 1 in. to 1/2 in. pipe (Brand may very)",
      "image": "assets/images/BlackPipe1inTo.5inReducer.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3/4 in. to 1/4 in. Black Iron Reducer Fitting",
      "price": 9.00,
      "description":
          "Black iron fitting for reducing from 3/4 in. to 1/4 in. pipe (Brand may very)",
      "image": "assets/images/BlackPipe.75inTo.25inReducer.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
      "specialtyStoreTag": "blackIron",
    },
    //BUSHINGS
    {
      "name": "3 in. to 2 1/2 in. Black Iron Reducing Bushing",
      "price": 93.00,
      "description":
          "Black iron bushing for reducing from 3 in. to 2 1/2 in. pipe (Brand may very)",
      "image": "assets/images/Black3inTo2.5inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3 in. to 2 in. Black Iron Reducing Bushing",
      "price": 79.50,
      "description":
          "Black iron bushing for reducing from 3 in. to 2 in. pipe (Brand may very)",
      "image": "assets/images/Black3inTo2inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3 in. to 1 in. Black Iron Reducing Bushing",
      "price": 98.00,
      "description":
          "Black iron bushing for reducing from 3 in. to 1 in. pipe (Brand may very)",
      "image": "assets/images/Black3inTo1inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 1/2 in. to 2 in. Black Iron Reducing Bushing",
      "price": 22.50,
      "description":
          "Black iron bushing for reducing from 2 1/2 in. to 2 in. pipe (Brand may very)",
      "image": "assets/images/Black2.5inTo2inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 1/2 in. to 1 1/2 in. Black Iron Reducing Bushing",
      "price": 74.50,
      "description":
          "Black iron bushing for reducing from 2 1/2 in. to 1 1/2 in. pipe (Brand may very)",
      "image": "assets/images/Black2.5inTo1.5inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 1/2 in. to 1 1/4 in. Black Iron Reducing Bushing",
      "price": 81.00,
      "description":
          "Black iron bushing for reducing from 2 1/2 in. to 1 1/4 in. pipe (Brand may very)",
      "image": "assets/images/Black2.5inTo1.25inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 1/2 in. to 1 in. Black Iron Reducing Bushing",
      "price": 81.00,
      "description":
          "Black iron bushing for reducing from 2 1/2 in. to 1 in. pipe (Brand may very)",
      "image": "assets/images/Black2.5inTo1inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 1/2 in. to 3/4 in. Black Iron Reducing Bushing",
      "price": 11.00,
      "description":
          "Black iron bushing for reducing from 2 1/2 in. to 3/4 in. pipe (Brand may very)",
      "image": "assets/images/Black2.5inTo.75inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 1/2 in. to 1/2 in. Black Iron Reducing Bushing",
      "price": 11.00,
      "description":
          "Black iron bushing for reducing from 2 1/2 in. to 1/2 in. pipe (Brand may very)",
      "image": "assets/images/Black2.5inTo.5inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 in. to 1 1/2 in. Black Iron Reducing Bushing",
      "price": 14.50,
      "description":
          "Black iron bushing for reducing from 2 in. to 1 1/2 in. pipe (Brand may very)",
      "image": "assets/images/Black2inTo1.5inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 in. to 1 in. Black Iron Reducing Bushing",
      "price": 29.00,
      "description":
          "Black iron bushing for reducing from 2 in. to 1 in. pipe (Brand may very)",
      "image": "assets/images/Black2inTo1inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 in. to 3/4 in. Black Iron Reducing Bushing",
      "price": 31.00,
      "description":
          "Black iron bushing for reducing from 2 in. to 3/4 in. pipe (Brand may very)",
      "image": "assets/images/Black2inTo.75inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 in. to 1/2 in. Black Iron Reducing Bushing",
      "price": 35.50,
      "description":
          "Black iron bushing for reducing from 2 in. to 1/2 in. pipe (Brand may very)",
      "image": "assets/images/Black2inTo.5inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/2 in. to 1 1/4 in. Black Iron Reducing Bushing",
      "price": 11.50,
      "description":
          "Black iron bushing for reducing from 1 1/2 in. to 1 1/4 in. pipe (Brand may very)",
      "image": "assets/images/Black1.5inTo1.25inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/2 in. to 1 in. Black Iron Reducing Bushing",
      "price": 21.50,
      "description":
          "Black iron bushing for reducing from 1 1/2 in. to 1 in. pipe (Brand may very)",
      "image": "assets/images/Black1.5inTo1inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/2 in. to 3/4 in. Black Iron Reducing Bushing",
      "price": 11.00,
      "description":
          "Black iron bushing for reducing from 1 1/2 in. to 3/4 in. pipe (Brand may very)",
      "image": "assets/images/Black1.5inTo.75inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/2 in. to 1/2 in. Black Iron Reducing Bushing",
      "price": 11.00,
      "description":
          "Black iron bushing for reducing from 1 1/2 in. to 1/2 in. pipe (Brand may very)",
      "image": "assets/images/Black1.5inTo.5inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/2 in. to 1/4 in. Black Iron Reducing Bushing",
      "price": 11.00,
      "description":
          "Black iron bushing for reducing from 1 1/2 in. to 1/4 in. pipe (Brand may very)",
      "image": "assets/images/Black1.5inTo.25inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/4 in. to 1 in. Black Iron Reducing Bushing",
      "price": 9.00,
      "description":
          "Black iron bushing for reducing from 1 1/4 in. to 1 in. pipe (Brand may very)",
      "image": "assets/images/Black1.25inTo1inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/4 in. to 3/4 in. Black Iron Reducing Bushing",
      "price": 9.00,
      "description":
          "Black iron bushing for reducing from 1 1/4 in. to 3/4 in. pipe (Brand may very)",
      "image": "assets/images/Black1.25inTo.75inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/4 in. to 1/2 in. Black Iron Reducing Bushing",
      "price": 10.50,
      "description":
          "Black iron bushing for reducing from 1 1/4 in. to 1/2 in. pipe (Brand may very)",
      "image": "assets/images/Black1.25inTo.5inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/4 in. to 1/4 in. Black Iron Reducing Bushing",
      "price": 13.50,
      "description":
          "Black iron bushing for reducing from 1 1/4 in. to 1/4 in. pipe (Brand may very)",
      "image": "assets/images/Black1.25inTo.25inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 in. to 3/4 in. Black Iron Reducing Bushing",
      "price": 7.00,
      "description":
          "Black iron bushing for reducing from 1 in. to 3/4 in. pipe (Brand may very)",
      "image": "assets/images/Black1inTo.75inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 in. to 1/2 in. Black Iron Reducing Bushing",
      "price": 7.00,
      "description":
          "Black iron bushing for reducing from 1 in. to 1/2 in. pipe (Brand may very)",
      "image": "assets/images/Black1inTo.5inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 in. to 1/4 in. Black Iron Reducing Bushing",
      "price": 9.50,
      "description":
          "Black iron bushing for reducing from 1 in. to 1/4 in. pipe (Brand may very)",
      "image": "assets/images/Black1inTo.25inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 in. to 1/8 in. Black Iron Reducing Bushing",
      "price": 11.00,
      "description":
          "Black iron bushing for reducing from 1 in. to 1/8 in. pipe (Brand may very)",
      "image": "assets/images/Black1inTo.125inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3/4 in. to 1/2 in. Black Iron Reducing Bushing",
      "price": 7.00,
      "description":
          "Black iron bushing for reducing from 3/4 in. to 1/2 in. pipe (Brand may very)",
      "image": "assets/images/Black.75inTo.5inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3/4 in. to 1/4 in. Black Iron Reducing Bushing",
      "price": 11.00,
      "description":
          "Black iron bushing for reducing from 3/4 in. to 1/2 in. pipe (Brand may very)",
      "image": "assets/images/Black.75inTo.25inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3/4 in. to 1/8 in. Black Iron Reducing Bushing",
      "price": 11.00,
      "description":
          "Black iron bushing for reducing from 3/4 in. to 1/8 in. pipe (Brand may very)",
      "image": "assets/images/Black.75inTo.125inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1/2 in. to 1/4 in. Black Iron Reducing Bushing",
      "price": 11.00,
      "description":
          "Black iron bushing for reducing from 1/2 in. to 1/4 in. pipe (Brand may very)",
      "image": "assets/images/Black.5inTo.25inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1/2 in. to 1/8 in. Black Iron Reducing Bushing",
      "price": 11.00,
      "description":
          "Black iron bushing for reducing from 1/2 in. to 1/8 in. pipe (Brand may very)",
      "image": "assets/images/Black.5inTo.125inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1/4 in. to 1/8 in. Black Iron Reducing Bushing",
      "price": 11.00,
      "description":
          "Black iron bushing for reducing from 1/4 in. to 1/8 in. pipe (Brand may very)",
      "image": "assets/images/Black.25inTo.125inBushing.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Bushings",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3 in. to 2 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 3 in. to 2 in. pipe (Brand may very)",
      "image": "assets/images/Black3inTo2inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3 in. to 2 1/2 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 3 in. to 2 1/2 in. pipe (Brand may very)",
      "image": "assets/images/Black3inTo2.5inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3 in. to 1 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 3 in. to 1 in. pipe (Brand may very)",
      "image": "assets/images/Black3inTo1inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 1/2 in. to 2 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 2 1/2 in. to 2 in. pipe (Brand may very)",
      "image": "assets/images/Black2.5inTo2inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 1/2 in. to 1 1/2 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 2 1/2 in. to 1 1/2 in. pipe (Brand may very)",
      "image": "assets/images/Black2.5inTo1.5inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 1/2 in. to 1 1/4 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 2 1/2 in. to 1 1/4 in. pipe (Brand may very)",
      "image": "assets/images/Black2.5inTo1.25inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 1/2 in. to 1 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 2 1/2 in. to 1 in. pipe (Brand may very)",
      "image": "assets/images/Black2.5inTo1inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 1/2 in. to 3/4 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 2 1/2 in. to 3/4 in. pipe (Brand may very)",
      "image": "assets/images/Black2.5inTo.75inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    /*{
      "name": "2 1/2 in. to 1/2 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 2 1/2 in. to 1/2 in. pipe(Brand may very)",
      "image": "assets/images/Black2.5inTo.5inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
    },*/
    {
      "name": "2 in. to 1 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 2 in. to 1 in. pipe (Brand may very)",
      "image": "assets/images/Black2inTo1inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 in. to 1 1/2 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 2 in. to 1 1/2 in. pipe (Brand may very)",
      "image": "assets/images/Black2inTo1.5inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 in. to 1 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 2 in. to 1 in. pipe (Brand may very)",
      "image": "assets/images/Black2inTo1inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 in. to 3/4 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 2 in. to 3/4 in. pipe (Brand may very)",
      "image": "assets/images/Black2inTo.75inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "2 in. to 1/2 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 2 in. to 1/2 in. pipe (Brand may very)",
      "image": "assets/images/Black2inTo.5inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/2 in. to 1 1/4 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 1 1/2 in. to 1 1/4 in. pipe (Brand may very)",
      "image": "assets/images/Black1.5inTo1.25inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/2 in. to 1 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 1 1/2 in. to 1 in. pipe (Brand may very)",
      "image": "assets/images/Black1.5inTo1inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/2 in. to 3/4 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 1 1/2 in. to 3/4 in. pipe (Brand may very)",
      "image": "assets/images/Black1.5inTo.75inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/2 in. to 1/2 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 1 1/2 in. to 1/2 in. pipe (Brand may very)",
      "image": "assets/images/Black1.5inTo.5inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/4 in. to 1 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 1 1/4 in. to 1 in. pipe (Brand may very)",
      "image": "assets/images/Black1.25inTo1inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/4 in. to 3/4 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 1 1/4 in. to 3/4 in. pipe (Brand may very)",
      "image": "assets/images/Black1.25inTo.75inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 1/4 in. to 1/2 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 1 1/4 in. to 1/2 in. pipe (Brand may very)",
      "image": "assets/images/Black1.25inTo.5inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 in. to 3/4 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 1 in. to 3/4 in. pipe (Brand may very)",
      "image": "assets/images/Black1inTo.75inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 in. to 1/2 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 1 in. to 1/2 in. pipe (Brand may very)",
      "image": "assets/images/Black1inTo.5inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1 in. to 1/4 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 1 in. to 1/4 in. pipe (Brand may very)",
      "image": "assets/images/Black1inTo.25inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3/4 in. to 1/2 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 3/4 in. to 1/2 in. pipe (Brand may very)",
      "image": "assets/images/Black.75inTo.5inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3/4 in. to 1/4 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 3/4 in. to 1/2 in. pipe (Brand may very)",
      "image": "assets/images/Black.75inTo.25inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "3/4 in. to 1/8 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 3/4 in. to 1/8 in. pipe (Brand may very)",
      "image": "assets/images/Black.75inTo.125inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1/2 in. to 1/4 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 1/2 in. to 1/4 in. pipe (Brand may very)",
      "image": "assets/images/Black.5inTo.25inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1/2 in. to 1/8 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 1/2 in. to 1/8 in. pipe (Brand may very)",
      "image": "assets/images/Black.5inTo.125inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "1/4 in. to 1/8 in. Black Iron Reducing Elbow",
      "price": 11.00,
      "description":
          "Black iron elbow for reducing from 1/4 in. to 1/8 in. pipe (Brand may very)",
      "image": "assets/images/Black.25inTo.125inElbow.jpg",
      "categories": [
        "Gas",
        "Black Steel Pipe",
        "Fittings",
        "Elbows/90s",
        "Reducers",
      ],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "Pipe Dope (8 oz.)",
      "price": 7.00,
      "description":
          "Paste for sealing pipe connections from leaks (Brand may very)",
      "image": "assets/images/PipeDope.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "pipeSealants",
    },
    {
      "name": "4 in. Rubber Gasket",
      "price": 9.00,
      "description":
          "4 in. Rubber gasket for installing 4 in. pipe into existing cast iron(Brand may very)",
      "image": "assets/images/2inRubberGasket.jpg",
      "categories": ["PVC", "NoHub"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "4 in. Shielded Rubber Coupling",
      "price": 13.00,
      "description":
          "4 in. Rubber coupling for conneting drain pipe (Brand may very)",
      "image": "assets/images/Shielded2inRubberCoupling.jpg",
      "categories": ["PVC", "Drains", "NoHub"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "4 in. Heavy Duty Shielded Rubber Coupling",
      "price": 17.00,
      "description":
          "4 in. Shielded rubber coupling for conneting drain pipe (Brand may very)",
      "image": "assets/images/HeavyDutyRubberCoupling(3or4in).jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "4 in. Rubber Cap",
      "price": 8.50,
      "description":
          "4 in. rubber cap for PVC or Cast iron pipe (Brand may very)",
      "image": "assets/images/RubberCap.jpg",
      "categories": ["NoHub", "Drains", "PVC"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 4 in. 45",
      "price": 25.00,
      "description": "4 in. Cast iron 45 (Brand may very)",
      "image": "assets/images/NoHub45.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 4 in. Cleanout",
      "price": 62.00,
      "description": "4 in. Cast iron cleanout without cap (Brand may very)",
      "image": "assets/images/NoHubCleanout.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 4 in. Sanitary Tee",
      "price": 73.00,
      "description":
          "4 in. Cast iron santary tee for drain piping (Brand may very)",
      "image": "assets/images/NoHubSanitaryTee.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 4 in. Long Sweep Elbow",
      "price": 95.00,
      "description":
          "4 in. Cast iron elbow with a large bend for better flow (Brand may very)",
      "image": "assets/images/NoHubLongSweepElbow.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 4 in. Short Sweep Elbow",
      "price": 73.00,
      "description":
          "4 in. Cast iron elbow with a slighly larger bend for better flow (Brand may very)",
      "image": "assets/images/NoHubShortSweepElbow.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 4 in. Wye",
      "price": 40.00,
      "description": "4 in. Cast iron wye (Brand may very)",
      "image": "assets/images/NoHubWye.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 4 in. To 3 in. Reducer",
      "price": 25.00,
      "description": "4 in. Cast iron to 3 in. reducer (Brand may very)",
      "image": "assets/images/NoHubReducer(1).jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "3 in. Rubber Gasket",
      "price": 9.00,
      "description":
          "3 in. Rubber gasket for installing 3in. pipe into existing cast iron(Brand may very)",
      "image": "assets/images/2inRubberGasket.jpg",
      "categories": ["PVC", "NoHub"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "3 in. Shielded Rubber Coupling",
      "price": 12.00,
      "description":
          "3 in. Rubber coupling for conneting drain pipe(Brand may very)",
      "image": "assets/images/Shielded2inRubberCoupling.jpg",
      "categories": ["PVC", "Drains", "NoHub"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "3 in. Heavy Duty Shielded Rubber Coupling",
      "price": 11.00,
      "description":
          "3 in. Shielded rubber coupling for conneting drain pipe(Brand may very)",
      "image": "assets/images/HeavyDutyRubberCoupling(2inOrLower).jpg",
      "categories": ["PVC", "Drains", "NoHub"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "3 in. Rubber Cap",
      "price": 8.50,
      "description":
          "3 in. rubber cap for PVC or Cast iron pipe (Brand may very)",
      "image": "assets/images/RubberCap.jpg",
      "categories": ["NoHub", "Drains", "PVC"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 3 in. 45",
      "price": 11.00,
      "description": "3 in. Cast iron 45 (Brand may very)",
      "image": "assets/images/NoHub45.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 3 in. Cleanout",
      "price": 11.00,
      "description": "3 in. Cast iron cleanout without cap (Brand may very)",
      "image": "assets/images/NoHubCleanout.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 3 in. Sanitary Tee",
      "price": 38.50,
      "description":
          "3 in. Cast iron santary tee for drain piping (Brand may very)",
      "image": "assets/images/NoHubSanitaryTee.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 3 in. Long Sweep Elbow",
      "price": 59.50,
      "description":
          "3 in. Cast iron elbow with a large bend for better flow (Brand may very)",
      "image": "assets/images/NoHubLongSweepElbow.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 3 in. Short Sweep Elbow",
      "price": 41.50,
      "description":
          "3 in. Cast iron elbow with a slighly larger bend for better flow (Brand may very)",
      "image": "assets/images/NoHubShortSweepElbow.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 3 in. Wye",
      "price": 27.00,
      "description": "3 in. Cast iron wye (Brand may very)",
      "image": "assets/images/NoHubWye.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 3 in. To 2 in. Reducer",
      "price": 16.50,
      "description": "3 in. Cast iron to 2 in. reducer (Brand may very)",
      "image": "assets/images/NoHubReducer(1).jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "2 in. Rubber Gasket",
      "price": 9.00,
      "description":
          "2 in. Rubber gasket for installing 2in. pipe into existing cast iron(Brand may very)",
      "image": "assets/images/2inRubberGasket.jpg",
      "categories": ["PVC", "NoHub"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "2 in. Shielded Rubber Coupling",
      "price": 12.00,
      "description":
          "2 in. Rubber coupling for conneting drain pipe(Brand may very)",
      "image": "assets/images/Shielded2inRubberCoupling.jpg",
      "categories": ["PVC", "Drains", "NoHub"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "2 in. Heavy Duty Shielded Rubber Coupling",
      "price": 11.00,
      "description":
          "2 in. Shielded rubber coupling for conneting drain pipe(Brand may very)",
      "image": "assets/images/HeavyDutyRubberCoupling(2inOrLower).jpg",
      "categories": ["PVC", "Drains", "NoHub"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "2 in. Rubber Cap",
      "price": 5.00,
      "description":
          "2 in. rubber cap for PVC or Cast iron pipe (Brand may very)",
      "image": "assets/images/RubberCap.jpg",
      "categories": ["NoHub", "Drains", "PVC"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 2 in. 45",
      "price": 16.50,
      "description": "2 in. Cast iron 45 (Brand may very)",
      "image": "assets/images/NoHub45.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 2 in. Cleanout",
      "price": 28.50,
      "description": "2 in. Cast iron cleanout without cap (Brand may very)",
      "image": "assets/images/NoHubCleanout.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 2 in. Sanitary Tee",
      "price": 24.00,
      "description":
          "2 in. Cast iron santary tee for drain piping (Brand may very)",
      "image": "assets/images/NoHubSanitaryTee.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 2 in. Long Sweep Elbow",
      "price": 49.50,
      "description":
          "2 in. Cast iron elbow with a large bend for better flow (Brand may very)",
      "image": "assets/images/NoHubLongSweepElbow.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 2 in. Short Sweep Elbow",
      "price": 31.50,
      "description":
          "2 in. Cast iron elbow with a slighly larger bend for better flow (Brand may very)",
      "image": "assets/images/NoHubShortSweepElbow.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 2 in. Wye",
      "price": 29.00,
      "description": "2 in. Cast iron wye (Brand may very)",
      "image": "assets/images/NoHubWye.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "Purple Primer (8 oz.)",
      "price": 9.00,
      "description":
          "Purple CPVC/PVC primer for cleaning connections(Brand may very)",
      "image": "assets/images/PurplePrimer.jpg",
      "categories": ["PVC"],
      "specialtyStoreTag": "pipeSealants",
    },
    {
      "name": "Clear Primer (8 oz.)",
      "price": 7.00,
      "description":
          "Clear CPVC/PVC primer for cleaning connections(Brand may very)",
      "image": "assets/images/ClearPrimer.jpg",
      "categories": ["PVC"],
      "specialtyStoreTag": "pipeSealants",
    },
    {
      "name": "PVC Cement (8 oz.)",
      "price": 8.00,
      "description": "Clear CPVC/PVC cement for connections(Brand may very)",
      "image": "assets/images/PVCCement.jpg",
      "categories": ["PVC"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC Cutting Bit",
      "price": 8.00,
      "description":
          "Bit for cutting pvc in out of reach areas(Brand may very)",
      "image": "assets/images/PVCCuttingBit.jpg",
      "categories": ["PVC", "Tools"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 4 in. NonSlip Coupling",
      "price": 7.00,
      "description": "4 in. PVC Coupling with internal stops(Brand may very)",
      "image": "assets/images/PVCCoupling(HUB).jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 4 in. Slip Coupling",
      "price": 19.00,
      "description":
          "4 in. PVC Coupling without internal stops(Brand may very)",
      "image": "assets/images/PVCSlipCoupling.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 4 in. 45",
      "price": 13.00,
      "description": "4 in. PVC 45 (Brand may very)",
      "image": "assets/images/PVC45.jpg",
      "categories": ["PVC   ", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 4 in. 90",
      "price": 14.50,
      "description": "4 in. PVC 90 (Brand may very)",
      "image": "assets/images/PVC90.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 4 in. Cleanout With Plug",
      "price": 59.50,
      "description": "4 in. PVC cleanout with plug (Brand may very)",
      "image": "assets/images/PVCCleanoutWithCap.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 4 in. Threaded Cap",
      "price": 7.50,
      "description": "4 in. PVC cleanout cap(Brand may very)",
      "image": "assets/images/PVCThreadedCap.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 4 in. Sanitary Tee",
      "price": 43.50,
      "description": "4 in. PVC santary tee for drain piping (Brand may very)",
      "image": "assets/images/PVCSanitaryTee.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 4 in. Wye",
      "price": 54.00,
      "description": "4 in. PVC wye (Brand may very)",
      "image": "assets/images/PVCWye.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 4 in. To 3 in. Reducer",
      "price": 14.50,
      "description": "4 in. PVC to 3 in. reducer (Brand may very)",
      "image": "assets/images/PVCReducer(NoHub).jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 3 in. NonSlip Coupling",
      "price": 3.00,
      "description": "3 in. PVC Coupling with internal stops(Brand may very)",
      "image": "assets/images/PVCCoupling(HUB).jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 3 in. Slip Coupling",
      "price": 11.50,
      "description":
          "3 in. PVC Coupling without internal stops(Brand may very)",
      "image": "assets/images/PVCSlipCoupling.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 3 in. 45",
      "price": 5.50,
      "description": "3 in. PVC 45 (Brand may very)",
      "image": "assets/images/PVC45.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 3 in. 90",
      "price": 8.00,
      "description": "3 in. PVC 90 (Brand may very)",
      "image": "assets/images/PVC90.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 3 in. Cleanout",
      "price": 34.50,
      "description": "3 in. PVC cleanout with plug (Brand may very)",
      "image": "assets/images/PVCCleanoutWithCap.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 3 in. Threaded Cap",
      "price": 4.50,
      "description": "3 in. PVC cleanout cap(Brand may very)",
      "image": "assets/images/PVCThreadedCap.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 3 in. Sanitary Tee",
      "price": 12.00,
      "description": "3 in. PVC sanitary tee for drain piping (Brand may very)",
      "image": "assets/images/PVCSanitaryTee.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 3 in. Wye",
      "price": 16.00,
      "description": "3 in. PVC wye (Brand may very)",
      "image": "assets/images/PVCWye.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 3 in. To 2 in. Reducer",
      "price": 8.00,
      "description": "3 in. PVC to 2 in. reducer (Brand may very)",
      "image": "assets/images/PVCReducer(NoHub).jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 2 in. NonSlip Coupling",
      "price": 4.00,
      "description": "2 in. PVC Coupling with internal stops (Brand may very)",
      "image": "assets/images/PVCCoupling(HUB).jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 2 in. Slip Coupling",
      "price": 4.00,
      "description":
          "2 in. PVC Coupling without internal stops (Brand may very)",
      "image": "assets/images/PVCSlipCoupling.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 2 in. 45",
      "price": 4.00,
      "description": "2 in. PVC 45 (Brand may very)",
      "image": "assets/images/PVC45.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 2 in. 90",
      "price": 4.00,
      "description": "2 in. PVC 90 (Brand may very)",
      "image": "assets/images/PVC90.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 2 in. Cleanout",
      "price": 18.00,
      "description": "2 in. Cast iron cleanout with plug (Brand may very)",
      "image": "assets/images/PVCCleanoutWithCap.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 2 in. Threaded Cap",
      "price": 4.00,
      "description": "2 in. PVC cleanout cap (Brand may very)",
      "image": "assets/images/PVCThreadedCap.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 2 in. Sanitary Tee",
      "price": 4.00,
      "description": "2 in. PVC saitary tee for drain piping (Brand may very)",
      "image": "assets/images/PVCSanitaryTee.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 2 in. Wye",
      "price": 7.00,
      "description": "2 in. PVC wye (Brand may very)",
      "image": "assets/images/PVCWye.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 2 in. PTrap",
      "price": 6.00,
      "description": "2 in. PVC p-trap without nut (Brand may very)",
      "image": "assets/images/PVCPTrap.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "PVC 2 in. PTrap With Union",
      "price": 36.00,
      "description":
          "2 in. PVC p-trap with nut and threaded connection (Brand may very)",
      "image": "assets/images/PVCPTrap.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "2 in. Shower Drain",
      "price": 15.00,
      "description": "Shower Drain fits over 2 in. pvc pipe (Brand may very)",
      "image": "assets/images/ShowerDrain.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "Plumber's Putty (14 oz.)",
      "price": 5.00,
      "description": "Putty for waterproofing drains (Brand may very)",
      "image": "assets/images/PlumbersPutty.jpg",
      "categories": ["Drains"],
      "specialtyStoreTag": "pipeSealants",
    },
    {
      "name": "1 1/2 in. Chrome Plated Tailpipe Assembly",
      "price": 5.00,
      "description":
          "1 1/2 in. tailpipe with opening and closing mechanism for sink drain (Brand may very)",
      "image": "assets/images/ChromePlatedSinkDrainAssembly.jpg",
      "categories": ["Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "1 1/2 in. PVC Tailpipe",
      "price": 5.00,
      "description":
          "1 1/2 in. tailpipe with opening and closing mechanism for sink drain (Brand may very)",
      "image": "assets/images/PVCTailPipe.25.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "1 1/4 in. Chrome Plated Tailpipe Assembly",
      "price": 5.00,
      "description":
          "1 1/4 in. tailpipe with opening and closing mechanism for sink drain (Brand may very)",
      "image": "assets/images/ChromePlatedSinkDrainAssembly.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "1 1/4 in. PVC TailPipe",
      "price": 5.00,
      "description":
          "1 1/4 in. threaded PVC tailpipe for sink drain (Brand may very)",
      "image": "assets/images/PVCTailPipe.25.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "1 1/2 in. To 1 1/4 in. Plastic Reducing Bushing",
      "price": 5.00,
      "description":
          "PLastic bushing for reducing from 1 1/2in. drain pipe to 1 1/4in. trap/pipe (Brand may very)",
      "image": "assets/images/PVCTailPipe.25.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "generalPlumbing",
    },
    {
      "name": "1 1/2 in. Chrome Plated P-Trap",
      "price": 5.00,
      "description": "1 1/2 in. chrome plated p-trap (Brand may very)",
      "image": "assets/images/ChromePlatedPTrap.jpg",
      "categories": ["Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "1 1/2 in. PVC P-Trap",
      "price": 5.00,
      "description": "1 1/2 in. PVC p-trap (Brand may very)",
      "image": "assets/images/PVCP-Trap.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "1 1/4 in. Chrome Plated P-Trap ",
      "price": 5.00,
      "description": "1 1/4 in. chrome plated p-trap (Brand may very)",
      "image": "assets/images/ChromePlatedPTrap.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "1 1/4 in. PVC P-Trap",
      "price": 5.00,
      "description": "1 1/4 in. PVC p-trap (Brand may very)",
      "image": "assets/images/PVCP-Trap.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "1 1/2 in. PVC Trap Adapter",
      "price": 5.00,
      "description":
          "Adapter to fit a p trap into 1 1/2 in. pvc pipe (Brand may very)",
      "image": "assets/images/PVCTrapAdapter.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "1 1/2 in. x 4 in. MPT Galvanized Nipple",
      "price": 11.00,
      "description":
          "1 1/2 in. x 4 in. male pipe thread galvanized nipple for P-trap or other uses (Brand may very)",
      "image": "assets/images/MPT4inGalvanizedNipple.jpg",
      "categories": ["Fittings", "Drains"],
      "specialtyStoreTag": "generalPlumbing",
    },
    {
      "name": "1 1/2 in. x 6 in. MPT Galvanized Nipple",
      "price": 11.00,
      "description":
          "1 1/2 in. x 6 in. male pipe thread galvanized nipple for P-trap or other uses (Brand may very)",
      "image": "assets/images/MPT4inGalvanizedNipple.jpg",
      "categories": ["Fittings", "Drains"],
      "specialtyStoreTag": "generalPlumbing",
    },
    {
      "name": "1 1/2 in. PTrap Slip Nut",
      "price": 7.00,
      "description":
          "Nut with a rubber reducer to fit a 1 1/2 p trap trap into 1 1/2 in. MPT nipple (Brand may very)",
      "image": "assets/images/PTrapSlipNut.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "1 1/4 in. PTrap Slip Nut",
      "price": 7.00,
      "description":
          "Nut with a rubber reducer to fit a 1 1/4 p trap trap into 1 1/4 in. MPT nipple (Brand may very)",
      "image": "assets/images/PTrapSlipNut.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "3 in. PVC Toilet Flange",
      "price": 7.00,
      "description":
          "3 in. wide fitting for connecting toilet to drain (Brand may very)",
      "image": "assets/images/PVCToiletFlange.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "3 in. PVC Toilet Flange With Stainless Steel Ring",
      "price": 7.00,
      "description":
          "3 in. wide fitting for connecting toilet to drain (Brand may very)",
      "image": "assets/images/PVCToiletFlangeWithMetalRing.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "pvcDrainage",
    },
    {
      "name": "4 in. x 2 in. Cast Iron Toilet Flange",
      "price": 7.00,
      "description":
          "4 in. wide code blue cast iron toilet flange (Brand may very)",
      "image": "assets/images/CastIronToiletFlange(4inx2in).jpg",
      "categories": ["Drains"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "4 in. Wax Ring",
      "price": 7.00,
      "description": "3 in. wax ring for toilet drains (Brand may very)",
      "image": "assets/images/WaxRing.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "4 in. Wax Ring With Horn",
      "price": 7.00,
      "description":
          "4 in. wax ring for toilet drains with black horn (Brand may very)",
      "image": "assets/images/WaxRingWithHorn.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "3 in. Wax Ring",
      "price": 7.00,
      "description": "3 in. wax ring for toilet drains (Brand may very)",
      "image": "assets/images/WaxRing.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "3 in. Wax Ring With Horn",
      "price": 7.00,
      "description":
          "3 in. wax ring for toilet drains with black horn (Brand may very)",
      "image": "assets/images/WaxRingWithHorn.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "Toilet/Closet Bolts",
      "price": 7.00,
      "description":
          "Bolts, nuts, and washers for fastening toilet to toilet drain flange (Brand may very)",
      "image": "assets/images/JonnyBolts.jpg",
      "categories": ["PVC", "Drains"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "4 in. Hole Saw",
      "price": 11.00,
      "description":
          "4in. circular blade for cutting holes to fit piping (Brand may very)",
      "image": "assets/images/HoleSaw(NoBit).jpg",
      "categories": ["Tools"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "3 in. Hole Saw",
      "price": 11.00,
      "description":
          "3in. circular blade for cutting holes to fit piping (Brand may very)",
      "image": "assets/images/HoleSaw(NoBit).jpg",
      "categories": ["Tools"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "2 in. Hole Saw",
      "price": 11.00,
      "description":
          "2in. circular blade for cutting holes to fit piping (Brand may very)",
      "image": "assets/images/HoleSaw(NoBit).jpg",
      "categories": ["Tools"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "1 1/2 in. Hole Saw",
      "price": 11.00,
      "description":
          "1 1/2 in. circular blade for cutting holes to fit piping (Brand may very)",
      "image": "assets/images/HoleSaw(NoBit).jpg",
      "categories": ["Tools"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "1 1/4 in. Hole Saw",
      "price": 11.00,
      "description":
          "1 1/4 in. circular blade for cutting holes to fit piping (Brand may very)",
      "image": "assets/images/HoleSaw(NoBit).jpg",
      "categories": ["Tools"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "1 in. Hole Saw",
      "price": 11.00,
      "description":
          "1in. circular blade for cutting holes to fit piping (Brand may very)",
      "image": "assets/images/HoleSaw(NoBit).jpg",
      "categories": ["Tools"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "Metal Reciprocating Saw Bit",
      "price": 11.00,
      "description":
          "Bit designed for cutting metal on a reciprocating saw (Brand may very)",
      "image": "assets/images/MetalSawzallBlade.jpg",
      "categories": ["Tools"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "Wood Reciprocating Saw Bit",
      "price": 11.00,
      "description":
          "Bit designed for cutting wood on a reciprocating saw (Brand may very)",
      "image": "assets/images/WoodSawzallBlade.jpg",
      "categories": ["Tools"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "Pipe Wrench (14 in.)",
      "price": 45.00,
      "description": "Heavy-duty wrench for gripping pipes (Brand may very)",
      "image": "assets/images/PipeWrench.jpg",
      "categories": ["Tools"],
      "specialtyStoreTag": "plumbingTools",
    },
  ];

  List<CartItem> cart = [];

  List<Order> orders = [];

  String searchQuery = "";

  String selectedCategory = "All";

  bool showAddedMessage = false;

  Future<void> saveOrderToFirebase(Map<String, dynamic> order) async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) return;

    await FirebaseFirestore.instance.collection('orders').add({
      ...order,
      "userId": user.uid,
    });
  }

  Future<void> saveOrders() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = FirebaseAuth.instance.currentUser!.uid;

    List<String> orderList = orders
        .map((order) => jsonEncode(order.toJson()))
        .toList();

    await prefs.setStringList("orders", orderList);
  }

  Future<void> loadOrders() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = FirebaseAuth.instance.currentUser!.uid;

    List<String>? orderList = prefs.getStringList("orders");

    if (orderList != null) {
      setState(() {
        orders = orderList
            .map((order) => Order.fromJson(jsonDecode(order)))
            .toList();
      });
    }
  }

  void showAddedToCartMessage() {
    setState(() {
      showAddedMessage = true;
    });

    Future.delayed(Duration(seconds: 2), () {
      setState(() {
        showAddedMessage = false;
      });
    });
  }

  late AnimationController _controller;
  late Animation<double> _scaleAnimation; //Animations for Cart

  Future<void> saveCart() async {
    final prefs = await SharedPreferences.getInstance();
    List<String> cartItems = cart
        .map(
          (item) => jsonEncode({
            "name": item.name,
            "price": item.price,
            "image": item.image,
            "quantity": item.quantity,
            "specialtyStoreTag": item.specialtyStoreTag,
            requiresCarDeliveryKey: item.requiresCarDelivery,
          }),
        )
        .toList();
    await prefs.setStringList('cart', cartItems);
  }

  Future<void> loadCart() async {
    final prefs = await SharedPreferences.getInstance();
    List<String>? cartItems = prefs.getStringList('cart');

    if (cartItems != null) {
      setState(() {
        cart = cartItems.map((item) {
          final decoded = jsonDecode(item);

          return CartItem(
            name: decoded["name"],
            price: decoded["price"],
            image: decoded["image"],
            description: decoded["description"] ?? "",
            specialtyStoreTag: decoded["specialtyStoreTag"],
            requiresCarDelivery: decoded[requiresCarDeliveryKey] == true,
            quantity: decoded["quantity"] ?? 1,
          );
        }).toList();
      });
    }
  }

  Future<void> addToCart(Map<String, dynamic> item, [int qty = 1]) async {
    final user = FirebaseAuth.instance.currentUser;

    final docRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user!.uid)
        .collection('cart')
        .doc(item["name"]);

    final doc = await docRef.get();

    if (doc.exists) {
      // 🔁 Increase quantity
      final currentQty = doc["quantity"] ?? 1;

      await docRef.update({
        "quantity": currentQty + qty,
        requiresCarDeliveryKey: item[requiresCarDeliveryKey] == true,
      });
    } else {
      // ➕ New item
      await docRef.set({
        "name": item["name"],
        "price": item["price"],
        "image": item["image"],
        "description": item["description"],
        "quantity": qty,
        "specialtyStoreTag": item["specialtyStoreTag"],
        requiresCarDeliveryKey: item[requiresCarDeliveryKey] == true,
      });
    }

    showAddedToCartMessage();
  }

  int getCartCount() {
    int total = 0;

    for (var item in cart) {
      total += item.quantity;
    }

    return total;
  }

  @override
  void initState() {
    super.initState();
    loadCart();

    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 300),
    );

    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 1.3,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
  }

  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    List<Map<String, dynamic>> filteredParts = parts.where((item) {
      bool matchesSearch = item["name"].toLowerCase().contains(
        searchQuery.toLowerCase(),
      );

      bool matchesCategory =
          selectedCategory == "All" ||
          (item["categories"] as List).contains(selectedCategory);

      return matchesSearch && matchesCategory;
    }).toList();
    return Scaffold(
      drawer: Drawer(
        child: MediaQuery.removePadding(
          context: context,
          removeTop: true,
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              Container(
                height: kToolbarHeight + 12,
                width: double.infinity,
                color: Colors.blue,
                alignment: Alignment.bottomLeft,
                padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  "Customer Menu",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),

              ListTile(
                leading: Icon(Icons.person),
                title: Text("Profile"),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => ProfileScreen()),
                  );
                },
              ),

              ListTile(
                leading: Icon(Icons.history),
                title: Text("Order History"),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => OrderHistoryScreen(orders: orders),
                    ),
                  );
                },
              ),

              Divider(),

              ListTile(
                leading: Icon(Icons.location_on),
                title: Text("Update Location"),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => AddressSearchScreen()),
                  );
                },
              ),
            ],
          ),
        ),
      ),
      appBar: AppBar(
        iconTheme: IconThemeData(color: Colors.blue.shade700),
        backgroundColor: Colors.blue.shade100,
        elevation: 0,
        shape: Border(
          bottom: BorderSide(color: Colors.blue.shade700, width: 2),
        ),
        title: Text(
          "Plumbing",
          style: TextStyle(
            color: Colors.blue.shade700,
            fontWeight: FontWeight.bold,
            fontSize: 24,
          ),
        ),
        centerTitle: false,
        titleSpacing: 0,

        leading: IconButton(
          icon: Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.pop(context);
          },
        ),
        actions: [
          Builder(
            builder: (context) => IconButton(
              icon: Icon(Icons.person),
              onPressed: () {
                Scaffold.of(context).openDrawer();
              },
            ),
          ),
          IconButton(
            icon: Icon(Icons.notifications),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => NotificationsScreen()),
              );
            },
          ),
          Stack(
            children: [
              IconButton(
                icon: ScaleTransition(
                  scale: _scaleAnimation,
                  child: Icon(Icons.shopping_cart),
                ),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => CartScreen(
                        cart: cart,
                        tradeType: "Plumbing",
                        onUpdate: () {
                          setState(() {
                            saveCart();
                          });
                        },

                        orders: orders,

                        onSaveOrders: () {
                          saveOrders();
                        },
                      ),
                    ),
                  );
                },
              ),

              StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('users')
                    .doc(FirebaseAuth.instance.currentUser!.uid)
                    .collection('cart')
                    .snapshots(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) return SizedBox();

                  int total = 0;

                  for (var doc in snapshot.data!.docs) {
                    final data = doc.data() as Map<String, dynamic>;
                    total += (data["quantity"] ?? 0) as int;
                  }

                  if (total == 0) return SizedBox(); // 👈 hide badge when empty

                  return Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      padding: EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        "$total",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ], //actions
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: EdgeInsets.all(10),
                child: Padding(
                  padding: EdgeInsets.all(10),
                  child: GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              SearchScreen(parts: parts, addToCart: addToCart),
                        ),
                      );
                    },
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 15,
                        vertical: 15,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.search),
                          SizedBox(width: 10),
                          Text("Search plumbing parts..."),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              SizedBox(
                height: 50,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children:
                      [
                        "All",
                        "Bathroom",
                        "Black Iron Fittings",
                        "Copper Fittings",
                        "Drains",
                        "Gas",
                        "Kitchen",
                        "Misc.",
                        "NoHub",
                        "Pipes",
                        "PVC",
                        "Sink",
                        "Soldering",
                        "Steam",
                        "Toilet",
                        "Tools",
                        "Valves",
                      ].map((category) {
                        final isSelected = selectedCategory == category;

                        return Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: ChoiceChip(
                            label: Text(
                              category,
                              style: TextStyle(
                                color: isSelected ? Colors.white : Colors.black,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            selected: isSelected,
                            selectedColor: Colors.blue,
                            backgroundColor: Colors.grey[200],
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                            onSelected: (_) {
                              setState(() {
                                selectedCategory = category;
                              });
                            },
                          ),
                        );
                      }).toList(),
                ),
              ),

              Expanded(
                child: GridView.builder(
                  padding: EdgeInsets.all(10),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: 0.75,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: filteredParts.length,
                  itemBuilder: (context, index) {
                    return GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => DetailScreen(
                              name: filteredParts[index]["name"],
                              price: filteredParts[index]["price"],
                              description: filteredParts[index]["description"],
                              image: filteredParts[index]["image"],
                              onAdd: (qty) {
                                addToCart(filteredParts[index], qty);
                              },
                            ),
                          ),
                        );
                      },
                      child: Card(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          children: [
                            Expanded(
                              child: Image.asset(
                                filteredParts[index]["image"],
                                fit: BoxFit.cover,
                              ),
                            ),
                            Padding(
                              padding: EdgeInsets.all(8),
                              child: Text(filteredParts[index]["name"]),
                            ),
                            Text(
                              "\$${(filteredParts[index]["price"] as num).toDouble().toStringAsFixed(2)}",
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          Positioned(
            bottom: 50,
            left: 0,
            right: 0,
            child: Center(
              child: AnimatedOpacity(
                duration: Duration(milliseconds: 500),
                opacity: showAddedMessage ? 1.0 : 0.0,
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.green,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check, color: Colors.white),
                      SizedBox(width: 8),
                      Text(
                        "Added to cart",
                        style: TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
