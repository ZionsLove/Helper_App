part of 'main.dart';

class HVACScreen extends StatefulWidget {
  @override
  State<HVACScreen> createState() => _HVACScreenState();
}

class _HVACScreenState extends State<HVACScreen> {
  String selectedCategory = "All";
  String searchQuery = "";

  final List<String> categories = [
    "All",
    "Filters",
    "Thermostats",
    "Capacitors",
    "Motors",
    "Tools",
    "Ductwork",
    "Refrigerant",
    "Specialty",
  ];

  final List<Map<String, dynamic>> parts = [
    {
      "name": "Condenser Coil Cleaner (1 Gallon)",
      "price": 50.00,
      "description":
          "Undiluted chemical for cleaning outdoor condenser coils (Brand may vary)",
      "image": "assets/images/CondenserCoilCleaner.jpg",
      "categories": ["HVAC Service"],
    },
    {
      "name": "Evaporator Coil Cleaner (1 Gallon)",
      "price": 50.00,
      "description":
          "Undiluted chemical for cleaning indoor condenser coils (Brand may vary)",
      "image": "assets/images/Non-RinseEvaporatorCoilCleaner.jpg",
      "categories": ["HVAC Service"],
    },
    {
      "name": "Coil Cleaning Brush",
      "price": 5.00,
      "description":
          "Firm bristle brush for removing dirt layers from coils (Brand may vary)",
      "image": "assets/images/CoilCleaningBrush.jpg",
      "categories": ["HVAC Service"],
    },
    {
      "name": "Evaporator Coil Cleaner (1 Gallon)",
      "price": 50.00,
      "description":
          "Undiluted chemical for cleaning indoor condenser coils (Brand may vary)",
      "image": "assets/images/Non-RinseEvaporatorCoilCleaner.jpg",
      "categories": ["HVAC Service"],
    },
    {
      "name": "Standard 1/4 in. Yellow Hose",
      "price": 50.00,
      "description":
          "Yellow hose with no valve core depressers for servicing air conditioner (Brand may vary)",
      "image": "assets/images/StandardYellowHose.jpg",
      "categories": ["HVAC Hoses", "HVAC Service"],
    },
    {
      "name": "Standard 1/4 in. Red Hose",
      "price": 50.00,
      "description":
          "Red hose with no valve core depressers for servicing air conditioner (Brand may vary)",
      "image": "assets/images/StandardRedHose.jpg",
      "categories": ["HVAC Hoses", "HVAC Service"],
    },
    {
      "name": "Standard 1/4 in. Blue Hose",
      "price": 50.00,
      "description":
          "Blue hose with no valve core depressers for servicing air conditioner (Brand may vary)",
      "image": "assets/images/StandardBlueHose.jpg",
      "categories": ["HVAC Hoses", "HVAC Service"],
    },
    {
      "name": "1/4 in. Yellow Hose With Valve Core Depresser",
      "price": 50.00,
      "description":
          "Yellow hose with valve core depressers for servicing air conditioner (Brand may vary)",
      "image": "assets/images/DepresserYellowHose.jpg",
      "categories": ["HVAC Hoses", "HVAC Service"],
    },
    {
      "name": "1/4 in. Red Hose With Valve Core Depresser",
      "price": 50.00,
      "description":
          "Red hose with valve core depressers for servicing air conditioner (Brand may vary)",
      "image": "assets/images/DepresserRedHose.jpg",
      "categories": ["HVAC Hoses", "HVAC Service"],
    },
    {
      "name": "1/4 in. Blue Hose With Valve Core Depresser",
      "price": 50.00,
      "description":
          "Blue hose with valve core depressers for servicing air conditioner (Brand may vary)",
      "image": "assets/images/DepresserBlueHose.jpg",
      "categories": ["HVAC Hoses", "HVAC Service"],
    },
    {
      "name": "Low-Loss 1/4 in. Yellow Hose With Valve Core Depresser",
      "price": 50.00,
      "description":
          "Yellow Low-Loss fitting hose with valve core depressers for servicing air conditioner (Brand may vary)",
      "image": "assets/images/LowLossYellowHose.jpg",
      "categories": ["HVAC Hoses", "HVAC Service"],
    },
    {
      "name": "Low-Loss 1/4 in. Red Hose With Valve Core Depresser",
      "price": 50.00,
      "description":
          "Red Low-Loss fitting hose with valve core depressers for servicing air conditioner (Brand may vary)",
      "image": "assets/images/LowLossRedHose.jpg",
      "categories": ["HVAC Hoses", "HVAC Service"],
    },
    {
      "name": "Low-Loss 1/4 in. Blue Hose With Valve Core Depresser",
      "price": 50.00,
      "description":
          "Blue Low-Loss fitting hose with valve core depressers for servicing air conditioner (Brand may vary)",
      "image": "assets/images/LowLossBlueHose.jpg",
      "categories": ["HVAC Hoses", "HVAC Service"],
    },
    {
      "name": "Low-Loss 1/4 in. Blue Hose With Valve Core Depresser",
      "price": 50.00,
      "description":
          "Blue Low-Loss fitting hose with valve core depressers for servicing air conditioner (Brand may vary)",
      "image": "assets/images/LowLossBlueHose.jpg",
      "categories": ["HVAC Hoses", "HVAC Service"],
    },
    {
      "name": "Refrigerant Hose 1 1/4 in. Gaskets (Pack of 10)",
      "price": 7.00,
      "description":
          "Rubber gaskets to replace existing ones that are damaged or leaking on a standard size refrigerant hose (Brand may vary)",
      "image": "assets/images/RefrigerantHoseGaskets.jpg",
      "categories": ["HVAC Hoses", "HVAC Service"],
    },
    {
      "name": "Schrader Valve",
      "price": 5.00,
      "description":
          "Replacement valve for air conditioner service port/sensors. Pack of 4-10 depending on stock (Brand may vary)",
      "image": "assets/images/SchraderValve.jpg",
      "categories": ["HVAC Service"],
    },
    {
      "name": "Vacuum Hose (1/2 in)",
      "price": 45.00,
      "description":
          "1/2 in. vacuum hose for faster vacuuming (Brand may vary)",
      "image": "assets/images/VacuumHose(.5in).jpg",
      "categories": ["HVAC Hoses", "HVAC Service", "Vacuum"],
    },
    {
      "name": "Vacuum Hose (3/8 in)",
      "price": 45.00,
      "description":
          "3/8 in. vacuum hose for faster vacuuming (Brand may vary)",
      "image": "assets/images/VacuumHose(.5in).jpg",
      "categories": ["HVAC Hoses", "HVAC Service", "Vacuum"],
    },
    {
      "name": "Vacuum Pump Oil (1 Gallon)",
      "price": 45.00,
      "description":
          "1 gallon of oil to lubricate vacuum pump (Brand may vary)",
      "image": "assets/images/VacuumPumpOil(1Gallon).jpg",
      "categories": ["HVAC Hoses", "HVAC Service", "Vacuum"],
    },
    {
      "name": "Nitrogen Regulator",
      "price": 170.00,
      "description":
          "Adjustable valve for regulating nitrogen pressure from nitrogen tank (Brand may vary)",
      "image": "assets/images/NitrogenRegulator.jpg",
      "categories": ["HVAC Service"],
    },
    {
      "name": "Leak Detector Spray",
      "price": 20.00,
      "description":
          "Mixture that bubbles to find detect leak (Brand may vary)",
      "image": "assets/images/LeakDetectorSpray.jpg",
      "categories": ["HVAC Service"],
    },
    {
      "name": "Copper Brazing Rods",
      "price": 35.00,
      "description": "Rods used for brazing copper (Brand may vary)",
      "image": "assets/images/CopperBrazingRods.jpg",
      "categories": ["HVAC Service", "Brazing"],
    },
    {
      "name": "Silver Brazing Rods",
      "price": 35.00,
      "description":
          "Rods used for brazing copper to brass/steel/stainless steel (Brand may vary)",
      "image": "assets/images/BrazingRods.jpg",
      "categories": ["HVAC Service", "Brazing"],
    },
    {
      "name": "Sparker",
      "price": 7.00,
      "description":
          "Tool for creating spark to ignite flame torch (Brand may vary)",
      "image": "assets/images/Sparker.jpg",
      "categories": ["HVAC Service", "Brazing"],
    },
    {
      "name": "Turbo Torch",
      "price": 7.00,
      "description":
          "Torch with extreme heat for brazing not soldering (Brand may vary)",
      "image": "assets/images/TurboTorch.jpg",
      "categories": ["HVAC Service", "Brazing"],
    },
    {
      "name": "Heavy Futy Flaring Tool (3/16 in. to 3/4 in.)",
      "price": 170.00,
      "description":
          "Tool used to make flare on pipe to fasten nut to threaded fitting (Brand may vary)",
      "image": "assets/images/FlaringTool.jpg",
      "categories": ["HVAC Service", "Brazing"],
    },
    {
      "name": "Pipe Bending Kit",
      "price": 170.00,
      "description":
          "Tool used to make flare on pipe to fasten nut to threaded fitting (Brand may vary)",
      "image": "assets/images/FlaringTool.jpg",
      "categories": ["HVAC Service", "Brazing"],
    },
    {
      "name": "208/230V to 24V 75VA Transformer",
      "price": 170.00,
      "description":
          "Transformer used to step down from 208/230V to 24V (Brand may vary)",
      "image": "assets/images/FlaringTool.jpg",
      "categories": ["HVAC Service", "Brazing"],
    },
    {
      "name": "208/230V to 24V 50VA Transformer",
      "price": 170.00,
      "description":
          "Transformer used to step down from 208/230V to 24V (Brand may vary)",
      "image": "assets/images/FlaringTool.jpg",
      "categories": ["HVAC Service", "Brazing"],
    },
    {
      "name": "208/230V to 24V 40VA Transformer",
      "price": 170.00,
      "description":
          "Transformer used to step down from 208/230V to 24V (Brand may vary)",
      "image": "assets/images/FlaringTool.jpg",
      "categories": ["HVAC Service", "Brazing"],
    },
    {
      "name": "120V to 24V 75VA Transformer",
      "price": 170.00,
      "description":
          "Transformer used to step down from 208/230V to 24V (Brand may vary)",
      "image": "assets/images/FlaringTool.jpg",
      "categories": ["HVAC Service", "Brazing"],
    },
    {
      "name": "120V to 24V 50VA Transformer",
      "price": 170.00,
      "description":
          "Transformer used to step down from 208/230V to 24V (Brand may vary)",
      "image": "assets/images/FlaringTool.jpg",
      "categories": ["HVAC Service", "Brazing"],
    },
    {
      "name": "120V to 24V 40VA Transformer",
      "price": 170.00,
      "description":
          "Transformer used to step down from 208/230V to 24V (Brand may vary)",
      "image": "assets/images/FlaringTool.jpg",
      "categories": ["HVAC Service", "Brazing"],
    },
    {
      "name": "Residential Hermetic AC Compressor",
      "price": 425.00,
      "description":
          "Special order replacement compressor. Select matching system specifications before adding.",
      "image": "assets/images/hvac_compressor.jpg",
      "categories": ["Specialty", "Refrigerant"],
      "isSpecialty": true,
      requiresCarDeliveryKey: true,
      "specs": {
        "Tonnage": [
          "1.5 Ton",
          "2 Ton",
          "2.5 Ton",
          "3 Ton",
          "3.5 Ton",
          "4 Ton",
          "5 Ton",
        ],
        "Voltage": ["208/230V", "460V"],
        "Phase": ["Single Phase", "Three Phase"],
        "Refrigerant": ["R-410A", "R-32", "R-454B"],
        "Suction / Liquid Line Size": [
          "5/8 in. x 1/4 in.",
          "3/4 in. x 3/8 in.",
          "7/8 in. x 3/8 in.",
          "1 1/8 in. x 3/8 in.",
          "Unknown - match existing unit",
        ],
      },
    },
    {
      "name": "16 x 25 x 1 Pleated Air Filter",
      "price": 12.00,
      "description":
          "Standard pleated return air filter. MERV rating may vary.",
      "image": "assets/images/hvac_air_filter_16x25x1.jpg",
      "categories": ["Filters"],
    },
    {
      "name": "20 x 20 x 1 Pleated Air Filter",
      "price": 13.00,
      "description":
          "Disposable pleated HVAC filter for common residential returns.",
      "image": "assets/images/hvac_air_filter_20x20x1.jpg",
      "categories": ["Filters"],
    },
    {
      "name": "24V Non-Programmable Thermostat",
      "price": 34.00,
      "description": "Basic heat/cool wall thermostat for 24V HVAC systems.",
      "image": "assets/images/hvac_basic_thermostat.jpg",
      "categories": ["Thermostats"],
    },
    {
      "name": "Programmable Thermostat",
      "price": 58.00,
      "description":
          "Programmable thermostat for scheduled heating and cooling.",
      "image": "assets/images/hvac_programmable_thermostat.jpg",
      "categories": ["Thermostats"],
    },
    {
      "name": "40/5 MFD Dual Run Capacitor",
      "price": 21.00,
      "description":
          "Dual run capacitor for condenser fan and compressor circuits.",
      "image": "assets/images/hvac_dual_run_capacitor.jpg",
      "categories": ["Capacitors"],
    },
    {
      "name": "45/5 MFD Dual Run Capacitor",
      "price": 23.00,
      "description":
          "Common replacement dual run capacitor. Voltage rating may vary.",
      "image": "assets/images/hvac_dual_run_capacitor_45_5.jpg",
      "categories": ["Capacitors"],
    },
    {
      "name": "1/4 HP Condenser Fan Motor",
      "price": 96.00,
      "description":
          "Replacement condenser fan motor. Rotation and voltage may vary.",
      "image": "assets/images/hvac_condenser_fan_motor.jpg",
      "categories": ["Motors"],
    },
    {
      "name": "1/3 HP Blower Motor",
      "price": 128.00,
      "description": "Residential furnace or air handler blower motor.",
      "image": "assets/images/hvac_blower_motor.jpg",
      "categories": ["Motors"],
    },
    {
      "name": "Foil HVAC Tape",
      "price": 10.00,
      "description": "UL-listed foil tape for sealing ducts and plenums.",
      "image": "assets/images/hvac_foil_tape.jpg",
      "categories": ["Ductwork"],
    },
    {
      "name": "Mastic Duct Sealant",
      "price": 18.00,
      "description": "Brush-on duct sealant for air leaks and joints.",
      "image": "assets/images/hvac_mastic.jpg",
      "categories": ["Ductwork"],
    },
    {
      "name": "6 in. Flexible Insulated Duct",
      "price": 42.00,
      "description": "Insulated flexible duct for residential HVAC runs.",
      "image": "assets/images/hvac_flex_duct_6in.jpg",
      "categories": ["Ductwork"],
    },
    {
      "name": "Line Set Insulation",
      "price": 15.00,
      "description": "Replacement insulation for refrigerant suction lines.",
      "image": "assets/images/hvac_line_set_insulation.jpg",
      "categories": ["Refrigerant"],
    },
    {
      "name": "1/4 in. Access Tee With Schrader Valve",
      "price": 12.00,
      "description": "Service access tee for refrigerant line service work.",
      "image": "assets/images/hvac_access_tee.jpg",
      "categories": ["Refrigerant"],
    },
    {
      "name": "Refrigerant Manifold Gauge Set",
      "price": 82.00,
      "description": "Manifold gauge set for AC diagnostics and service.",
      "image": "assets/images/hvac_manifold_gauges.jpg",
      "categories": ["Tools", "Refrigerant"],
    },
    {
      "name": "Fin Comb Set",
      "price": 9.00,
      "description":
          "Plastic fin comb set for straightening condenser coil fins.",
      "image": "assets/images/hvac_fin_comb.jpg",
      "categories": ["Tools"],
    },
    {
      "name": "Digital Multimeter",
      "price": 36.00,
      "description":
          "General purpose multimeter for HVAC electrical troubleshooting.",
      "image": "assets/images/hvac_multimeter.jpg",
      "categories": ["Tools"],
    },
  ];

