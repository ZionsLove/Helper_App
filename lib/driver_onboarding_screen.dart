import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'main.dart';

const String driverOnboardingStepVehicle = "vehicle";
const String driverOnboardingStepPhone = "phone";
const String driverOnboardingStepOtp = "otp";
const String driverOnboardingStepProfile = "profile";
const String driverOnboardingStepComplete = "complete";

typedef DriverPhoneCodeSent =
    void Function(String verificationId, String phoneNumber);

class DriverOnboardingScreen extends StatefulWidget {
  const DriverOnboardingScreen({super.key});

  @override
  State<DriverOnboardingScreen> createState() => _DriverOnboardingScreenState();
}

class _DriverOnboardingScreenState extends State<DriverOnboardingScreen> {
  int step = 0;

  String vehicleType = "";
  String verificationId = "";
  bool isLoadingProgress = true;

  @override
  void initState() {
    super.initState();
    loadSavedProgress();
  }

  Future<void> loadSavedProgress() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      if (mounted) {
        setState(() => isLoadingProgress = false);
      }
      return;
    }

    final doc = await FirebaseFirestore.instance
        .collection('drivers')
        .doc(user.uid)
        .get();

    if (!mounted) return;

    final data = doc.data();
    final savedVehicle = data?["vehicleType"] as String?;
    final savedStep =
        data?["onboardingStep"] as String? ?? driverOnboardingStepVehicle;

    setState(() {
      vehicleType = savedVehicle ?? "";

      if (savedStep == driverOnboardingStepProfile &&
          vehicleType.trim().isNotEmpty) {
        step = 3;
      } else if ((savedStep == driverOnboardingStepPhone ||
              savedStep == driverOnboardingStepOtp) &&
          vehicleType.trim().isNotEmpty) {
        step = 1;
      } else {
        step = 0;
      }

      isLoadingProgress = false;
    });
  }

  Future<void> saveProgress({
    required String onboardingStep,
    String? vehicle,
    String? phone,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final progress = <String, dynamic>{
      "onboardingComplete": false,
      "onboardingStep": onboardingStep,
      "updatedAt": FieldValue.serverTimestamp(),
    };

    if (vehicle != null) {
      progress["vehicleType"] = vehicle;
    }

    if (phone != null) {
      progress["phone"] = phone;
    }

    await FirebaseFirestore.instance
        .collection('drivers')
        .doc(user.uid)
        .set(progress, SetOptions(merge: true));
  }

  @override
  Widget build(BuildContext context) {
    if (isLoadingProgress) {
      return Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (step == 0) {
      return VehicleStep(
        initialVehicle: vehicleType.isEmpty ? null : vehicleType,
        onVehicleSelected: (vehicle) async {
          await saveProgress(
            onboardingStep: driverOnboardingStepPhone,
            vehicle: vehicle,
          );
          if (!mounted) return;
          setState(() {
            vehicleType = vehicle;
            step = 1;
          });
        },
      );
    }

    if (step == 1) {
      return PhoneStep(
        onCodeSent: (id, phone) async {
          await saveProgress(
            onboardingStep: driverOnboardingStepOtp,
            phone: phone,
          );
          if (!mounted) return;
          setState(() {
            verificationId = id;
            step = 2;
          });
        },
      );
    }

    if (step == 2) {
      return OTPStep(
        verificationId: verificationId,
        onVerified: () async {
          await saveProgress(onboardingStep: driverOnboardingStepProfile);
          if (!mounted) return;
          setState(() {
            step = 3;
          });
        },
      );
    }

    return DriverFormStep(vehicleType: vehicleType);
  }
}

class DriverOnboardingShell extends StatelessWidget {
  final int step;
  final String title;
  final String subtitle;
  final IconData icon;
  final List<Widget> children;

  const DriverOnboardingShell({
    super.key,
    required this.step,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: Text("Driver Setup"),
        centerTitle: true,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: List.generate(4, (index) {
                  final active = index <= step;
                  return Expanded(
                    child: Container(
                      height: 5,
                      margin: EdgeInsets.only(right: index == 3 ? 0 : 6),
                      decoration: BoxDecoration(
                        color: active ? Colors.orange : Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  );
                }),
              ),
              SizedBox(height: 22),
              Container(
                padding: EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.07),
                      blurRadius: 14,
                      offset: Offset(0, 5),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        icon,
                        color: Colors.orange.shade800,
                        size: 30,
                      ),
                    ),
                    SizedBox(height: 18),
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        height: 1.1,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade700,
                        height: 1.35,
                      ),
                    ),
                    SizedBox(height: 22),
                    ...children,
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

InputDecoration driverInputDecoration({
  required String label,
  required IconData icon,
  String? hint,
}) {
  return InputDecoration(
    labelText: label,
    hintText: hint,
    prefixIcon: Icon(icon),
    filled: true,
    fillColor: Colors.grey.shade50,
    contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 16),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: Colors.grey.shade300),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: Colors.grey.shade300),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: Colors.orange, width: 2),
    ),
  );
}

