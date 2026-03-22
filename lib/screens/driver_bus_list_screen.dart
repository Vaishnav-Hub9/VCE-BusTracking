import 'package:flutter/material.dart';
import '../services/firestore_service.dart';
import '../services/driver_session_service.dart';
import '../models/bus_model.dart';
import '../widgets/bus_card.dart';
import 'driver_mode_screen.dart';
import 'role_selection_screen.dart';

/// The bus list screen for drivers.
/// Shows all buses but only the "Drive" button — no Track.
/// Drivers log in with their driverId, not Firebase Auth.
class DriverBusListScreen extends StatefulWidget {
  final String driverName;
  final String driverId;

  const DriverBusListScreen({
    super.key,
    required this.driverName,
    required this.driverId,
  });

  @override
  State<DriverBusListScreen> createState() => _DriverBusListScreenState();
}

class _DriverBusListScreenState extends State<DriverBusListScreen> {
  final _firestoreService = FirestoreService();
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Logout'),
        content:
            const Text('Are you sure you want to log out from driver mode?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await DriverSessionService.clearSession();
      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const RoleSelectionScreen()),
          (_) => false,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text(
          'Select Your Bus',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        backgroundColor: Colors.orange.shade800,
        foregroundColor: Colors.white,
        elevation: 0,
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            tooltip: 'Logout',
            onPressed: _logout,
          ),
        ],
      ),
      body: Column(
        children: [
          // Driver info header
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.orange.shade800,
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(24),
                bottomRight: Radius.circular(24),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Hello, ${widget.driverName} 👋',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      'ID: ${widget.driverId}',
                      style: TextStyle(
                        color: Colors.white.withAlpha(180),
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(40),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Text(
                        'DRIVER MODE',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Select a bus to start driving',
                  style: TextStyle(
                    color: Colors.white.withAlpha(160),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search buses or routes...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: Colors.grey[100],
              ),
              onChanged: (value) {
                setState(() {
                  _searchQuery = value.toLowerCase();
                });
              },
            ),
          ),

          // Bus list
          Expanded(
            child: StreamBuilder<List<Bus>>(
              stream: _firestoreService.getBusesStream(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(
                        color: Color(0xFFBF360C)),
                  );
                }

                if (snapshot.hasError) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline,
                            size: 48, color: Colors.red.shade300),
                        const SizedBox(height: 12),
                        Text('Error loading buses',
                            style: TextStyle(
                                color: Colors.grey.shade700, fontSize: 16)),
                      ],
                    ),
                  );
                }

                var buses = snapshot.data ?? [];
                
                if (_searchQuery.isNotEmpty) {
                  buses = buses.where((bus) {
                    final busName = bus.name.toLowerCase();
                    final routeName = bus.route.toLowerCase();
                    return busName.contains(_searchQuery) || routeName.contains(_searchQuery);
                  }).toList();
                }

                if (buses.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.directions_bus_outlined,
                            size: 64, color: Colors.grey.shade300),
                        const SizedBox(height: 16),
                        Text(_searchQuery.isNotEmpty ? 'No routes found' : 'No buses available',
                            style: TextStyle(
                                color: Colors.grey.shade600,
                                fontSize: 17,
                                fontWeight: FontWeight.w500)),
                        const SizedBox(height: 6),
                        Text(
                          _searchQuery.isNotEmpty ? 'Try adjusting your search query.' : 'Buses will appear here once added by admin.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.grey.shade500, fontSize: 13),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.only(top: 8, bottom: 20),
                  itemCount: buses.length,
                  itemBuilder: (context, index) {
                    final bus = buses[index];
                    return BusCard(
                      bus: bus,
                      // Driver ID used to check "iAmDriver" state in card
                      currentUserId: widget.driverId,
                      userRole: UserRole.driver,
                      onDrive: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => DriverModeScreen(
                              bus: bus,
                              driverName: widget.driverName,
                              driverId: widget.driverId,
                            ),
                          ),
                        );
                      },
                      onTrack: () {},
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