  Widget partImage(String imagePath) {
    return Image.asset(
      imagePath,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) {
        return Container(
          color: Colors.orange.withOpacity(0.08),
          alignment: Alignment.center,
          child: Icon(Icons.ac_unit, size: 42, color: Colors.orange.shade700),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredParts = parts.where((item) {
      final matchesSearch = item["name"].toLowerCase().contains(
        searchQuery.toLowerCase(),
      );

      final matchesCategory =
          selectedCategory == "All" ||
          (item["categories"] as List).contains(selectedCategory);

      return matchesSearch && matchesCategory;
    }).toList();

    return Scaffold(
      appBar: AppBar(
        iconTheme: IconThemeData(color: Colors.orange.shade700),
        backgroundColor: Colors.orange.shade100,
        elevation: 0,
        shape: Border(
          bottom: BorderSide(color: Colors.orange.shade700, width: 2),
        ),
        title: Text(
          "HVAC",
          style: TextStyle(
            color: Colors.orange.shade700,
            fontWeight: FontWeight.bold,
            fontSize: 24,
          ),
        ),
        centerTitle: false,
        titleSpacing: 0,
      ),

      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.all(20),
            child: TextField(
              decoration: InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: "Search HVAC parts...",
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onChanged: (value) {
                setState(() {
                  searchQuery = value;
                });
              },
            ),
          ),

          SizedBox(
            height: 50,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: categories.map((category) {
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
                    selectedColor: Colors.orange,
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
            child: filteredParts.isEmpty
                ? Center(
                    child: Text(
                      "No HVAC parts found",
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : GridView.builder(
                    padding: EdgeInsets.all(10),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      childAspectRatio: 0.75,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                    ),
                    itemCount: filteredParts.length,
                    itemBuilder: (context, index) {
                      final item = filteredParts[index];
                      final bool isSpecialty = item["isSpecialty"] == true;

                      return GestureDetector(
                        onTap: () {
                          if (isSpecialty) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    HVACSpecialtyDetailScreen(item: item),
                              ),
                            );
                          } else {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => DetailScreen(
                                  name: item["name"],
                                  price: item["price"],
                                  description: item["description"],
                                  image: item["image"],
                                  onAdd: (qty) {
                                    // Cart support can be wired in next.
                                  },
                                ),
                              ),
                            );
                          }
                        },
                        child: Card(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            children: [
                              Expanded(child: partImage(item["image"])),
                              Padding(
                                padding: EdgeInsets.all(8),
                                child: Column(
                                  children: [
                                    if (isSpecialty)
                                      Container(
                                        margin: EdgeInsets.only(bottom: 6),
                                        padding: EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.orange.shade100,
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                          border: Border.all(
                                            color: Colors.orange.shade700,
                                          ),
                                        ),
                                        child: Text(
                                          "Specialty Item",
                                          style: TextStyle(
                                            color: Colors.orange.shade800,
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    Text(
                                      item["name"],
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                "\$${(item["price"] as num).toDouble().toStringAsFixed(2)}",
                              ),
                              SizedBox(height: 8),
                            ],
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

class HVACSpecialtyDetailScreen extends StatefulWidget {
  final Map<String, dynamic> item;

  HVACSpecialtyDetailScreen({required this.item});

  @override
  State<HVACSpecialtyDetailScreen> createState() =>
      _HVACSpecialtyDetailScreenState();
}

class _HVACSpecialtyDetailScreenState extends State<HVACSpecialtyDetailScreen> {
  final Map<String, String> selectedSpecs = {};
  int quantity = 1;

  @override
  void initState() {
    super.initState();

    final specs = widget.item["specs"] as Map<String, dynamic>? ?? {};

    specs.forEach((label, options) {
      final values = (options as List).cast<String>();
      selectedSpecs[label] = values.first;
    });
  }

  Widget specialtyImage(String imagePath) {
    return Image.asset(
      imagePath,
      height: 220,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) {
        return Container(
          height: 220,
          width: double.infinity,
          color: Colors.orange.withOpacity(0.08),
          alignment: Alignment.center,
          child: Icon(Icons.ac_unit, size: 70, color: Colors.orange.shade700),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final specs = widget.item["specs"] as Map<String, dynamic>? ?? {};

    return Scaffold(
      appBar: AppBar(title: Text(widget.item["name"])),
      body: ListView(
        padding: EdgeInsets.all(20),
        children: [
          specialtyImage(widget.item["image"]),
          SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.item["name"],
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
              ),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.orange.shade100,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.orange.shade700),
                ),
                child: Text(
                  "Specialty",
                  style: TextStyle(
                    color: Colors.orange.shade800,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          Text(
            "\$${(widget.item["price"] as num).toDouble().toStringAsFixed(2)}",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 10),
          Text(widget.item["description"]),
          SizedBox(height: 24),
          Text(
            "Select Specifications",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 12),
          ...specs.entries.map((entry) {
            final label = entry.key;
            final values = (entry.value as List).cast<String>();

            return Padding(
              padding: EdgeInsets.only(bottom: 14),
              child: DropdownButtonFormField<String>(
                value: selectedSpecs[label],
                decoration: InputDecoration(
                  labelText: label,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                items: values.map((value) {
                  return DropdownMenuItem<String>(
                    value: value,
                    child: Text(value),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value == null) return;

                  setState(() {
                    selectedSpecs[label] = value;
                  });
                },
              ),
            );
          }).toList(),
          SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: Icon(Icons.remove),
                onPressed: () {
                  if (quantity <= 1) return;

                  setState(() {
                    quantity--;
                  });
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
              final specSummary = selectedSpecs.entries
                  .map((entry) => "${entry.key}: ${entry.value}")
                  .join(", ");

              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    "Selected $quantity ${widget.item["name"]}: $specSummary",
                  ),
                ),
              );

              Navigator.pop(context);
            },
            child: Text("Add Specialty Item"),
          ),
        ],
      ),
    );
  }
}
