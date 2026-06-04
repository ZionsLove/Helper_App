import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'main.dart';

class DriverOnboardingScreen extends StatefulWidget {
  @override
  _DriverOnboardingScreenState createState() => _DriverOnboardingScreenState();
}

class _DriverOnboardingScreenState extends State<DriverOnboardingScreen> {
  int step = 0;

  String verificationId = "";

  @override
  Widget build(BuildContext context) {
    if (step == 0) {
      return PhoneStep(
        onCodeSent: (id) {
          setState(() {
            verificationId = id;
            step = 1;
          });
        },
      );
    }

    if (step == 1) {
      return OTPStep(
        verificationId: verificationId,
        onVerified: () {
          setState(() {
            step = 2;
          });
        },
      );
    }

    return DriverFormStep();
  }
}

class PhoneStep extends StatefulWidget {
  final Function(String) onCodeSent;

  PhoneStep({required this.onCodeSent});

  @override
  _PhoneStepState createState() => _PhoneStepState();
}

class _PhoneStepState extends State<PhoneStep> {
  final controller = TextEditingController();
  bool isSendingCode = false;

  String formatPhoneNumber(String input) {
    String phone = input.trim();

    // 🔥 remove spaces, dashes, parentheses
    phone = phone.replaceAll(RegExp(r'[^0-9+]'), '');

    // 🔥 if user already typed +1 → keep it
    if (phone.startsWith("+1")) {
      return phone;
    }

    // 🔥 if user typed without + → add +1
    if (!phone.startsWith("+")) {
      return "+1$phone";
    }

    return phone;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Verify Phone")),
      body: Column(
        children: [
          TextField(
            controller: controller,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(labelText: "Phone Number"),
          ),
          ElevatedButton(
            onPressed: isSendingCode
                ? null
                : () async {
                    setState(() {
                      isSendingCode = true;
                    });
                    print("SEND CODE PRESSED");

                    String formattedPhone = formatPhoneNumber(controller.text);

                    print("FORMATTED: $formattedPhone");

                    if (!RegExp(r'^\+1\d{10}$').hasMatch(formattedPhone)) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text("Enter a valid US phone number"),
                        ),
                      );
                      return;
                    }

                    await FirebaseAuth.instance.verifyPhoneNumber(
                      phoneNumber: formattedPhone,
                      codeSent: (verificationId, _) {
                        print("CODE SENT ✅");
                        widget.onCodeSent(verificationId);

                        setState(() {
                          isSendingCode = false;
                        });
                      },
                      verificationFailed: (e) {
                        print("ERROR ❌: ${e.message}");

                        setState(() {
                          isSendingCode = false;
                        });
                      },
                      verificationCompleted: (_) {
                        print("AUTO VERIFIED");
                      },

                      codeAutoRetrievalTimeout: (_) {},
                    );
                  },
            child: isSendingCode
                ? SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text("Send Code"),
          ),
        ],
      ),
    );
  }
}

class OTPStep extends StatelessWidget {
  final String verificationId;
  final VoidCallback onVerified;

  OTPStep({required this.verificationId, required this.onVerified});

  final controller = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Enter Code")),
      body: Column(
        children: [
          TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: "SMS Code"),
          ),
          ElevatedButton(
            onPressed: () async {
              final credential = PhoneAuthProvider.credential(
                verificationId: verificationId,
                smsCode: controller.text,
              );

              final user = FirebaseAuth.instance.currentUser;

              bool alreadyLinked = user!.providerData.any(
                (provider) => provider.providerId == 'phone',
              );

              if (alreadyLinked) {
                print("PHONE ALREADY LINKED ✅");

                // 👉 just move forward
                onVerified();
                return;
              }

              try {
                final credential = PhoneAuthProvider.credential(
                  verificationId: verificationId,
                  smsCode: controller.text,
                );

                await user.linkWithCredential(credential);

                print("PHONE LINKED ✅");

                onVerified();
              } catch (e) {
                print("LINK ERROR: $e");
                if (e.toString().contains('credential-already-in-use')) {
                  print("PHONE ALREADY USED BY ANOTHER ACCOUNT ⚠️");

                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text("This phone number is already in use"),
                    ),
                  );
                } else {
                  print("OTHER ERROR: $e");
                }
              }

              await user!.linkWithCredential(credential);

              onVerified();
            },
            child: Text("Verify"),
          ),
        ],
      ),
    );
  }
}

class DriverFormStep extends StatefulWidget {
  @override
  _DriverFormStepState createState() => _DriverFormStepState();
}

class _DriverFormStepState extends State<DriverFormStep> {
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final addressController = TextEditingController();

  final cityController = TextEditingController();
  final stateController = TextEditingController();
  final zipController = TextEditingController();

  bool isLoading = false;

  Future<void> saveDriver() async {
    final user = FirebaseAuth.instance.currentUser;

    setState(() => isLoading = true);

    await FirebaseFirestore.instance.collection('drivers').doc(user!.uid).set({
      "name": nameController.text.trim(),
      "email": emailController.text.trim(),
      "address": addressController.text.trim(),
      "city": cityController.text.trim(),
      "state": stateController.text.trim(),
      "zipCode": zipController.text.trim(),
      "phone": user.phoneNumber,
      "phoneVerified": true,
      "active": false,
      "earnings": 0.0,
      "createdAt": FieldValue.serverTimestamp(),
    });

    setState(() => isLoading = false);

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => DriverScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Driver Setup")),
      body: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: nameController,
              decoration: InputDecoration(labelText: "Full Name"),
            ),
            TextField(
              controller: emailController,
              decoration: InputDecoration(labelText: "Email"),
            ),
            TextField(
              controller: addressController,
              decoration: InputDecoration(labelText: "Home Address"),
            ),

            TextField(
              controller: cityController,
              decoration: InputDecoration(labelText: "City"),
            ),

            TextField(
              controller: stateController,
              decoration: InputDecoration(labelText: "State"),
            ),

            TextField(
              controller: zipController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: "ZIP Code"),
            ),

            SizedBox(height: 20),

            ElevatedButton(
              onPressed: isLoading ? null : saveDriver,
              child: isLoading
                  ? CircularProgressIndicator(color: Colors.white)
                  : Text("Finish Setup"),
            ),
          ],
        ),
      ),
    );
  }
}
