import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'confirm_location_screen.dart';
import 'driver_onboarding_screen.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_stripe/flutter_stripe.dart' as stripe;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart' as app_permissions;

import 'package:url_launcher/url_launcher.dart';

part 'HVACScreen.dart';
part 'catalog_items.dart';
//com.example.apprentice_app
//C7:C8:50:2F:DD:1F:8A:51:43:7A:58:00:E0:57:E4:F8:73:00:77:61

//Jesus Christ is The Way

const double minDeliveryFee = 17.0;
const double taxRate = 0.08875;
const String requiresCarDeliveryKey = "requiresCarDelivery";
const String customerTermsVersion = "2026-07-03";
const String privacyPolicyVersion = "2026-07-03";
const String customerTermsUrl = "https://thehelpersapp.com/terms";
const String privacyPolicyUrl = "https://thehelpersapp.com/privacy-policy";
const String returnRefundPolicyUrl =
    "https://thehelpersapp.com/return-refund-policy";
const Set<String> motorVehicleTypes = {"car", "pickup_truck_van"};
const Set<String> ownerAdminEmails = {"chrisl2000@thehelpersapp.com"};

bool isOwnerAdminEmail(String? email) {
  return email != null && ownerAdminEmails.contains(email.toLowerCase());
}

String generateCustomerDeliveryPin() {
  final random = Random.secure();
  return (1000 + random.nextInt(9000)).toString();
}

Future<String> ensureCustomerDeliveryPin(String userId) async {
  final userRef = FirebaseFirestore.instance.collection('users').doc(userId);
  final userDoc = await userRef.get();
  final existingPin = userDoc.data()?["deliveryPin"]?.toString();

  if (existingPin != null && RegExp(r'^\d{4}$').hasMatch(existingPin)) {
    return existingPin;
  }

  final newPin = generateCustomerDeliveryPin();
  await userRef.set({
    "deliveryPin": newPin,
    "deliveryPinUpdatedAt": FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));
  return newPin;
}

BoxDecoration appScreenFadeDecoration() {
  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: [Colors.grey.shade300, Colors.grey.shade50],
      stops: [0.0, 0.55],
    ),
  );
}

Widget appScreenFade({required Widget child}) {
  return Container(
    width: double.infinity,
    height: double.infinity,
    decoration: appScreenFadeDecoration(),
    child: child,
  );
}

String cartItemDocId(String itemName) {
  return itemName.replaceAll("/", "_slash_");
}

String catalogSlug(String value) {
  final slug = value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  return slug.isEmpty ? 'item' : slug;
}

String catalogItemIdForTrade(String tradeType, String itemName) {
  return "${tradeType.toLowerCase()}:${catalogSlug(itemName)}";
}

Future<void> addTradeItemToCart(
  Map<String, dynamic> item, {
  required String tradeType,
  int quantity = 1,
}) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;

  final itemName = item["name"]?.toString() ?? "";
  final itemId =
      item["itemId"]?.toString() ?? catalogItemIdForTrade(tradeType, itemName);

  final cartRef = FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid)
      .collection('cart');
  final docRef = cartRef.doc(cartItemDocId(itemId));
  final doc = await docRef.get();

  if (doc.exists) {
    final currentQuantity = (doc.data()?["quantity"] ?? 1) as int;
    await docRef.update({
      "itemId": itemId,
      "quantity": currentQuantity + quantity,
      "tradeType": tradeType,
      requiresCarDeliveryKey: item[requiresCarDeliveryKey] == true,
    });
    return;
  }

  final legacyDocRef = cartRef.doc(cartItemDocId(itemName));
  if (legacyDocRef.path != docRef.path) {
    final legacyDoc = await legacyDocRef.get();

    if (legacyDoc.exists) {
      final currentQuantity = (legacyDoc.data()?["quantity"] ?? 1) as int;
      await legacyDocRef.update({
        "itemId": itemId,
        "quantity": currentQuantity + quantity,
        "tradeType": tradeType,
        requiresCarDeliveryKey: item[requiresCarDeliveryKey] == true,
      });
      return;
    }
  }

  await docRef.set({
    "itemId": itemId,
    "name": itemName,
    "price": item["price"],
    "image": item["image"],
    "description": item["description"],
    "quantity": quantity,
    "tradeType": tradeType,
    "specialtyStoreTag": item["specialtyStoreTag"],
    requiresCarDeliveryKey: item[requiresCarDeliveryKey] == true,
  });
}

class PartsScrollRail extends StatelessWidget {
  final ScrollController controller;
  final Widget child;

  const PartsScrollRail({
    super.key,
    required this.controller,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(right: 8),
      child: Scrollbar(
        controller: controller,
        thumbVisibility: true,
        thickness: 16,
        radius: Radius.circular(14),
        interactive: true,
        child: child,
      ),
    );
  }
}

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
        "pk_live_51TQWNoEn8pLIEIC790W7UTfUJaW26vD8qrwfniHNzcTmwERVL4ZqGJAqjiSwW7UyCya8f5og0eGLk81vBJkndIAf00xpM60p8S";
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
      final driverRef = FirebaseFirestore.instance
          .collection('drivers')
          .doc(userId);
      final driverDoc = await driverRef.get();

      if (!driverDoc.exists) return;

      await driverRef.set({
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
  final String? itemId;
  final String name;
  final double price;
  final String image;
  final String description;
  final String? specialtyStoreTag;
  final bool requiresCarDelivery;
  int quantity;

  CartItem({
    this.itemId,
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
      'itemId': itemId,
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
          "itemId": item.itemId,
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
          itemId: item["itemId"],
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
      body: appScreenFade(
        child: Stack(
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
      ),
      resizeToAvoidBottomInset: true,
    );
  }
}

class _CartScreenState extends State<CartScreen> {
  void showEmptyCartMessage() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text("Add items before checkout.")));
  }

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
                      final cartDoc = items[index];
                      final data = items[index].data() as Map<String, dynamic>;

                      final qty = data["quantity"] ?? 1;

                      return ListTile(
                        key: ValueKey(cartDoc.id),
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
                                if (qty <= 1) {
                                  await cartDoc.reference.delete();
                                } else {
                                  await cartDoc.reference.update({
                                    "quantity": qty - 1,
                                  });
                                }
                              },
                            ),

                            Text("$qty"),

                            // ➕ ADD
                            IconButton(
                              icon: Icon(Icons.add),
                              onPressed: () async {
                                await cartDoc.reference.update({
                                  "quantity": qty + 1,
                                });
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

            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(FirebaseAuth.instance.currentUser!.uid)
                  .collection('cart')
                  .snapshots(),
              builder: (context, snapshot) {
                final hasItems =
                    snapshot.hasData && snapshot.data!.docs.isNotEmpty;

                return ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    minimumSize: Size(double.infinity, 50),
                    backgroundColor: hasItems ? Colors.green : Colors.grey,
                  ),
                  onPressed: () {
                    if (!hasItems) {
                      showEmptyCartMessage();
                      return;
                    }

                    showCheckoutModal(context);
                  },
                  child: Text("Proceed to Checkout"),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void showCheckoutModal(BuildContext context) {
    bool useSavedAddressLocal = true;
    final cartContext = context;

    showModalBottomSheet(
      context: context,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (modalContext, setModalState) {
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
                      Navigator.pop(sheetContext);

                      final snapshot = await FirebaseFirestore.instance
                          .collection('users')
                          .doc(FirebaseAuth.instance.currentUser!.uid)
                          .collection('cart')
                          .get();

                      final cartItems = snapshot.docs.map((doc) {
                        final data = doc.data();

                        return CartItem(
                          itemId:
                              data["itemId"]?.toString() ??
                              catalogItemIdForTrade(
                                widget.tradeType,
                                data["name"]?.toString() ?? "",
                              ),
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

                      if (cartItems.isEmpty) {
                        if (cartContext.mounted) {
                          showEmptyCartMessage();
                        }
                        return;
                      }

                      final result = await Navigator.push(
                        cartContext,
                        MaterialPageRoute(
                          builder: (_) => CheckoutScreen(
                            cart: cartItems,
                            tradeType: widget.tradeType,
                            useSavedAddress: useSavedAddressLocal,
                          ),
                        ),
                      );

                      print("📦 RESULT FROM CHECKOUT: $result");

                      final orderPlaced =
                          result == "orderPlaced" ||
                          (result is Map && result["status"] == "orderPlaced");
                      final placedOrderId = result is Map
                          ? result["orderId"]?.toString()
                          : null;

                      if (orderPlaced) {
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

                        if (!cartContext.mounted) return;

                        if (placedOrderId != null && placedOrderId.isNotEmpty) {
                          Navigator.pushReplacement(
                            cartContext,
                            MaterialPageRoute(
                              builder: (_) => CustomerOrderTrackingScreen(
                                orderId: placedOrderId,
                              ),
                            ),
                          );
                        }
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
  late final Future<String?> deliveryPinFuture;
  double selectedTip = 0.0;

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser;
    deliveryPinFuture = user == null
        ? Future.value(null)
        : ensureCustomerDeliveryPin(user.uid);
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

  Future<void> chooseCustomTip() async {
    final controller = TextEditingController(
      text: selectedTip > 0 ? selectedTip.toStringAsFixed(2) : "",
    );

    final customTip = await showDialog<double>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text("Custom Tip"),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              prefixText: "\$",
              labelText: "Tip amount",
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () {
                final amount = double.tryParse(controller.text.trim());
                Navigator.pop(
                  context,
                  amount == null || amount < 0 ? 0 : amount,
                );
              },
              child: Text("Apply"),
            ),
          ],
        );
      },
    );

    if (customTip == null || !mounted) return;

    setState(() {
      selectedTip = customTip;
    });
  }

  Widget tipButton(String label, double amount) {
    final isSelected = selectedTip == amount;

    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => selectedTip = amount),
        child: AnimatedContainer(
          duration: Duration(milliseconds: 180),
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSelected ? Colors.orange : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? Colors.orange : Colors.orange.shade200,
              width: 1.4,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isSelected ? Colors.white : Colors.orange.shade900,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }

  Widget customTipButton() {
    final isSelected =
        selectedTip > 0 && !const [2.0, 3.0, 4.0, 5.0].contains(selectedTip);

    return Expanded(
      child: GestureDetector(
        onTap: chooseCustomTip,
        child: AnimatedContainer(
          duration: Duration(milliseconds: 180),
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSelected ? Colors.orange : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? Colors.orange : Colors.orange.shade200,
              width: 1.4,
            ),
          ),
          child: Text(
            isSelected ? "\$${selectedTip.toStringAsFixed(2)}" : "Custom",
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isSelected ? Colors.white : Colors.orange.shade900,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
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

    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'findClosestSupplyStore',
      );
      final result = await callable.call({
        'latitude': position.latitude,
        'longitude': position.longitude,
        'tradeType': tradeType,
      });
      final data = Map<String, dynamic>.from(result.data as Map);
      final store = data['store'];

      if (store == null) {
        print("No trade stores found");
        return null;
      }

      final storeData = Map<String, dynamic>.from(store as Map);
      print(
        "🌍 STORE SEARCH SELECTED: " +
            (storeData["storeName"] ?? "Supply Store").toString(),
      );
      return storeData;
    } on FirebaseFunctionsException catch (error) {
      print("Places function failed: ${error.message}");
      return null;
    } catch (error) {
      print("Places function failed: $error");
      return null;
    }
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
    final hasCartItems = widget.cart.isNotEmpty;

    double deliveryFee = minDeliveryFee;

    double tax = subtotal * taxRate;

    double total = subtotal + deliveryFee + tax + selectedTip;

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
                        SizedBox(height: 4),

                        Text("Tip: \$${selectedTip.toStringAsFixed(2)}"),
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

                  Container(
                    width: double.infinity,
                    margin: EdgeInsets.only(top: 12),
                    padding: EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Add a driver tip",
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        SizedBox(height: 10),
                        Row(
                          children: [
                            tipButton("\$2", 2),
                            SizedBox(width: 8),
                            tipButton("\$3", 3),
                            SizedBox(width: 8),
                            tipButton("\$4", 4),
                            SizedBox(width: 8),
                            tipButton("\$5", 5),
                            SizedBox(width: 8),
                            customTipButton(),
                          ],
                        ),
                      ],
                    ),
                  ),

                  FutureBuilder<String?>(
                    future: deliveryPinFuture,
                    builder: (context, snapshot) {
                      final pin = snapshot.data;

                      return Container(
                        width: double.infinity,
                        margin: EdgeInsets.only(top: 12),
                        padding: EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.orange.shade200),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.pin, color: Colors.orange.shade800),
                            SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    "Delivery PIN",
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.orange.shade900,
                                    ),
                                  ),
                                  SizedBox(height: 3),
                                  Text(
                                    pin ?? "Loading...",
                                    style: TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 5,
                                    ),
                                  ),
                                  SizedBox(height: 3),
                                  Text(
                                    "Your driver must enter this before marking delivered.",
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),

                  SizedBox(height: 12),

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
                      onPressed:
                          (hasPaymentMethod && !isPlacingOrder && hasCartItems)
                          ? () async {
                              if (!hasCartItems) {
                                ScaffoldMessenger.of(context)
                                  ..hideCurrentSnackBar()
                                  ..showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        "Add items before checkout.",
                                      ),
                                    ),
                                  );
                                return;
                              }

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

                                double tip = selectedTip;

                                final callable = FirebaseFunctions.instance
                                    .httpsCallable('placeOrder');

                                final orderResult = await callable.call({
                                  "paymentMethodId": selectedPaymentMethodId,
                                  "customerLat": lat,
                                  "customerLng": lng,
                                  "customerAddress": address,
                                  "customerName":
                                      userData?['name'] ?? "Unknown",
                                  "store": closestStore,
                                  "tradeType": widget.tradeType,
                                  "requiresCarDelivery":
                                      cartRequiresCarDelivery(widget.cart),
                                  "tip": tip,
                                  "items": widget.cart
                                      .map(
                                        (item) => {
                                          "itemId":
                                              item.itemId ??
                                              catalogItemIdForTrade(
                                                widget.tradeType,
                                                item.name,
                                              ),
                                          "quantity": item.quantity,
                                        },
                                      )
                                      .toList(),
                                });
                                final orderData = Map<String, dynamic>.from(
                                  orderResult.data as Map,
                                );
                                final orderId = orderData["orderId"]
                                    ?.toString();

                                if (orderId == null || orderId.isEmpty) {
                                  throw StateError(
                                    "Order was not confirmed by the server.",
                                  );
                                }

                                print("💰 ORDER AND PAYMENT SUCCESS");

                                final savedOrder = await FirebaseFirestore
                                    .instance
                                    .collection('orders')
                                    .doc(orderId)
                                    .get(
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
                                    builder: (_) =>
                                        OrderSuccessScreen(orderId: orderId),
                                  ),
                                );

                                if (result == "orderPlaced" ||
                                    (result is Map &&
                                        result["status"] == "orderPlaced")) {
                                  Navigator.pop(context, {
                                    "status": "orderPlaced",
                                    "orderId": result is Map
                                        ? result["orderId"]?.toString() ??
                                              orderId
                                        : orderId,
                                  });
                                }
                              } on FirebaseFunctionsException catch (error) {
                                print("❌ CHECKOUT FUNCTION ERROR: $error");

                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      error.message ??
                                          "Could not place order. Please try again.",
                                    ),
                                  ),
                                );
                              } catch (e) {
                                print("❌ ERROR: $e");

                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text("Something went wrong"),
                                  ),
                                );
                              } finally {
                                if (mounted) {
                                  setState(() {
                                    isPlacingOrder = false;
                                  });
                                }
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
  final String orderId;

  const OrderSuccessScreen({required this.orderId});

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
                Navigator.pop(context, {
                  "status": "orderPlaced",
                  "orderId": orderId,
                });
              },
              child: Text("Track Order"),
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
      case "Store Issue":
        return Icons.report_problem;
      case "Customer Cancelled":
        return Icons.cancel;
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
      case "Store Issue":
        return Colors.deepOrange;
      case "Customer Cancelled":
        return Colors.red;
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
      case "Store Issue":
        return "$storeName reported an item was not in stock. Choose whether to try the next nearest store.";
      case "Customer Cancelled":
        return "Your order was cancelled. The \$12 base delivery charge still applies.";
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
      case "Store Issue":
        return Colors.deepOrange;
      case "Rejected":
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  String trackingMessage(String status, bool hasDriver) {
    if (status == "Store Issue") {
      return "The store reported an item was not in stock. You can try sending this order to the next nearest store.";
    }

    if (status == "Customer Cancelled") {
      return "This order was cancelled. The \$12 cancellation charge still applies.";
    }

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
            if (status == "Store Issue") ...[
              SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.deepOrange.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.deepOrange.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Item not in stock",
                      style: TextStyle(
                        color: Colors.deepOrange.shade800,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      "Your order is paused. We can try the next nearest supply store without cancelling the order.",
                      style: TextStyle(color: Colors.grey.shade800),
                    ),
                    SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        icon: Icon(Icons.storefront),
                        label: Text("Try next nearest store"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.deepOrange,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () => retryAtNextStore(orderId),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.deepOrange.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.deepOrange.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Cancel order",
                      style: TextStyle(
                        color: Colors.deepOrange.shade800,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      "If you cancel now, you agree that the \$12 base delivery charge still applies.",
                      style: TextStyle(color: Colors.grey.shade800),
                    ),
                    SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: Icon(Icons.cancel_outlined),
                        label: Text("Cancel order"),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.deepOrange.shade800,
                          side: BorderSide(color: Colors.deepOrange.shade400),
                        ),
                        onPressed: () => cancelStoreIssueOrder(orderId),
                      ),
                    ),
                  ],
                ),
              ),
            ],
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

  Future<void> retryAtNextStore(String orderId) async {
    final messenger = appNavigatorKey.currentContext == null
        ? null
        : ScaffoldMessenger.of(appNavigatorKey.currentContext!);

    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'retryOrderAtNextStore',
      );
      final result = await callable.call({"orderId": orderId});
      final data = Map<String, dynamic>.from(result.data as Map);
      final store = data["store"] is Map
          ? Map<String, dynamic>.from(data["store"] as Map)
          : <String, dynamic>{};
      final storeName = store["storeName"] ?? "the next store";

      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text("Order sent to $storeName.")));
    } on FirebaseFunctionsException catch (error) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(error.message ?? "Could not find another store."),
          ),
        );
    } catch (_) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text("Could not try another store right now.")),
        );
    }
  }

  Future<bool> confirmStoreIssueCancellation() async {
    final context = appNavigatorKey.currentContext;
    if (context == null) return false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text("Cancel order?"),
          content: Text(
            "By cancelling this order, you agree that the \$12 base delivery charge still applies.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text("Keep Order"),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepOrange,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: Text("I Agree, Cancel"),
            ),
          ],
        );
      },
    );

    return confirmed == true;
  }

  Future<void> cancelStoreIssueOrder(String orderId) async {
    final messenger = appNavigatorKey.currentContext == null
        ? null
        : ScaffoldMessenger.of(appNavigatorKey.currentContext!);

    final confirmed = await confirmStoreIssueCancellation();
    if (!confirmed) return;

    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'cancelStoreIssueOrder',
      );
      final result = await callable.call({"orderId": orderId});
      final data = Map<String, dynamic>.from(result.data as Map);
      final refundAmountCents = data["refundAmountCents"] is num
          ? (data["refundAmountCents"] as num).toInt()
          : 0;
      final refundText = (refundAmountCents / 100).toStringAsFixed(2);

      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              "Order cancelled. \$12 charge applies. Refunded \$$refundText.",
            ),
          ),
        );
    } on FirebaseFunctionsException catch (error) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              error.message ?? "Could not cancel order. Please try again.",
            ),
          ),
        );
    } catch (error) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text("Could not cancel order. Please try again.")),
        );
    }
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

