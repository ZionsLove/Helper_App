import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';

class ConfirmLocationScreen extends StatefulWidget {
  final double? lat;
  final double? lng;
  final String address;

  const ConfirmLocationScreen({
    super.key,
    required this.lat,
    required this.lng,
    required this.address,
  });

  @override
  State<ConfirmLocationScreen> createState() => _ConfirmLocationScreenState();
}

class _ConfirmLocationScreenState extends State<ConfirmLocationScreen> {
  LatLng? selectedLocation;

  GoogleMapController? mapController;

  bool hasSetInitialLocation = false;

  bool userMovedPin = false;

  @override
  void initState() {
    super.initState();
  }

  Future<void> _initLocation() async {
    if (hasSetInitialLocation || userMovedPin) return; // 👈 KEY FIX

    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }

    final position = await Geolocator.getCurrentPosition();

    final newLocation = LatLng(position.latitude, position.longitude);

    setState(() {
      selectedLocation = newLocation;
      hasSetInitialLocation = true;
    });

    mapController?.animateCamera(CameraUpdate.newLatLngZoom(newLocation, 17));
    print("🚨 INIT LOCATION RUNNING");
  }

  Future<void> confirmLocation() async {
    print("📍 CONFIRM BUTTON PRESSED");

    final user = FirebaseAuth.instance.currentUser;

    if (user == null || selectedLocation == null) {
      print("❌ Missing user or location");
      return;
    }

    print("👤 USER: ${user.uid}");
    print("📍 LOCATION: $selectedLocation");
    print("🏠 ADDRESS: ${widget.address}");

    await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
      "lat": selectedLocation!.latitude,
      "lng": selectedLocation!.longitude,
      "address": widget.address, // ✅ IMPORTANT
      "lastUpdated": FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    print("✅ SAVED TO FIREBASE");

    // 🚀 GO BACK TO STORE SCREEN
    Navigator.popUntil(context, (route) => route.isFirst);
  }

  Future<void> centerOnUser() async {
    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }

    final position = await Geolocator.getCurrentPosition();

    final newLocation = LatLng(position.latitude, position.longitude);

    // ❌ DO NOT update selectedLocation here

    mapController?.animateCamera(CameraUpdate.newLatLngZoom(newLocation, 17));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Confirm Location")),
      body: Stack(
        children: [
          GoogleMap(
            onMapCreated: (controller) async {
              mapController = controller;

              // 👇 ONLY RUN ONCE HERE
              LocationPermission permission =
                  await Geolocator.checkPermission();

              if (permission == LocationPermission.denied) {
                permission = await Geolocator.requestPermission();
              }

              if (permission == LocationPermission.denied ||
                  permission == LocationPermission.deniedForever) {
                return;
              }

              final position = await Geolocator.getCurrentPosition();

              final newLocation = LatLng(position.latitude, position.longitude);

              setState(() {
                selectedLocation = newLocation;
              });

              mapController!.animateCamera(
                CameraUpdate.newLatLngZoom(newLocation, 17),
              );
            },

            initialCameraPosition: CameraPosition(
              target: selectedLocation ?? LatLng(40.7128, -74.0060),
              zoom: 17,
            ),

            onTap: (LatLng newPosition) {
              print("📍 USER PICKED: $newPosition");

              setState(() {
                selectedLocation = newPosition;
                userMovedPin = true; // 👈 LOCK USER CONTROL
              });
            },

            markers: selectedLocation == null
                ? {}
                : {
                    Marker(
                      markerId: MarkerId("selected"),
                      position: selectedLocation!,
                    ),
                  },
          ),

          // Bottom panel
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.address,
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  SizedBox(height: 10),

                  ElevatedButton(
                    onPressed: confirmLocation,
                    child: Text("Confirm Location"),
                  ),

                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                    },
                    child: Text("Go Back"),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 100,
            right: 16,
            child: FloatingActionButton(
              backgroundColor: Colors.white,
              onPressed: centerOnUser,
              child: Icon(Icons.my_location, color: Colors.black),
            ),
          ),
        ],
      ),
    );
  }
}
