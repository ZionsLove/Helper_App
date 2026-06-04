part of 'main.dart';

class HVACScreen extends StatefulWidget {
  @override
  State<HVACScreen> createState() => _HVACScreenState();
}

class _HVACScreenState extends State<HVACScreen> {
  String selectedCategory = "All";

  final List<String> categories = [
    "All",
    "Filters",
    "Thermostats",
    "Capacitors",
    "Motors",
    "Tools",
    "Ductwork",
    "Refrigerant",
  ];

  final List<Map<String, dynamic>> parts = [];

  @override
  Widget build(BuildContext context) {
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
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 15, vertical: 15),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.search),
                  SizedBox(width: 10),
                  Text("Search HVAC parts..."),
                ],
              ),
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
            child: Center(
              child: Text(
                "HVAC parts coming soon",
                style: TextStyle(color: Colors.grey),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