class PrimaryDriverButton extends StatelessWidget {
  final String label;
  final bool isLoading;
  final VoidCallback? onPressed;

  const PrimaryDriverButton({
    super.key,
    required this.label,
    required this.isLoading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      width: double.infinity,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.orange.shade700,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        onPressed: isLoading ? null : onPressed,
        child: isLoading
            ? SizedBox(
                height: 22,
                width: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Text(label),
      ),
    );
  }
}

class VehicleStep extends StatefulWidget {
  final ValueChanged<String> onVehicleSelected;
  final String? initialVehicle;

  const VehicleStep({
    super.key,
    required this.onVehicleSelected,
    this.initialVehicle,
  });

  @override
  State<VehicleStep> createState() => _VehicleStepState();
}

class _VehicleStepState extends State<VehicleStep> {
  String? selectedVehicle;

  final vehicles = const [
    {
      "value": "bicycle",
      "label": "Bicycle",
      "subtitle": "Small local deliveries",
      "icon": Icons.pedal_bike,
    },
    {
      "value": "car",
      "label": "Car",
      "subtitle": "Standard supply runs",
      "icon": Icons.directions_car,
    },
    {
      "value": "pickup_truck_van",
      "label": "Pickup Truck / Van",
      "subtitle": "Larger parts and bulkier orders",
      "icon": Icons.local_shipping,
    },
  ];

  @override
  void initState() {
    super.initState();
    selectedVehicle = widget.initialVehicle;
  }

  @override
  Widget build(BuildContext context) {
    return DriverOnboardingShell(
      step: 0,
      title: "Choose your delivery vehicle",
      subtitle:
          "Select the vehicle you plan to use so we can match you with the right supply deliveries.",
      icon: Icons.delivery_dining,
      children: [
        ...vehicles.map((vehicle) {
          final value = vehicle["value"] as String;
          final isSelected = selectedVehicle == value;

          return Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                setState(() {
                  selectedVehicle = value;
                });
              },
              child: Container(
                padding: EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isSelected
                      ? Colors.orange.shade50
                      : Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected ? Colors.orange : Colors.grey.shade300,
                    width: isSelected ? 2 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      vehicle["icon"] as IconData,
                      color: isSelected
                          ? Colors.orange.shade800
                          : Colors.grey.shade700,
                      size: 30,
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            vehicle["label"] as String,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            vehicle["subtitle"] as String,
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey.shade700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isSelected)
                      Icon(Icons.check_circle, color: Colors.orange.shade800),
                  ],
                ),
              ),
            ),
          );
        }),
        SizedBox(height: 8),
        PrimaryDriverButton(
          label: "Continue",
          isLoading: false,
          onPressed: selectedVehicle == null
              ? null
              : () => widget.onVehicleSelected(selectedVehicle!),
        ),
      ],
    );
  }
}

class PhoneStep extends StatefulWidget {
  final DriverPhoneCodeSent onCodeSent;

