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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // 🔥 STEP 1 — ADD YOUR PUBLISHABLE KEY HERE
  if (!kIsWeb) {
    stripe.Stripe.publishableKey =
        "pk_test_51TQWNvROBLc14B5hkhpybYHZ2wQSL6MjKJynFQsRkl1fsMMCniENxjgz3ZNTkTR3ByhTXoUzau9EI56QWEiPsxoW00LrgMgzp4";
  }

  runApp(MyApp());
}

typedef AddToCart = void Function(int quantity);

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(title: 'Plumbing Parts', home: SplashScreen());
  }
}

class CartItem {
  final String name;
  final double price;
  final String image;
  final String description;
  int quantity;

  CartItem({
    required this.name,
    required this.price,
    required this.image,
    required this.description,
    this.quantity = 1,
  });

  Map<String, dynamic> toJson() {
    return {'name': name, 'price': price, 'image': image, 'quantity': quantity};
  }
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

  Future<Map<String, dynamic>?> findClosestTradeStore(
    Position position,
    String tradeType,
  ) async {
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
    double customerLng,
  ) async {
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
                          ? () async {
                              setState(() {
                                isAddingPaymentMethod = true;
                              });

                              try {
                                final callable = FirebaseFunctions.instance
                                    .httpsCallable('createSetupIntent');

                                final response = await callable.call();
                                final clientSecret =
                                    response.data['clientSecret'];

                                await stripe.Stripe.instance.initPaymentSheet(
                                  paymentSheetParameters:
                                      stripe.SetupPaymentSheetParameters(
                                        setupIntentClientSecret: clientSecret,
                                        merchantDisplayName: 'Apprentice App',
                                      ),
                                );

                                await stripe.Stripe.instance
                                    .presentPaymentSheet();

                                await loadPaymentMethod();

                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text("Payment method added"),
                                  ),
                                );
                              } catch (e) {
                                print("Error: $e");
                              } finally {
                                setState(() {
                                  isAddingPaymentMethod = false;
                                });
                              }
                            }
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
                                await FirebaseFirestore.instance
                                    .collection('orders')
                                    .add({
                                      "customerLat": lat,
                                      "customerLng": lng,
                                      "customerAddress": address,
                                      "customerName":
                                          userData?['name'] ?? "Unknown",
                                      "date": DateTime.now().toIso8601String(),

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
                                              "quantity": item.quantity,
                                            },
                                          )
                                          .toList(),

                                      "subtotal": subtotal,
                                      "deliveryFee": deliveryFee,
                                      "tax": tax,
                                      "total": total,

                                      "status": "Pending",
                                      "tradeType": widget.tradeType,
                                      "eligibleDrivers": nearbyDrivers,
                                      "userId": user.uid,
                                    });

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
                //_roleCard("Store", Icons.store, Colors.green),
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
          return StoreOrdersScreen(storeName: storeName);
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

      if (data['status'] != "OK") {
        print("❌ ROUTE ERROR: ${data['status']}");
        return;
      }
      final leg = data['routes'][0]['legs'][0];

      final distance = leg['distance']['text']; // "5.2 mi"
      final duration = leg['duration']['text']; // "12 mins"
      print("📦 ROUTE DATA: ${data['routes'][0]['legs'][0]}");

      final points = data['routes'][0]['overview_polyline']['points'];
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

      final leg1 = data1['routes'][0]['legs'][0];
      final leg2 = data2['routes'][0]['legs'][0];

      final distance1 = leg1['distance']['value']; // meters
      final distance2 = leg2['distance']['value'];

      final duration1 = leg1['duration']['value']; // seconds
      final duration2 = leg2['duration']['value'];

      final totalDistanceMeters = distance1 + distance2;
      final totalDurationSeconds = duration1 + duration2;

      final distanceMiles = (totalDistanceMeters / 1609).toStringAsFixed(1);

      final durationMinutes = (totalDurationSeconds / 60).round();

      if (data1['status'] != "OK" || data2['status'] != "OK") {
        print("❌ PREVIEW ROUTE ERROR");
        return;
      }

      final points1 = data1['routes'][0]['overview_polyline']['points'];
      final points2 = data2['routes'][0]['overview_polyline']['points'];

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

                    if (storeLat != null &&
                        storeLng != null &&
                        (currentStoreLat != storeLat ||
                            currentStoreLng != storeLng)) {
                      currentStoreLat = storeLat;
                      currentStoreLng = storeLng;
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
                                                await FirebaseFirestore.instance
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
                                              newStatus = "Picked Up";
                                            } else if (currentStatus ==
                                                "Picked Up") {
                                              newStatus = "Delivered";
                                            } else {
                                              setState(
                                                () => isUpdatingStatus = false,
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
                                            } else {
                                              await FirebaseFirestore.instance
                                                  .collection('orders')
                                                  .doc(orderDoc.id)
                                                  .update({
                                                    "status": newStatus,
                                                  });
                                            }

                                            if (newStatus == "Picked Up") {
                                              setState(() {
                                                isPickedUp = true;
                                              });

                                              switchToCustomerRoute(); // 👈 switches map to customer
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

                    return Container(
                      height: 220,
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
            index * 260.0,
            duration: Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        });

        previewRoute(); // 👈 triggers route preview
      },

      child: AnimatedContainer(
        duration: Duration(milliseconds: 300),

        width: previewOrderId == orderId
            ? MediaQuery.of(context).size.width * 0.9
            : 250,

        height: previewOrderId == orderId ? 250 : 120, // ✅ LOCKED

        margin: EdgeInsets.all(10),
        padding: EdgeInsets.all(12),

        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 6),
          ],
        ),

        child: Stack(
          children: [
            // 🔹 CONTENT (top area)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              bottom: 50,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    order['customerName'] ?? 'Customer',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  Text(
                    "Order at ${order['storeName'] ?? 'Store'}",
                    style: TextStyle(color: Colors.grey[700]),
                  ),
                  Text(
                    "Trade: ${order['tradeType'] ?? 'Unknown'}",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.blue,
                    ),
                  ),

                  SizedBox(height: 6),

                  Text("${(order['items'] as List).length} items"),

                  AnimatedPadding(
                    duration: Duration(milliseconds: 250),
                    curve: Curves.easeInOut,
                    padding: EdgeInsets.only(
                      top: previewOrderId == orderId ? 10 : 2,
                    ),
                    child: SizedBox(
                      height: 22,
                      child: AnimatedOpacity(
                        duration: Duration(milliseconds: 200),
                        opacity:
                            (previewOrderId == orderId &&
                                previewDistance != null &&
                                previewDuration != null)
                            ? 1.0
                            : 0.0,
                        child: Text(
                          "$previewDistance • $previewDuration",
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: Colors.green[700],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // 🔹 BACK ARROW (TOP RIGHT) ✅ FIXED
            if (previewOrderId == orderId)
              Positioned(
                top: 0,
                right: 5,
                child: IconButton(
                  icon: Icon(Icons.arrow_back),
                  onPressed: () {
                    setState(() {
                      previewOrderId = null;
                      previewStoreLat = null;
                      previewStoreLng = null;
                      previewCustomerLat = null;
                      previewCustomerLng = null;

                      isPreviewingOrder = false;
                      isOnActiveDelivery = false;

                      // 🔥 CLEAR ROUTES
                      storeRoutePoints = [];

                      // 🔥 RESET FADE
                      customerRouteOpacity = 1.0;
                    });
                  },
                ),
              ),

            // 🔹 BUTTON (BOTTOM)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Padding(
                padding: EdgeInsets.only(
                  right: 50,
                ), // 👈 keeps space without resizing
                child: SizedBox(
                  width: 250,
                  height: 45,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isPreviewingOrder
                          ? Colors.blue
                          : Colors.grey,
                    ),
                    onPressed: isPreviewingOrder
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
                              isOnActiveDelivery = true;
                            });

                            // 🔥 SWITCH TO STORE ROUTE
                            await getRoute();

                            // 🔥 ZOOM IN
                            zoomToStoreRoute();
                          }
                        : null,
                    child: Text("Accept Delivery"),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
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
            .update({"lat": position.latitude, "lng": position.longitude});
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
    },
    {
      "name": "8 oz. Flux",
      "price": 6.00,
      "description":
          "Flux paste used before soldering to clean metal surface (Brand may vary)",
      "image": "assets/images/Flux.jpg",
      "categories": ["Soldering"],
    },
    {
      "name": "Flux Brush",
      "price": 5.00,
      "description": "Brush used to apply flux paste to pipe (Brand may vary)",
      "image": "assets/images/FluxBrush.jpg",
      "categories": ["Soldering"],
    },
    {
      "name": "Plumbers Sanding Cloth 1-1/2 in. x 2 yd.",
      "price": 5.00,
      "description":
          "Sanding cloth for prepping pipe for solder (Brand may vary)",
      "image": "assets/images/PlumbersCloth2yd.jpg",
      "categories": ["Soldering"],
    },
    {
      "name": "14.1 oz. Propane cyliner",
      "price": 6.00,
      "description":
          "Propane cylinder for soldering copper pipe (Brand may vary)",
      "image": "assets/images/BluePropaneTank.png",
      "categories": ["Soldering"],
    },
    {
      "name": "Adjustable Propane Gas Torch",
      "price": 22.00,
      "description":
          "Adjustable propane cylinder torch for soldering copper pipe (Brand may vary)",
      "image": "assets/images/PropaneTorch.png",
      "categories": ["Soldering"],
    },
    {
      "name": "Pipe Cutter",
      "price": 22.00,
      "description": "Adjustable tool for cutting pipe (Brand may vary)",
      "image": "assets/images/AdjustablePipeCutter.png",
      "categories": ["Tools"],
    },
    {
      "name": "Baby Pipe Cutter",
      "price": 22.00,
      "description": "Small adjustable tool for cutting pipe (Brand may vary)",
      "image": "assets/images/BabyAdjustablePipeCutter.png",
      "categories": ["Tools"],
    },
    {
      "name": "Pipe Prepping Tool",
      "price": 13.00,
      "description":
          "Pipe prepping tool for pipes 1/2 in. to 3/4 in. (Brand may vary)",
      "image": "assets/images/PipePreppingTool.jpg",
      "categories": ["Soldering"],
    },
    {
      "name": "1 in. Copper Pressure Coupling With Stop",
      "price": 5.00,
      "description":
          "Copper coupling for connecting 1 in. pipe with internal stops (Brand may vary)",
      "image": "assets/images/CopperNonSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1 in. Copper Slip Coupling",
      "price": 7.50,
      "description":
          "Copper coupling for connecting 1 in. pipe without internal stops (Brand may vary)",
      "image": "assets/images/CopperSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1 in. Copper ProPress Coupling With Stop",
      "price": 12.00,
      "description":
          "Copper coupling for propress connecting 1 in. pipe with internal stops (Brand may vary)",
      "image": "assets/images/CopperProPressNonSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1 in. Copper ProPress Coupling Without Stop",
      "price": 16.50,
      "description":
          "Copper coupling for propress connecting 1 in. pipe without internal stops (Brand may vary)",
      "image": "assets/images/CopperProPressSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1 in. Copper Tee Fitting",
      "price": 24.00,
      "description":
          "Copper all cup tee fitting for connecting 1 in. pipe (Brand may vary)",
      "image": "assets/images/CopperTee.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1 in. Copper ProPress Tee Fitting",
      "price": 21.50,
      "description":
          "Copper tee fitting for connecting 1 in. pipe with propress (Brand may vary)",
      "image": "assets/images/CopperProPressTee.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1 in. Copper 45-Degree Fitting",
      "price": 15.00,
      "description":
          "Copper 45-degree fitting for connecting 1 in. pipe (Brand may vary)",
      "image": "assets/images/Copper45.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1 in. Copper 45-Degree Street Fitting",
      "price": 20.00,
      "description":
          "Copper 45-degree fitting with one male end for connecting 1 in. pipe (Brand may vary)",
      "image": "assets/images/CopperStreet45.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1 in. Copper 45-Degree ProPress Fitting",
      "price": 20.00,
      "description":
          "Copper 45-degree fitting for connecting 1 in. pipe with propress (Brand may vary)",
      "image": "assets/images/CopperProPress45.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1 in. Copper 90-Degree Elbow",
      "price": 9.00,
      "description":
          "Copper 90-degree Non-slip fitting for connecting 1 in. pipe (Brand may vary)",
      "image": "assets/images/Copper90.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1 in. Copper 90-Degree Street Elbow",
      "price": 15.50,
      "description":
          "Copper 90-degree street fitting for connecting 1 in. pipe (Brand may vary)",
      "image": "assets/images/CopperStreet90.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1 in. Copper 90-Degree ProPress Elbow",
      "price": 14.00,
      "description":
          "Copper 90-degree fitting for connecting 1 in. pipe with propress(Brand may vary)",
      "image": "assets/images/CopperProPress90.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
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
    },
    {
      "name": "1 in. Copper Female Threaded Adapter",
      "price": 3.00,
      "description": "1 in. Copper female threaded adapter (Brand may vary)",
      "image": "assets/images/CopperThreadedFemaleAdapter.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1 in. Brass Cap",
      "price": 15.00,
      "description": "1 in. brass threaded cap (Brand may vary)",
      "image": "assets/images/BrassCap.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
    },
    {
      "name": "1 in. Brass Coupling",
      "price": 17.00,
      "description": "1 in. brass threaded coupling (Brand may vary)",
      "image": "assets/images/BrassCoupling.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
    },
    {
      "name": "1 in. Brass 90",
      "price": 42.00,
      "description": "1 in. brass threaded elbow fitting (Brand may vary)",
      "image": "assets/images/Brass90.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
    },
    {
      "name": "1 in. Brass 45",
      "price": 24.00,
      "description": "1 in. brass threaded 45 fitting (Brand may vary)",
      "image": "assets/images/Brass45.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
    },
    {
      "name": "1 in. Brass Street 90",
      "price": 57.50,
      "description":
          "1 in. brass threaded street elbow fitting (Brand may vary)",
      "image": "assets/images/BrassStreet90.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
    },
    {
      "name": "1 in. Brass Street 45",
      "price": 31.50,
      "description": "1 in. brass threaded street 45 fitting (Brand may vary)",
      "image": "assets/images/BrassStreet45.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
    },
    {
      "name": "1 in. Brass Ball Valve(Threaded)",
      "price": 35.00,
      "description":
          "1 Full port brass ball valve with threading on both ends (Brand may vary)",
      "image": "assets/images/ThreadedBallValve.jpg",
      "categories": ["Valves", "Bathroom", "Kitchen"],
    },
    {
      "name": "1 in. Brass Ball Valve(Non-Threaded)",
      "price": 25.00,
      "description":
          "1 Full port brass ball valve with female port on both ends (Brand may very)",
      "image": "assets/images/NonThreadedBallValve.jpg",
      "categories": ["Valves", "Bathroom", "Kitchen"],
    },
    {
      "name": "3/4 in. Copper Pressure Coupling With Stop",
      "price": 2.50,
      "description":
          "Copper coupling for connecting 3/4 in. pipe with internal stops (Brand may vary)",
      "image": "assets/images/CopperNonSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "3/4 in. Copper Slip Coupling",
      "price": 3.00,
      "description":
          "Copper coupling for connecting 3/4 in. pipe without internal stops (Brand may vary)",
      "image": "assets/images/CopperCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "3/4 in. Copper ProPress Coupling With Stop",
      "price": 6.00,
      "description":
          "Copper coupling for propress connecting 3/4 in. pipe with internal stops (Brand may vary)",
      "image": "assets/images/CopperProPressNonSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "3/4 in. Copper ProPress Coupling Without Stop",
      "price": 13.00,
      "description":
          "Copper coupling for propress connecting 3/4 in. pipe without internal stops (Brand may vary)",
      "image": "assets/images/CopperProPressSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "3/4 in. Copper Tee Fitting",
      "price": 6.00,
      "description":
          "Copper all cup tee fitting for connecting 3/4 in. pipe (Brand may vary)",
      "image": "assets/images/CopperTee.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "3/4 in. Copper ProPress Tee Fitting",
      "price": 12.00,
      "description":
          "Copper tee fitting for connecting 3/4 in. pipe with propress (Brand may vary)",
      "image": "assets/images/CopperProPressTee.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "3/4 in. Copper 45-Degree Fitting",
      "price": 5.00,
      "description":
          "Copper 45-degree fitting for connecting 3/4 in. pipe (Brand may vary)",
      "image": "assets/images/Copper45.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "3/4 in. Copper 45-Degree Street Fitting",
      "price": 5.50,
      "description":
          "Copper 45-degree fitting with one male end for connecting 3/4 in. pipe (Brand may vary)",
      "image": "assets/images/CopperStreet45.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "3/4 in. Copper 45-Degree ProPress Fitting",
      "price": 6.50,
      "description":
          "Copper 45-degree fitting for connecting 3/4 in. pipe with propress (Brand may vary)",
      "image": "assets/images/CopperProPress45.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "3/4 in. Copper 90-Degree Elbow",
      "price": 3.50,
      "description":
          "Copper 90-degree Non-slip fitting for connecting 3/4 in. pipe (Brand may vary)",
      "image": "assets/images/Copper90.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "3/4 in. Copper 90-Degree Street Elbow",
      "price": 5.50,
      "description":
          "Copper 90-degree street fitting for connecting 3/4 in. pipe (Brand may vary)",
      "image": "assets/images/CopperStreet90.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "3/4 in. Copper 90-Degree ProPress Elbow",
      "price": 7.00,
      "description":
          "Copper 90-degree fitting for connecting 3/4 in. pipe with propress (Brand may vary)",
      "image": "assets/images/CopperProPress90.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
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
    },
    {
      "name": "3/4 in. Copper Female Threaded Adapter",
      "price": 3.00,
      "description": "3/4 in. Copper female threaded adapter (Brand may vary)",
      "image": "assets/images/CopperThreadedFemaleAdapter.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "3/4 in. Brass Cap",
      "price": 9.50,
      "description": "3/4 in. brass threaded cap (Brand may vary)",
      "image": "assets/images/BrassCap.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
    },
    {
      "name": "3/4 in. Brass Coupling",
      "price": 11.50,
      "description": "3/4 in. brass threaded coupling(Brand may vary)",
      "image": "assets/images/BrassCoupling.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
    },
    {
      "name": "3/4 in. Brass 90",
      "price": 13.00,
      "description": "3/4 in. brass threaded elbow fitting (Brand may vary)",
      "image": "assets/images/Brass90.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
    },
    {
      "name": "3/4 in. Brass 45",
      "price": 3.00,
      "description": "3/4 in. brass threaded 45 fitting (Brand may vary)",
      "image": "assets/images/Brass45.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
    },
    {
      "name": "3/4 in. Brass Street 90",
      "price": 18.00,
      "description":
          "3/4 in. brass threaded street elbow fitting (Brand may vary)",
      "image": "assets/images/BrassStreet90.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
    },
    {
      "name": "3/4 in. Brass Street 45",
      "price": 19.00,
      "description":
          "3/4 in. brass threaded street 45 fitting (Brand may vary)",
      "image": "assets/images/BrassStreet45.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
    },
    {
      "name": "3/4 in. Brass Ball Valve(Threaded)",
      "price": 25.00,
      "description":
          "3/4 Full port brass ball valve with threading on both ends (Brand may vary)",
      "image": "assets/images/ThreadedBallValve.jpg",
      "categories": ["Valves", "Bathroom", "Kitchen"],
    },
    {
      "name": "3/4 in. Brass Ball Valve(Non-Threaded)",
      "price": 20.00,
      "description":
          "3/4 Full port brass ball valve with female port on both ends (Brand may very)",
      "image": "assets/images/NonThreadedBallValve.jpg",
      "categories": ["Valves", "Bathroom", "Kitchen"],
    },
    {
      "name": "1/2 in. Copper Pressure Coupling With Stop",
      "price": 1.50,
      "description":
          "Copper coupling for connecting 1/2 in. pipe with internal stops (Brand may vary)",
      "image": "assets/images/CopperNonSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1/2 in. Copper Slip Coupling",
      "price": 1.50,
      "description":
          "Copper coupling for connecting 1/2 in. pipe without internal stops (Brand may vary)",
      "image": "assets/images/CopperSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1/2 in. Copper ProPress Coupling With Stop",
      "price": 4.00,
      "description":
          "Copper coupling for propress connecting 1/2 in. pipe with internal stops (Brand may vary)",
      "image": "assets/images/CopperProPressNonSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1/2 in. Copper ProPress Coupling Without Stop",
      "price": 10.00,
      "description":
          "Copper coupling for propress connecting 1/2 in. pipe without internal stops (Brand may vary)",
      "image": "assets/images/CopperProPressSlipCoupling.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1/2 in. Copper Tee Fitting",
      "price": 2.50,
      "description":
          "Copper all cup tee fitting for connecting 1/2 in. pipe (Brand may vary)",
      "image": "assets/images/CopperTee.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1/2 in. Copper ProPress Tee Fitting",
      "price": 7.00,
      "description":
          "Copper tee fitting for connecting 1/2 in. pipe with propress (Brand may vary)",
      "image": "assets/images/CopperProPressTee.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1/2 in. Copper 45-Degree Fitting",
      "price": 3.00,
      "description":
          "Copper 45-degree fitting for connecting 1/2 in. pipe (Brand may vary)",
      "image": "assets/images/Copper45.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1/2 in. Copper 45-Degree Street Fitting",
      "price": 3.50,
      "description":
          "Copper 45-degree fitting with one male end for connecting 1/2 in. pipe (Brand may vary)",
      "image": "assets/images/CopperStreet45.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1/2 in. Copper 45-Degree ProPress Fitting",
      "price": 5.50,
      "description":
          "Copper 45-degree fitting for connecting 1/2 in. pipe with propress (Brand may vary)",
      "image": "assets/images/CopperProPress45.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1/2 in. Copper 90-Degree Elbow",
      "price": 2.00,
      "description":
          "Copper 90-degree Non-slip fitting for connecting 1/2 in. pipe (Brand may vary)",
      "image": "assets/images/Copper90.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1/2 in. Copper 90-Degree Street Elbow",
      "price": 2.50,
      "description":
          "Copper 90-degree street fitting for connecting 1/2 in. pipe (Brand may vary)",
      "image": "assets/images/CopperStreet90.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1/2 in. Copper 90-Degree ProPress Elbow",
      "price": 4.50,
      "description":
          "Copper 90-degree fitting for connecting 1/2 in. pipe with propress (Brand may vary)",
      "image": "assets/images/CopperProPress90.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
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
    },
    {
      "name": "1/2 in. Copper Female Threaded Adapter",
      "price": 3.00,
      "description": "1/2 in. Copper female threaded adapter (Brand may vary)",
      "image": "assets/images/CopperThreadedFemaleAdapter.jpg",
      "categories": ["Copper Fittings", "Bathroom", "Kitchen"],
    },
    {
      "name": "1/2 in. Brass Cap",
      "price": 3.00,
      "description": "1/2 in. brass threaded cap (Brand may vary)",
      "image": "assets/images/BrassCap.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
    },
    {
      "name": "1/2 in. Brass Coupling",
      "price": 8.50,
      "description": "1/2 in. brass threaded coupling (Brand may vary)",
      "image": "assets/images/BrassCoupling.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
    },
    {
      "name": "1/2 in. Brass 90",
      "price": 19.50,
      "description": "1/2 in. brass threaded elbow fitting (Brand may vary)",
      "image": "assets/images/Brass90.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
    },
    {
      "name": "1/2 in. Brass 45",
      "price": 10.00,
      "description": "1/2 in. brass threaded 45 fitting (Brand may vary)",
      "image": "assets/images/Brass45.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
    },
    {
      "name": "1/2 in. Brass Street 90",
      "price": 13.00,
      "description":
          "1/2 in. brass threaded street elbow fitting (Brand may vary)",
      "image": "assets/images/BrassStreet90.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
    },
    {
      "name": "1/2 in. Brass Street 45",
      "price": 14.00,
      "description":
          "1/2 in. brass threaded street 45 fitting (Brand may vary)",
      "image": "assets/images/BrassStreet45.jpg",
      "categories": ["Brass", "Bathroom", "Kitchen"],
    },
    {
      "name": "1/2 in. Brass Ball Valve(Threaded)",
      "price": 16.00,
      "description":
          "1/2 Full port brass ball valve with threading on both ends (Brand may vary)",
      "image": "assets/images/ThreadedBallValve.jpg",
      "categories": ["Valves", "Bathroom", "Kitchen"],
    },
    {
      "name": "1/2 in. Brass Ball Valve(Non-Threaded)",
      "price": 20.00,
      "description":
          "1/2 in. Full port brass ball valve with female port on both ends (Brand may very)",
      "image": "assets/images/NonThreadedBallValve.jpg",
      "categories": ["Valves", "Bathroom", "Kitchen"],
    },
    //Reducers
    {
      "name": "2 in. x 1 1/2 in. Copper Reducer",
      "price": 20.00,
      "description":
          "Copper Fitting for reducing from 2in. copper pipe to 1 1/2in. copper pipe (Brand may very)",
      "image": "assets/images/Copper1inTo.75inReducer.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "2 in. x 1 in. Copper Reducer",
      "price": 20.00,
      "description":
          "Copper Fitting for reducing from 2in. copper pipe to 1in. copper pipe (Brand may very)",
      "image": "assets/images/Copper2inTo1inReducer.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1 1/2 in. x 3/4 in. Copper Reducer",
      "price": 20.00,
      "description":
          "Copper Fitting for reducing from 1 1/2in. copper pipe to 3/4in. copper pipe (Brand may very)",
      "image": "assets/images/Copper2inTo1inReducer.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1 in. x 3/4 in. Copper Reducer",
      "price": 20.00,
      "description":
          "Copper Fitting for reducing from 1in. copper pipe to 3/4in. copper pipe (Brand may very)",
      "image": "assets/images/Copper1inTo.75inReducer.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1 in. x 1/2 in. Copper Reducer",
      "price": 20.00,
      "description":
          "Copper Fitting for reducing from 1in. copper pipe to 1/2in. copper pipe (Brand may very)",
      "image": "assets/images/Copper2inTo1inReducer.jpg",
      "categories": ["Copper Fittings"],
    },
    //Reducing Tees
    {
      "name": "2 in. x 2 in. x 1 in. Copper Reducing Tee",
      "price": 20.00,
      "description":
          "2in. x 2in. x 1in. Copper Fitting for reducing from 2in. copper pipe to 1in. pipe (Brand may very)",
      "image": "assets/images/Copper1inx1inx.5inTee.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "2 in. x 2 in. x 1 in. ProPress Copper Reducing Tee",
      "price": 20.00,
      "description":
          "2in. x 2in. x 1in. Copper Fitting for reducing from 2in. copper pipe to 1in. pipe with a propress (Brand may very)",
      "image": "assets/images/Copper1inx1inx.5inProPressTee.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "2 in. x 1 in. x 2 in. Copper Reducing Tee",
      "price": 20.00,
      "description":
          "2in. x 1in. x 2in. Copper Fitting for reducing from 2in. copper pipe to 1in. pipe (Brand may very)",
      "image": "assets/images/Copper1inx.5inx1inTee.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "2 in. x 1 in. x 2 in. ProPress Copper Reducing Tee",
      "price": 20.00,
      "description":
          "2in. x 1in. x 2in. Copper Fitting for reducing from 2in. copper pipe to 1in. pipe with a propress (Brand may very)",
      "image": "assets/images/Copper1inx.5inx1inProPressTee.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "2 in. x 1 in. x 1 in. Copper Reducing Tee",
      "price": 20.00,
      "description":
          "2in. x 1in. x 1in. Copper Fitting for reducing from 2in. copper pipe to 1in. pipe (Brand may very)",
      "image": "assets/images/Copper1inx.5inx.5inTee.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "2 in. x 1 in. x 1 in. ProPress Copper Reducing Tee",
      "price": 20.00,
      "description":
          "2in. x 1in. x 1in. Copper Fitting for reducing from 2in. copper pipe to 1in. pipe with a propress (Brand may very)",
      "image": "assets/images/Copper1inx.5inx.5inProPressTee.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1 in. x 1 in. x 2 in. Copper Reducing Tee",
      "price": 20.00,
      "description":
          "1in. x 1in. x 2in. Copper Fitting for reducing from 2in. copper pipe to 1in. pipe (Brand may very)",
      "image": "assets/images/Copper.5inx.5inx1inTee.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1 in. x 1 in. x 2 in. ProPress Copper Reducing Tee",
      "price": 20.00,
      "description":
          "1in. x 1in. x 2in. Copper Fitting for reducing from 2in. copper pipe to 1in. pipe with a propress (Brand may very)",
      "image": "assets/images/Copper.5inx.5inx1inProPressTee.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "2 in. x 2 in. x 1/2 in. Copper Reducing Tee",
      "price": 20.00,
      "description":
          "2in. x 2in. x 1/2in. Copper Fitting for reducing from 2in. copper pipe to 1/2in. pipe (Brand may very)",
      "image": "assets/images/Copper2inx2inx.5inTee.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "2 in. x 2 in. x 1/2 in. ProPress Copper Reducing Tee",
      "price": 20.00,
      "description":
          "2in. x 2in. x 1/2in. Copper Fitting for reducing from 2in. copper pipe to 1/2in. pipe with a propress (Brand may very)",
      "image": "assets/images/Copper2inx2inx.5inProPressTee.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1 in. x 1 in. x 3/4 in. Copper Reducing Tee",
      "price": 20.00,
      "description":
          "2in. x 2in. x 2/4in. Copper Fitting for reducing from 1in. copper pipe to 3/4in. pipe (Brand may very)",
      "image": "assets/images/Copper1inx1inx.75inTee.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1 in. x 1 in. x 3/4 in. ProPress Copper Reducing Tee",
      "price": 20.00,
      "description":
          "1in. x 1in. x 3/4in. Copper Fitting for reducing from 1in. copper pipe to 3/4in. pipe with a propress (Brand may very)",
      "image": "assets/images/Copper1inx1inx.75inProPressTee.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "3/4 in. x 3/4 in. x 1 in.  Copper Reducing Tee",
      "price": 20.00,
      "description":
          "3/4in. x 3/4in. x 1in. Copper Fitting for reducing from 1in. copper pipe to 3/4in. pipe (Brand may very)",
      "image": "assets/images/Copper.75inx.75inx1inTee.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "3/4 in. x 3/4 in. x 1 in. ProPress Copper Reducing Tee",
      "price": 20.00,
      "description":
          "3/4in. x 3/4in. x 1in. Copper Fitting for reducing from 1in. copper pipe to 3/4in. pipe with a propress (Brand may very)",
      "image": "assets/images/Copper.75inx.75inx1inProPressTee.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1 in. x 1 in. x 1/2 in. Copper Reducing Tee",
      "price": 20.00,
      "description":
          "1in. x 1in. x 1/2in. Copper Fitting for reducing from 1in. copper pipe to 1/2in. pipe (Brand may very)",
      "image": "assets/images/Copper1inx1inx.5inTee.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1 in. x 1 in. x 1/2 in. ProPress Copper Reducing Tee",
      "price": 20.00,
      "description":
          "1in. x 1in. x 1/2in. Copper Fitting for reducing from 1in. copper pipe to 1/2in. pipe with a propress (Brand may very)",
      "image": "assets/images/Copper1inx1inx.5inProPressTee.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1 in. x 1/2 in. x 1/2 in. Copper Reducing Tee",
      "price": 20.00,
      "description":
          "1in. x 1/2in. x 1/2in. Copper Fitting for reducing from 1in. copper pipe to 1/2in. pipe (Brand may very)",
      "image": "assets/images/Copper1inx.5inx.5inTee.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1 in. x 1/2 in. x 1/2 in. ProPress Copper Reducing Tee",
      "price": 20.00,
      "description":
          "1in. x 1/2in. x 1/2in. Copper Fitting for reducing from 1in. copper pipe to 1/2in. pipe with a propress (Brand may very)",
      "image": "assets/images/Copper1inx.5inx.5inProPressTee.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1/2 in. x 1/2 in. x 1 in. Copper Reducing Tee",
      "price": 20.00,
      "description":
          "1/2in. x 1/2in. x 1in. Copper Fitting for reducing from 1in. copper pipe to 1/2in. pipe (Brand may very)",
      "image": "assets/images/Copper.5inx.5inx1inTee.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1/2 in. x 1/2 in. x 1 in. ProPress Copper Reducing Tee",
      "price": 20.00,
      "description":
          "1/2in. x 1/2in. x 1in. Copper Fitting for reducing from 1in. copper pipe to 1/2in. pipe with a propress (Brand may very)",
      "image": "assets/images/Copper.5inx.5inx1inProPressTee.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "3/4 in. x 1/2 in. x 3/4 in. Copper Reducing Tee",
      "price": 20.00,
      "description":
          "3/4in. x 1/2in. x 3/4in. Copper Fitting for reducing from 3/4in. copper pipe to 1/2in. pipe (Brand may very)",
      "image": "assets/images/Copper1inx.75inx1inTee.jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "2 in. Swing Check Valve (Non-Threaded)",
      "price": 20.00,
      "description": "2in. swing check valve (Brand may very)",
      "image": "assets/images/SwingCheckValve(NonThreaded).jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "2 in. Swing Check Valve (Threaded)",
      "price": 20.00,
      "description": "2in. swing check valve (Brand may very)",
      "image": "assets/images/SwingCheckValve(Threaded).jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1 1/2 in. Swing Check Valve (Non-Threaded)",
      "price": 20.00,
      "description": "1 1/2 in. swing check valve (Brand may very)",
      "image": "assets/images/SwingCheckValve(NonThreaded).jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1 1/2 in. Swing Check Valve (Threaded)",
      "price": 20.00,
      "description": "1 1/2 in. swing check valve (Brand may very)",
      "image": "assets/images/SwingCheckValve(Threaded).jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1 in. Swing Check Valve (Non-Threaded)",
      "price": 20.00,
      "description": "1in. swing check valve (Brand may very)",
      "image": "assets/images/SwingCheckValve(NonThreaded).jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1 in. Swing Check Valve (Threaded)",
      "price": 20.00,
      "description": "1in. swing check valve (Brand may very)",
      "image": "assets/images/SwingCheckValve(Threaded).jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "3/4 in. Swing Check Valve (Non-Threaded)",
      "price": 20.00,
      "description": "3/4 in. swing check valve (Brand may very)",
      "image": "assets/images/SwingCheckValve(NonThreaded).jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "3/4 in. Swing Check Valve (Threaded)",
      "price": 20.00,
      "description": "3/4 in. swing check valve (Brand may very)",
      "image": "assets/images/SwingCheckValve(Threaded).jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1/2 in. Swing Check Valve (Non-Threaded)",
      "price": 20.00,
      "description": "1/2 in. swing check valve (Brand may very)",
      "image": "assets/images/SwingCheckValve(NonThreaded).jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1/2 in. Swing Check Valve (Threaded)",
      "price": 20.00,
      "description": "1/2 in. swing check valve (Brand may very)",
      "image": "assets/images/SwingCheckValve(Threaded).jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "2 in. Spring Check Valve (Non-Threaded)",
      "price": 20.00,
      "description": "2in. swing check valve (Brand may very)",
      "image": "assets/images/SpringCheckValve(NonThreaded).jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "2 in. Spring Check Valve (Threaded)",
      "price": 20.00,
      "description": "2in. swing check valve (Brand may very)",
      "image": "assets/images/SpringCheckValve(Threaded).jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1 1/2 in. Spring Check Valve (Non-Threaded)",
      "price": 20.00,
      "description": "1 1/2 in. swing check valve (Brand may very)",
      "image": "assets/images/SpringCheckValve(NonThreaded).jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1 1/2 in. Spring Check Valve (Threaded)",
      "price": 20.00,
      "description": "1 1/2 in. swing check valve (Brand may very)",
      "image": "assets/images/SpringCheckValve(Threaded).jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1 in. Spring Check Valve (Non-Threaded)",
      "price": 20.00,
      "description": "1in. swing check valve (Brand may very)",
      "image": "assets/images/SpringCheckValve(NonThreaded).jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1 in. Spring Check Valve (Threaded)",
      "price": 20.00,
      "description": "1in. swing check valve (Brand may very)",
      "image": "assets/images/SpringCheckValve(Threaded).jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "3/4 in. Spring Check Valve (Non-Threaded)",
      "price": 20.00,
      "description": "3/4 in. swing check valve (Brand may very)",
      "image": "assets/images/SpringCheckValve(NonThreaded).jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "3/4 in. Spring Check Valve (Threaded)",
      "price": 20.00,
      "description": "3/4 in. swing check valve (Brand may very)",
      "image": "assets/images/SpringCheckValve(Threaded).jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1/2 in. Spring Check Valve (Non-Threaded)",
      "price": 20.00,
      "description": "1/2 in. swing check valve (Brand may very)",
      "image": "assets/images/SpringCheckValve(NonThreaded).jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "1/2 in. Spring Check Valve (Threaded)",
      "price": 20.00,
      "description": "1/2 in. swing check valve (Brand may very)",
      "image": "assets/images/SpringCheckValve(Threaded).jpg",
      "categories": ["Copper Fittings"],
    },
    {
      "name": "Shower Valve(Threaded)",
      "price": 20.00,
      "description": "1/2 in. threaded port shower valve (Brand may very)",
      "image": "assets/images/ShowerValve(Threaded).jpg",
      "categories": ["Valves", "Bathroom"],
    },
    {
      "name": "Shower Valve(Non-Threaded)",
      "price": 20.00,
      "description": "1/2 in. non threaded port shower valve (Brand may very)",
      "image": "assets/images/ShowerValve(NonThreaded).jpg",
      "categories": ["Valves", "Bathroom"],
    },
    {
      "name": "Speedy Valve 1/2 in. Compression Outlet",
      "price": 10.00,
      "description":
          "Toilet water supply shut off valve with compression fittings and 1/2 in. outlet to tank (Brand may very)",
      "image": "assets/images/SpeedyValve.jpg",
      "categories": ["Bathroom", "Valves"],
    },
    {
      "name": "Speedy Valve 3/8 in. Compression Outlet",
      "price": 10.00,
      "description":
          "Toilet water supply shut off valve with compression fittings and 3/8 in. outlet to tank (Brand may very)",
      "image": "assets/images/SpeedyValve.jpg",
      "categories": ["Bathroom", "Valves"],
    },
    {
      "name": "Sink Supply Line (3/8 in. x 1/2 in. FIP)",
      "price": 10.00,
      "description":
          "3/8 in. compression x 1/2 in. FIP sink supply line 9 or 12 inches long depending on stock (Brand may very)",
      "image": "assets/images/SinkSupplyLineFIP.jpg",
      "categories": ["Bathroom", "Kitchen"],
    },
    {
      "name": "Sink Supply Line (3/8 in. x 1/2 in. FIP x 20 in.)",
      "price": 12.00,
      "description":
          "3/8 in. compression x 1/2 in. FIP sink supply line 20 in. long (Brand may very)",
      "image": "assets/images/SinkSupplyLineFIP.jpg",
      "categories": ["Bathroom", "Kitchen"],
    },
    {
      "name": "Sink Supply Line (3/8 in. x 3/8 in.)",
      "price": 10.00,
      "description":
          "3/8 in. compression x 3/8 in. compression sink supply line 9 or 12 inches long depending on stock (Brand may very)",
      "image": "assets/images/SinkSupplyLine.jpg",
      "categories": ["Bathroom", "Kitchen"],
    },
    {
      "name": "Sink Supply Line (3/8 in. x 3/8 in. x 20 in.)",
      "price": 12.00,
      "description":
          "3/8 in. compression x 3/8 in. compression sink supply line 20 in. long (Brand may very)",
      "image": "assets/images/SinkSupplyLine.jpg",
      "categories": ["Bathroom", "Kitchen"],
    },
    {
      "name": "0 Washers (Pack of 10)",
      "price": 5.00,
      "description":
          "Washers for hot/cold water valves on a sink (Brand may very)",
      "image": "assets/images/0Washers.jpg",
      "categories": ["Sinks"],
    },
    {
      "name": "00 Washers (Pack of 10)",
      "price": 5.00,
      "description":
          "Washers for hot/cold water valves on a sink (Brand may very)",
      "image": "assets/images/00Washers.jpg",
      "categories": ["Sinks"],
    },
    {
      "name": "Toilet Supply Line (1/2 in. x 7/8 in.)",
      "price": 10.00,
      "description":
          "1/2 in. compression connector x 7/8 in. Toilet supply line 9 or 12 inches long depending on stock (Brand may very)",
      "image": "assets/images/CompressionToiletSupplyLine.jpg",
      "categories": ["Bathroom"],
    },
    {
      "name": "Toilet Supply Line (1/2 in. FIP x 7/8 in.)",
      "price": 10.00,
      "description":
          "1/2 in. FIP  x 7/8 in. Toilet supply line 9 or 12 inches long depending on stock (Brand may very)",
      "image": "assets/images/FIPToiletSupplyLine.jpg",
      "categories": ["Bathroom"],
    },
    {
      "name": "Toilet Supply Line (1/2 in. x 7/8 in. x 20 in.)",
      "price": 12.00,
      "description":
          "1/2 in. compression x 7/8 in. Toilet supply line 20 in. long (Brand may very)",
      "image": "assets/images/CompressionToiletSupplyLine.jpg",
      "categories": ["Bathroom"],
    },
    {
      "name": "Toilet Supply Line (1/2 in. FIP x 7/8 in. x 20 in.)",
      "price": 12.00,
      "description":
          "1/2 in. FIP x 7/8 in. Toilet supply line 20 in. long (Brand may very)",
      "image": "assets/images/FIPToiletSupplyLine.jpg",
      "categories": ["Bathroom"],
    },
    {
      "name": "Toilet Supply Line (3/8 in. x 7/8 in.)",
      "price": 10.00,
      "description":
          "3/8 in. compression x 7/8 in. Toilet supply line 9 or 12 inches long depending on stock (Brand may very)",
      "image": "assets/images/ToiletSupplyLine.jpg",
      "categories": ["Bathroom"],
    },
    {
      "name": "Toilet Supply Line (3/8 in. x 7/8 in. x 20 in.)",
      "price": 12.00,
      "description":
          "3/8 in. compression x 7/8 in. Toilet supply line 20 in. long (Brand may very)",
      "image": "assets/images/ToiletSupplyLine.jpg",
      "categories": ["Bathroom"],
    },
    {
      "name": "Toilet Handle With Chain",
      "price": 12.00,
      "description":
          "Handle with chain mechanism for toilet with flapper (Brand may very)",
      "image": "assets/images/ToiletHandle.jpg",
      "categories": ["Bathroom"],
    },
    {
      "name": "Toilet Flapper",
      "price": 12.00,
      "description": "Rubber flapper for toilet flush  (Brand may very)",
      "image": "assets/images/Flapper.jpg",
      "categories": ["Bathroom"],
    },
    {
      "name": "3 in. Black Iron Pipe Coupling",
      "price": 2.50,
      "description": "3 in. Black iron coupling for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCoupling.jpg",
      "categories": ["Couplings", "Gas", "Black Steel Pipe"],
    },
    {
      "name": "3 in. Black Iron Pipe Cap",
      "price": 2.50,
      "description":
          "3 in. Threaded black iron cap for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCap.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "3 in. Black Iron Pipe 45 degree Elbow",
      "price": 4.00,
      "description":
          "3 in. black iron 45 degree fitting for gas line (Brand may very)",
      "image": "assets/images/BlackPipe45.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "3 in. Black Iron Pipe 90 degree Elbow",
      "price": 4.00,
      "description":
          "3 in. black iron 90 degree elbow for gas line (Brand may very)",
      "image": "assets/images/BlackPipe90.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "3 in. Black Iron Pipe Nipple",
      "price": 2.50,
      "description": "3 in. black steel nipple for gas line (Brand may very)",
      "image": "assets/images/BlackPipeNipple.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "3 in. Black Iron Pipe Tee",
      "price": 2.50,
      "description":
          "3 in. black iron tee for connecting threaded steel pipe (Brand may very)",
      "image": "assets/images/BlackPipeTee.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "3 in. Black Iron Pipe Union Fiting",
      "price": 11.00,
      "description":
          "3 in. black iron Union fitting for connecting two threaded steel pipes (Brand may very)",
      "image": "assets/images/BlackPipeUnion.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
    },
    {
      "name": "2 1/2  in. Black Iron Pipe Coupling",
      "price": 2.50,
      "description":
          "2 1/2  in. Black iron coupling for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCoupling.jpg",
      "categories": ["Couplings", "Gas", "Black Steel Pipe"],
    },
    {
      "name": "2 1/2  in. Black Iron Pipe Cap",
      "price": 2.50,
      "description":
          "2 1/2  in. Threaded black iron cap for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCap.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "2 1/2  in. Black Iron Pipe 45 degree Elbow",
      "price": 4.00,
      "description":
          "2 1/2  in. black iron 45 degree fitting for gas line (Brand may very)",
      "image": "assets/images/BlackPipe45.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "2 1/2  in. Black Iron Pipe 90 degree Elbow",
      "price": 4.00,
      "description":
          "2 1/2  in. black iron 90 degree elbow for gas line (Brand may very)",
      "image": "assets/images/BlackPipe90.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "2 1/2  in. Black Iron Pipe Nipple",
      "price": 2.50,
      "description":
          "2 1/2  in. black steel nipple for gas line (Brand may very)",
      "image": "assets/images/BlackPipeNipple.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "2 1/2  in. Black Iron Pipe Tee",
      "price": 2.50,
      "description":
          "2 1/2  in. black iron tee for connecting threaded steel pipe (Brand may very)",
      "image": "assets/images/BlackPipeTee.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "2 1/2  in. Black Iron Pipe Union Fiting",
      "price": 11.00,
      "description":
          "2 1/2 in. black iron Union fitting for connecting two threaded steel pipes (Brand may very)",
      "image": "assets/images/BlackPipeUnion.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
    },
    {
      "name": "2 in. Black Iron Pipe Coupling",
      "price": 2.50,
      "description": "2 in. Black iron coupling for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCoupling.jpg",
      "categories": ["Couplings", "Gas", "Black Steel Pipe"],
    },
    {
      "name": "2 in. Black Iron Pipe Cap",
      "price": 2.50,
      "description":
          "2 in. Threaded black iron cap for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCap.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "2 in. Black Iron Pipe 45 degree Elbow",
      "price": 4.00,
      "description":
          "2 in. black iron 45 degree fitting for gas line (Brand may very)",
      "image": "assets/images/BlackPipe45.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "2 in. Black Iron Pipe 90 degree Elbow",
      "price": 4.00,
      "description":
          "2 in. black iron 90 degree elbow for gas line (Brand may very)",
      "image": "assets/images/BlackPipe90.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "2 in. Black Iron Pipe Nipple",
      "price": 2.50,
      "description": "2 in. black steel nipple for gas line (Brand may very)",
      "image": "assets/images/BlackPipeNipple.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "2 in. Black Iron Pipe Tee",
      "price": 2.50,
      "description":
          "2 in. black iron tee for connecting threaded steel pipe (Brand may very)",
      "image": "assets/images/BlackPipeTee.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "2 in. Black Iron Pipe Union Fiting",
      "price": 11.00,
      "description":
          "2 in. black iron Union fitting for connecting two threaded steel pipes (Brand may very)",
      "image": "assets/images/BlackPipeUnion.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
    },
    {
      "name": "1 1/2 in. Black Iron Pipe Coupling",
      "price": 2.50,
      "description":
          "1 1/2 in. Black iron coupling for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCoupling.jpg",
      "categories": ["Couplings", "Gas", "Black Steel Pipe"],
    },
    {
      "name": "1 1/2 in. Black Iron Pipe Cap",
      "price": 2.50,
      "description":
          "1 1/2 in. Threaded black iron cap for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCap.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "1 1/2 in. Black Iron Pipe 45 degree Elbow",
      "price": 4.00,
      "description":
          "1 1/2 in. black iron 45 degree fitting for gas line (Brand may very)",
      "image": "assets/images/BlackPipe45.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "1 1/2 in. Black Iron Pipe 90 degree Elbow",
      "price": 4.00,
      "description":
          "1 1/2 in. black iron 90 degree elbow for gas line (Brand may very)",
      "image": "assets/images/BlackPipe90.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "1 1/2 in. Black Iron Pipe Nipple",
      "price": 2.50,
      "description":
          "1 1/2 in. black steel nipple for gas line (Brand may very)",
      "image": "assets/images/BlackPipeNipple.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "1 1/2 in. Black Iron Pipe Tee",
      "price": 2.50,
      "description":
          "1 1/2 in. black iron tee for connecting threaded steel pipe (Brand may very)",
      "image": "assets/images/BlackPipeTee.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "1 1/2 in. Black Iron Pipe Union Fiting",
      "price": 11.00,
      "description":
          "1 1/2 in. black iron Union fitting for connecting two threaded steel pipes (Brand may very)",
      "image": "assets/images/BlackPipeUnion.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
    },
    {
      "name": "1 1/4 in. Black Iron Pipe Coupling",
      "price": 2.50,
      "description":
          "1 1/4 in. Black iron coupling for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCoupling.jpg",
      "categories": ["Couplings", "Gas", "Black Steel Pipe"],
    },
    {
      "name": "1 1/4 in. Black Iron Pipe Cap",
      "price": 2.50,
      "description":
          "1 1/4 in. Threaded black iron cap for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCap.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "1 1/4 in. Black Iron Pipe 45 degree Elbow",
      "price": 4.00,
      "description":
          "1 1/4 in. black iron 45 degree fitting for gas line (Brand may very)",
      "image": "assets/images/BlackPipe45.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "1 1/4 in. Black Iron Pipe 90 degree Elbow",
      "price": 4.00,
      "description":
          "1 1/4 in. black iron 90 degree elbow for gas line (Brand may very)",
      "image": "assets/images/BlackPipe90.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "1 1/4 in. Black Iron Pipe Nipple",
      "price": 2.50,
      "description":
          "1 1/4 in. black steel nipple for gas line (Brand may very)",
      "image": "assets/images/BlackPipeNipple.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "1 1/4 in. Black Iron Pipe Tee",
      "price": 2.50,
      "description":
          "1 1/4 in. black iron tee for connecting threaded steel pipe (Brand may very)",
      "image": "assets/images/BlackPipeTee.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "1 1/4 in. Black Iron Pipe Union Fiting",
      "price": 11.00,
      "description":
          "1 1/4 in. black iron Union fitting for connecting two threaded steel pipes (Brand may very)",
      "image": "assets/images/BlackPipeUnion.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
    },
    {
      "name": "1 in. Black Iron Pipe Coupling",
      "price": 2.50,
      "description": "1 in. Black iron coupling for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCoupling.jpg",
      "categories": ["Couplings", "Gas", "Black Steel Pipe"],
    },
    {
      "name": "1 in. Black Iron Pipe Cap",
      "price": 2.50,
      "description":
          "1 in. Threaded black iron cap for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCap.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "1 in. Black Iron Pipe 45 degree Elbow",
      "price": 4.00,
      "description":
          "1 in. black iron 45 degree fitting for gas line (Brand may very)",
      "image": "assets/images/BlackPipe45.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "1 in. Black Iron Pipe 90 degree Elbow",
      "price": 4.00,
      "description":
          "1 in. black iron 90 degree elbow for gas line (Brand may very)",
      "image": "assets/images/BlackPipe90.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "1 in. Black Iron Pipe Nipple",
      "price": 2.50,
      "description": "1 in. black steel nipple for gas line (Brand may very)",
      "image": "assets/images/BlackPipeNipple.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "1 in. Black Iron Pipe Tee",
      "price": 2.50,
      "description":
          "1 in. black iron tee for connecting threaded steel pipe (Brand may very)",
      "image": "assets/images/BlackPipeTee.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "1 in. Black Iron Pipe Union Fiting",
      "price": 11.00,
      "description":
          "1 in. black iron Union fitting for connecting two threaded steel pipes (Brand may very)",
      "image": "assets/images/BlackPipeUnion.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
    },
    {
      "name": "3/4 in. Black Iron Pipe Coupling",
      "price": 2.50,
      "description":
          "3/4 in. Black iron coupling for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCoupling.jpg",
      "categories": ["Couplings", "Gas", "Black Steel Pipe"],
    },
    {
      "name": "1/2 in. Black Iron Pipe Cap",
      "price": 2.50,
      "description":
          "3/4 in. Threaded black iron cap for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCap.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "3/4 in. Black Iron Pipe 45 degree Elbow",
      "price": 4.00,
      "description":
          "3/4 in. black iron 45 degree fitting for gas line (Brand may very)",
      "image": "assets/images/BlackPipe45.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "3/4 in. Black Iron Pipe 90 degree Elbow",
      "price": 4.00,
      "description":
          "3/4 in. black iron 90 degree elbow for gas line (Brand may very)",
      "image": "assets/images/BlackPipe90.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "3/4 in. Black Iron Pipe Nipple",
      "price": 2.50,
      "description": "3/4 in. black steel nipple for gas line (Brand may very)",
      "image": "assets/images/BlackPipeNipple.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "3/4 in. Black Iron Pipe Tee",
      "price": 2.50,
      "description":
          "3/4 in. black iron tee for connecting threaded steel pipe (Brand may very)",
      "image": "assets/images/BlackPipeTee.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "3/4 in. Black Iron Pipe Union Fiting",
      "price": 11.00,
      "description":
          "3/4 in. black iron Union fitting for connecting two threaded steel pipes (Brand may very)",
      "image": "assets/images/BlackPipeUnion.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
    },
    {
      "name": "1/2 in. Black Iron Pipe Coupling",
      "price": 2.50,
      "description":
          "1/2 in. Black iron coupling for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCoupling.jpg",
      "categories": ["Couplings", "Gas", "Black Steel Pipe"],
    },
    {
      "name": "1/2 in. Black Iron Pipe Cap",
      "price": 2.50,
      "description":
          "1/2 in. Threaded black iron cap for gas line (Brand may very)",
      "image": "assets/images/BlackPipeCap.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "1/2 in. Black Iron Pipe 45 degree Elbow",
      "price": 4.00,
      "description":
          "1/2 in. black iron 45 degree fitting for gas line (Brand may very)",
      "image": "assets/images/BlackPipe45.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "1/2 in. Black Iron Pipe 90 degree Elbow",
      "price": 4.00,
      "description":
          "1/2 in. black iron 90 degree elbow for gas line (Brand may very)",
      "image": "assets/images/BlackPipe90.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "1/2 in. Black Iron Pipe Nipple",
      "price": 2.50,
      "description": "1/2 in. black steel nipple for gas line (Brand may very)",
      "image": "assets/images/BlackPipeNipple.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "1/2 in. Black Iron Pipe Tee",
      "price": 2.50,
      "description":
          "1/2 in. black iron tee for connecting threaded steel pipe (Brand may very)",
      "image": "assets/images/BlackPipeTee.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "1/2 in. Black Iron Pipe Union Fiting",
      "price": 11.00,
      "description":
          "1/2 in. black iron Union fitting for connecting two threaded steel pipes (Brand may very)",
      "image": "assets/images/BlackPipeUnion.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
    },
    //REDUCERS + Bushings
    {
      "name": "3 in. to 2 1/2 in. Black Iron Reducer Fitting",
      "price": 93.00,
      "description":
          "Black iron fitting for reducing from 3 in. to 2 1/2 in. pipe (Brand may very)",
      "image": "assets/images/BlackPipe3inTo2.5inReducer.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
    },
    {
      "name": "3 in. to 2 in. Black Iron Reducer Fitting",
      "price": 79.50,
      "description":
          "3Black iron fitting for reducing from 3 in. to 2 in. pipe (Brand may very)",
      "image": "assets/images/BlackPipe3inTo2inReducer.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
    },
    {
      "name": "2 in. to 1 1/2 in. Black Iron Reducer Fitting",
      "price": 27.00,
      "description":
          "Black iron fitting for reducing from 2 in. to 2 1/2 in. pipe (Brand may very)",
      "image": "assets/images/BlackPipe2inTo1.5inReducer.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
    },
    {
      "name": "2 in. to 1 in. Black Iron Reducer Fitting",
      "price": 29.00,
      "description":
          "Black iron fitting for reducing from 2 in. to 1 in. pipe (Brand may very)",
      "image": "assets/images/BlackPipe2inTo1inReducer.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
    },
    {
      "name": "1 1/2 in. to 1 in. Black Iron Reducer Fitting",
      "price": 21.50,
      "description":
          "Black iron fitting for reducing from 1 1/2 in. to 1 in. pipe (Brand may very)",
      "image": "assets/images/BlackPipe1.5inTo1inReducer.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
    },
    {
      "name": "1 1/4 in. to 3/4 in. Black Iron Reducer Fitting",
      "price": 15.00,
      "description":
          "Black iron fitting for reducing from 1 1/4 in. to 3/4 in. pipe (Brand may very)",
      "image": "assets/images/BlackPipe1.25inTo.75inReducer.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
    },
    {
      "name": "1 in. to 1/2 in. Black Iron Reducer Fitting",
      "price": 12.00,
      "description":
          "Black iron fitting for reducing from 1 in. to 1/2 in. pipe (Brand may very)",
      "image": "assets/images/BlackPipe1inTo.5inReducer.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
    },
    {
      "name": "3/4 in. to 1/4 in. Black Iron Reducer Fitting",
      "price": 9.00,
      "description":
          "Black iron fitting for reducing from 3/4 in. to 1/4 in. pipe (Brand may very)",
      "image": "assets/images/BlackPipe.75inTo.25inReducer.jpg",
      "categories": ["Gas", "Black Steel Pipe", "Fittings"],
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
    },
    {
      "name": "Pipe Dope (8 oz.)",
      "price": 7.00,
      "description":
          "Paste for sealing pipe connections from leaks (Brand may very)",
      "image": "assets/images/PipeDope.jpg",
      "categories": ["Gas", "Black Steel Pipe"],
    },
    {
      "name": "4 in. Rubber Gasket",
      "price": 9.00,
      "description":
          "4 in. Rubber gasket for installing 4 in. pipe into existing cast iron(Brand may very)",
      "image": "assets/images/2inRubberGasket.jpg",
      "categories": ["PVC", "NoHub"],
    },
    {
      "name": "4 in. Shielded Rubber Coupling",
      "price": 13.00,
      "description":
          "4 in. Rubber coupling for conneting drain pipe (Brand may very)",
      "image": "assets/images/Shielded2inRubberCoupling.jpg",
      "categories": ["PVC", "Drains", "NoHub"],
    },
    {
      "name": "4 in. Heavy Duty Shielded Rubber Coupling",
      "price": 17.00,
      "description":
          "4 in. Shielded rubber coupling for conneting drain pipe (Brand may very)",
      "image": "assets/images/HeavyDutyRubberCoupling(3or4in).jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "4 in. Rubber Cap",
      "price": 8.50,
      "description":
          "4 in. rubber cap for PVC or Cast iron pipe (Brand may very)",
      "image": "assets/images/RubberCap.jpg",
      "categories": ["NoHub", "Drains", "PVC"],
    },
    {
      "name": "No Hub 4 in. 45",
      "price": 25.00,
      "description": "4 in. Cast iron 45 (Brand may very)",
      "image": "assets/images/NoHub45.jpg",
      "categories": ["NoHub", "Drains"],
    },
    {
      "name": "No Hub 4 in. Cleanout",
      "price": 62.00,
      "description": "4 in. Cast iron cleanout without cap (Brand may very)",
      "image": "assets/images/NoHubCleanout.jpg",
      "categories": ["NoHub", "Drains"],
    },
    {
      "name": "No Hub 4 in. Sanitary Tee",
      "price": 73.00,
      "description":
          "4 in. Cast iron santary tee for drain piping (Brand may very)",
      "image": "assets/images/NoHubSanitaryTee.jpg",
      "categories": ["NoHub", "Drains"],
    },
    {
      "name": "No Hub 4 in. Long Sweep Elbow",
      "price": 95.00,
      "description":
          "4 in. Cast iron elbow with a large bend for better flow (Brand may very)",
      "image": "assets/images/NoHubLongSweepElbow.jpg",
      "categories": ["NoHub", "Drains"],
    },
    {
      "name": "No Hub 4 in. Short Sweep Elbow",
      "price": 73.00,
      "description":
          "4 in. Cast iron elbow with a slighly larger bend for better flow (Brand may very)",
      "image": "assets/images/NoHubShortSweepElbow.jpg",
      "categories": ["NoHub", "Drains"],
    },
    {
      "name": "No Hub 4 in. Wye",
      "price": 40.00,
      "description": "4 in. Cast iron wye (Brand may very)",
      "image": "assets/images/NoHubWye.jpg",
      "categories": ["NoHub", "Drains"],
    },
    {
      "name": "No Hub 4 in. To 3 in. Reducer",
      "price": 25.00,
      "description": "4 in. Cast iron to 3 in. reducer (Brand may very)",
      "image": "assets/images/NoHubReducer(1).jpg",
      "categories": ["NoHub", "Drains"],
    },
    {
      "name": "3 in. Rubber Gasket",
      "price": 9.00,
      "description":
          "3 in. Rubber gasket for installing 3in. pipe into existing cast iron(Brand may very)",
      "image": "assets/images/2inRubberGasket.jpg",
      "categories": ["PVC", "NoHub"],
    },
    {
      "name": "3 in. Shielded Rubber Coupling",
      "price": 12.00,
      "description":
          "3 in. Rubber coupling for conneting drain pipe(Brand may very)",
      "image": "assets/images/Shielded2inRubberCoupling.jpg",
      "categories": ["PVC", "Drains", "NoHub"],
    },
    {
      "name": "3 in. Heavy Duty Shielded Rubber Coupling",
      "price": 11.00,
      "description":
          "3 in. Shielded rubber coupling for conneting drain pipe(Brand may very)",
      "image": "assets/images/HeavyDutyRubberCoupling(2inOrLower).jpg",
      "categories": ["PVC", "Drains", "NoHub"],
    },
    {
      "name": "3 in. Rubber Cap",
      "price": 8.50,
      "description":
          "3 in. rubber cap for PVC or Cast iron pipe (Brand may very)",
      "image": "assets/images/RubberCap.jpg",
      "categories": ["NoHub", "Drains", "PVC"],
    },
    {
      "name": "No Hub 3 in. 45",
      "price": 11.00,
      "description": "3 in. Cast iron 45 (Brand may very)",
      "image": "assets/images/NoHub45.jpg",
      "categories": ["NoHub", "Drains"],
    },
    {
      "name": "No Hub 3 in. Cleanout",
      "price": 11.00,
      "description": "3 in. Cast iron cleanout without cap (Brand may very)",
      "image": "assets/images/NoHubCleanout.jpg",
      "categories": ["NoHub", "Drains"],
    },
    {
      "name": "No Hub 3 in. Sanitary Tee",
      "price": 38.50,
      "description":
          "3 in. Cast iron santary tee for drain piping (Brand may very)",
      "image": "assets/images/NoHubSanitaryTee.jpg",
      "categories": ["NoHub", "Drains"],
    },
    {
      "name": "No Hub 3 in. Long Sweep Elbow",
      "price": 59.50,
      "description":
          "3 in. Cast iron elbow with a large bend for better flow (Brand may very)",
      "image": "assets/images/NoHubLongSweepElbow.jpg",
      "categories": ["NoHub", "Drains"],
    },
    {
      "name": "No Hub 3 in. Short Sweep Elbow",
      "price": 41.50,
      "description":
          "3 in. Cast iron elbow with a slighly larger bend for better flow (Brand may very)",
      "image": "assets/images/NoHubShortSweepElbow.jpg",
      "categories": ["NoHub", "Drains"],
    },
    {
      "name": "No Hub 3 in. Wye",
      "price": 27.00,
      "description": "3 in. Cast iron wye (Brand may very)",
      "image": "assets/images/NoHubWye.jpg",
      "categories": ["NoHub", "Drains"],
    },
    {
      "name": "No Hub 3 in. To 2 in. Reducer",
      "price": 16.50,
      "description": "3 in. Cast iron to 2 in. reducer (Brand may very)",
      "image": "assets/images/NoHubReducer(1).jpg",
      "categories": ["NoHub", "Drains"],
    },
    {
      "name": "2 in. Rubber Gasket",
      "price": 9.00,
      "description":
          "2 in. Rubber gasket for installing 2in. pipe into existing cast iron(Brand may very)",
      "image": "assets/images/2inRubberGasket.jpg",
      "categories": ["PVC", "NoHub"],
    },
    {
      "name": "2 in. Shielded Rubber Coupling",
      "price": 12.00,
      "description":
          "2 in. Rubber coupling for conneting drain pipe(Brand may very)",
      "image": "assets/images/Shielded2inRubberCoupling.jpg",
      "categories": ["PVC", "Drains", "NoHub"],
    },
    {
      "name": "2 in. Heavy Duty Shielded Rubber Coupling",
      "price": 11.00,
      "description":
          "2 in. Shielded rubber coupling for conneting drain pipe(Brand may very)",
      "image": "assets/images/HeavyDutyRubberCoupling(2inOrLower).jpg",
      "categories": ["PVC", "Drains", "NoHub"],
    },
    {
      "name": "2 in. Rubber Cap",
      "price": 5.00,
      "description":
          "2 in. rubber cap for PVC or Cast iron pipe (Brand may very)",
      "image": "assets/images/RubberCap.jpg",
      "categories": ["NoHub", "Drains", "PVC"],
    },
    {
      "name": "No Hub 2 in. 45",
      "price": 16.50,
      "description": "2 in. Cast iron 45 (Brand may very)",
      "image": "assets/images/NoHub45.jpg",
      "categories": ["NoHub", "Drains"],
    },
    {
      "name": "No Hub 2 in. Cleanout",
      "price": 28.50,
      "description": "2 in. Cast iron cleanout without cap (Brand may very)",
      "image": "assets/images/NoHubCleanout.jpg",
      "categories": ["NoHub", "Drains"],
    },
    {
      "name": "No Hub 2 in. Sanitary Tee",
      "price": 24.00,
      "description":
          "2 in. Cast iron santary tee for drain piping (Brand may very)",
      "image": "assets/images/NoHubSanitaryTee.jpg",
      "categories": ["NoHub", "Drains"],
    },
    {
      "name": "No Hub 2 in. Long Sweep Elbow",
      "price": 49.50,
      "description":
          "2 in. Cast iron elbow with a large bend for better flow (Brand may very)",
      "image": "assets/images/NoHubLongSweepElbow.jpg",
      "categories": ["NoHub", "Drains"],
    },
    {
      "name": "No Hub 2 in. Short Sweep Elbow",
      "price": 31.50,
      "description":
          "2 in. Cast iron elbow with a slighly larger bend for better flow (Brand may very)",
      "image": "assets/images/NoHubShortSweepElbow.jpg",
      "categories": ["NoHub", "Drains"],
    },
    {
      "name": "No Hub 2 in. Wye",
      "price": 29.00,
      "description": "2 in. Cast iron wye (Brand may very)",
      "image": "assets/images/NoHubWye.jpg",
      "categories": ["NoHub", "Drains"],
    },
    {
      "name": "Purple Primer (8 oz.)",
      "price": 9.00,
      "description":
          "Purple CPVC/PVC primer for cleaning connections(Brand may very)",
      "image": "assets/images/PurplePrimer.jpg",
      "categories": ["PVC"],
    },
    {
      "name": "Clear Primer (8 oz.)",
      "price": 7.00,
      "description":
          "Clear CPVC/PVC primer for cleaning connections(Brand may very)",
      "image": "assets/images/ClearPrimer.jpg",
      "categories": ["PVC"],
    },
    {
      "name": "PVC Cement (8 oz.)",
      "price": 8.00,
      "description": "Clear CPVC/PVC cement for connections(Brand may very)",
      "image": "assets/images/PVCCement.jpg",
      "categories": ["PVC"],
    },
    {
      "name": "PVC Cutting Bit",
      "price": 8.00,
      "description":
          "Bit for cutting pvc in out of reach areas(Brand may very)",
      "image": "assets/images/PVCCuttingBit.jpg",
      "categories": ["PVC", "Tools"],
    },
    {
      "name": "PVC 4 in. NonSlip Coupling",
      "price": 7.00,
      "description": "4 in. PVC Coupling with internal stops(Brand may very)",
      "image": "assets/images/PVCCoupling(HUB).jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 4 in. Slip Coupling",
      "price": 19.00,
      "description":
          "4 in. PVC Coupling without internal stops(Brand may very)",
      "image": "assets/images/PVCSlipCoupling.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 4 in. 45",
      "price": 13.00,
      "description": "4 in. PVC 45 (Brand may very)",
      "image": "assets/images/PVC45.jpg",
      "categories": ["PVC   ", "Drains"],
    },
    {
      "name": "PVC 4 in. 90",
      "price": 14.50,
      "description": "4 in. PVC 90 (Brand may very)",
      "image": "assets/images/PVC90.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 4 in. Cleanout With Plug",
      "price": 59.50,
      "description": "4 in. PVC cleanout with plug (Brand may very)",
      "image": "assets/images/PVCCleanoutWithCap.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 4 in. Threaded Cap",
      "price": 7.50,
      "description": "4 in. PVC cleanout cap(Brand may very)",
      "image": "assets/images/PVCThreadedCap.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 4 in. Sanitary Tee",
      "price": 43.50,
      "description": "4 in. PVC santary tee for drain piping (Brand may very)",
      "image": "assets/images/PVCSanitaryTee.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 4 in. Wye",
      "price": 54.00,
      "description": "4 in. PVC wye (Brand may very)",
      "image": "assets/images/PVCWye.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 4 in. To 3 in. Reducer",
      "price": 14.50,
      "description": "4 in. PVC to 3 in. reducer (Brand may very)",
      "image": "assets/images/PVCReducer(NoHub).jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 3 in. NonSlip Coupling",
      "price": 3.00,
      "description": "3 in. PVC Coupling with internal stops(Brand may very)",
      "image": "assets/images/PVCCoupling(HUB).jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 3 in. Slip Coupling",
      "price": 11.50,
      "description":
          "3 in. PVC Coupling without internal stops(Brand may very)",
      "image": "assets/images/PVCSlipCoupling.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 3 in. 45",
      "price": 5.50,
      "description": "3 in. PVC 45 (Brand may very)",
      "image": "assets/images/PVC45.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 3 in. 90",
      "price": 8.00,
      "description": "3 in. PVC 90 (Brand may very)",
      "image": "assets/images/PVC90.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 3 in. Cleanout",
      "price": 34.50,
      "description": "3 in. PVC cleanout with plug (Brand may very)",
      "image": "assets/images/PVCCleanoutWithCap.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 3 in. Threaded Cap",
      "price": 4.50,
      "description": "3 in. PVC cleanout cap(Brand may very)",
      "image": "assets/images/PVCThreadedCap.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 3 in. Sanitary Tee",
      "price": 12.00,
      "description": "3 in. PVC sanitary tee for drain piping (Brand may very)",
      "image": "assets/images/PVCSanitaryTee.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 3 in. Wye",
      "price": 16.00,
      "description": "3 in. PVC wye (Brand may very)",
      "image": "assets/images/PVCWye.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 3 in. To 2 in. Reducer",
      "price": 8.00,
      "description": "3 in. PVC to 2 in. reducer (Brand may very)",
      "image": "assets/images/PVCReducer(NoHub).jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 2 in. NonSlip Coupling",
      "price": 4.00,
      "description": "2 in. PVC Coupling with internal stops (Brand may very)",
      "image": "assets/images/PVCCoupling(HUB).jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 2 in. Slip Coupling",
      "price": 4.00,
      "description":
          "2 in. PVC Coupling without internal stops (Brand may very)",
      "image": "assets/images/PVCSlipCoupling.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 2 in. 45",
      "price": 4.00,
      "description": "2 in. PVC 45 (Brand may very)",
      "image": "assets/images/PVC45.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 2 in. 90",
      "price": 4.00,
      "description": "2 in. PVC 90 (Brand may very)",
      "image": "assets/images/PVC90.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 2 in. Cleanout",
      "price": 18.00,
      "description": "2 in. Cast iron cleanout with plug (Brand may very)",
      "image": "assets/images/PVCCleanoutWithCap.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 2 in. Threaded Cap",
      "price": 4.00,
      "description": "2 in. PVC cleanout cap (Brand may very)",
      "image": "assets/images/PVCThreadedCap.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 2 in. Sanitary Tee",
      "price": 4.00,
      "description": "2 in. PVC saitary tee for drain piping (Brand may very)",
      "image": "assets/images/PVCSanitaryTee.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 2 in. Wye",
      "price": 7.00,
      "description": "2 in. PVC wye (Brand may very)",
      "image": "assets/images/PVCWye.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 2 in. PTrap",
      "price": 6.00,
      "description": "2 in. PVC p-trap without nut (Brand may very)",
      "image": "assets/images/PVCPTrap.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "PVC 2 in. PTrap With Union",
      "price": 36.00,
      "description":
          "2 in. PVC p-trap with nut and threaded connection (Brand may very)",
      "image": "assets/images/PVCPTrap.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "2 in. Shower Drain",
      "price": 15.00,
      "description": "Shower Drain fits over 2 in. pvc pipe (Brand may very)",
      "image": "assets/images/ShowerDrain.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "Plumber's Putty (14 oz.)",
      "price": 5.00,
      "description": "Putty for waterproofing drains (Brand may very)",
      "image": "assets/images/PlumbersPutty.jpg",
      "categories": ["Drains"],
    },
    {
      "name": "1 1/2 in. Chrome Plated Tailpipe Assembly",
      "price": 5.00,
      "description":
          "1 1/2 in. tailpipe with opening and closing mechanism for sink drain (Brand may very)",
      "image": "assets/images/ChromePlatedSinkDrainAssembly.jpg",
      "categories": ["Drains"],
    },
    {
      "name": "1 1/2 in. PVC Tailpipe",
      "price": 5.00,
      "description":
          "1 1/2 in. tailpipe with opening and closing mechanism for sink drain (Brand may very)",
      "image": "assets/images/PVCTailPipe.25.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "1 1/4 in. Chrome Plated Tailpipe Assembly",
      "price": 5.00,
      "description":
          "1 1/4 in. tailpipe with opening and closing mechanism for sink drain (Brand may very)",
      "image": "assets/images/ChromePlatedSinkDrainAssembly.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "1 1/4 in. PVC TailPipe",
      "price": 5.00,
      "description":
          "1 1/4 in. threaded PVC tailpipe for sink drain (Brand may very)",
      "image": "assets/images/PVCTailPipe.25.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "1 1/2 in. To 1 1/4 in. Plastic Reducing Bushing",
      "price": 5.00,
      "description":
          "PLastic bushing for reducing from 1 1/2in. drain pipe to 1 1/4in. trap/pipe (Brand may very)",
      "image": "assets/images/PVCTailPipe.25.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "1 1/2 in. Chrome Plated P-Trap",
      "price": 5.00,
      "description": "1 1/2 in. chrome plated p-trap (Brand may very)",
      "image": "assets/images/ChromePlatedPTrap.jpg",
      "categories": ["Drains"],
    },
    {
      "name": "1 1/2 in. PVC P-Trap",
      "price": 5.00,
      "description": "1 1/2 in. PVC p-trap (Brand may very)",
      "image": "assets/images/PVCP-Trap.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "1 1/4 in. Chrome Plated P-Trap ",
      "price": 5.00,
      "description": "1 1/4 in. chrome plated p-trap (Brand may very)",
      "image": "assets/images/ChromePlatedPTrap.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "1 1/4 in. PVC P-Trap",
      "price": 5.00,
      "description": "1 1/4 in. PVC p-trap (Brand may very)",
      "image": "assets/images/PVCP-Trap.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "1 1/2 in. PVC Trap Adapter",
      "price": 5.00,
      "description":
          "Adapter to fit a p trap into 1 1/2 in. pvc pipe (Brand may very)",
      "image": "assets/images/PVCTrapAdapter.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "1 1/2 in. x 4 in. MPT Galvanized Nipple",
      "price": 11.00,
      "description":
          "1 1/2 in. x 4 in. male pipe thread galvanized nipple for P-trap or other uses (Brand may very)",
      "image": "assets/images/MPT4inGalvanizedNipple.jpg",
      "categories": ["Fittings", "Drains"],
    },
    {
      "name": "1 1/2 in. x 6 in. MPT Galvanized Nipple",
      "price": 11.00,
      "description":
          "1 1/2 in. x 6 in. male pipe thread galvanized nipple for P-trap or other uses (Brand may very)",
      "image": "assets/images/MPT4inGalvanizedNipple.jpg",
      "categories": ["Fittings", "Drains"],
    },
    {
      "name": "1 1/2 in. PTrap Slip Nut",
      "price": 7.00,
      "description":
          "Nut with a rubber reducer to fit a 1 1/2 p trap trap into 1 1/2 in. MPT nipple (Brand may very)",
      "image": "assets/images/PTrapSlipNut.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "1 1/4 in. PTrap Slip Nut",
      "price": 7.00,
      "description":
          "Nut with a rubber reducer to fit a 1 1/4 p trap trap into 1 1/4 in. MPT nipple (Brand may very)",
      "image": "assets/images/PTrapSlipNut.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "3 in. PVC Toilet Flange",
      "price": 7.00,
      "description":
          "3 in. wide fitting for connecting toilet to drain (Brand may very)",
      "image": "assets/images/PVCToiletFlange.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "3 in. PVC Toilet Flange With Stainless Steel Ring",
      "price": 7.00,
      "description":
          "3 in. wide fitting for connecting toilet to drain (Brand may very)",
      "image": "assets/images/PVCToiletFlangeWithMetalRing.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "4 in. x 2 in. Cast Iron Toilet Flange",
      "price": 7.00,
      "description":
          "4 in. wide code blue cast iron toilet flange (Brand may very)",
      "image": "assets/images/CastIronToiletFlange(4inx2in).jpg",
      "categories": ["Drains"],
    },
    {
      "name": "4 in. Wax Ring",
      "price": 7.00,
      "description": "3 in. wax ring for toilet drains (Brand may very)",
      "image": "assets/images/WaxRing.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "4 in. Wax Ring With Horn",
      "price": 7.00,
      "description":
          "4 in. wax ring for toilet drains with black horn (Brand may very)",
      "image": "assets/images/WaxRingWithHorn.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "3 in. Wax Ring",
      "price": 7.00,
      "description": "3 in. wax ring for toilet drains (Brand may very)",
      "image": "assets/images/WaxRing.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "3 in. Wax Ring With Horn",
      "price": 7.00,
      "description":
          "3 in. wax ring for toilet drains with black horn (Brand may very)",
      "image": "assets/images/WaxRingWithHorn.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "Toilet/Closet Bolts",
      "price": 7.00,
      "description":
          "Bolts, nuts, and washers for fastening toilet to toilet drain flange (Brand may very)",
      "image": "assets/images/JonnyBolts.jpg",
      "categories": ["PVC", "Drains"],
    },
    {
      "name": "4 in. Hole Saw",
      "price": 11.00,
      "description":
          "4in. circular blade for cutting holes to fit piping (Brand may very)",
      "image": "assets/images/HoleSaw(NoBit).jpg",
      "categories": ["Tools"],
    },
    {
      "name": "3 in. Hole Saw",
      "price": 11.00,
      "description":
          "3in. circular blade for cutting holes to fit piping (Brand may very)",
      "image": "assets/images/HoleSaw(NoBit).jpg",
      "categories": ["Tools"],
    },
    {
      "name": "2 in. Hole Saw",
      "price": 11.00,
      "description":
          "2in. circular blade for cutting holes to fit piping (Brand may very)",
      "image": "assets/images/HoleSaw(NoBit).jpg",
      "categories": ["Tools"],
    },
    {
      "name": "1 1/2 in. Hole Saw",
      "price": 11.00,
      "description":
          "1 1/2 in. circular blade for cutting holes to fit piping (Brand may very)",
      "image": "assets/images/HoleSaw(NoBit).jpg",
      "categories": ["Tools"],
    },
    {
      "name": "1 1/4 in. Hole Saw",
      "price": 11.00,
      "description":
          "1 1/4 in. circular blade for cutting holes to fit piping (Brand may very)",
      "image": "assets/images/HoleSaw(NoBit).jpg",
      "categories": ["Tools"],
    },
    {
      "name": "1 in. Hole Saw",
      "price": 11.00,
      "description":
          "1in. circular blade for cutting holes to fit piping (Brand may very)",
      "image": "assets/images/HoleSaw(NoBit).jpg",
      "categories": ["Tools"],
    },
    {
      "name": "Metal Reciprocating Saw Bit",
      "price": 11.00,
      "description":
          "Bit designed for cutting metal on a reciprocating saw (Brand may very)",
      "image": "assets/images/MetalSawzallBlade.jpg",
      "categories": ["Tools"],
    },
    {
      "name": "Wood Reciprocating Saw Bit",
      "price": 11.00,
      "description":
          "Bit designed for cutting wood on a reciprocating saw (Brand may very)",
      "image": "assets/images/WoodSawzallBlade.jpg",
      "categories": ["Tools"],
    },
    {
      "name": "Pipe Wrench (14 in.)",
      "price": 45.00,
      "description": "Heavy-duty wrench for gripping pipes (Brand may very)",
      "image": "assets/images/PipeWrench.jpg",
      "categories": ["Tools"],
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

      await docRef.update({"quantity": currentQty + qty});
    } else {
      // ➕ New item
      await docRef.set({
        "name": item["name"],
        "price": item["price"],
        "image": item["image"],
        "description": item["description"],
        "quantity": qty,
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
              // 🔔 does nothing for now
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