class _AuthScreenState extends State<AuthScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  bool _didPrecacheBrandImages = false;

  bool isLogin = true;
  bool obscurePassword = true;
  bool isLoading = false;
  bool acceptedCustomerTerms = false;

  String? errorMessage;

  Future<void> openPolicyLink(String url) async {
    final uri = Uri.parse(url);

    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Could not open document link")));
    }
  }

  Widget policyLink(String text, String url) {
    return InkWell(
      onTap: () => openPolicyLink(url),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.blue.shade700,
          decoration: TextDecoration.underline,
          decorationColor: Colors.blue.shade700,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget helperBrand(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final wordmarkWidth = min(screenWidth * 0.76, 340.0);

    return RepaintBoundary(
      child: Image.asset(
        "assets/images/HelperWordmark.png",
        width: wordmarkWidth,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didPrecacheBrandImages) return;
    _didPrecacheBrandImages = true;
    precacheImage(AssetImage("assets/images/HelperWordmark.png"), context);
  }

  Future<void> submit() async {
    FocusScope.of(context).unfocus();

    if (!isLogin && !acceptedCustomerTerms) {
      setState(() {
        errorMessage =
            "Please agree to the Terms, Privacy Policy, and Refund Policy";
      });
      return;
    }

    setState(() {
      isLoading = true;
      errorMessage = null;
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

          final user = credential.user;
          if (user != null) {
            final acceptedAt = FieldValue.serverTimestamp();
            await FirebaseFirestore.instance
                .collection("users")
                .doc(user.uid)
                .set({
                  "email": user.email,
                  "agreements": {
                    "customerTerms": {
                      "accepted": true,
                      "version": customerTermsVersion,
                      "url": customerTermsUrl,
                      "acceptedAt": acceptedAt,
                    },
                    "privacyPolicy": {
                      "accepted": true,
                      "version": privacyPolicyVersion,
                      "url": privacyPolicyUrl,
                      "acceptedAt": acceptedAt,
                    },
                    "returnRefundPolicy": {
                      "accepted": true,
                      "version": customerTermsVersion,
                      "url": returnRefundPolicyUrl,
                      "acceptedAt": acceptedAt,
                    },
                  },
                  "agreementHistory": FieldValue.arrayUnion([
                    {
                      "types": [
                        "customerTerms",
                        "privacyPolicy",
                        "returnRefundPolicy",
                      ],
                      "termsVersion": customerTermsVersion,
                      "privacyPolicyVersion": privacyPolicyVersion,
                      "termsUrl": customerTermsUrl,
                      "privacyPolicyUrl": privacyPolicyUrl,
                      "returnRefundPolicyUrl": returnRefundPolicyUrl,
                      "acceptedAt": Timestamp.now(),
                      "source": "signup",
                    },
                  ]),
                }, SetOptions(merge: true));
          }

          print("✅ USER CREATED");

          if (!mounted) return;

          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => RoleRouter()),
          );
        } catch (e) {
          print("❌ ERROR: $e");
          String message = "Sign up failed";

          if (e is FirebaseAuthException) {
            switch (e.code) {
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
                message = e.message ?? "Sign up failed";
            }
          }

          if (!mounted) return;
          setState(() {
            errorMessage = message;
            isLoading = false;
          });
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
      resizeToAvoidBottomInset: true,
      backgroundColor: Colors.white,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
          final minHeight = max(0.0, constraints.maxHeight - keyboardInset);

          return SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(24, 32, 24, keyboardInset + 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: max(0.0, minHeight - 56)),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  helperBrand(context),
                  SizedBox(height: 24),
                  Container(
                    padding: EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
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

                        if (!isLogin) ...[
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.72),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: acceptedCustomerTerms
                                    ? Colors.orange
                                    : Colors.grey.shade300,
                              ),
                            ),
                            child: CheckboxListTile(
                              value: acceptedCustomerTerms,
                              activeColor: Colors.orange,
                              controlAffinity: ListTileControlAffinity.leading,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              title: Wrap(
                                spacing: 3,
                                runSpacing: 2,
                                children: [
                                  Text(
                                    "I agree to the",
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  policyLink("Terms", customerTermsUrl),
                                  Text(
                                    ",",
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  policyLink(
                                    "Privacy Policy",
                                    privacyPolicyUrl,
                                  ),
                                  Text(
                                    ", and",
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  policyLink(
                                    "Return & Refund Policy",
                                    returnRefundPolicyUrl,
                                  ),
                                  Text(
                                    ".",
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              onChanged: (value) {
                                setState(() {
                                  acceptedCustomerTerms = value == true;
                                });
                              },
                            ),
                          ),
                          SizedBox(height: 20),
                        ],

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
                              errorMessage = null;
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
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
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
        child: FutureBuilder<String?>(
          future: user == null
              ? Future.value(null)
              : ensureCustomerDeliveryPin(user.uid),
          builder: (context, snapshot) {
            final deliveryPin = snapshot.data;

            return Column(
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

                SizedBox(height: 20),

                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.orange.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Delivery PIN",
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.orange.shade900,
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        deliveryPin ?? "Loading...",
                        style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 6,
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        "Give this PIN to your driver when your order arrives.",
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                    ],
                  ),
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
            );
          },
        ),
      ),
    );
  }
}

class CustomerHelpScreen extends StatelessWidget {
  const CustomerHelpScreen({super.key});

  Widget helpSection({
    required IconData icon,
    required String title,
    required String body,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        leading: Icon(icon, color: Colors.blue.shade700),
        title: Text(title, style: TextStyle(fontWeight: FontWeight.w600)),
        childrenPadding: EdgeInsets.fromLTRB(56, 0, 20, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            body,
            style: TextStyle(color: Colors.grey.shade700, height: 1.4),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Help")),
      body: appScreenFade(
        child: ListView(
          padding: EdgeInsets.symmetric(vertical: 12),
          children: [
            helpSection(
              icon: Icons.receipt_long,
              title: "Order not showing",
              body:
                  "Open Order History to confirm the order is Pending. The app automatically checks again for available drivers while the order is waiting.",
            ),
            helpSection(
              icon: Icons.credit_card,
              title: "Payment method problems",
              body:
                  "Confirm you are online and try adding the payment method again. Test cards only work while the app is using Stripe test mode.",
            ),
            helpSection(
              icon: Icons.local_shipping,
              title: "Delivery tracking",
              body:
                  "Open Order History and select the active order. Tracking updates after a driver accepts, picks up, and delivers the order.",
            ),
            helpSection(
              icon: Icons.pin,
              title: "Delivery PIN",
              body:
                  "Your 4-digit delivery PIN confirms the order was handed to you. You can find it during checkout and in your profile. Give it to the driver only when the order arrives. The driver cannot mark the order delivered without it.",
            ),
            helpSection(
              icon: Icons.location_on,
              title: "Location problems",
              body:
                  "Make sure location services and app location permission are enabled, then use Update Location from the customer menu.",
            ),
            helpSection(
              icon: Icons.shopping_cart,
              title: "Switching trades",
              body:
                  "Your current trade cart must be empty before shopping another trade. Remove its items or complete the order to unlock the other trades.",
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
      duration: Duration(milliseconds: 1),
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

    await Future.delayed(Duration.zero);

    final user = FirebaseAuth.instance.currentUser;

    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, __, ___) => user == null ? AuthScreen() : RoleRouter(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(backgroundColor: Colors.white, body: SizedBox.expand());
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
      body: appScreenFade(
        child: SingleChildScrollView(
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
                                  storeName = null;
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
                                  final user =
                                      FirebaseAuth.instance.currentUser;

                                  final userDoc = await FirebaseFirestore
                                      .instance
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

class AdminDashboardScreen extends StatefulWidget {
  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  bool isLoading = true;
  String? errorText;
  Map<String, dynamic>? dashboard;

  @override
  void initState() {
    super.initState();
    loadDashboard();
  }

  Future<void> loadDashboard() async {
    setState(() {
      isLoading = true;
      errorText = null;
    });

    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'getAdminDashboard',
      );
      final result = await callable.call();

      if (!mounted) return;

      setState(() {
        dashboard = Map<String, dynamic>.from(result.data as Map);
        isLoading = false;
      });
    } on FirebaseFunctionsException catch (error) {
      if (!mounted) return;

      setState(() {
        errorText = error.message ?? "Could not load admin dashboard.";
        isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        errorText = "Could not load admin dashboard.";
        isLoading = false;
      });
    }
  }

  List<Map<String, dynamic>> adminList(String key) {
    final value = dashboard?[key];
    if (value is! List) return [];
    return value.map((item) => Map<String, dynamic>.from(item as Map)).toList();
  }

  Future<void> openAdminContact(Uri uri) async {
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);

    if (!opened && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Could not open contact option.")));
    }
  }

  Widget? contactMenu({String? email, String? phone}) {
    final cleanedEmail = email?.trim();
    final cleanedPhone = phone?.trim();
    final hasEmail = cleanedEmail != null && cleanedEmail.isNotEmpty;
    final hasPhone = cleanedPhone != null && cleanedPhone.isNotEmpty;

    if (!hasEmail && !hasPhone) return null;

    return PopupMenuButton<String>(
      tooltip: "Contact",
      icon: Icon(Icons.more_vert),
      onSelected: (value) {
        if (value == "email" && hasEmail) {
          openAdminContact(Uri(scheme: "mailto", path: cleanedEmail));
        } else if (value == "phone" && hasPhone) {
          openAdminContact(Uri(scheme: "tel", path: cleanedPhone));
        }
      },
      itemBuilder: (context) => [
        if (hasEmail)
          PopupMenuItem(
            value: "email",
            child: Row(
              children: [
                Icon(Icons.email_outlined, size: 18),
                SizedBox(width: 8),
                Text("Email"),
              ],
            ),
          ),
        if (hasPhone)
          PopupMenuItem(
            value: "phone",
            child: Row(
              children: [
                Icon(Icons.phone_outlined, size: 18),
                SizedBox(width: 8),
                Text("Call"),
              ],
            ),
          ),
      ],
    );
  }

  Widget metricCard(String label, int count, Color color) {
    return Expanded(
      child: Container(
        padding: EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "$count",
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: Colors.grey.shade700,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  int countValue(Map<String, dynamic> counts, String key) {
    final value = counts[key];
    return value is num ? value.toInt() : 0;
  }

  Widget section({
    required String title,
    required List<Map<String, dynamic>> items,
    required Widget Function(Map<String, dynamic>) itemBuilder,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: 22),
        Text(
          title,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        SizedBox(height: 8),
        if (items.isEmpty)
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: Text("Nothing to show"),
          )
        else
          ...items.map(itemBuilder),
      ],
    );
  }

  Widget orderTile(Map<String, dynamic> order) {
    final status = order["status"]?.toString() ?? "Unknown";
    final payoutError = order["driverPayoutError"]?.toString();

    return Card(
      margin: EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(child: Icon(Icons.receipt_long)),
        title: Text("${order["storeName"] ?? "Store"} • $status"),
        subtitle: Text(
          [
            "Customer: ${order["customerName"] ?? "Customer"}",
            "Total: \$${((order["total"] ?? 0) as num).toDouble().toStringAsFixed(2)}",
            if (payoutError != null && payoutError.isNotEmpty)
              "Payout issue: $payoutError",
          ].join("\n"),
        ),
        isThreeLine: payoutError != null && payoutError.isNotEmpty,
      ),
    );
  }

  Widget userTile(Map<String, dynamic> user) {
    final email = user["email"]?.toString();
    final phone = user["phone"]?.toString();

    return Card(
      margin: EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(child: Icon(Icons.person)),
        title: Text(
          user["name"]?.toString() ?? user["email"]?.toString() ?? "User",
        ),
        subtitle: Text(
          [
            "Role: ${user["role"] ?? "unknown"}",
            if (user["email"] != null) "Email: ${user["email"]}",
            if (user["phone"] != null) "Phone: ${user["phone"]}",
          ].join("\n"),
        ),
        trailing: contactMenu(email: email, phone: phone),
      ),
    );
  }

  Widget driverTile(Map<String, dynamic> driver) {
    final phone = driver["phone"]?.toString();

    return Card(
      margin: EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(child: Icon(Icons.local_shipping)),
        title: Text(driver["name"]?.toString() ?? "Driver"),
        subtitle: Text(
          [
            "Online: ${driver["isOnline"] == true ? "yes" : "no"}",
            "Busy: ${driver["isBusy"] == true ? "yes" : "no"}",
            "Earnings: \$${((driver["earnings"] ?? 0) as num).toDouble().toStringAsFixed(2)}",
          ].join("\n"),
        ),
        trailing: contactMenu(phone: phone),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final counts = dashboard?["counts"] is Map
        ? Map<String, dynamic>.from(dashboard!["counts"] as Map)
        : <String, dynamic>{};

    return Scaffold(
      appBar: AppBar(
        title: Text("Admin Dashboard"),
        actions: [
          IconButton(
            tooltip: "Refresh",
            onPressed: isLoading ? null : loadDashboard,
            icon: Icon(Icons.refresh),
          ),
        ],
      ),
      body: appScreenFade(
        child: isLoading
            ? Center(child: CircularProgressIndicator())
            : errorText != null
            ? Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(errorText!, textAlign: TextAlign.center),
                ),
              )
            : RefreshIndicator(
                onRefresh: loadDashboard,
                child: ListView(
                  padding: EdgeInsets.all(16),
                  children: [
                    Row(
                      children: [
                        metricCard(
                          "Payout issues",
                          countValue(counts, "payoutIssues"),
                          Colors.red,
                        ),
                        SizedBox(width: 10),
                        metricCard(
                          "Store issues",
                          countValue(counts, "storeIssues"),
                          Colors.orange,
                        ),
                      ],
                    ),
                    SizedBox(height: 10),
                    Row(
                      children: [
                        metricCard(
                          "Recent orders",
                          countValue(counts, "recentOrders"),
                          Colors.blue,
                        ),
                        SizedBox(width: 10),
                        metricCard(
                          "Drivers loaded",
                          countValue(counts, "driversLoaded"),
                          Colors.green,
                        ),
                      ],
                    ),
                    section(
                      title: "Payout Issues",
                      items: adminList("payoutIssues"),
                      itemBuilder: orderTile,
                    ),
                    section(
                      title: "Store Issues",
                      items: adminList("storeIssues"),
                      itemBuilder: orderTile,
                    ),
                    section(
                      title: "Recent Orders",
                      items: adminList("recentOrders"),
                      itemBuilder: orderTile,
                    ),
                    section(
                      title: "Recent Users",
                      items: adminList("users"),
                      itemBuilder: userTile,
                    ),
                    section(
                      title: "Drivers",
                      items: adminList("drivers"),
                      itemBuilder: driverTile,
                    ),
                  ],
                ),
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

        if (isOwnerAdminEmail(user.email)) {
          return AdminDashboardScreen();
        }

        // 🔥 2. ROLE
        if (data['role'] == null) {
          return _buildRoleSelection();
        }

        final role = data['role'];

        // 🔥 3. CUSTOMER NAME
        if (role == "customer") {
          return CameraPermissionGate(
            child: Builder(
              builder: (context) {
                final name = data['name'];

                if (name == null || name.toString().trim().isEmpty) {
                  return CustomerNameScreen();
                }

                return TradeStoreScreen();
              },
            ),
          );
        }

        // 🔥 4. FINAL ROUTING
        if (role == "store") {
          final existingStoreName = data['storeName']?.toString().trim() ?? "";

          if (data['storeOnboardingComplete'] != true &&
              existingStoreName.isEmpty) {
            return StoreOnboardingScreen();
          }

          if (data['storeOnboardingComplete'] == true &&
              data['storeInventoryOnboardingComplete'] != true) {
            return StoreInventoryTagsOnboardingScreen();
          }

          final storeName = data['storeName'] ?? "My Store";
          return StoreDashboardScreen(storeName: storeName);
        } else if (role == "driver") {
          return CameraPermissionGate(
            child: FutureBuilder<DocumentSnapshot>(
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
            ),
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

class CameraPermissionGate extends StatelessWidget {
  final Widget child;

  const CameraPermissionGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<app_permissions.PermissionStatus>(
      future: app_permissions.Permission.camera.status,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        if (snapshot.data!.isGranted) {
          return child;
        }

        return CameraPermissionScreen();
      },
    );
  }
}

class CameraPermissionScreen extends StatefulWidget {
  const CameraPermissionScreen({super.key});

  @override
  State<CameraPermissionScreen> createState() => _CameraPermissionScreenState();
}

class _CameraPermissionScreenState extends State<CameraPermissionScreen> {
  bool isLoading = false;

  Future<void> handleCameraPermission() async {
    setState(() => isLoading = true);

    var status = await app_permissions.Permission.camera.status;

    if (status.isDenied || status.isLimited || status.isRestricted) {
      status = await app_permissions.Permission.camera.request();
    }

    if (!mounted) return;

    if (status.isGranted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => RoleRouter()),
      );
      return;
    }

    if (status.isPermanentlyDenied) {
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text("Camera Required"),
          content: Text(
            "Camera access is turned off. Please enable it in Settings to continue.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () async {
                await app_permissions.openAppSettings();
              },
              child: Text("Open Settings"),
            ),
          ],
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Please allow camera access to continue")),
      );
    }

    if (mounted) {
      setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.photo_camera, size: 80, color: Colors.orange),
            SizedBox(height: 20),
            Text(
              "Enable Camera",
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 10),
            Text(
              "We use camera access for delivery proof, receipts, and order support photos.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            SizedBox(height: 40),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: isLoading ? null : handleCameraPermission,
                child: isLoading
                    ? CircularProgressIndicator(color: Colors.white)
                    : Text("Enable Camera"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class StoreOnboardingScreen extends StatefulWidget {
  const StoreOnboardingScreen({super.key});

  @override
  State<StoreOnboardingScreen> createState() => _StoreOnboardingScreenState();
}

class _StoreOnboardingScreenState extends State<StoreOnboardingScreen> {
  final searchController = TextEditingController();
  final nameController = TextEditingController();
  final addressController = TextEditingController();
  final days = const [
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
    "Sunday",
  ];

  late final List<TextEditingController> hoursControllers;
  List<Map<String, dynamic>> results = [];
  List<Map<String, dynamic>> selectedHoursPeriods = [];
  String? selectedPlaceId;
  double? selectedLatitude;
  double? selectedLongitude;
  int? selectedUtcOffsetMinutes;
  bool isSearching = false;
  bool isSaving = false;

  @override
  void initState() {
    super.initState();
    hoursControllers = List.generate(
      7,
      (_) => TextEditingController(text: "Closed"),
    );
  }

  @override
  void dispose() {
    searchController.dispose();
    nameController.dispose();
    addressController.dispose();
    for (final controller in hoursControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> searchStores() async {
    final query = searchController.text.trim();
    if (query.length < 3 || isSearching) return;

    setState(() {
      isSearching = true;
      results = [];
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      final userDoc = user == null
          ? null
          : await FirebaseFirestore.instance
                .collection('users')
                .doc(user.uid)
                .get();
      final userData = userDoc?.data();

      final callable = FirebaseFunctions.instance.httpsCallable(
        'searchStorePlaces',
      );
      final response = await callable.call({
        "query": query,
        "latitude": userData?['lat'],
        "longitude": userData?['lng'],
      });

      final rawPlaces = (response.data?['places'] as List?) ?? [];
      if (!mounted) return;

      setState(() {
        results = rawPlaces
            .whereType<Map>()
            .map((place) => Map<String, dynamic>.from(place))
            .toList();
      });
    } on FirebaseFunctionsException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.message ?? "Could not search for stores."),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Could not search for stores right now.")),
      );
    } finally {
      if (mounted) {
        setState(() => isSearching = false);
      }
    }
  }

  void selectStore(Map<String, dynamic> place) {
    final placeHours = (place['hours'] as List?) ?? [];

    setState(() {
      selectedPlaceId = place['placeId']?.toString();
      selectedLatitude = (place['latitude'] as num?)?.toDouble();
      selectedLongitude = (place['longitude'] as num?)?.toDouble();
      selectedUtcOffsetMinutes = (place['utcOffsetMinutes'] as num?)?.toInt();
      selectedHoursPeriods = ((place['hoursPeriods'] as List?) ?? [])
          .whereType<Map>()
          .map((period) => Map<String, dynamic>.from(period))
          .toList();
      nameController.text = place['name']?.toString() ?? "";
      addressController.text = place['address']?.toString() ?? "";
      results = [];
    });

    for (var index = 0; index < hoursControllers.length; index++) {
      final description = index < placeHours.length
          ? placeHours[index].toString()
          : "${days[index]}: Closed";
      hoursControllers[index].text = description.contains(":")
          ? description.split(":").skip(1).join(":").trim()
          : description;
    }
  }

  Future<void> useCurrentLocation() async {
    try {
      final position = await requestLocation();
      if (position == null || !mounted) return;

      setState(() {
        selectedPlaceId = null;
        selectedLatitude = position.latitude;
        selectedLongitude = position.longitude;
        selectedUtcOffsetMinutes = null;
        selectedHoursPeriods = [];
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Current location added. Enter the address.")),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Could not get your current location.")),
      );
    }
  }

  Future<void> saveStore() async {
    final user = FirebaseAuth.instance.currentUser;
    final name = nameController.text.trim();
    final address = addressController.text.trim();

    if (user == null || isSaving) return;

    if (name.isEmpty ||
        address.isEmpty ||
        selectedLatitude == null ||
        selectedLongitude == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Add the store name, address, and select a Google result or current location.",
          ),
        ),
      );
      return;
    }

    setState(() => isSaving = true);

    try {
      final hours = <String, String>{};
      for (var index = 0; index < days.length; index++) {
        final value = hoursControllers[index].text.trim();
        hours[days[index]] = value.isEmpty ? "Closed" : value;
      }

      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        "role": "store",
        "storeName": name,
        "address": address,
        "storePlaceId": selectedPlaceId,
        "lat": selectedLatitude,
        "lng": selectedLongitude,
        "storeHours": hours,
        "storeHoursPeriods": selectedHoursPeriods,
        "storeUtcOffsetMinutes": selectedUtcOffsetMinutes,
        "storeOnboardingComplete": true,
        "storeInventoryOnboardingComplete": false,
        "storeOnboardingCompletedAt": FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await PushNotificationService.saveCurrentToken(user.uid);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Could not save the store. Please try again.")),
      );
    } finally {
      if (mounted) {
        setState(() => isSaving = false);
      }
    }
  }

  InputDecoration fieldDecoration({
    required String label,
    IconData? icon,
    String? hint,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: icon == null ? null : Icon(icon),
      filled: true,
      fillColor: Colors.grey.shade50,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: Colors.green.shade700, width: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Set Up Your Store"),
        centerTitle: true,
        automaticallyImplyLeading: false,
      ),
      body: appScreenFade(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Row(
                  children: List.generate(
                    3,
                    (index) => Expanded(
                      child: Container(
                        height: 5,
                        margin: EdgeInsets.only(right: index == 2 ? 0 : 8),
                        decoration: BoxDecoration(
                          color: Colors.green.shade700,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(16, 6, 16, 24),
                  children: [
                    Text(
                      "Find your business",
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      "Search Google to fill in your store details, then review them before continuing.",
                      style: TextStyle(
                        color: Colors.grey.shade700,
                        height: 1.35,
                      ),
                    ),
                    SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: searchController,
                            textInputAction: TextInputAction.search,
                            onSubmitted: (_) => searchStores(),
                            decoration: fieldDecoration(
                              label: "Search store",
                              icon: Icons.search,
                              hint: "Store name and city",
                            ),
                          ),
                        ),
                        SizedBox(width: 10),
                        SizedBox(
                          width: 52,
                          height: 56,
                          child: IconButton.filled(
                            tooltip: "Search Google",
                            onPressed: isSearching ? null : searchStores,
                            icon: isSearching
                                ? SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Icon(Icons.arrow_forward),
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.green.shade700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (results.isNotEmpty) ...[
                      SizedBox(height: 10),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: Column(
                          children: List.generate(results.length, (index) {
                            final place = results[index];
                            return Column(
                              children: [
                                ListTile(
                                  leading: Icon(
                                    Icons.store,
                                    color: Colors.green.shade700,
                                  ),
                                  title: Text(
                                    place['name']?.toString() ?? "Store",
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Text(
                                    place['address']?.toString() ?? "",
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: Icon(Icons.chevron_right),
                                  onTap: () => selectStore(place),
                                ),
                                if (index < results.length - 1)
                                  Divider(height: 1),
                              ],
                            );
                          }),
                        ),
                      ),
                    ],
                    SizedBox(height: 18),
                    TextField(
                      controller: nameController,
                      textCapitalization: TextCapitalization.words,
                      decoration: fieldDecoration(
                        label: "Store name",
                        icon: Icons.storefront,
                      ),
                    ),
                    SizedBox(height: 12),
                    TextField(
                      controller: addressController,
                      minLines: 1,
                      maxLines: 2,
                      textCapitalization: TextCapitalization.words,
                      decoration: fieldDecoration(
                        label: "Store address",
                        icon: Icons.location_on,
                      ),
                    ),
                    SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: useCurrentLocation,
                        icon: Icon(Icons.my_location),
                        label: Text("Use current location"),
                      ),
                    ),
                    SizedBox(height: 14),
                    Text(
                      "Hours of operation",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 10),
                    ...List.generate(
                      days.length,
                      (index) => Padding(
                        padding: EdgeInsets.only(bottom: 10),
                        child: TextField(
                          controller: hoursControllers[index],
                          onChanged: (_) {
                            selectedHoursPeriods = [];
                          },
                          decoration: fieldDecoration(
                            label: days[index],
                            hint: "9:00 AM - 5:00 PM or Closed",
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: 8),
                    SizedBox(
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed: isSaving ? null : saveStore,
                        icon: isSaving
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Icon(Icons.check_circle),
                        label: Text(
                          isSaving ? "Saving Store..." : "Finish Store Setup",
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green.shade700,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String storeInventoryItemKey(Map<String, dynamic> item) {
  final raw = "${item['trade']}|${item['name']}";
  return base64Url.encode(utf8.encode(raw));
}

List<Map<String, dynamic>> storeInventoryCatalog() {
  final plumbingParts = plumbingCatalogParts.map((item) {
    return {
      "trade": "Plumbing",
      "name": item["name"] ?? "Part",
      "image": item["image"],
      "categories": item["categories"] ?? [],
    };
  });

  final hvacParts = hvacCatalogParts.map((item) {
    return {
      "trade": "HVAC",
      "name": item["name"] ?? "Part",
      "image": item["image"],
      "categories": item["categories"] ?? [],
    };
  });

  final seen = <String>{};
  final combined = [...plumbingParts, ...hvacParts].where((item) {
    final key = storeInventoryItemKey(item);
    if (!seen.add(key)) return false;
    return true;
  }).toList();

  combined.sort((a, b) {
    final tradeCompare = a['trade'].toString().compareTo(b['trade'].toString());
    if (tradeCompare != 0) return tradeCompare;
    return a['name'].toString().compareTo(b['name'].toString());
  });

  return combined;
}

class StoreInventoryTagsOnboardingScreen extends StatefulWidget {
  const StoreInventoryTagsOnboardingScreen({super.key});

  @override
  State<StoreInventoryTagsOnboardingScreen> createState() =>
      _StoreInventoryTagsOnboardingScreenState();
}

class _StoreInventoryTagsOnboardingScreenState
    extends State<StoreInventoryTagsOnboardingScreen> {
  final selectedTags = <String>{};
  final searchController = TextEditingController();
  String searchText = "";
  bool isSaving = false;

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  Map<String, Map<String, int>> groupedTags(List<Map<String, dynamic>> parts) {
    final grouped = <String, Map<String, int>>{};

    for (final item in parts) {
      final trade = item['trade'].toString();
      final categories = (item['categories'] as List?) ?? [];
      final tradeTags = grouped.putIfAbsent(trade, () => {});

      for (final category in categories) {
        final tag = category.toString().trim();
        if (tag.isEmpty) continue;
        tradeTags[tag] = (tradeTags[tag] ?? 0) + 1;
      }
    }

    for (final tags in grouped.values) {
      final sorted = tags.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      tags
        ..clear()
        ..addEntries(sorted);
    }

    return grouped;
  }

  String tagKey(String trade, String tag) => "$trade|$tag";

  bool itemMatchesSelectedTag(Map<String, dynamic> item) {
    final trade = item['trade'].toString();
    final categories = (item['categories'] as List?) ?? [];

    return categories.any((category) {
      final tag = category.toString().trim();
      return selectedTags.contains(tagKey(trade, tag));
    });
  }

  Future<void> saveInventoryTags(List<Map<String, dynamic>> parts) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || isSaving) return;

    if (selectedTags.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Select at least one parts group.")),
      );
      return;
    }

    setState(() => isSaving = true);

    try {
      final inventory = <String, dynamic>{};

      for (final item in parts) {
        inventory[storeInventoryItemKey(item)] = {
          "carries": itemMatchesSelectedTag(item),
          "name": item['name'],
          "trade": item['trade'],
          "image": item['image'],
          "updatedAt": DateTime.now().toIso8601String(),
        };
      }

      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        "storeInventory": inventory,
        "storeInventoryTags": selectedTags.toList()..sort(),
        "storeInventoryOnboardingComplete": true,
        "storeInventoryOnboardingCompletedAt": FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Could not save inventory groups.")),
      );
    } finally {
      if (mounted) {
        setState(() => isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final parts = storeInventoryCatalog();
    final groups = groupedTags(parts);
    final query = searchText.trim().toLowerCase();
    final selectedPartCount = parts.where(itemMatchesSelectedTag).length;

    return Scaffold(
      appBar: AppBar(
        title: Text("Choose Parts Groups"),
        centerTitle: true,
        automaticallyImplyLeading: false,
      ),
      body: appScreenFade(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Row(
                  children: List.generate(
                    3,
                    (index) => Expanded(
                      child: Container(
                        height: 5,
                        margin: EdgeInsets.only(right: index == 2 ? 0 : 8),
                        decoration: BoxDecoration(
                          color: index < 2
                              ? Colors.green.shade700
                              : Colors.orange,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "What parts does your store carry?",
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      "Select groups. Every matching part will be checked in your inventory automatically.",
                      style: TextStyle(
                        color: Colors.grey.shade700,
                        height: 1.35,
                      ),
                    ),
                    SizedBox(height: 14),
                    TextField(
                      controller: searchController,
                      onChanged: (value) => setState(() => searchText = value),
                      decoration: InputDecoration(
                        hintText: "Search parts groups",
                        prefixIcon: Icon(Icons.search),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    SizedBox(height: 10),
                    Text(
                      "${selectedTags.length} groups selected • $selectedPartCount parts checked",
                      style: TextStyle(
                        color: Colors.green.shade800,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(12, 0, 12, 12),
                  children: groups.entries.map((tradeEntry) {
                    final visibleTags = tradeEntry.value.entries.where((entry) {
                      return query.isEmpty ||
                          entry.key.toLowerCase().contains(query) ||
                          tradeEntry.key.toLowerCase().contains(query);
                    }).toList();

                    if (visibleTags.isEmpty) return SizedBox.shrink();

                    return Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade200),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: EdgeInsets.fromLTRB(14, 13, 14, 8),
                              child: Text(
                                tradeEntry.key,
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            ...visibleTags.map((entry) {
                              final key = tagKey(tradeEntry.key, entry.key);
                              final selected = selectedTags.contains(key);

                              return CheckboxListTile(
                                value: selected,
                                activeColor: Colors.green.shade700,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title: Text(
                                  entry.key,
                                  style: TextStyle(fontWeight: FontWeight.w600),
                                ),
                                subtitle: Text(
                                  "${entry.value} matching ${entry.value == 1 ? 'part' : 'parts'}",
                                ),
                                onChanged: (value) {
                                  setState(() {
                                    if (value == true) {
                                      selectedTags.add(key);
                                    } else {
                                      selectedTags.remove(key);
                                    }
                                  });
                                },
                              );
                            }),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(16, 10, 16, 16),
                child: SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: isSaving ? null : () => saveInventoryTags(parts),
                    icon: isSaving
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(Icons.checklist),
                    label: Text(
                      isSaving ? "Building Inventory..." : "Finish Inventory",
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade700,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
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

class StoreDashboardScreen extends StatefulWidget {
  final String storeName;

  const StoreDashboardScreen({required this.storeName});

  @override
  State<StoreDashboardScreen> createState() => _StoreDashboardScreenState();
}

class _StoreDashboardScreenState extends State<StoreDashboardScreen> {
  Timer? storeHoursTimer;

  @override
  void initState() {
    super.initState();
    storeHoursTimer = Timer.periodic(Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    storeHoursTimer?.cancel();
    super.dispose();
  }

  bool isStoreOpen(Map<String, dynamic>? data) {
    if (data == null) return true;

    final offset = (data['storeUtcOffsetMinutes'] as num?)?.toInt();
    final now = offset == null
        ? DateTime.now()
        : DateTime.now().toUtc().add(Duration(minutes: offset));
    final periods = (data['storeHoursPeriods'] as List?) ?? [];

    if (periods.isNotEmpty) {
      final currentDay = now.weekday % 7;
      final currentWeekMinute = currentDay * 1440 + now.hour * 60 + now.minute;
      const weekMinutes = 7 * 1440;

      for (final rawPeriod in periods) {
        if (rawPeriod is! Map) continue;

        final period = Map<String, dynamic>.from(rawPeriod);
        final open = period['open'];
        final close = period['close'];
        if (open is! Map) continue;

        final openDay = (open['day'] as num?)?.toInt();
        final openHour = (open['hour'] as num?)?.toInt() ?? 0;
        final openMinute = (open['minute'] as num?)?.toInt() ?? 0;
        if (openDay == null) continue;

        if (close is! Map) return true;

        final closeDay = (close['day'] as num?)?.toInt();
        final closeHour = (close['hour'] as num?)?.toInt() ?? 0;
        final closeMinute = (close['minute'] as num?)?.toInt() ?? 0;
        if (closeDay == null) continue;

        final openWeekMinute = openDay * 1440 + openHour * 60 + openMinute;
        var closeWeekMinute = closeDay * 1440 + closeHour * 60 + closeMinute;

        if (closeWeekMinute <= openWeekMinute) {
          closeWeekMinute += weekMinutes;
        }

        if ((currentWeekMinute >= openWeekMinute &&
                currentWeekMinute < closeWeekMinute) ||
            (currentWeekMinute + weekMinutes >= openWeekMinute &&
                currentWeekMinute + weekMinutes < closeWeekMinute)) {
          return true;
        }
      }

      return false;
    }

    final hours = data['storeHours'];
    if (hours is! Map || hours.isEmpty) return true;

    const dayNames = [
      "Monday",
      "Tuesday",
      "Wednesday",
      "Thursday",
      "Friday",
      "Saturday",
      "Sunday",
    ];
    final today = dayNames[now.weekday - 1];
    final schedule = hours[today]?.toString().trim() ?? "";

    return isTimeWithinSchedule(schedule, now);
  }

  bool isTimeWithinSchedule(String schedule, DateTime now) {
    if (schedule.isEmpty) return true;

    final normalized = schedule
        .replaceAll("–", "-")
        .replaceAll("—", "-")
        .replaceAll(" ", " ")
        .replaceAll(" ", " ")
        .trim();
    final lower = normalized.toLowerCase();

    if (lower == "closed") return false;
    if (lower.contains("open 24 hours") || lower == "24 hours") return true;

    final parts = normalized.split(RegExp(r'\s+-\s+'));
    if (parts.length != 2) return false;

    final openMinutes = parseClockMinutes(parts[0]);
    final closeMinutes = parseClockMinutes(parts[1]);
    if (openMinutes == null || closeMinutes == null) return false;

    final currentMinutes = now.hour * 60 + now.minute;

    if (closeMinutes > openMinutes) {
      return currentMinutes >= openMinutes && currentMinutes < closeMinutes;
    }

    return currentMinutes >= openMinutes || currentMinutes < closeMinutes;
  }

  int? parseClockMinutes(String value) {
    final match = RegExp(
      r'^(\d{1,2})(?::(\d{2}))?\s*([AaPp][Mm])$',
    ).firstMatch(value.trim());
    if (match == null) return null;

    var hour = int.parse(match.group(1)!);
    final minute = int.tryParse(match.group(2) ?? "0") ?? 0;
    final period = match.group(3)!.toUpperCase();

    if (hour == 12) hour = 0;
    if (period == "PM") hour += 12;

    return hour * 60 + minute;
  }

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
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Container(
              height: MediaQuery.paddingOf(context).top + kToolbarHeight,
              padding: EdgeInsets.fromLTRB(
                20,
                MediaQuery.paddingOf(context).top,
                16,
                0,
              ),
              color: Colors.green.shade700,
              alignment: Alignment.centerLeft,
              child: Text(
                "Store Menu",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ListTile(
              leading: Icon(Icons.edit),
              title: Text("Update Store Name"),
              onTap: () {
                Navigator.pop(context);
                updateStoreName();
              },
            ),
            Divider(height: 1, color: Colors.grey.shade300),
            ListTile(
              leading: Icon(Icons.location_on),
              title: Text("Update Store Location"),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => AddressSearchScreen()),
                );
              },
            ),
          ],
        ),
      ),
      appBar: AppBar(
        title: StreamBuilder<DocumentSnapshot>(
          stream: user == null
              ? null
              : FirebaseFirestore.instance
                    .collection('users')
                    .doc(user.uid)
                    .snapshots(),
          builder: (context, snapshot) {
            final data = snapshot.data?.data() as Map<String, dynamic>?;
            final isOpen = isStoreOpen(data);

            return AnimatedSwitcher(
              duration: Duration(milliseconds: 350),
              child: SizedBox(
                key: ValueKey(isOpen),
                width: isOpen ? 132 : 148,
                height: 48,
                child: Image.asset(
                  isOpen
                      ? "assets/images/neon_open_sign_hd.png"
                      : "assets/images/neon_closed_sign_hd.png",
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                ),
              ),
            );
          },
        ),
        centerTitle: true,
        leading: Builder(
          builder: (context) => IconButton(
            tooltip: "Store menu",
            icon: Icon(Icons.store),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
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
      body: appScreenFade(
        child: StreamBuilder<DocumentSnapshot>(
          stream: user == null
              ? null
              : FirebaseFirestore.instance
                    .collection('users')
                    .doc(user.uid)
                    .snapshots(),
          builder: (context, snapshot) {
            final data = snapshot.data?.data() as Map<String, dynamic>?;
            final storeName = data?['storeName'] ?? widget.storeName;

            return Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                children: [
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: Colors.green.shade700,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      storeName,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  SizedBox(height: 16),
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Colors.orange.shade300,
                          width: 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.05),
                            blurRadius: 8,
                            offset: Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: EdgeInsets.fromLTRB(16, 15, 16, 13),
                            child: Row(
                              children: [
                                Container(
                                  width: 42,
                                  height: 42,
                                  decoration: BoxDecoration(
                                    color: Colors.orange.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(9),
                                  ),
                                  child: Icon(
                                    Icons.inventory_2,
                                    color: Colors.orange.shade800,
                                    size: 23,
                                  ),
                                ),
                                SizedBox(width: 12),
                                Text(
                                  "Incoming Orders",
                                  style: TextStyle(
                                    fontSize: 21,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Divider(height: 1, color: Colors.grey.shade200),
                          Expanded(
                            child: user == null
                                ? Center(child: Text("Log in to view orders"))
                                : StreamBuilder<QuerySnapshot>(
                                    stream: FirebaseFirestore.instance
                                        .collection('orders')
                                        .where('storeId', isEqualTo: user.uid)
                                        .where('status', isEqualTo: 'Pending')
                                        .snapshots(),
                                    builder: (context, orderSnapshot) {
                                      if (orderSnapshot.hasError) {
                                        return Center(
                                          child: Padding(
                                            padding: EdgeInsets.all(20),
                                            child: Text(
                                              "Could not load incoming orders.",
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                color: Colors.grey.shade700,
                                              ),
                                            ),
                                          ),
                                        );
                                      }

                                      if (!orderSnapshot.hasData) {
                                        return Center(
                                          child: CircularProgressIndicator(),
                                        );
                                      }

                                      final orders = orderSnapshot.data!.docs;

                                      if (orders.isEmpty) {
                                        return Center(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.inbox_outlined,
                                                size: 38,
                                                color: Colors.grey.shade400,
                                              ),
                                              SizedBox(height: 8),
                                              Text(
                                                "No incoming orders",
                                                style: TextStyle(
                                                  color: Colors.grey.shade600,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      }

                                      return Scrollbar(
                                        child: ListView.builder(
                                          padding: EdgeInsets.symmetric(
                                            vertical: 6,
                                          ),
                                          itemCount: orders.length,
                                          itemBuilder: (context, index) {
                                            final order =
                                                orders[index].data()
                                                    as Map<String, dynamic>;

                                            return _realOrderCard(
                                              order,
                                              orders[index].id,
                                              context,
                                            );
                                          },
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class StoreInventoryScreen extends StatefulWidget {
  @override
  State<StoreInventoryScreen> createState() => _StoreInventoryScreenState();
}

class _StoreInventoryScreenState extends State<StoreInventoryScreen> {
  final ScrollController _partsScrollController = ScrollController();
  String selectedTrade = "All";
  String selectedCategory = "All";
  String searchText = "";
  bool isSaving = false;

  final List<String> trades = ["All", "Plumbing", "HVAC"];

  String inventoryKey(Map<String, dynamic> item) {
    return storeInventoryItemKey(item);
  }

  List<Map<String, dynamic>> inventoryParts() {
    return storeInventoryCatalog();
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
  void dispose() {
    _partsScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final allParts = inventoryParts();

    return Scaffold(
      appBar: AppBar(title: Text("Inventory"), centerTitle: true),
      body: appScreenFade(
        child: user == null
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
                                            selectedColor:
                                                Colors.green.shade700,
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
                        child: PartsScrollRail(
                          controller: _partsScrollController,
                          child: ListView.separated(
                            controller: _partsScrollController,
                            padding: EdgeInsets.fromLTRB(12, 12, 34, 12),
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
                                      child: partImage(
                                        item['image'] as String?,
                                      ),
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
                                        color: carries
                                            ? Colors.green
                                            : Colors.grey,
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
                                        color: markedNo
                                            ? Colors.red
                                            : Colors.grey,
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
                      ),
                    ],
                  );
                },
              ),
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

class _DeliveryPinDialog extends StatefulWidget {
  @override
  State<_DeliveryPinDialog> createState() => _DeliveryPinDialogState();
}

class _DeliveryPinDialogState extends State<_DeliveryPinDialog> {
  final TextEditingController controller = TextEditingController();
  String? errorText;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void submitPin() {
    final pin = controller.text.trim();

    if (RegExp(r'^\d{4}$').hasMatch(pin)) {
      FocusScope.of(context).unfocus();
      Navigator.of(context).pop(pin);
      return;
    }

    setState(() {
      errorText = "Enter the 4-digit PIN.";
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text("Enter Delivery PIN"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Ask the customer for their 4-digit delivery PIN."),
          SizedBox(height: 14),
          TextField(
            controller: controller,
            autofocus: true,
            maxLength: 4,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(4),
            ],
            onChanged: (_) {
              if (errorText != null) {
                setState(() {
                  errorText = null;
                });
              }
            },
            onSubmitted: (_) => submitPin(),
            decoration: InputDecoration(
              labelText: "Delivery PIN",
              border: OutlineInputBorder(),
              counterText: "",
              errorText: errorText,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            FocusScope.of(context).unfocus();
            Navigator.of(context).pop(null);
          },
          child: Text("Cancel"),
        ),
        ElevatedButton(onPressed: submitPin, child: Text("Confirm")),
      ],
    );
  }
}

class DriverScreen extends StatefulWidget {
  @override
  State<DriverScreen> createState() => _DriverScreenState();
}

class _DriverScreenState extends State<DriverScreen> {
  StreamSubscription<Position>? positionStream;
  StreamSubscription<QuerySnapshot>? assignedOrderStatusStream;

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
  final Set<String> completedDriverOrderIds = {};
  int driverMapClearVersion = 0;

  DateTime? lastRouteUpdate;
  LatLng? lastRoutePosition;

  DateTime? lastFirestoreUpdate;
  DateTime? lastCameraMove;

  String? distanceText;
  String? eta;
  final Set<String> handledCancelledOrderIds = {};
  final List<Map<String, dynamic>> driverUpdates = [];
  int unreadDriverUpdates = 0;

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

  Future<Map<String, dynamic>?> fetchDirectionsRoute({
    required LatLng origin,
    required LatLng destination,
  }) async {
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'getDirectionsRoute',
      );
      final result = await callable.call({
        "originLat": origin.latitude,
        "originLng": origin.longitude,
        "destinationLat": destination.latitude,
        "destinationLng": destination.longitude,
      });

      return Map<String, dynamic>.from(result.data as Map);
    } on FirebaseFunctionsException catch (error) {
      print("❌ ROUTE ERROR: ${error.code} ${error.message ?? ''}");
      return null;
    } catch (error) {
      print("❌ ROUTE ERROR: $error");
      return null;
    }
  }

  Future<void> getRoute() async {
    if (isFetchingRoute) return; // 👈 prevent overlap

    isFetchingRoute = true;
    final routeVersion = driverMapClearVersion;
    final targetStoreLat = currentStoreLat;
    final targetStoreLng = currentStoreLng;

    try {
      if (targetStoreLat == null || targetStoreLng == null) return;

      final route = await fetchDirectionsRoute(
        origin: currentPosition,
        destination: LatLng(targetStoreLat, targetStoreLng),
      );

      if (route == null) {
        return;
      }

      final distance = route['distanceText']?.toString() ?? "";
      final duration = route['durationText']?.toString() ?? "";
      final points = route['polyline']?.toString() ?? "";
      final decoded = decodePolyline(points);

      if (!mounted) return;
      if (routeVersion != driverMapClearVersion) return;
      if (currentStoreLat != targetStoreLat ||
          currentStoreLng != targetStoreLng) {
        return;
      }

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

    try {
      final routeToStore = await fetchDirectionsRoute(
        origin: currentPosition,
        destination: LatLng(previewStoreLat!, previewStoreLng!),
      );
      final routeToCustomer = await fetchDirectionsRoute(
        origin: LatLng(previewStoreLat!, previewStoreLng!),
        destination: LatLng(previewCustomerLat!, previewCustomerLng!),
      );

      if (routeToStore == null || routeToCustomer == null) {
        return;
      }

      final distance1 = (routeToStore['distanceMeters'] as num?)?.toInt() ?? 0;
      final distance2 =
          (routeToCustomer['distanceMeters'] as num?)?.toInt() ?? 0;

      final duration1 = (routeToStore['durationSeconds'] as num?)?.toInt() ?? 0;
      final duration2 =
          (routeToCustomer['durationSeconds'] as num?)?.toInt() ?? 0;

      final totalDistanceMeters = distance1 + distance2;
      final totalDurationSeconds = duration1 + duration2;

      final distanceMiles = (totalDistanceMeters / 1609).toStringAsFixed(1);

      final durationMinutes = (totalDurationSeconds / 60).round();

      final points1 = routeToStore['polyline']?.toString() ?? "";
      final points2 = routeToCustomer['polyline']?.toString() ?? "";

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

    loadInitialDriverLocation();
    loadDriverStatus();
    listenForDriverOrderCancellations();
    startTracking();
  }

  void listenForDriverOrderCancellations() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    assignedOrderStatusStream = FirebaseFirestore.instance
        .collection('orders')
        .where("driverId", isEqualTo: user.uid)
        .where("status", isEqualTo: "Customer Cancelled")
        .snapshots()
        .listen((snapshot) {
          for (final change in snapshot.docChanges) {
            if (change.type == DocumentChangeType.removed) continue;

            final orderId = change.doc.id;
            if (handledCancelledOrderIds.contains(orderId)) continue;

            final isCurrentDriverOrder =
                isOnActiveDelivery ||
                isPreviewingOrder ||
                previewOrderId == orderId ||
                currentStoreLat != null ||
                currentStoreLng != null;

            if (!isCurrentDriverOrder) continue;

            handledCancelledOrderIds.add(orderId);
            handleDriverOrderCancelled(orderId: orderId);
          }
        });
  }

  void handleDriverOrderCancelled({String? orderId}) {
    if (!mounted) return;

    setState(() {
      if (orderId != null) {
        completedDriverOrderIds.add(orderId);
      }

      addDriverUpdate(
        title: "Order cancelled",
        message: "The customer cancelled the order.",
        icon: Icons.cancel,
        color: Colors.red,
      );

      clearDriverOrderMapState();
      isUpdatingStatus = false;
    });

    locationTimer?.cancel();

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: Duration(seconds: 4),
          backgroundColor: Colors.grey.shade800,
          content: Text(
            "Order cancelled by customer.",
            style: TextStyle(color: Colors.white),
          ),
        ),
      );
  }

  void clearDriverOrderMapState() {
    driverMapClearVersion++;
    previewOrderId = null;
    previewStoreLat = null;
    previewStoreLng = null;
    previewCustomerLat = null;
    previewCustomerLng = null;
    previewDistance = null;
    previewDuration = null;

    currentStoreLat = null;
    currentStoreLng = null;

    isPreviewingOrder = false;
    isOnActiveDelivery = false;
    isPickedUp = false;
    routeLoaded = false;
    isFetchingRoute = false;

    storeRoutePoints = [];
    customerRoutePoints = [];
    polylines = {};
    customerRouteOpacity = 1.0;
    distanceText = null;
    eta = null;
  }

  void addDriverUpdate({
    required String title,
    required String message,
    required IconData icon,
    required Color color,
  }) {
    driverUpdates.insert(0, {
      "title": title,
      "message": message,
      "icon": icon,
      "color": color,
      "createdAt": DateTime.now(),
    });

    unreadDriverUpdates += 1;
  }

  void openDriverUpdates() {
    setState(() {
      unreadDriverUpdates = 0;
    });

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Driver Updates",
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 12),
                if (driverUpdates.isEmpty)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        "No updates yet",
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.45,
                    ),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: driverUpdates.length,
                      separatorBuilder: (context, index) => Divider(height: 1),
                      itemBuilder: (context, index) {
                        final update = driverUpdates[index];
                        final createdAt = update["createdAt"] as DateTime;

                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            backgroundColor: (update["color"] as Color)
                                .withOpacity(0.12),
                            child: Icon(
                              update["icon"] as IconData,
                              color: update["color"] as Color,
                            ),
                          ),
                          title: Text(
                            update["title"] as String,
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(update["message"] as String),
                          trailing: Text(
                            "${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}",
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 12,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget driverNotificationBell() {
    return Padding(
      padding: EdgeInsets.only(right: 8),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          IconButton(
            tooltip: "Driver updates",
            icon: Icon(Icons.notifications_outlined),
            onPressed: openDriverUpdates,
          ),
          if (unreadDriverUpdates > 0)
            Positioned(
              right: 7,
              top: 7,
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                constraints: BoxConstraints(minWidth: 18),
                child: Text(
                  unreadDriverUpdates > 9 ? "9+" : "$unreadDriverUpdates",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> loadInitialDriverLocation() async {
    final position = await requestLocation();
    if (position == null || !mounted) return;

    final driverPosition = LatLng(position.latitude, position.longitude);

    setState(() {
      currentPosition = driverPosition;
    });

    mapController?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: driverPosition, zoom: 16),
      ),
    );
  }

  Future<void> resetDriverBusyIfNoActiveOrder() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) return;

    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'syncDriverAvailability',
      );
      final result = await callable.call();
      final data = Map<String, dynamic>.from(result.data as Map);

      if (data["isBusy"] == true) {
        print("🚗 Active order found — Driver remains busy");
      } else {
        print("✅ No active orders — Driver marked available");
      }
    } on FirebaseFunctionsException catch (error) {
      print("❌ DRIVER AVAILABILITY SYNC ERROR: ${error.message}");
    } catch (error) {
      print("❌ DRIVER AVAILABILITY SYNC ERROR: $error");
    }
  }

  @override
  void dispose() {
    positionStream?.cancel();
    assignedOrderStatusStream?.cancel();
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
    final savedLat = (data?["lat"] as num?)?.toDouble();
    final savedLng = (data?["lng"] as num?)?.toDouble();
    final hasCurrentLocation =
        currentPosition.latitude != 0 || currentPosition.longitude != 0;
    final hasSavedLocation =
        savedLat != null &&
        savedLng != null &&
        savedLat.isFinite &&
        savedLng.isFinite &&
        (savedLat != 0 || savedLng != 0);

    setState(() {
      isOnline = data?["active"] ?? false;

      if (!hasCurrentLocation && hasSavedLocation) {
        currentPosition = LatLng(savedLat, savedLng);
      }
    });

    if (isOnline) {
      await refreshDriverAvailableOrders();
    }
  }

  Future<void> refreshDriverAvailableOrders() async {
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'refreshDriverAvailableOrders',
      );
      await callable.call();
    } catch (error) {
      debugPrint("Could not refresh driver delivery requests: $error");
    }
  }

  Future<void> updateOnlineStatus(bool value) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (isUpdatingStatus) return;

    setState(() {
      isUpdatingStatus = true;
    });

    try {
      if (value) {
        final payoutsReady = await ensureDriverPayoutsReady();
        if (!payoutsReady) return;
      }

      final callable = FirebaseFunctions.instance.httpsCallable(
        'updateDriverOnlineStatus',
      );
      await callable.call({"active": value});

      if (value) {
        await refreshDriverAvailableOrders();
      }

      if (!mounted) return;

      setState(() {
        isOnline = value;

        if (!isOnline) {
          previewOrderId = null;
          isPreviewingOrder = false;
        }
      });
    } on FirebaseFunctionsException catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            duration: Duration(seconds: 4),
            backgroundColor: Colors.grey.shade800,
            content: Text(
              error.message ?? "Could not update driver status.",
              style: TextStyle(color: Colors.white),
            ),
          ),
        );
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            duration: Duration(seconds: 4),
            backgroundColor: Colors.grey.shade800,
            content: Text(
              "Could not update driver status. Please try again.",
              style: TextStyle(color: Colors.white),
            ),
          ),
        );
    } finally {
      if (mounted) {
        setState(() {
          isUpdatingStatus = false;
        });
      }
    }
  }

  Future<bool> ensureDriverPayoutsReady() async {
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'getDriverPayoutStatus',
      );
      final result = await callable.call();
      final data = Map<String, dynamic>.from(result.data as Map);
      final ready = data["ready"] == true;

      if (ready) return true;

      if (!mounted) return false;

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            duration: Duration(seconds: 6),
            backgroundColor: Colors.grey.shade800,
            content: Text(
              "Set up Stripe payouts before going online.",
              style: TextStyle(color: Colors.white),
            ),
            action: SnackBarAction(
              label: "SET UP",
              textColor: Colors.orange.shade200,
              onPressed: openDriverPayoutSetup,
            ),
          ),
        );

      return false;
    } catch (error) {
      if (!mounted) return false;

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            duration: Duration(seconds: 4),
            backgroundColor: Colors.grey.shade800,
            content: Text(
              "Could not check payout setup. Please try again.",
              style: TextStyle(color: Colors.white),
            ),
          ),
        );

      return false;
    }
  }

  Future<void> openDriverPayoutSetup() async {
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'createDriverDashboardLink',
      );

      final result = await callable.call();
      final url = result.data['url'];

      if (url == null) {
        throw Exception("No Stripe link returned");
      }

      final uri = Uri.parse(url);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text("Could not open Stripe payout setup")),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
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
              onChanged: isUpdatingStatus ? null : updateOnlineStatus,
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

        actions: [driverNotificationBell()],
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Container(
              height: MediaQuery.paddingOf(context).top + kToolbarHeight,
              padding: EdgeInsets.fromLTRB(
                20,
                MediaQuery.paddingOf(context).top,
                16,
                0,
              ),
              color: Colors.orange,
              alignment: Alignment.centerLeft,
              child: Text(
                "Driver Menu",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
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
            .where("status", whereIn: ["Accepted", "Picked Up", "Store Issue"])
            .snapshots(),
        builder: (context, activeSnapshot) {
          if (!activeSnapshot.hasData) {
            return Column(
              children: [
                Container(
                  height: 1,
                  width: double.infinity,
                  color: Colors.grey.shade300,
                ),
                Expanded(child: _buildDriverMap()),
              ],
            );
          }

          final activeOrders = (activeSnapshot.data?.docs ?? [])
              .where((doc) => !completedDriverOrderIds.contains(doc.id))
              .toList();

          final hasActiveOrder = activeOrders.isNotEmpty;
          final hasDriverLocation =
              currentPosition.latitude != 0 || currentPosition.longitude != 0;

          return Column(
            children: [
              Container(
                height: 1,
                width: double.infinity,
                color: Colors.grey.shade300,
              ),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.42,
                ),
                child: ClipRect(
                  child: AnimatedSize(
                    duration: Duration(milliseconds: 450),
                    curve: Curves.easeInOutCubic,
                    alignment: Alignment.topCenter,
                    child: AnimatedSwitcher(
                      duration: Duration(milliseconds: 400),
                      reverseDuration: Duration(milliseconds: 300),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      layoutBuilder: (currentChild, previousChildren) {
                        return Stack(
                          alignment: Alignment.topCenter,
                          children: [
                            ...previousChildren,
                            if (currentChild != null) currentChild,
                          ],
                        );
                      },
                      transitionBuilder: (child, animation) {
                        final curvedAnimation = CurvedAnimation(
                          parent: animation,
                          curve: Curves.easeOutCubic,
                          reverseCurve: Curves.easeInCubic,
                        );

                        return FadeTransition(
                          opacity: curvedAnimation,
                          child: SlideTransition(
                            position: Tween<Offset>(
                              begin: Offset(0, 0.06),
                              end: Offset.zero,
                            ).animate(curvedAnimation),
                            child: child,
                          ),
                        );
                      },
                      child: hasActiveOrder
                          ? Builder(
                              key: ValueKey(
                                "active-delivery-${activeOrders.first.id}",
                              ),
                              builder: (context) {
                                final orderDoc = activeOrders.first;
                                final order =
                                    orderDoc.data() as Map<String, dynamic>;
                                final storeLat = (order['storeLat'] as num?)
                                    ?.toDouble();
                                final storeLng = (order['storeLng'] as num?)
                                    ?.toDouble();

                                if (storeLat != null && storeLng != null) {
                                  final storeChanged =
                                      currentStoreLat != storeLat ||
                                      currentStoreLng != storeLng;

                                  currentStoreLat = storeLat;
                                  currentStoreLng = storeLng;

                                  if ((storeChanged ||
                                          storeRoutePoints.isEmpty) &&
                                      !isFetchingRoute) {
                                    WidgetsBinding.instance
                                        .addPostFrameCallback((_) {
                                          if (mounted) {
                                            getRoute();
                                          }
                                        });
                                  }
                                }

                                final status = order['status'];
                                final isWaitingForCustomer =
                                    status == "Store Issue";
                                final hasPickupProof =
                                    (order['pickupProofPhotoUrl'] ?? "")
                                        .toString()
                                        .isNotEmpty;

                                final customerName =
                                    order['customerName'] ?? "Customer";
                                final storeName = order['storeName'] ?? "Store";
                                final tradeType = order['tradeType'] ?? "Trade";
                                final items = order['items'] as List? ?? [];
                                final total = ((order['total'] ?? 0) as num)
                                    .toDouble();

                                int totalQuantity = 0;

                                for (var item in items) {
                                  totalQuantity +=
                                      (item['quantity'] ?? 1) as int;
                                }

                                void openActiveOrderDetails() {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => DriverOrderDetailsScreen(
                                        order: order,
                                        orderId: orderDoc.id,
                                      ),
                                    ),
                                  );
                                }

                                return GestureDetector(
                                  onTap: openActiveOrderDetails,
                                  child: Container(
                                    width: double.infinity,
                                    margin: EdgeInsets.fromLTRB(10, 10, 10, 8),
                                    padding: EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: Colors.green.shade600,
                                        width: 2,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.08),
                                          blurRadius: 8,
                                          offset: Offset(0, 3),
                                        ),
                                      ],
                                    ),
                                    child: SingleChildScrollView(
                                      physics: BouncingScrollPhysics(),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      storeName,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        fontSize: 16,
                                                      ),
                                                    ),
                                                    SizedBox(height: 4),
                                                    Text(
                                                      customerName,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        color: Colors
                                                            .grey
                                                            .shade700,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              SizedBox(width: 8),
                                              Container(
                                                padding: EdgeInsets.symmetric(
                                                  horizontal: 9,
                                                  vertical: 5,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: Colors.green
                                                      .withOpacity(0.1),
                                                  borderRadius:
                                                      BorderRadius.circular(20),
                                                ),
                                                child: Text(
                                                  tradeType,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color:
                                                        Colors.green.shade800,
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          SizedBox(height: 8),
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
                                          SizedBox(height: 8),
                                          Row(
                                            children: [
                                              Flexible(
                                                child: Container(
                                                  padding: EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 4,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: isWaitingForCustomer
                                                        ? Colors.deepOrange
                                                              .withOpacity(0.1)
                                                        : Colors.green
                                                              .withOpacity(0.1),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          20,
                                                        ),
                                                  ),
                                                  child: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Icon(
                                                        isWaitingForCustomer
                                                            ? Icons
                                                                  .hourglass_top
                                                            : Icons
                                                                  .local_shipping,
                                                        size: 15,
                                                        color:
                                                            isWaitingForCustomer
                                                            ? Colors
                                                                  .deepOrange
                                                                  .shade800
                                                            : Colors
                                                                  .green
                                                                  .shade800,
                                                      ),
                                                      SizedBox(width: 5),
                                                      Flexible(
                                                        child: Text(
                                                          isWaitingForCustomer
                                                              ? "Waiting for customer"
                                                              : "Active Delivery",
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: TextStyle(
                                                            color:
                                                                isWaitingForCustomer
                                                                ? Colors
                                                                      .deepOrange
                                                                      .shade800
                                                                : Colors
                                                                      .green
                                                                      .shade800,
                                                            fontWeight:
                                                                FontWeight.bold,
                                                            fontSize: 12,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                              SizedBox(width: 8),
                                              TextButton.icon(
                                                onPressed:
                                                    openActiveOrderDetails,
                                                icon: Icon(
                                                  Icons.inventory_2,
                                                  size: 16,
                                                ),
                                                label: Text("View parts"),
                                                style: TextButton.styleFrom(
                                                  minimumSize: Size(0, 34),
                                                  padding: EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                  ),
                                                  tapTargetSize:
                                                      MaterialTapTargetSize
                                                          .shrinkWrap,
                                                ),
                                              ),
                                            ],
                                          ),

                                          if (distanceText != null &&
                                              eta != null)
                                            Padding(
                                              padding: EdgeInsets.only(top: 12),
                                              child: Row(
                                                children: [
                                                  Icon(
                                                    Icons.route,
                                                    size: 16,
                                                    color:
                                                        Colors.green.shade700,
                                                  ),
                                                  SizedBox(width: 5),
                                                  Text(
                                                    "$distanceText • $eta",
                                                    style: TextStyle(
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      color:
                                                          Colors.green.shade700,
                                                      fontSize: 14,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          SizedBox(height: 12),
                                          if (isWaitingForCustomer) ...[
                                            Container(
                                              width: double.infinity,
                                              padding: EdgeInsets.all(10),
                                              decoration: BoxDecoration(
                                                color: Colors.deepOrange
                                                    .withOpacity(0.08),
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                border: Border.all(
                                                  color: Colors
                                                      .deepOrange
                                                      .shade200,
                                                ),
                                              ),
                                              child: Text(
                                                "Customer notified. If they choose another nearby store, this order will update here.",
                                                style: TextStyle(
                                                  color: Colors
                                                      .deepOrange
                                                      .shade900,
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                            SizedBox(height: 12),
                                          ],
                                          Row(
                                            children: [
                                              // ✅ GREEN BUTTON
                                              Expanded(
                                                child: ElevatedButton(
                                                  style: ElevatedButton.styleFrom(
                                                    backgroundColor:
                                                        isWaitingForCustomer
                                                        ? Colors.grey.shade400
                                                        : Colors.green.shade700,
                                                    foregroundColor:
                                                        Colors.white,
                                                    minimumSize:
                                                        Size.fromHeight(44),
                                                    shape: RoundedRectangleBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            8,
                                                          ),
                                                    ),
                                                  ),
                                                  onPressed:
                                                      isUpdatingStatus ||
                                                          isWaitingForCustomer
                                                      ? null
                                                      : () async {
                                                          setState(
                                                            () =>
                                                                isUpdatingStatus =
                                                                    true,
                                                          );

                                                          startLocationUpdates();

                                                          final freshDoc =
                                                              await FirebaseFirestore
                                                                  .instance
                                                                  .collection(
                                                                    'orders',
                                                                  )
                                                                  .doc(
                                                                    orderDoc.id,
                                                                  )
                                                                  .get();

                                                          final freshData =
                                                              freshDoc.data()
                                                                  as Map<
                                                                    String,
                                                                    dynamic
                                                                  >;
                                                          final currentStatus =
                                                              freshData['status'];

                                                          String newStatus;

                                                          if (currentStatus ==
                                                              "Accepted") {
                                                            final pickupStoreLat =
                                                                (freshData['storeLat']
                                                                        as num?)
                                                                    ?.toDouble();
                                                            final pickupStoreLng =
                                                                (freshData['storeLng']
                                                                        as num?)
                                                                    ?.toDouble();

                                                            if (pickupStoreLat ==
                                                                    null ||
                                                                pickupStoreLng ==
                                                                    null) {
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
                                                                () =>
                                                                    isUpdatingStatus =
                                                                        false,
                                                              );
                                                              return;
                                                            }

                                                            final markedPickedUp =
                                                                await markOrderPickedUp(
                                                                  orderId:
                                                                      orderDoc
                                                                          .id,
                                                                  storeLat:
                                                                      pickupStoreLat,
                                                                  storeLng:
                                                                      pickupStoreLng,
                                                                );

                                                            if (markedPickedUp) {
                                                              setState(() {
                                                                isPickedUp =
                                                                    true;
                                                              });
                                                              switchToCustomerRoute();
                                                              await promptForPickupProofPhoto(
                                                                orderId:
                                                                    orderDoc.id,
                                                              );
                                                            }

                                                            if (mounted) {
                                                              setState(
                                                                () =>
                                                                    isUpdatingStatus =
                                                                        false,
                                                              );
                                                            }
                                                            return;
                                                          } else if (currentStatus ==
                                                              "Picked Up") {
                                                            final freshHasPickupProof =
                                                                (freshData['pickupProofPhotoUrl'] ??
                                                                        "")
                                                                    .toString()
                                                                    .isNotEmpty;

                                                            if (!freshHasPickupProof) {
                                                              await promptForPickupProofPhoto(
                                                                orderId:
                                                                    orderDoc.id,
                                                              );

                                                              if (mounted) {
                                                                setState(
                                                                  () =>
                                                                      isUpdatingStatus =
                                                                          false,
                                                                );
                                                              }
                                                              return;
                                                            }

                                                            newStatus =
                                                                "Delivered";
                                                          } else {
                                                            setState(
                                                              () =>
                                                                  isUpdatingStatus =
                                                                      false,
                                                            );
                                                            return;
                                                          }

                                                          if (newStatus ==
                                                              "Delivered") {
                                                            final deliveryPin =
                                                                await showDeliveryPinDialog();

                                                            if (deliveryPin ==
                                                                null) {
                                                              if (mounted) {
                                                                setState(
                                                                  () =>
                                                                      isUpdatingStatus =
                                                                          false,
                                                                );
                                                              }
                                                              return;
                                                            }

                                                            final callable =
                                                                FirebaseFunctions
                                                                    .instance
                                                                    .httpsCallable(
                                                                      'markOrderDelivered',
                                                                    );
                                                            HttpsCallableResult
                                                            result;

                                                            try {
                                                              result = await callable
                                                                  .call({
                                                                    "orderId":
                                                                        orderDoc
                                                                            .id,
                                                                    "deliveryPin":
                                                                        deliveryPin,
                                                                  });
                                                            } on FirebaseFunctionsException catch (
                                                              error
                                                            ) {
                                                              if (mounted) {
                                                                ScaffoldMessenger.of(
                                                                  context,
                                                                ).showSnackBar(
                                                                  SnackBar(
                                                                    content: Text(
                                                                      error.message ??
                                                                          "Could not verify delivery PIN.",
                                                                    ),
                                                                  ),
                                                                );
                                                                setState(
                                                                  () =>
                                                                      isUpdatingStatus =
                                                                          false,
                                                                );
                                                              }
                                                              return;
                                                            }

                                                            final payoutStatus =
                                                                result
                                                                    .data['payoutStatus'];

                                                            if (payoutStatus ==
                                                                "pending_driver_onboarding") {
                                                              ScaffoldMessenger.of(
                                                                context,
                                                              ).showSnackBar(
                                                                SnackBar(
                                                                  content: Text(
                                                                    "Order delivered. Set up Stripe payouts to receive this pay.",
                                                                  ),
                                                                ),
                                                              );
                                                            } else if (payoutStatus ==
                                                                "pending_withdrawal") {
                                                              ScaffoldMessenger.of(
                                                                context,
                                                              ).showSnackBar(
                                                                SnackBar(
                                                                  content: Text(
                                                                    "Order delivered. Pay is ready to withdraw from Earnings.",
                                                                  ),
                                                                ),
                                                              );
                                                            }
                                                          }

                                                          if (newStatus ==
                                                              "Delivered") {
                                                            setState(() {
                                                              completedDriverOrderIds
                                                                  .add(
                                                                    orderDoc.id,
                                                                  );
                                                              clearDriverOrderMapState();
                                                              isUpdatingStatus =
                                                                  false;
                                                            });

                                                            locationTimer
                                                                ?.cancel();
                                                          }

                                                          setState(
                                                            () =>
                                                                isUpdatingStatus =
                                                                    false,
                                                          );
                                                        },
                                                  child: Text(
                                                    isWaitingForCustomer
                                                        ? "Awaiting Reply"
                                                        : status == "Accepted"
                                                        ? "Mark Picked Up"
                                                        : status == "Picked Up"
                                                        ? hasPickupProof
                                                              ? "Mark Delivered"
                                                              : "Add Photo"
                                                        : "",
                                                  ),
                                                ),
                                              ),

                                              SizedBox(width: 10),

                                              // ❌ RED BUTTON
                                              Expanded(
                                                child: ElevatedButton(
                                                  style: ElevatedButton.styleFrom(
                                                    backgroundColor:
                                                        Colors.red.shade600,
                                                    foregroundColor:
                                                        Colors.white,
                                                    minimumSize:
                                                        Size.fromHeight(44),
                                                    shape: RoundedRectangleBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            8,
                                                          ),
                                                    ),
                                                  ),
                                                  onPressed: () async {
                                                    await cancelActiveOrder(
                                                      orderId: orderDoc.id,
                                                      status: status,
                                                    );
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
                            )
                          : isOnline
                          ? StreamBuilder<QuerySnapshot>(
                              key: ValueKey("available-orders"),
                              stream: isOnline
                                  ? FirebaseFirestore.instance
                                        .collection('drivers')
                                        .doc(
                                          FirebaseAuth
                                              .instance
                                              .currentUser!
                                              .uid,
                                        )
                                        .collection('availableOrders')
                                        .snapshots()
                                  : null,
                              builder: (context, snapshot) {
                                if (snapshot.hasError) {
                                  debugPrint(
                                    "Driver available orders stream error: ${snapshot.error}",
                                  );

                                  return driverAvailabilityPrompt(
                                    keyName: "driver-waiting-error",
                                    iconColor: Colors.green,
                                    message:
                                        "Could not load delivery requests.",
                                  );
                                }

                                if (!snapshot.hasData) {
                                  return hasDriverLocation
                                      ? driverAvailabilityPrompt(
                                          keyName: "driver-waiting-loading",
                                          iconColor: Colors.green,
                                          message: "Waiting for deliveries...",
                                        )
                                      : driverLocationLoadingPrompt();
                                }

                                final orders = snapshot.data!.docs.where((doc) {
                                  final order =
                                      doc.data() as Map<String, dynamic>;
                                  return order["status"] == "Pending";
                                }).toList();

                                if (orders.isEmpty) {
                                  return hasDriverLocation
                                      ? driverAvailabilityPrompt(
                                          keyName: "driver-waiting",
                                          iconColor: Colors.green,
                                          message: "Waiting for deliveries...",
                                        )
                                      : driverLocationLoadingPrompt();
                                }

                                return AnimatedContainer(
                                  duration: Duration(milliseconds: 420),
                                  curve: Curves.easeInOutCubic,
                                  height: previewOrderId != null ? 330 : 220,
                                  child: ListView.builder(
                                    controller: _scrollController,
                                    scrollDirection: Axis.horizontal,

                                    physics: previewOrderId != null
                                        ? NeverScrollableScrollPhysics()
                                        : BouncingScrollPhysics(),

                                    itemCount: orders.length,
                                    itemBuilder: (context, index) {
                                      final order =
                                          orders[index].data()
                                              as Map<String, dynamic>;
                                      return _driverOrderCard(
                                        order,
                                        orders[index].id,
                                        index,
                                      );
                                    },
                                  ),
                                );
                              },
                            )
                          : offlineDriverPrompt(),
                    ),
                  ),
                ),
              ),

              // 🗺️ MAP
              Expanded(child: _buildDriverMap()),
            ],
          );
        },
      ),
    );
  }

  Widget driverLocationLoadingPrompt() {
    return Padding(
      key: ValueKey("driver-location-loading"),
      padding: EdgeInsets.symmetric(vertical: 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: Colors.grey.shade600,
            ),
          ),
          SizedBox(height: 8),
          Text(
            "Loading your location...",
            style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
          ),
        ],
      ),
    );
  }

  Widget offlineDriverPrompt() {
    return driverAvailabilityPrompt(
      keyName: "driver-offline",
      iconColor: Colors.grey,
      message: "Go online to receive orders",
    );
  }

  Widget driverAvailabilityPrompt({
    required String keyName,
    required Color iconColor,
    required String message,
  }) {
    return Padding(
      key: ValueKey(keyName),
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.local_shipping, size: 28, color: iconColor),
          SizedBox(height: 6),
          Text(message, style: TextStyle(fontSize: 14, color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildDriverMap() {
    final hasDriverLocation =
        currentPosition.latitude != 0 || currentPosition.longitude != 0;

    return Stack(
      children: [
        GoogleMap(
          initialCameraPosition: CameraPosition(
            target: currentPosition,
            zoom: 15,
          ),
          onMapCreated: (controller) {
            mapController = controller;
          },
          myLocationEnabled: true,
          myLocationButtonEnabled: true,
          markers: {
            if (hasDriverLocation)
              Marker(
                markerId: MarkerId("driver"),
                position: currentPosition,
                icon: BitmapDescriptor.defaultMarkerWithHue(
                  BitmapDescriptor.hueAzure,
                ),
                infoWindow: InfoWindow(title: "You"),
              ),
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
            else if (isOnActiveDelivery &&
                currentStoreLat != null &&
                currentStoreLng != null)
              Marker(
                markerId: MarkerId("store"),
                position: LatLng(currentStoreLat!, currentStoreLng!),
                infoWindow: InfoWindow(title: "Store"),
                icon: BitmapDescriptor.defaultMarkerWithHue(
                  BitmapDescriptor.hueGreen,
                ),
              ),
            if (isPreviewingOrder &&
                previewCustomerLat != null &&
                previewCustomerLng != null)
              Marker(
                markerId: MarkerId("customer"),
                position: LatLng(previewCustomerLat!, previewCustomerLng!),
                infoWindow: InfoWindow(title: "Customer"),
                icon: BitmapDescriptor.defaultMarkerWithHue(
                  BitmapDescriptor.hueRed,
                ),
              ),
          },
          polylines: {
            if ((isPreviewingOrder || isOnActiveDelivery) &&
                storeRoutePoints.isNotEmpty)
              Polyline(
                polylineId: PolylineId("toStore"),
                points: storeRoutePoints,
                color: Colors.blue,
                width: 5,
              ),
            if ((isPreviewingOrder || isOnActiveDelivery) &&
                customerRoutePoints.isNotEmpty)
              Polyline(
                polylineId: PolylineId("toCustomer"),
                points: customerRoutePoints,
                color: isPickedUp
                    ? Colors.green
                    : isOnActiveDelivery
                    ? Colors.green.withOpacity(0.25)
                    : Colors.green,
                width: 5,
              ),
          },
        ),
        Positioned(left: 14, bottom: 34, child: driverMapBalanceChip()),
        if (!hasDriverLocation)
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.08),
                    blurRadius: 8,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "Finding your location...",
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget driverMapBalanceChip() {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => DriverEarningsScreen()),
        );
      },
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.86),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.22),
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.account_balance_wallet, color: Colors.white, size: 18),
            SizedBox(width: 7),
            StreamBuilder<DocumentSnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('drivers')
                  .doc(FirebaseAuth.instance.currentUser!.uid)
                  .snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return Text(
                    "\$0.00",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
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
          ],
        ),
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
    final previewItems = items
        .whereType<Map<String, dynamic>>()
        .take(3)
        .toList();

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
            duration: Duration(milliseconds: 420),
            curve: Curves.easeInOutCubic,
          );
        });

        previewRoute();
      },
      child: AnimatedContainer(
        duration: Duration(milliseconds: 420),
        curve: Curves.easeInOutCubic,
        width: isSelected ? MediaQuery.of(context).size.width * 0.9 : 265,
        height: isSelected ? 310 : 200,
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
              bottom: 56,
              child: SingleChildScrollView(
                physics: isSelected
                    ? BouncingScrollPhysics()
                    : NeverScrollableScrollPhysics(),
                padding: EdgeInsets.only(bottom: 4),
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
                        SizedBox(width: 4),
                        AnimatedOpacity(
                          duration: Duration(milliseconds: 300),
                          curve: Curves.easeOutCubic,
                          opacity: isSelected ? 1 : 0,
                          child: IgnorePointer(
                            ignoring: !isSelected,
                            child: SizedBox(
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
                          ),
                        ),
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
                            Icon(
                              Icons.route,
                              size: 16,
                              color: Colors.green[700],
                            ),
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
                    if (isSelected) ...[
                      SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade200),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              "Parts on order",
                              style: TextStyle(
                                color: Colors.grey.shade700,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: 6),
                            if (previewItems.isEmpty)
                              Text(
                                "No parts listed",
                                style: TextStyle(
                                  color: Colors.grey.shade600,
                                  fontSize: 12,
                                ),
                              )
                            else
                              ...previewItems.map((item) {
                                final name = (item['name'] ?? 'Part')
                                    .toString();
                                final quantity = item['quantity'] ?? 1;

                                return Padding(
                                  padding: EdgeInsets.only(bottom: 4),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 22,
                                        height: 22,
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: Colors.blue.withOpacity(0.1),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                        child: Text(
                                          "x$quantity",
                                          style: TextStyle(
                                            color: Colors.blue.shade800,
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      SizedBox(width: 7),
                                      _previewItemThumbnail(item),
                                      SizedBox(width: 7),
                                      Expanded(
                                        child: Text(
                                          name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }),
                            if (items.length > previewItems.length)
                              Padding(
                                padding: EdgeInsets.only(top: 1),
                                child: Text(
                                  "+${items.length - previewItems.length} more parts",
                                  style: TextStyle(
                                    color: Colors.grey.shade600,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
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
                          try {
                            final callable = FirebaseFunctions.instance
                                .httpsCallable('acceptOrder');
                            await callable.call({"orderId": orderId});
                          } on FirebaseFunctionsException catch (error) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  error.message ?? "Order was already accepted",
                                ),
                              ),
                            );
                            return;
                          } catch (_) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  "Could not accept this order. Please try again.",
                                ),
                              ),
                            );
                            return;
                          }

                          if (!mounted) return;

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

  Widget _previewItemThumbnail(Map<String, dynamic> item) {
    final imagePath = (item['image'] ?? '').toString();
    final name = (item['name'] ?? 'Part').toString();

    return InkWell(
      onTap: imagePath.isEmpty
          ? null
          : () => _showPreviewItemImage(imagePath: imagePath, itemName: name),
      borderRadius: BorderRadius.circular(7),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Container(
          width: 30,
          height: 30,
          color: Colors.white,
          child: imagePath.isEmpty
              ? Icon(Icons.inventory_2, size: 16, color: Colors.grey.shade500)
              : Image.asset(
                  imagePath,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    return Icon(
                      Icons.inventory_2,
                      size: 16,
                      color: Colors.grey.shade500,
                    );
                  },
                ),
        ),
      ),
    );
  }

  void _showPreviewItemImage({
    required String imagePath,
    required String itemName,
  }) {
    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          insetPadding: EdgeInsets.symmetric(horizontal: 22, vertical: 32),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          child: Padding(
            padding: EdgeInsets.all(14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        itemName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: "Close",
                      icon: Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.55,
                    ),
                    width: double.infinity,
                    color: Colors.grey.shade100,
                    child: InteractiveViewer(
                      minScale: 1,
                      maxScale: 3,
                      child: Image.asset(
                        imagePath,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) {
                          return SizedBox(
                            height: 220,
                            child: Center(
                              child: Icon(
                                Icons.inventory_2,
                                size: 42,
                                color: Colors.grey.shade500,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
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

  Future<ImageSource?> choosePickupProofPhotoSource() {
    return showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                SizedBox(height: 14),
                Text(
                  "Add pickup proof",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 6),
                Text(
                  "Take a photo of the item or receipt before continuing the delivery.",
                  style: TextStyle(color: Colors.grey.shade700),
                ),
                SizedBox(height: 12),
                ListTile(
                  leading: Icon(Icons.photo_camera, color: Colors.green),
                  title: Text("Take photo"),
                  onTap: () => Navigator.pop(context, ImageSource.camera),
                ),
                ListTile(
                  leading: Icon(Icons.photo_library, color: Colors.blueGrey),
                  title: Text("Choose from gallery"),
                  onTap: () => Navigator.pop(context, ImageSource.gallery),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<String?> showDeliveryPinDialog() async {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DeliveryPinDialog(),
    );
  }

  Future<bool> promptForPickupProofPhoto({required String orderId}) async {
    final uploaded = await uploadPickupProofPhoto(orderId: orderId);

    if (mounted && uploaded) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Photo saved. You can continue the delivery.")),
      );
    }

    return uploaded;
  }

  Future<bool> uploadPickupProofPhoto({required String orderId}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;

    try {
      final source = await choosePickupProofPhotoSource();
      if (source == null) return false;

      final picker = ImagePicker();
      final image = await picker.pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 1600,
      );

      if (image == null) return false;

      final bytes = await image.readAsBytes();
      final path =
          "pickup_proofs/$orderId/${DateTime.now().millisecondsSinceEpoch}.jpg";
      final ref = FirebaseStorage.instance.ref(path);

      await ref.putData(
        bytes,
        SettableMetadata(
          contentType: "image/jpeg",
          customMetadata: {
            "orderId": orderId,
            "driverId": user.uid,
            "proofType": "item_or_receipt",
          },
        ),
      );

      final photoUrl = await ref.getDownloadURL();

      await FirebaseFirestore.instance.collection('orders').doc(orderId).set({
        "pickupProofPhotoUrl": photoUrl,
        "pickupProofPhotoPath": path,
        "pickupProofUploadedAt": FieldValue.serverTimestamp(),
        "pickupProofUploadedBy": user.uid,
      }, SetOptions(merge: true));

      return true;
    } on FirebaseException catch (error) {
      debugPrint("❌ PICKUP PROOF UPLOAD ERROR: ${error.code} ${error.message}");

      if (mounted) {
        final message = error.code == "unauthorized"
            ? "Photo upload was denied by Firebase Storage rules."
            : error.message ??
                  "Could not save the photo. Please try again before delivery.";

        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      }
      return false;
    } catch (error) {
      debugPrint("❌ PICKUP PROOF UPLOAD ERROR: $error");

      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                "Could not save the photo. Please try again before delivery.",
              ),
            ),
          );
      }
      return false;
    }
  }

  Future<bool> markOrderPickedUp({
    required String orderId,
    required double storeLat,
    required double storeLng,
  }) async {
    const pickupRadiusMeters = 16093.0;
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
        final distanceFeet = distanceMeters * 3.28084;
        final distanceText = distanceFeet < 5280
            ? "${distanceFeet.round()} ft"
            : "${(distanceFeet / 5280).toStringAsFixed(1)} mi";
        final pickupRadiusFeet = pickupRadiusMeters * 3.28084;
        final pickupRadiusText = pickupRadiusFeet < 5280
            ? "${pickupRadiusFeet.round()} ft"
            : "${(pickupRadiusFeet / 5280).toStringAsFixed(1)} mi";

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                "You are $distanceText from the store. Move within $pickupRadiusText to mark this order picked up.",
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

  Future<Map<String, String>?> showDriverCancelReasonSheet() async {
    final reasons = [
      {
        "code": "vehicle_broke_down",
        "label": "Vehicle broke down",
        "icon": Icons.car_repair,
      },
      {
        "code": "payment_problem",
        "label": "Payment problem",
        "icon": Icons.credit_card_off,
      },
      {
        "code": "not_in_stock",
        "label": "Not in stock",
        "icon": Icons.inventory_2_outlined,
      },
    ];

    return showModalBottomSheet<Map<String, String>>(
      context: context,
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                SizedBox(height: 16),
                Text(
                  "Why are you cancelling?",
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 6),
                Text(
                  "If an item is not in stock, the customer will be asked whether to try another nearby store.",
                  style: TextStyle(color: Colors.grey.shade700),
                ),
                SizedBox(height: 12),
                ...reasons.map((reason) {
                  return Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(color: Colors.grey.shade200),
                      ),
                      leading: Icon(
                        reason["icon"] as IconData,
                        color: Colors.red.shade600,
                      ),
                      title: Text(
                        reason["label"] as String,
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      trailing: Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.pop(context, {
                          "code": reason["code"] as String,
                          "label": reason["label"] as String,
                        });
                      },
                    ),
                  );
                }),
                SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text("Keep Order"),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> cancelActiveOrder({
    required String orderId,
    required String status,
  }) async {
    if (status == "Picked Up") {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              "This order has already been picked up. Contact support if there is a problem.",
            ),
          ),
        );
      return;
    }

    final cancelReason = await showDriverCancelReasonSheet();
    if (cancelReason == null) return;

    bool isNotInStock;

    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'driverCancelOrder',
      );
      final result = await callable.call({
        "orderId": orderId,
        "reasonCode": cancelReason["code"],
      });
      final data = Map<String, dynamic>.from(result.data as Map);
      isNotInStock = data["isWaitingForCustomer"] == true;
    } on FirebaseFunctionsException catch (error) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              error.message ?? "Could not cancel this order right now.",
            ),
          ),
        );
      return;
    } catch (_) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text("Could not cancel this order right now.")),
        );
      return;
    }

    setState(() {
      isOnActiveDelivery = isNotInStock;
      isPreviewingOrder = false;
      if (!isNotInStock) {
        storeRoutePoints = [];
        customerRoutePoints = [];
      }
      customerRouteOpacity = 1.0;
      if (!isNotInStock) {
        currentStoreLat = null;
        currentStoreLng = null;
      }
      distanceText = null;
      eta = null;
    });

    if (!isNotInStock) {
      locationTimer?.cancel();
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

class DriverEarningsScreen extends StatefulWidget {
  @override
  State<DriverEarningsScreen> createState() => _DriverEarningsScreenState();
}

class _DriverEarningsScreenState extends State<DriverEarningsScreen>
    with WidgetsBindingObserver {
  bool isCheckingPayoutStatus = false;
  bool isWithdrawingBalance = false;
  bool isPayoutReady = false;
  String payoutStatusText = "Checking payout setup...";
  int withdrawableCents = 0;
  int payoutReviewCents = 0;
  int legacyBalanceCents = 0;
  int payoutReviewCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refreshPayoutStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      refreshPayoutStatus();
    }
  }

  Future<void> refreshPayoutStatus() async {
    if (isCheckingPayoutStatus) return;

    setState(() {
      isCheckingPayoutStatus = true;
      payoutStatusText = "Checking payout setup...";
    });

    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'getDriverPayoutStatus',
      );
      final result = await callable.call();
      final data = Map<String, dynamic>.from(result.data as Map);
      final ready = data["ready"] == true;
      final bankName = data["bankName"]?.toString();
      final bankLast4 = data["bankLast4"]?.toString();
      final availableCents = data["availableCents"] is num
          ? (data["availableCents"] as num).toInt()
          : 0;
      final reviewCents = data["reviewCents"] is num
          ? (data["reviewCents"] as num).toInt()
          : 0;
      final legacyCents = data["legacyBalanceCents"] is num
          ? (data["legacyBalanceCents"] as num).toInt()
          : 0;
      final reviewCount = data["reviewCount"] is num
          ? (data["reviewCount"] as num).toInt()
          : 0;

      if (!mounted) return;

      setState(() {
        isPayoutReady = ready;
        withdrawableCents = availableCents;
        payoutReviewCents = reviewCents;
        legacyBalanceCents = legacyCents;
        payoutReviewCount = reviewCount;
        isCheckingPayoutStatus = false;
        payoutStatusText = ready && bankLast4 != null && bankLast4.isNotEmpty
            ? "${bankName == null || bankName.isEmpty ? "Bank account" : bankName} ending in $bankLast4"
            : ready
            ? "Payouts ready"
            : "Payout setup needs to be finished";
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        isPayoutReady = false;
        withdrawableCents = 0;
        isCheckingPayoutStatus = false;
        payoutStatusText = "Could not check payout setup";
      });
    }
  }

  Future<void> openPayoutSetup() async {
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'createDriverDashboardLink',
      );

      final result = await callable.call();

      final url = result.data['url'];

      if (url == null) {
        throw Exception("No Stripe link returned");
      }

      final uri = Uri.parse(url);

      await launchUrl(uri, mode: LaunchMode.externalApplication);
      await refreshPayoutStatus();
    } catch (e) {
      print("Payout setup error: $e");

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Could not open Stripe payout setup")),
      );
    }
  }

  Future<void> withdrawAvailableBalance(int availableCents) async {
    if (isWithdrawingBalance || availableCents <= 0) return;

    setState(() {
      isWithdrawingBalance = true;
    });

    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'withdrawDriverBalance',
      );
      final result = await callable.call();
      final data = Map<String, dynamic>.from(result.data as Map);
      final amountCents = data["amountCents"] is num
          ? (data["amountCents"] as num).toInt()
          : 0;
      final failedCount = data["failedCount"] is num
          ? (data["failedCount"] as num).toInt()
          : 0;
      final amountText = (amountCents / 100).toStringAsFixed(2);

      if (!mounted) return;

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              failedCount > 0
                  ? "Withdrew \$$amountText. Some payouts need review."
                  : "Withdrew \$$amountText to Stripe Express.",
            ),
          ),
        );
      await refreshPayoutStatus();
    } on FirebaseFunctionsException catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              error.message ?? "Could not withdraw balance right now.",
            ),
          ),
        );
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text("Could not withdraw balance right now.")),
        );
    } finally {
      if (mounted) {
        setState(() {
          isWithdrawingBalance = false;
        });
      }
    }
  }

  Widget earningsActionButton({
    required BuildContext context,
    required String label,
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
    bool filled = false,
  }) {
    final isDisabled = onTap == null;
    final effectiveColor = isDisabled ? Colors.grey : color;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Ink(
          padding: EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: filled
                ? effectiveColor
                : isDisabled
                ? Colors.grey.shade100
                : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: effectiveColor, width: 2),
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
              Icon(
                icon,
                size: 30,
                color: filled ? Colors.white : effectiveColor,
              ),
              SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: filled ? Colors.white : effectiveColor,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_forward_ios,
                size: 18,
                color: filled ? Colors.white : effectiveColor,
              ),
            ],
          ),
        ),
      ),
    );
  }

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

          final availableBalance = withdrawableCents / 100;
          final reviewBalance = (payoutReviewCents + legacyBalanceCents) / 100;
          final careerEarnings = (data?['careerEarnings'] ?? availableBalance)
              .toDouble();
          final actionsEnabled =
              !isCheckingPayoutStatus && !isWithdrawingBalance;

          return appScreenFade(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(height: 20),

                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "Available Balance",
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.grey[700],
                              ),
                            ),

                            SizedBox(height: 6),

                            Text(
                              "\$${availableBalance.toStringAsFixed(2)}",
                              style: TextStyle(
                                fontSize: 40,
                                fontWeight: FontWeight.bold,
                              ),
                            ),

                            SizedBox(height: 4),

                            Text(
                              "Career earnings: \$${careerEarnings.toStringAsFixed(2)}",
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey.shade600,
                                fontWeight: FontWeight.w600,
                              ),
                            ),

                            if (reviewBalance > 0) ...[
                              SizedBox(height: 4),
                              Text(
                                "Needs review: \$${reviewBalance.toStringAsFixed(2)}"
                                "${payoutReviewCount > 0 ? " ($payoutReviewCount order${payoutReviewCount == 1 ? "" : "s"})" : ""}",
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.orange.shade900,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),

                      SizedBox(width: 14),

                      SizedBox(
                        width: 132,
                        height: 82,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap:
                                actionsEnabled &&
                                    isPayoutReady &&
                                    withdrawableCents > 0
                                ? () => withdrawAvailableBalance(
                                    withdrawableCents,
                                  )
                                : null,
                            child: Ink(
                              decoration: BoxDecoration(
                                color:
                                    actionsEnabled &&
                                        isPayoutReady &&
                                        withdrawableCents > 0
                                    ? Colors.green
                                    : Colors.grey,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color:
                                      actionsEnabled &&
                                          isPayoutReady &&
                                          withdrawableCents > 0
                                      ? Colors.green.shade700
                                      : Colors.grey.shade500,
                                  width: 2,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.08),
                                    blurRadius: 10,
                                    offset: Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.payments,
                                    color: Colors.white,
                                    size: 26,
                                  ),
                                  SizedBox(height: 6),
                                  Text(
                                    isWithdrawingBalance
                                        ? "Withdrawing"
                                        : "Withdraw",
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),

                  SizedBox(height: 24),

                  Container(
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Colors.grey.shade300, Colors.grey.shade100],
                        stops: [0.0, 0.55],
                      ),
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
                          "Set up or manage your Stripe Express payout account.",
                          style: TextStyle(color: Colors.grey[700]),
                        ),

                        SizedBox(height: 12),

                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 9,
                          ),
                          decoration: BoxDecoration(
                            color: isPayoutReady
                                ? Colors.green.withOpacity(0.1)
                                : Colors.orange.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: isPayoutReady
                                  ? Colors.green
                                  : Colors.orange.shade700,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isCheckingPayoutStatus)
                                SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              else
                                Icon(
                                  isPayoutReady
                                      ? Icons.check_circle
                                      : Icons.warning_amber_rounded,
                                  size: 18,
                                  color: isPayoutReady
                                      ? Colors.green
                                      : Colors.orange.shade800,
                                ),
                              SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  payoutStatusText,
                                  style: TextStyle(
                                    color: isPayoutReady
                                        ? Colors.green.shade800
                                        : Colors.orange.shade900,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: "Refresh payout status",
                                onPressed: actionsEnabled
                                    ? refreshPayoutStatus
                                    : null,
                                icon: Icon(Icons.refresh, size: 18),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  SizedBox(height: 20),

                  earningsActionButton(
                    context: context,
                    label: "Set Up Stripe Express",
                    icon: Icons.account_balance,
                    color: Colors.green,
                    filled: true,
                    onTap: actionsEnabled && !isPayoutReady
                        ? openPayoutSetup
                        : null,
                  ),

                  SizedBox(height: 10),

                  Text(
                    "Already have an account? Just set one up? Connect it to the app here.",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontSize: 12,
                      decoration: TextDecoration.underline,
                      decorationColor: Colors.grey.shade600,
                    ),
                  ),

                  SizedBox(height: 10),

                  earningsActionButton(
                    context: context,
                    label: "Connect/Manage Stripe Express Account",
                    icon: Icons.link,
                    color: Colors.green,
                    onTap: actionsEnabled
                        ? () async {
                            await refreshPayoutStatus();

                            if (!context.mounted) return;

                            ScaffoldMessenger.of(context)
                              ..hideCurrentSnackBar()
                              ..showSnackBar(
                                SnackBar(
                                  content: Text(
                                    isPayoutReady
                                        ? "Stripe Express account connected."
                                        : "Stripe still needs a little more setup.",
                                  ),
                                ),
                              );
                          }
                        : null,
                  ),

                  SizedBox(height: 12),

                  earningsActionButton(
                    context: context,
                    label: "View Earnings History",
                    icon: Icons.receipt_long,
                    color: Theme.of(context).colorScheme.primary,
                    onTap: actionsEnabled
                        ? () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => DriverEarningsHistoryScreen(),
                              ),
                            );
                          }
                        : null,
                  ),
                ],
              ),
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

    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: Text("Earnings History")),
        body: Center(child: Text("Sign in to view earnings history.")),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text("Earnings History")),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('orders')
            .where('driverId', isEqualTo: user.uid)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            debugPrint("Earnings history error: ${snapshot.error}");

            return Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  "Could not load earnings history right now.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade700),
                ),
              ),
            );
          }

          if (!snapshot.hasData) {
            return Center(child: CircularProgressIndicator());
          }

          final orders =
              snapshot.data!.docs.where((doc) {
                final data = doc.data() as Map<String, dynamic>;
                return data['status'] == "Delivered";
              }).toList()..sort((a, b) {
                final aData = a.data() as Map<String, dynamic>;
                final bData = b.data() as Map<String, dynamic>;
                final aCreatedAt = aData['createdAt'];
                final bCreatedAt = bData['createdAt'];
                final aMillis = aCreatedAt is Timestamp
                    ? aCreatedAt.millisecondsSinceEpoch
                    : 0;
                final bMillis = bCreatedAt is Timestamp
                    ? bCreatedAt.millisecondsSinceEpoch
                    : 0;

                return bMillis.compareTo(aMillis);
              });

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
      "deliveryPin": generateCustomerDeliveryPin(),
      "deliveryPinUpdatedAt": FieldValue.serverTimestamp(),
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

    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'autocompleteAddress',
      );
      final result = await callable.call({"input": input});
      final data = Map<String, dynamic>.from(result.data as Map);

      setState(() {
        predictions = List<dynamic>.from(data['predictions'] ?? []);
      });
    } on FirebaseFunctionsException catch (error) {
      print("❌ AUTOCOMPLETE ERROR: ${error.code} ${error.message ?? ''}");
    } catch (error) {
      print("❌ ERROR: $error");
    }
  }

  Future<void> selectPlace(dynamic place) async {
    final placeId = place['place_id'];
    final selectedAddress = place['description']; // 👈 LOCK USER TEXT

    print("👉 USER SELECTED: $selectedAddress");

    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'getPlaceDetails',
      );
      final details = await callable.call({"placeId": placeId});
      final data = Map<String, dynamic>.from(details.data as Map);

      final lat = (data['lat'] as num).toDouble();
      final lng = (data['lng'] as num).toDouble();

      print("📍 COORDS: $lat, $lng");

      // 🚀 GO TO MAP CONFIRM SCREEN
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ConfirmLocationScreen(
            lat: lat,
            lng: lng,
            address: selectedAddress ?? data['address'] ?? "",
          ),
        ),
      );
    } on FirebaseFunctionsException catch (error) {
      print("❌ DETAILS ERROR: ${error.code} ${error.message ?? ''}");
    } catch (error) {
      print("❌ ERROR: $error");
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
  const TradeStoreScreen({super.key});

  String lockedCartMessage(String cartTrade) {
    return "$cartTrade cart must be empty before shopping for another trade.";
  }

  Widget tradeCard(
    BuildContext context,
    String trade,
    IconData icon,
    Color color,
    String? cartTrade,
  ) {
    final isLocked = cartTrade != null && cartTrade != trade;
    final cardColor = isLocked ? Colors.grey : color;

    return GestureDetector(
      onTap: () {
        if (isLocked) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                duration: Duration(seconds: 4),
                content: Text(lockedCartMessage(cartTrade!)),
              ),
            );
          return;
        }

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
          color: cardColor.withOpacity(isLocked ? 0.12 : 0.15),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: cardColor, width: 2),
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
            Icon(icon, size: 36, color: cardColor),

            SizedBox(width: 20),

            Text(
              trade,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: cardColor,
              ),
            ),

            Spacer(),

            Icon(
              isLocked ? Icons.lock_outline : Icons.arrow_forward_ios,
              color: cardColor,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: false, toolbarHeight: 0),
      body: StreamBuilder<QuerySnapshot>(
        stream: user == null
            ? null
            : FirebaseFirestore.instance
                  .collection('users')
                  .doc(user.uid)
                  .collection('cart')
                  .snapshots(),
        builder: (context, snapshot) {
          String? cartTrade;

          if (snapshot.hasData && snapshot.data!.docs.isNotEmpty) {
            final firstCartItem =
                snapshot.data!.docs.first.data() as Map<String, dynamic>;
            cartTrade = firstCartItem["tradeType"] as String? ?? "Plumbing";
          }

          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  "Choose Your Trade",
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 40),
                tradeCard(
                  context,
                  "Plumbing",
                  Icons.plumbing,
                  Colors.blue,
                  cartTrade,
                ),
                SizedBox(height: 20),
                tradeCard(
                  context,
                  "Electrical",
                  Icons.electrical_services,
                  Colors.green,
                  cartTrade,
                ),
                SizedBox(height: 20),
                tradeCard(
                  context,
                  "HVAC",
                  Icons.ac_unit,
                  Colors.orange,
                  cartTrade,
                ),
              ],
            ),
          );
        },
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
    /*
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
      "name": "Thread Seal Tape",
      "price": 13.00,
      "description":
          "Tape for sealing water connections commonly known as teflon tape (Brand may vary)",
      "image": "assets/images/TeflonTape.jpg",
      "categories": ["Tape"],
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
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. Copper ProPress Coupling With Stop",
      "price": 12.00,
      "description":
          "Copper coupling for propress connecting 2 in. pipe with internal stops (Brand may vary)",
      "image": "assets/images/CopperProPressNonSlipCoupling.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "2 in. Copper ProPress Coupling Without Stop",
      "price": 16.50,
      "description":
          "Copper coupling for propress connecting 2 in. pipe without internal stops (Brand may vary)",
      "image": "assets/images/CopperProPressSlipCoupling.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "2 in. Copper Tee Fitting",
      "price": 24.00,
      "description":
          "Copper all cup tee fitting for connecting 2 in. pipe (Brand may vary)",
      "image": "assets/images/CopperTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. Copper ProPress Tee Fitting",
      "price": 21.50,
      "description":
          "Copper tee fitting for connecting 2 in. pipe with propress (Brand may vary)",
      "image": "assets/images/CopperProPressTee.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "2 in. Copper 45-Degree Fitting",
      "price": 15.00,
      "description":
          "Copper 45-degree fitting for connecting 2 in. pipe (Brand may vary)",
      "image": "assets/images/Copper45.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. Copper 45-Degree Street Fitting",
      "price": 20.00,
      "description":
          "Copper 45-degree fitting with one male end for connecting 2 in. pipe (Brand may vary)",
      "image": "assets/images/CopperStreet45.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. Copper 45-Degree ProPress Fitting",
      "price": 20.00,
      "description":
          "Copper 45-degree fitting for connecting 2 in. pipe with propress (Brand may vary)",
      "image": "assets/images/CopperProPress45.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "propress",
    },
    {
      "name": "2 in. Copper 90-Degree Elbow",
      "price": 9.00,
      "description":
          "Copper 90-degree Non-slip fitting for connecting 2 in. pipe (Brand may vary)",
      "image": "assets/images/Copper90.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. Copper 90-Degree Street Elbow",
      "price": 15.50,
      "description":
          "Copper 90-degree street fitting for connecting 2 in. pipe (Brand may vary)",
      "image": "assets/images/CopperStreet90.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. Copper 90-Degree ProPress Elbow",
      "price": 14.00,
      "description":
          "Copper 90-degree fitting for connecting 2 in. pipe with propress(Brand may vary)",
      "image": "assets/images/CopperProPress90.jpg",
      "categories": ["Copper Fittings"],
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
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. Copper Female Threaded Adapter",
      "price": 3.00,
      "description": "2 in. Copper female threaded adapter (Brand may vary)",
      "image": "assets/images/CopperThreadedFemaleAdapter.jpg",
      "categories": ["Copper Fittings"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. Copper Tube Strap",
      "price": 3.00,
      "description":
          "2 in. copper strap for fastening copper pipe (Brand may vary)",
      "image": "assets/images/CopperTubeStrap.jpg",
      "categories": ["Straps/Hangers"],
      "specialtyStoreTag": "copperFittings",
    },
    {
      "name": "2 in. Brass Cap",
      "price": 15.00,
      "description": "2 in. brass threaded cap (Brand may vary)",
      "image": "assets/images/BrassCap.jpg",
      "categories": ["Brass"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "2 in. Brass Coupling",
      "price": 17.00,
      "description": "2 in. brass threaded coupling (Brand may vary)",
      "image": "assets/images/BrassCoupling.jpg",
      "categories": ["Brass"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "2 in. Brass 90",
      "price": 42.00,
      "description": "2 in. brass threaded elbow fitting (Brand may vary)",
      "image": "assets/images/Brass90.jpg",
      "categories": ["Brass"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "2 in. Brass 45",
      "price": 24.00,
      "description": "1 in. brass threaded 45 fitting (Brand may vary)",
      "image": "assets/images/Brass45.jpg",
      "categories": ["Brass"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "2 in. Brass Street 90",
      "price": 57.50,
      "description":
          "2 in. brass threaded street elbow fitting (Brand may vary)",
      "image": "assets/images/BrassStreet90.jpg",
      "categories": ["Brass"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "2 in. Brass Street 45",
      "price": 31.50,
      "description": "2 in. brass threaded street 45 fitting (Brand may vary)",
      "image": "assets/images/BrassStreet45.jpg",
      "categories": ["Brass"],
      "specialtyStoreTag": "brassFittings",
    },
    {
      "name": "2 in. Brass Ball Valve(Threaded)",
      "price": 35.00,
      "description":
          "2 Full port brass ball valve with threading on both ends (Brand may vary)",
      "image": "assets/images/ThreadedBallValve.jpg",
      "categories": ["Valves"],
      "specialtyStoreTag": "valves",
    },
    {
      "name": "2 in. Brass Ball Valve(Non-Threaded)",
      "price": 25.00,
      "description":
          "1 Full port brass ball valve with female port on both ends (Brand may very)",
      "image": "assets/images/NonThreadedBallValve.jpg",
      "categories": ["Valves"],
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
      "name": "1 in. Copper Tube Strap",
      "price": 3.00,
      "description":
          "1 in. copper strap for fastening copper pipe (Brand may vary)",
      "image": "assets/images/CopperTubeStrap.jpg",
      "categories": ["Straps/Hangers"],
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
      "name": "3/4 in. Copper Tube Strap",
      "price": 3.00,
      "description":
          "3/4 in. copper strap for fastening copper pipe (Brand may vary)",
      "image": "assets/images/CopperTubeStrap.jpg",
      "categories": ["Straps/Hangers"],
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
      "name": "1/2 in. Copper Tube Strap",
      "price": 3.00,
      "description":
          "1/2 in. copper strap for fastening copper pipe (Brand may vary)",
      "image": "assets/images/CopperTubeStrap.jpg",
      "categories": ["Straps/Hangers"],
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
      "name": "1 1/2 in. Flushometer Control Stop Valve",
      "price": 76.00,
      "description":
          "1 in. valve that shuts off water supply to flushometer (Brand may very)",
      "image": "assets/images/ControlStop1.5in.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "1 in. Flushometer Control Stop Valve",
      "price": 76.00,
      "description":
          "1 in. valve that shuts off water supply to flushometer (Brand may very)",
      "image": "assets/images/ControlStop1in.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "3/4 in. Flushometer Control Stop Valve",
      "price": 76.00,
      "description":
          "3/4 in. valve that shuts off water supply to flushometer (Brand may very)",
      "image": "assets/images/ControlStop.75in.jpg",
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
      "name": "Universal Toilet Fill Valve",
      "price": 15.00,
      "description":
          "Adjustable height *9-14 inches* toilet fill valve fits most standard toilets (Brand may very)",
      "image": "assets/images/UniversalFillValve.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "Universal 3 in. Toilet Flush Valve",
      "price": 15.00,
      "description": "3 in. adjustable flush valve (Brand may very)",
      "image": "assets/images/Universal3inFlushValve.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "Universal 2 in. Toilet Flush Valve",
      "price": 15.00,
      "description":
          "2 in. adjustable flush valve with adapter for Gerber, and Kholer brand toilets (Brand may very)",
      "image": "assets/images/Universal2inFlushValve.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "Toilet Flapper",
      "price": 12.00,
      "description": "Rubber flapper for toilet flush (Brand may very)",
      "image": "assets/images/Flapper.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "3 in. Toilet Tank To Bowl Kit",
      "price": 9.00,
      "description":
          "Kit that includes bowl gasket, 2 galvanized steel bolts, 4 galvanized steel nuts, and 4 galvanized steel washers with 4 rubber washers *Fits 3 in. flush valve* (Brand may very)",
      "image": "assets/images/3inTankToBowlKit.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "2 in. Toilet Tank To Bowl Kit",
      "price": 9.00,
      "description":
          "Kit that includes bowl gasket, 3 galvanized steel bolts, 6 galvanized steel nuts, and 6 galvanized steel washers with 6 rubber washers *Fits 2 in. flush valve* (Brand may very)",
      "image": "assets/images/2inTankToBowlKit.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "Manual Flushometer (1 in. Inlet x 1 1/2 in. Spud Connection)",
      "price": 9.00,
      "description": "Chrome assembly flushometer for toilet (Brand may very)",
      "image": "assets/images/RubberVacuumBreaker1.5in.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "1 1/2 in. Rubber Vacuum Breaker",
      "price": 9.00,
      "description":
          "A rubber diaphragm that seals and regulates airflow inside a flush valve vacuum breaker (Brand may very)",
      "image": "assets/images/RubberVacuumBreaker1.5in.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "1 1/4 in. Rubber Vacuum Breaker",
      "price": 9.00,
      "description":
          "A rubber diaphragm that seals and regulates airflow inside a flush valve vacuum breaker (Brand may very)",
      "image": "assets/images/RubberVacuumBreaker1.25in.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "1 in. Rubber Vacuum Breaker",
      "price": 9.00,
      "description":
          "A rubber diaphragm that seals and regulates airflow inside a flush valve vacuum breaker (Brand may very)",
      "image": "assets/images/RubberVacuumBreaker1in.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "3/4 in. Rubber Vacuum Breaker",
      "price": 9.00,
      "description":
          "A rubber diaphragm that seals and regulates airflow inside a flush valve vacuum breaker (Brand may very)",
      "image": "assets/images/RubberVacuumBreaker.75in.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "2 in. x 2 in. Spud",
      "price": 9.00,
      "description":
          "Spud fitting for connecting porcelain to flushometer (Brand may very)",
      "image": "assets/images/Spud2x2.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "1 1/2 in. x 1 1/2 in. Spud",
      "price": 9.00,
      "description":
          "Spud fitting for connecting porcelain to flushometer (Brand may very)",
      "image": "assets/images/Spud1.5x1.5.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "1 1/4 in. x 1 1/4 in. Spud",
      "price": 9.00,
      "description":
          "Spud fitting for connecting porcelain to flushometer (Brand may very)",
      "image": "assets/images/Spud1.25x1.25.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "3/4 in. x 3/4 in. Spud",
      "price": 9.00,
      "description":
          "Spud fitting for connecting porcelain to flushometer (Brand may very)",
      "image": "assets/images/Spud.75x.75.jpg",
      "categories": ["Bathroom"],
      "specialtyStoreTag": "toiletRepair",
    },
    {
      "name": "Garden Hose",
      "price": 12.00,
      "description": "Standard 3/4 in. GHT 50 ft. Hose (Brand may very)",
      "image": "assets/images/50ft.GardenHose.jpg",
      "categories": ["Hoses"],
      "specialtyStoreTag": "Plumbing",
    },
    {
      "name": "Pipe Dope (8 oz.)",
      "price": 7.00,
      "description":
          "Paste for sealing pipe connections from leaks (Brand may very)",
      "image": "assets/images/PipeDope.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "Plumbing",
    },
    {
      "name": "Yellow Thread Seal Tape",
      "price": 5.00,
      "description":
          "Yellow tape for sealing gas connections commonly known as teflon tape (Brand may very)",
      "image": "assets/images/TeflonTape(Yellow).jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "Plumbing",
    },
    {
      "name": "4 in. Black Iron Pipe Coupling",
      "price": 2.50,
      "description": "4 in. Black iron coupling for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCoupling.jpg",
      "categories": ["Couplings", "Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "4 in. Black Iron Pipe Cap",
      "price": 2.50,
      "description":
          "4 in. Threaded black iron cap for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCap.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "4 in. Black Iron Pipe 45 degree Elbow",
      "price": 4.00,
      "description":
          "4 in. black iron 45 degree fitting for gas line (Brand may very)",
      "image": "assets/images/BlackPipe45.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "4 in. Black Iron Pipe 90 degree Elbow",
      "price": 4.00,
      "description":
          "4 in. black iron 90 degree elbow for gas line (Brand may very)",
      "image": "assets/images/BlackPipe90.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "4 in. Black Iron Pipe Nipple",
      "price": 2.50,
      "description": "4 in. black steel nipple for gas line (Brand may very)",
      "image": "assets/images/BlackPipeNipple.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "4 in. Black Iron Pipe Tee",
      "price": 2.50,
      "description":
          "4 in. black iron tee for connecting threaded steel pipe (Brand may very)",
      "image": "assets/images/BlackPipeTee.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
      "specialtyStoreTag": "blackIron",
    },
    {
      "name": "4 in. Black Iron Pipe Union Fiting",
      "price": 11.00,
      "description":
          "4 in. black iron Union fitting for connecting two threaded steel pipes (Brand may very)",
      "image": "assets/images/BlackPipeUnion.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
      "specialtyStoreTag": "blackIron",
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
      "name": "3/4 in. Black Iron Pipe Cap",
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
      "name": "2 in. Discharge Hose",
      "price": 7.00,
      "description":
          "2 in. 50 ft. discharge hose with male NPSM and female pin lug coupling (Brand may very)",
      "image": "assets/images/50ft.2in.DischargeHose.jpg",
      "categories": ["Hoses"],
      "specialtyStoreTag": "Hoses",
    },
    {
      "name": "2 in. Outlet Clear Water Sump Pump",
      "price": 250.00,
      "description":
          "Clear water sump pump with 2 in. diameter outlet (Brand may very)",
      "image": "assets/images/2in.DischargeHose.jpg",
      "categories": ["Pumps", "Drains"],
      "specialtyStoreTag": "SumpPumps",
    },
    {
      "name": "2 in. Outlet Sewage Ejector Pump",
      "price": 350.00,
      "description":
          "Sewage Ejector pump with 2 in. diameter outlet (Brand may very)",
      "image": "assets/images/2in.SewageEjectorPump.jpg",
      "categories": ["Pumps", "Drains"],
      "specialtyStoreTag": "SumpPumps",
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
      "name": "1 1/2 in. Shielded Rubber Coupling",
      "price": 12.00,
      "description":
          "1 1/2 in. Rubber coupling for conneting drain pipe(Brand may very)",
      "image": "assets/images/Shielded2inRubberCoupling.jpg",
      "categories": ["PVC", "Drains", "NoHub"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "1 1/2 in. Heavy Duty Shielded Rubber Coupling",
      "price": 11.00,
      "description":
          "1 1/2 in. Shielded rubber coupling for conneting drain pipe(Brand may very)",
      "image": "assets/images/HeavyDutyRubberCoupling(2inOrLower).jpg",
      "categories": ["PVC", "Drains", "NoHub"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "1 1/2 in. Rubber Cap",
      "price": 5.00,
      "description":
          "1 1/2 in. rubber cap for PVC or Cast iron pipe (Brand may very)",
      "image": "assets/images/RubberCap.jpg",
      "categories": ["NoHub", "Drains", "PVC"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 1 1/2 in. 45",
      "price": 16.50,
      "description": "1 1/2 in. Cast iron 45 (Brand may very)",
      "image": "assets/images/NoHub45.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 1 1/2 in. Cleanout",
      "price": 28.50,
      "description":
          "1 1/2 in. Cast iron cleanout without cap (Brand may very)",
      "image": "assets/images/NoHubCleanout.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 1 1/2 in. Sanitary Tee",
      "price": 24.00,
      "description":
          "1 1/2 in. Cast iron santary tee for drain piping (Brand may very)",
      "image": "assets/images/NoHubSanitaryTee.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 1 1/2  in. Long Sweep Elbow",
      "price": 49.50,
      "description":
          "1 1/2 in. Cast iron elbow with a large bend for better flow (Brand may very)",
      "image": "assets/images/NoHubLongSweepElbow.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 1 1/2 in. Short Sweep Elbow",
      "price": 31.50,
      "description":
          "1 1/2 in. Cast iron elbow with a slighly larger bend for better flow (Brand may very)",
      "image": "assets/images/NoHubShortSweepElbow.jpg",
      "categories": ["NoHub", "Drains"],
      "specialtyStoreTag": "noHub",
    },
    {
      "name": "No Hub 1 1/2 in. Wye",
      "price": 29.00,
      "description": "1 1/2 in. Cast iron wye (Brand may very)",
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
      "image": "assets/images/Plastic1.5inTo1.25inReducingBushing.jpg",
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
          "Bolts, nuts, and washers for fastening toilet to toilet drain flange, commonly known as johnny bolts (Brand may very)",
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
      "name": "1/4 in. x 2 1/4 in. Concrete Anchor Screws (Pack of 8)",
      "price": 11.00,
      "description":
          "Screws for fastening material to concrete *Bit not included* (Brand may very)",
      "image": "assets/images/ConcreteAnchorScrew.25inx2.25in(8Pack).jpg",
      "categories": ["Tools", "Anchors/Fasteners"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "1/4 in. x 2 1/4 in. Concrete Anchor Screws (Pack of 25)",
      "price": 11.00,
      "description":
          "Screws for fastening material to concrete *Bit not included* (Brand may very)",
      "image": "assets/images/ConcreteAnchorScrew.25inx2.25in(25Pack).jpg",
      "categories": ["Tools", "Anchors/Fasteners"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "1/4 in. x 2 1/4 in. Concrete Anchor Screws (Pack of 75)",
      "price": 11.00,
      "description":
          "Screws for fastening material to concrete *Bit included* (Brand may very)",
      "image": "assets/images/ConcreteAnchorScrew.25inx2.25in(75Pack).jpg",
      "categories": ["Tools", "Anchors/Fasteners"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "1/4 in. x 1 1/4 in. Concrete Anchor Screws (Pack of 8)",
      "price": 11.00,
      "description":
          "Screws for fastening material to concrete *Bit not included* (Brand may very)",
      "image": "assets/images/ConcreteAnchorScrew.25inx1.25in(8Pack).jpg",
      "categories": ["Tools", "Anchors/Fasteners"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "1/4 in. x 1 1/4 in. Concrete Anchor Screws (Pack of 25)",
      "price": 11.00,
      "description":
          "Screws for fastening material to concrete *Bit not included* (Brand may very)",
      "image": "assets/images/ConcreteAnchorScrew.25inx1.25in(25Pack).jpg",
      "categories": ["Tools", "Anchors/Fasteners"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "1/4 in. x 1 1/4 in. Concrete Anchor Screws (Pack of 75)",
      "price": 11.00,
      "description":
          "Screws for fastening material to concrete *Bit included* (Brand may very)",
      "image": "assets/images/ConcreteAnchorScrew.25inx1.25in(75Pack).jpg",
      "categories": ["Tools", "Anchors/Fasteners"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "1/4 in. x 1 3/4 in. Concrete Anchor Screws (Pack of 8)",
      "price": 11.00,
      "description":
          "Screws for fastening material to concrete *Bit not included* (Brand may very)",
      "image": "assets/images/ConcreteAnchorScrew.25inx1.75in(8Pack).jpg",
      "categories": ["Tools", "Anchors/Fasteners"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "1/4 in. x 1 3/4 in. Concrete Anchor Screws (Pack of 25)",
      "price": 11.00,
      "description":
          "Screws for fastening material to concrete *Bit not included* (Brand may very)",
      "image": "assets/images/ConcreteAnchorScrew.25inx1.75in(25Pack).jpg",
      "categories": ["Anchors/Fasteners"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "1/4 in. x 1 3/4 in. Concrete Anchor Screws (Pack of 75)",
      "price": 11.00,
      "description":
          "Screws for fastening material to concrete *Bit included* (Brand may very)",
      "image": "assets/images/ConcreteAnchorScrew.25inx1.75in(75Pack).jpg",
      "categories": ["Anchors/Fasteners"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "5/8 in. 11 Thread Count Drop-In Anchor",
      "price": 11.00,
      "description":
          "Standard drop-in anchor for 5/8 in. threaded rod with 11 threads *7/8 in. masonry bit required for pilot hole* (Brand may very)",
      "image": "assets/images/DropInAnchor.375-16.jpg",
      "categories": ["Anchors/Fasteners"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "1/2 in. 13 Thread Count Drop-In Anchor",
      "price": 11.00,
      "description":
          "Standard drop-in anchor for 1/2 in. threaded rod with 13 threads *5/8 in. masonry bit required for pilot hole* (Brand may very)",
      "image": "assets/images/DropInAnchor.5-13.jpg",
      "categories": ["Anchors/Fasteners"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "3/8 in. 16 Thread Count Drop-In Anchor",
      "price": 11.00,
      "description":
          "Standard drop-in anchor for 3/8 in. threaded rod with 16 threads *1/2 in. masonry bit required for pilot hole* (Brand may very)",
      "image": "assets/images/DropInAnchor.375-16.jpg",
      "categories": ["Anchors/Fasteners"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "1/4 in. 20 Thread Count Drop-In Anchor",
      "price": 11.00,
      "description":
          "Standard drop-in anchor for 1/4 in. threaded rod with 20 threads *3/8 in. masonry bit required for pilot hole* (Brand may very)",
      "image": "assets/images/DropInAnchor.25-20.jpg",
      "categories": ["Anchors/Fasteners"],
      "specialtyStoreTag": "plumbingTools",
    },
    {
      "name": "1/4 in. Threaded Rod (1 ft.)",
      "price": 4.00,
      "description": "1/4 in. 1 foot long threaded rod (Brand may very)",
      "image": "assets/images/ThreadedRod.25in(1Foot).jpg",
      "categories": ["Straps/Hangers", "Threaded Rod"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "1/4 in. Threaded Rod (2 ft.)",
      "price": 4.00,
      "description": "1/4 in. 2 foot long threaded rod (Brand may very)",
      "image": "assets/images/ThreadedRod.25in(2Foot).jpg",
      "categories": ["Straps/Hangers", "Threaded Rod"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "1/4 in. Threaded Rod (3 ft.)",
      "price": 4.00,
      "description": "1/4 in. 3 foot long threaded rod (Brand may very)",
      "image": "assets/images/ThreadedRod.25in(3Foot).jpg",
      "categories": ["Straps/Hangers", "Threaded Rod"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "1/4 in. Threaded Rod (6 ft.)",
      "price": 4.00,
      "description": "1/4 in. 6 foot long threaded rod (Brand may very)",
      "image": "assets/images/ThreadedRod.25in(6Foot).jpg",
      "categories": ["Straps/Hangers", "Threaded Rod"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "1/2 in. Threaded Rod (1 ft.)",
      "price": 4.00,
      "description": "1/2 in. 1 foot long threaded rod (Brand may very)",
      "image": "assets/images/ThreadedRod.5in(1Foot).jpg",
      "categories": ["Straps/Hangers", "Threaded Rod"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "1/2 in. Threaded Rod (2 ft.)",
      "price": 4.00,
      "description": "1/2 in. 2 foot long threaded rod (Brand may very)",
      "image": "assets/images/ThreadedRod.5in(2Foot).jpg",
      "categories": ["Straps/Hangers", "Threaded Rod"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "1/2 in. Threaded Rod (3 ft.)",
      "price": 4.00,
      "description": "1/2 in. 3 foot long threaded rod (Brand may very)",
      "image": "assets/images/ThreadedRod.5in(3Foot).jpg",
      "categories": ["Straps/Hangers", "Threaded Rod"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "1/2 in. Threaded Rod (6 ft.)",
      "price": 4.00,
      "description": "1/2 in. 6 foot long threaded rod (Brand may very)",
      "image": "assets/images/ThreadedRod.5in(6Foot).jpg",
      "categories": ["Straps/Hangers", "Threaded Rod"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "3/8 in. Threaded Rod (1 ft.)",
      "price": 4.00,
      "description": "3/8 in. 1 foot long threaded rod (Brand may very)",
      "image": "assets/images/ThreadedRod.375in(1Foot).jpg",
      "categories": ["Straps/Hangers", "Threaded Rod"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "3/8 in. Threaded Rod (2 ft.)",
      "price": 4.00,
      "description": "3/8 in. 2 foot long threaded rod (Brand may very)",
      "image": "assets/images/ThreadedRod.375in(2Foot).jpg",
      "categories": ["Straps/Hangers", "Threaded Rod"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "3/8 in. Threaded Rod (3 ft.)",
      "price": 4.00,
      "description": "3/8 in. 3 foot long threaded rod (Brand may very)",
      "image": "assets/images/ThreadedRod.375in(3Foot).jpg",
      "categories": ["Straps/Hangers", "Threaded Rod"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "3/8 in. Threaded Rod (6 ft.)",
      "price": 4.00,
      "description": "3/8 in. 6 foot long threaded rod (Brand may very)",
      "image": "assets/images/ThreadedRod.375in(6Foot).jpg",
      "categories": ["Straps/Hangers", "Threaded Rod"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "1/4 in. Hex Nut (Zinc Plated)",
      "price": 0.50,
      "description": "1/4 in. zinc plated nut (Brand may very)",
      "image": "assets/images/HexNut.25in(Zinc).jpg",
      "categories": ["Straps/Hangers", "Threaded Rod"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "1/2 in. Hex Nut (Zinc Plated)",
      "price": 0.50,
      "description": "1/2 in. zinc plated nut (Brand may very)",
      "image": "assets/images/HexNut.5in(Zinc).jpg",
      "categories": ["Straps/Hangers", "Threaded Rod"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "3/8 in. Hex Nut (Zinc Plated)",
      "price": 0.50,
      "description": "3/8 in. zinc plated nut (Brand may very)",
      "image": "assets/images/HexNut.375in(Zinc).jpg",
      "categories": ["Straps/Hangers", "Threaded Rod"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "1/4 in. Washer (Zinc Plated)",
      "price": 0.50,
      "description": "1/4 in. zinc plated nut (Brand may very)",
      "image": "assets/images/Washer.25in(Zinc).jpg",
      "categories": ["Straps/Hangers", "Threaded Rod"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "1/2 in. Washer (Zinc Plated)",
      "price": 0.50,
      "description": "1/2 in. zinc plated nut (Brand may very)",
      "image": "assets/images/Washer.5in(Zinc).jpg",
      "categories": ["Straps/Hangers", "Threaded Rod"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "3/8 in. Washer (Zinc Plated)",
      "price": 0.50,
      "description": "3/8 in. zinc plated nut (Brand may very)",
      "image": "assets/images/Washer.375in(Zinc).jpg",
      "categories": ["Straps/Hangers", "Threaded Rod"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "4 in. Clevis Hanger",
      "price": 10.00,
      "description":
          "4 in. clevis hanger for 1/2 in. threaded rod (Brand may very)",
      "image": "assets/images/ClevisHanger.jpg",
      "categories": ["Straps/Hangers"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "3 in. Clevis Hanger",
      "price": 7.50,
      "description":
          "3 in. clevis hanger for 1/2 in. threaded rod (Brand may very)",
      "image": "assets/images/ClevisHanger.jpg",
      "categories": ["Straps/Hangers"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "2 1/2 in. Clevis Hanger",
      "price": 5.50,
      "description":
          "2 1/2 in. clevis hanger for 1/2 in. threaded rod (Brand may very)",
      "image": "assets/images/ClevisHanger.jpg",
      "categories": ["Straps/Hangers"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "2 in. Clevis Hanger",
      "price": 5.50,
      "description":
          "2 in. clevis hanger for 3/8 in. threaded rod (Brand may very)",
      "image": "assets/images/ClevisHanger.jpg",
      "categories": ["Straps/Hangers"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "1 1/2 in. Clevis Hanger",
      "price": 4.00,
      "description":
          "1 1/2 in. clevis hanger for 3/8 in. threaded rod (Brand may very)",
      "image": "assets/images/ClevisHanger.jpg",
      "categories": ["Straps/Hangers"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "1 1/4 in. Clevis Hanger",
      "price": 4.00,
      "description":
          "1 1/4 in. clevis hanger for 3/8 in. threaded rod (Brand may very)",
      "image": "assets/images/ClevisHanger.jpg",
      "categories": ["Straps/Hangers"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "1 in. Clevis Hanger",
      "price": 4.00,
      "description":
          "1 in. clevis hanger for 3/8 in. threaded rod (Brand may very)",
      "image": "assets/images/ClevisHanger.jpg",
      "categories": ["Straps/Hangers"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "3/4 in. Clevis Hanger",
      "price": 3.50,
      "description":
          "3/4 in. clevis hanger for 3/8 in. threaded rod (Brand may very)",
      "image": "assets/images/ClevisHanger.jpg",
      "categories": ["Straps/Hangers"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "1/2 in. Clevis Hanger",
      "price": 4.00,
      "description":
          "1/2 in. clevis hanger for 3/8 in. threaded rod (Brand may very)",
      "image": "assets/images/ClevisHanger.jpg",
      "categories": ["Straps/Hangers"],
      "specialtyStoreTag": "Straps/Hangers",
    },
    {
      "name": "Pipe Wrench (14 in.)",
      "price": 45.00,
      "description": "Heavy-duty wrench for gripping pipes (Brand may very)",
      "image": "assets/images/PipeWrench.jpg",
      "categories": ["Tools"],
      "specialtyStoreTag": "plumbingTools",
    },
    */
  ];

  List<CartItem> cart = [];

  List<Order> orders = [];

  String searchQuery = "";

  String selectedCategory = "All";

  bool showAddedMessage = false;
  final ScrollController _partsScrollController = ScrollController();

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
            "itemId": item.itemId,
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
            itemId:
                decoded["itemId"]?.toString() ??
                catalogItemIdForTrade("Plumbing", decoded["name"] ?? ""),
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
    await addTradeItemToCart(item, tradeType: "Plumbing", quantity: qty);
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

  @override
  void dispose() {
    _controller.dispose();
    _partsScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalogParts = plumbingCatalogParts.isNotEmpty
        ? plumbingCatalogParts
        : parts;
    List<Map<String, dynamic>> filteredParts = catalogParts.where((item) {
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
              ListTile(
                leading: Icon(Icons.help_outline),
                title: Text("Help"),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => CustomerHelpScreen()),
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
                child: PartsScrollRail(
                  controller: _partsScrollController,
                  child: GridView.builder(
                    controller: _partsScrollController,
                    padding: EdgeInsets.fromLTRB(10, 10, 34, 10),
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
                                description:
                                    filteredParts[index]["description"],
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