  const PhoneStep({super.key, required this.onCodeSent});

  @override
  State<PhoneStep> createState() => _PhoneStepState();
}

class _PhoneStepState extends State<PhoneStep> {
  final controller = TextEditingController();
  bool isSendingCode = false;

  String formatPhoneNumber(String input) {
    String phone = input.trim();

    phone = phone.replaceAll(RegExp(r'[^0-9+]'), '');

    if (phone.startsWith("+1")) {
      return phone;
    }

    if (!phone.startsWith("+")) {
      return "+1$phone";
    }

    return phone;
  }

  Future<void> sendCode() async {
    setState(() {
      isSendingCode = true;
    });

    final formattedPhone = formatPhoneNumber(controller.text);

    if (!RegExp(r'^\+1\d{10}$').hasMatch(formattedPhone)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Enter a valid US phone number")));
      setState(() {
        isSendingCode = false;
      });
      return;
    }

    await FirebaseAuth.instance.verifyPhoneNumber(
      phoneNumber: formattedPhone,
      codeSent: (verificationId, _) {
        if (!mounted) return;
        setState(() {
          isSendingCode = false;
        });
        widget.onCodeSent(verificationId, formattedPhone);
      },
      verificationFailed: (e) {
        if (!mounted) return;
        setState(() {
          isSendingCode = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? "Could not send code")),
        );
      },
      verificationCompleted: (_) {},
      codeAutoRetrievalTimeout: (_) {
        if (!mounted) return;
        setState(() {
          isSendingCode = false;
        });
      },
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DriverOnboardingShell(
      step: 1,
      title: "Verify your driver phone",
      subtitle:
          "We use your phone number for driver account security and delivery updates.",
      icon: Icons.phone_iphone,
      children: [
        TextField(
          controller: controller,
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.done,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9+()\- ]')),
          ],
          decoration: driverInputDecoration(
            label: "Phone Number",
            hint: "(555) 123-4567",
            icon: Icons.phone,
          ),
          onSubmitted: (_) => isSendingCode ? null : sendCode(),
        ),
        SizedBox(height: 18),
        PrimaryDriverButton(
          label: "Send Verification Code",
          isLoading: isSendingCode,
          onPressed: sendCode,
        ),
      ],
    );
  }
}

class OTPStep extends StatefulWidget {
  final String verificationId;
  final VoidCallback onVerified;

  const OTPStep({
    super.key,
    required this.verificationId,
    required this.onVerified,
  });

  @override
  State<OTPStep> createState() => _OTPStepState();
}

class _OTPStepState extends State<OTPStep> {
  final controller = TextEditingController();
  bool isVerifying = false;

  Future<void> verifyCode() async {
    final code = controller.text.trim();

    if (code.length < 6) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Enter the 6-digit code")));
      return;
    }

    setState(() => isVerifying = true);

    try {
      final user = FirebaseAuth.instance.currentUser;

      if (user == null) {
        throw FirebaseAuthException(
          code: "not-signed-in",
          message: "Please sign in before verifying your phone.",
        );
      }

      final alreadyLinked = user.providerData.any(
        (provider) => provider.providerId == 'phone',
      );

      if (!alreadyLinked) {
        final credential = PhoneAuthProvider.credential(
          verificationId: widget.verificationId,
          smsCode: code,
        );

        await user.linkWithCredential(credential);
      }

      if (!mounted) return;
      widget.onVerified();
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      final message = e.code == 'credential-already-in-use'
          ? "This phone number is already in use"
          : e.message ?? "Could not verify code";
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Could not verify code")));
    } finally {
      if (mounted) {
        setState(() => isVerifying = false);
      }
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DriverOnboardingShell(
      step: 2,
      title: "Enter the SMS code",
      subtitle:
          "Type the verification code sent to your phone to continue driver setup.",
      icon: Icons.sms,
      children: [
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: driverInputDecoration(
            label: "Verification Code",
            hint: "123456",
            icon: Icons.lock,
          ),
          onSubmitted: (_) => isVerifying ? null : verifyCode(),
        ),
        SizedBox(height: 8),
        PrimaryDriverButton(
          label: "Verify Phone",
          isLoading: isVerifying,
          onPressed: verifyCode,
        ),
      ],
    );
  }
}

class DriverFormStep extends StatefulWidget {
  final String vehicleType;

  const DriverFormStep({super.key, required this.vehicleType});

  @override
  State<DriverFormStep> createState() => _DriverFormStepState();
}

class _DriverFormStepState extends State<DriverFormStep> {
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final addressController = TextEditingController();

  final cityController = TextEditingController();
  final stateController = TextEditingController();
  final zipController = TextEditingController();

  bool isLoading = false;

  bool get formIsValid {
    return nameController.text.trim().isNotEmpty &&
        emailController.text.trim().isNotEmpty &&
        addressController.text.trim().isNotEmpty &&
        cityController.text.trim().isNotEmpty &&
        stateController.text.trim().isNotEmpty &&
        zipController.text.trim().length >= 5 &&
        widget.vehicleType.trim().isNotEmpty;
  }

  Future<void> saveDriver() async {
    if (!formIsValid) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Fill out all driver profile fields")),
      );
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => isLoading = true);

    await FirebaseFirestore.instance.collection('drivers').doc(user.uid).set({
      "name": nameController.text.trim(),
      "email": emailController.text.trim(),
      "address": addressController.text.trim(),
      "city": cityController.text.trim(),
      "state": stateController.text.trim().toUpperCase(),
      "zipCode": zipController.text.trim(),
      "vehicleType": widget.vehicleType,
      "phone": user.phoneNumber,
      "phoneVerified": true,
      "onboardingComplete": true,
      "onboardingStep": driverOnboardingStepComplete,
      "active": false,
      "earnings": 0.0,
      "createdAt": FieldValue.serverTimestamp(),
      "completedAt": FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await PushNotificationService.saveCurrentToken(user.uid);

    if (!mounted) return;

    setState(() => isLoading = false);

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => DriverScreen()),
    );
  }

  @override
  void dispose() {
    nameController.dispose();
    emailController.dispose();
    addressController.dispose();
    cityController.dispose();
    stateController.dispose();
    zipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DriverOnboardingShell(
      step: 3,
      title: "Complete your driver profile",
      subtitle:
          "Add the basic details needed for your driver account and payouts later.",
      icon: Icons.badge,
      children: [
        TextField(
          controller: nameController,
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.words,
          decoration: driverInputDecoration(
            label: "Full Name",
            icon: Icons.person,
          ),
        ),
        SizedBox(height: 12),
        TextField(
          controller: emailController,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          decoration: driverInputDecoration(label: "Email", icon: Icons.email),
        ),
        SizedBox(height: 12),
        TextField(
          controller: addressController,
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.words,
          decoration: driverInputDecoration(
            label: "Home Address",
            icon: Icons.home,
          ),
        ),
        SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: cityController,
                textInputAction: TextInputAction.next,
                textCapitalization: TextCapitalization.words,
                decoration: driverInputDecoration(
                  label: "City",
                  icon: Icons.location_city,
                ),
              ),
            ),
            SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: TextField(
                controller: stateController,
                textInputAction: TextInputAction.next,
                textCapitalization: TextCapitalization.characters,
                maxLength: 2,
                decoration: driverInputDecoration(
                  label: "State",
                  hint: "NY",
                  icon: Icons.map,
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: 12),
        TextField(
          controller: zipController,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: driverInputDecoration(
            label: "ZIP Code",
            icon: Icons.pin_drop,
          ),
          onSubmitted: (_) => isLoading ? null : saveDriver(),
        ),
        SizedBox(height: 20),
        PrimaryDriverButton(
          label: "Finish Driver Setup",
          isLoading: isLoading,
          onPressed: saveDriver,
        ),
      ],
    );
  }
}
