import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geocoding/geocoding.dart';
import '../models/bus_model.dart';
import '../models/bus_stop_model.dart';
import '../services/firestore_service.dart';

class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  final _firestoreService = FirestoreService();
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  // ─── ADD BUS DIALOG (two-step) ───────────────────────────────────────────

  Future<void> _showAddBusDialog() async {
    // Step 1: choose type
    final type = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text(
          'Add New Bus',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Select the type of bus you want to add:',
              style: TextStyle(color: Colors.black54, fontSize: 13),
            ),
            const SizedBox(height: 20),
            _typeButton(
              ctx: ctx,
              value: 'normal',
              icon: Icons.directions_bus_rounded,
              title: 'Normal Bus',
              subtitle: 'Free-roaming bus without a fixed route',
              color: const Color(0xFF1A237E),
            ),
            const SizedBox(height: 12),
            _typeButton(
              ctx: ctx,
              value: 'fixed',
              icon: Icons.route_rounded,
              title: 'Fixed Route Bus',
              subtitle: 'Bus with defined start, stops & destination',
              color: Colors.teal.shade700,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (type == null || !mounted) return;

    if (type == 'normal') {
      await _showNormalBusDialog();
    } else {
      await _showFixedRouteBusDialog();
    }
  }

  Widget _typeButton({
    required BuildContext ctx,
    required String value,
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
  }) {
    return InkWell(
      onTap: () => Navigator.pop(ctx, value),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          border: Border.all(color: color.withAlpha(80)),
          borderRadius: BorderRadius.circular(12),
          color: color.withAlpha(12),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withAlpha(20),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: color),
          ],
        ),
      ),
    );
  }

  // ─── Normal Bus Dialog ─────────────────────────────────────────────────────

  Future<void> _showNormalBusDialog() async {
    final nameCtrl = TextEditingController();
    final numberCtrl = TextEditingController();

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(
              Icons.directions_bus_rounded,
              color: const Color(0xFF1A237E),
              size: 22,
            ),
            const SizedBox(width: 8),
            const Text(
              'Normal Bus',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: _inputDec(
                'Bus Name',
                Icons.directions_bus,
                'e.g. Bus C',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: numberCtrl,
              decoration: _inputDec(
                'Bus Number / Route Label',
                Icons.tag,
                'e.g. VCE-03',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A237E),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () async {
              final name = nameCtrl.text.trim();
              final number = numberCtrl.text.trim();
              if (name.isEmpty) return;
              await _firestoreService.addBus(
                name: name,
                route: number.isEmpty ? name : number,
                hasFixedRoute: false,
              );
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Add Bus'),
          ),
        ],
      ),
    );
  }

  // ─── Fixed Route Bus Dialog ───────────────────────────────────────────────

  Future<void> _showFixedRouteBusDialog() async {
    final nameCtrl = TextEditingController();
    final routeCtrl = TextEditingController();
    final startNameCtrl = TextEditingController();
    final startLatCtrl = TextEditingController();
    final startLngCtrl = TextEditingController();
    final endNameCtrl = TextEditingController();
    final endLatCtrl = TextEditingController();
    final endLngCtrl = TextEditingController();

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.route_rounded, color: Colors.teal.shade700, size: 22),
            const SizedBox(width: 8),
            const Text(
              'Fixed Route Bus',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: _inputDec(
                  'Bus Name',
                  Icons.directions_bus,
                  'e.g. Bus A',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: routeCtrl,
                decoration: _inputDec(
                  'Route Label',
                  Icons.label,
                  'e.g. Miyapur → VCE',
                ),
              ),
              const SizedBox(height: 16),
              _sectionLabel('🟢 Starting Point'),
              const SizedBox(height: 8),
              TextField(
                controller: startNameCtrl,
                decoration: _inputDec(
                  'Start Name',
                  Icons.place,
                  'e.g. Miyapur',
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: startLatCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: _inputDec(
                        'Start Lat',
                        Icons.south,
                        '17.4947',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: startLngCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: _inputDec('Start Lng', Icons.east, '78.3996'),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.map, color: Colors.teal),
                    tooltip: 'Pick on Map',
                    onPressed: () async {
                      final currentLat = double.tryParse(startLatCtrl.text);
                      final currentLng = double.tryParse(startLngCtrl.text);
                      final result = await showDialog<Map<String, dynamic>>(
                        context: context,
                        builder: (_) => MapPickerModal(initialLat: currentLat, initialLng: currentLng),
                      );
                      if (result != null) {
                        startLatCtrl.text = result['lat'].toStringAsFixed(6);
                        startLngCtrl.text = result['lng'].toStringAsFixed(6);
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _sectionLabel('🔴 Destination'),
              const SizedBox(height: 8),
              TextField(
                controller: endNameCtrl,
                decoration: _inputDec('End Name', Icons.flag, 'e.g. VCE'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: endLatCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: _inputDec('End Lat', Icons.south, '17.3350'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: endLngCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: _inputDec('End Lng', Icons.east, '78.5439'),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.map, color: Colors.teal),
                    tooltip: 'Pick on Map',
                    onPressed: () async {
                      final currentLat = double.tryParse(endLatCtrl.text);
                      final currentLng = double.tryParse(endLngCtrl.text);
                      final result = await showDialog<Map<String, dynamic>>(
                        context: context,
                        builder: (_) => MapPickerModal(initialLat: currentLat, initialLng: currentLng),
                      );
                      if (result != null) {
                        endLatCtrl.text = result['lat'].toStringAsFixed(6);
                        endLngCtrl.text = result['lng'].toStringAsFixed(6);
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.teal.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 16,
                      color: Colors.teal.shade700,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Add stops after creating the bus using "Manage Stops".',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.teal.shade800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.teal.shade700,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () async {
              final name = nameCtrl.text.trim();
              final route = routeCtrl.text.trim();
              final startName = startNameCtrl.text.trim();
              final endName = endNameCtrl.text.trim();
              final startLat = double.tryParse(startLatCtrl.text.trim());
              final startLng = double.tryParse(startLngCtrl.text.trim());
              final endLat = double.tryParse(endLatCtrl.text.trim());
              final endLng = double.tryParse(endLngCtrl.text.trim());
              if (name.isEmpty ||
                  startLat == null ||
                  startLng == null ||
                  endLat == null ||
                  endLng == null)
                return;
              await _firestoreService.addBus(
                name: name,
                route: route.isEmpty
                    ? '${startName.isEmpty ? "Start" : startName} → ${endName.isEmpty ? "End" : endName}'
                    : route,
                hasFixedRoute: true,
                startName: startName.isEmpty ? null : startName,
                startLat: startLat,
                startLng: startLng,
                endName: endName.isEmpty ? null : endName,
                endLat: endLat,
                endLng: endLng,
              );
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Create Route'),
          ),
        ],
      ),
    );
  }

  // ─── MANAGE STOPS ─────────────────────────────────────────────────────────

  void _openStopsScreen(Bus bus) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _StopsManagementScreen(bus: bus)),
    );
  }

  // ─── EDIT BUS ──────────────────────────────────────────────────────────────

  Future<void> _showEditBusDialog(Bus bus) async {
    final nameCtrl = TextEditingController(text: bus.name);
    final routeCtrl = TextEditingController(text: bus.route);
    final startNameCtrl = TextEditingController(text: bus.startName ?? '');
    final startLatCtrl = TextEditingController(
      text: bus.startLat?.toString() ?? '',
    );
    final startLngCtrl = TextEditingController(
      text: bus.startLng?.toString() ?? '',
    );
    final endNameCtrl = TextEditingController(text: bus.endName ?? '');
    final endLatCtrl = TextEditingController(
      text: bus.endLat?.toString() ?? '',
    );
    final endLngCtrl = TextEditingController(
      text: bus.endLng?.toString() ?? '',
    );
    bool isFixed = bus.hasFixedRoute;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              Icon(Icons.edit, color: Colors.blue.shade700, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Edit ${bus.name}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: _inputDec(
                    'Bus Name',
                    Icons.directions_bus,
                    'e.g. Bus 1',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: routeCtrl,
                  decoration: _inputDec(
                    'Route Label',
                    Icons.label,
                    'e.g. Ameerpet → VCE',
                  ),
                ),
                const SizedBox(height: 16),

                // ─── Type Toggle ────────────────────────────────────────
                _sectionLabel('Bus Type'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setDialogState(() => isFixed = false),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: !isFixed
                                ? const Color(0xFF1A237E).withAlpha(20)
                                : Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: !isFixed
                                  ? const Color(0xFF1A237E)
                                  : Colors.grey.shade300,
                              width: !isFixed ? 2 : 1,
                            ),
                          ),
                          child: Column(
                            children: [
                              Icon(
                                Icons.directions_bus,
                                color: !isFixed
                                    ? const Color(0xFF1A237E)
                                    : Colors.grey,
                                size: 22,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Normal',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: !isFixed
                                      ? const Color(0xFF1A237E)
                                      : Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setDialogState(() => isFixed = true),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: isFixed
                                ? Colors.teal.shade700.withAlpha(20)
                                : Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isFixed
                                  ? Colors.teal.shade700
                                  : Colors.grey.shade300,
                              width: isFixed ? 2 : 1,
                            ),
                          ),
                          child: Column(
                            children: [
                              Icon(
                                Icons.route_rounded,
                                color: isFixed
                                    ? Colors.teal.shade700
                                    : Colors.grey,
                                size: 22,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Fixed Route',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: isFixed
                                      ? Colors.teal.shade700
                                      : Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),

                // Warning when switching Fixed → Normal
                if (bus.hasFixedRoute && !isFixed) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.orange.shade300),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 16,
                          color: Colors.orange.shade700,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Switching to Normal will clear start/end points. Existing stops will remain but won\'t be used.',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.orange.shade800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Fixed route fields
                if (isFixed) ...[
                  const SizedBox(height: 16),
                  _sectionLabel('🟢 Starting Point'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: startNameCtrl,
                    decoration: _inputDec(
                      'Start Name',
                      Icons.place,
                      'e.g. Miyapur',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: startLatCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: _inputDec(
                            'Start Lat',
                            Icons.south,
                            '17.4947',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: startLngCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: _inputDec(
                            'Start Lng',
                            Icons.east,
                            '78.3996',
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.map, color: Colors.teal),
                        tooltip: 'Pick on Map',
                        onPressed: () async {
                          final currentLat = double.tryParse(startLatCtrl.text);
                          final currentLng = double.tryParse(startLngCtrl.text);
                          final result = await showDialog<Map<String, dynamic>>(
                            context: context,
                            builder: (_) => MapPickerModal(initialLat: currentLat, initialLng: currentLng),
                          );
                          if (result != null) {
                            startLatCtrl.text = result['lat'].toStringAsFixed(6);
                            startLngCtrl.text = result['lng'].toStringAsFixed(6);
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _sectionLabel('🔴 Destination'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: endNameCtrl,
                    decoration: _inputDec('End Name', Icons.flag, 'e.g. VCE'),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: endLatCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: _inputDec(
                            'End Lat',
                            Icons.south,
                            '17.3350',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: endLngCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: _inputDec(
                            'End Lng',
                            Icons.east,
                            '78.5439',
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.map, color: Colors.teal),
                        tooltip: 'Pick on Map',
                        onPressed: () async {
                          final currentLat = double.tryParse(endLatCtrl.text);
                          final currentLng = double.tryParse(endLngCtrl.text);
                          final result = await showDialog<Map<String, dynamic>>(
                            context: context,
                            builder: (_) => MapPickerModal(initialLat: currentLat, initialLng: currentLng),
                          );
                          if (result != null) {
                            endLatCtrl.text = result['lat'].toStringAsFixed(6);
                            endLngCtrl.text = result['lng'].toStringAsFixed(6);
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade700,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () async {
                final name = nameCtrl.text.trim();
                final route = routeCtrl.text.trim();
                if (name.isEmpty) return;

                if (isFixed) {
                  final startLat = double.tryParse(startLatCtrl.text.trim());
                  final startLng = double.tryParse(startLngCtrl.text.trim());
                  final endLat = double.tryParse(endLatCtrl.text.trim());
                  final endLng = double.tryParse(endLngCtrl.text.trim());
                  if (startLat == null ||
                      startLng == null ||
                      endLat == null ||
                      endLng == null) {
                    return;
                  }
                  await _firestoreService.updateBus(
                    busId: bus.id,
                    name: name,
                    route: route.isEmpty ? bus.route : route,
                    hasFixedRoute: true,
                    startName: startNameCtrl.text.trim().isEmpty
                        ? null
                        : startNameCtrl.text.trim(),
                    startLat: startLat,
                    startLng: startLng,
                    endName: endNameCtrl.text.trim().isEmpty
                        ? null
                        : endNameCtrl.text.trim(),
                    endLat: endLat,
                    endLng: endLng,
                  );
                } else {
                  await _firestoreService.updateBus(
                    busId: bus.id,
                    name: name,
                    route: route.isEmpty ? name : route,
                    hasFixedRoute: false,
                  );
                }
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Save Changes'),
            ),
          ],
        ),
      ),
    );
  }

  // ─── DELETE BUS ─────────────────────────────────────────────────────────────

  Future<void> _showDeleteBusDialog(Bus bus) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: Colors.red.shade600,
              size: 24,
            ),
            const SizedBox(width: 8),
            const Text(
              'Delete Bus',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RichText(
              text: TextSpan(
                style: TextStyle(fontSize: 14, color: Colors.grey.shade800),
                children: [
                  const TextSpan(text: 'Are you sure you want to delete '),
                  TextSpan(
                    text: bus.name,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const TextSpan(text: '?'),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: Colors.red.shade600,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This will permanently delete the bus and all its stops. This action cannot be undone.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.red.shade700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _firestoreService.deleteBus(bus.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${bus.name} deleted.'),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _showLogoutConfirmation(BuildContext context) async {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Logout'),
          content: const Text('Are you sure you want to logout?'),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(dialogContext).pop(); // Closes the dialog
              },
            ),
            TextButton(
              child: const Text('Logout', style: TextStyle(color: Colors.red)),
              onPressed: () async {
                Navigator.of(dialogContext).pop(); // Closes the dialog FIRST
                await FirebaseAuth.instance.signOut();
                
                if (context.mounted) {
                  // This forces the app all the way back to your root/login screen
                  Navigator.of(context).popUntil((route) => route.isFirst);
                }
              },
            ),
          ],
        );
      },
    );
  }

  // ─── BUILD ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: PopScope(
        canPop: false,
        onPopInvoked: (didPop) async {
          if (!didPop) {
            _showLogoutConfirmation(context);
          }
        },
        child: Scaffold(
          backgroundColor: const Color(0xFFF5F7FA),
          appBar: AppBar(
            automaticallyImplyLeading: false,
            title: const Text(
              'Admin Panel',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            centerTitle: true,
            backgroundColor: const Color(0xFF1A237E),
            foregroundColor: Colors.white,
            elevation: 0,
            actions: [
              IconButton(
                icon: const Icon(Icons.logout),
                onPressed: () => _showLogoutConfirmation(context),
              ),
            ],
            bottom: const TabBar(
            indicatorColor: Colors.white,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white60,
            tabs: [
              Tab(icon: Icon(Icons.directions_bus_rounded), text: 'Buses'),
              Tab(icon: Icon(Icons.badge_rounded), text: 'Drivers'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            // ── TAB 1: BUSES ────────────────────────────────────────────────
            _buildBusesTab(),
            // ── TAB 2: DRIVERS ──────────────────────────────────────────────
            _buildDriversTab(),
          ],
        ),
        // FAB only shown in context of whichever tab is active
        floatingActionButton: _FABSwitcher(
          onAddBus: _showAddBusDialog,
          onAddDriver: _showAddDriverDialog,
        ),
      ),
      ),
    );
  }

  Widget _buildBusesTab() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            color: Color(0xFF1A237E),
            borderRadius: BorderRadius.only(
              bottomLeft: Radius.circular(24),
              bottomRight: Radius.circular(24),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Text(
            'Manage Buses & Routes',
            style: TextStyle(color: Colors.white.withAlpha(210), fontSize: 14),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search buses or routes...',
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
            ),
            onChanged: (val) {
              setState(() {
                _searchQuery = val.trim().toLowerCase();
              });
            },
          ),
        ),
        Expanded(
          child: StreamBuilder<List<Bus>>(
            stream: _firestoreService.getBusesStream(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                    child: CircularProgressIndicator(color: Color(0xFF1A237E)));
              }
              
              var buses = snapshot.data ?? [];
              if (_searchQuery.isNotEmpty) {
                buses = buses.where((bus) {
                  final nameMatches = bus.name.toLowerCase().contains(_searchQuery);
                  final routeMatches = bus.route.toLowerCase().contains(_searchQuery);
                  final startMatches = (bus.startName ?? '').toLowerCase().contains(_searchQuery);
                  final endMatches = (bus.endName ?? '').toLowerCase().contains(_searchQuery);
                  return nameMatches || routeMatches || startMatches || endMatches;
                }).toList();
              }

              if (buses.isEmpty) {
                return Center(
                    child: Text(_searchQuery.isEmpty ? 'No buses yet. Tap + to add one.' : 'No routes matched your search.'));
              }
              return ListView.builder(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: buses.length,
                itemBuilder: (_, i) => _BusAdminCard(
                  bus: buses[i],
                  onManageStops:
                      buses[i].hasFixedRoute ? () => _openStopsScreen(buses[i]) : null,
                  onEdit: () => _showEditBusDialog(buses[i]),
                  onDelete: () => _showDeleteBusDialog(buses[i]),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ─── DRIVERS TAB ──────────────────────────────────────────────────────────

  Widget _buildDriversTab() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.deepPurple.shade700,
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(24),
              bottomRight: Radius.circular(24),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Text(
            'Manage Driver Accounts',
            style: TextStyle(color: Colors.white.withAlpha(210), fontSize: 14),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: StreamBuilder<List<dynamic>>(
            stream: _firestoreService.getDriversStream(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                    child: CircularProgressIndicator(
                        color: Colors.deepPurple));
              }
              final drivers = snapshot.data ?? [];
              if (drivers.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.badge_outlined,
                          size: 64, color: Colors.grey.shade300),
                      const SizedBox(height: 16),
                      Text('No drivers yet.',
                          style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 16,
                              fontWeight: FontWeight.w500)),
                      const SizedBox(height: 6),
                      Text('Tap + to add a driver account.',
                          style: TextStyle(
                              color: Colors.grey.shade500, fontSize: 13)),
                    ],
                  ),
                );
              }
              return ListView.builder(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: drivers.length,
                itemBuilder: (_, i) {
                  final d = drivers[i];
                  return _DriverAdminCard(
                    driver: d,
                    onEdit: () => _showEditDriverDialog(d),
                    onDelete: () => _showDeleteDriverDialog(d),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  // ─── ADD DRIVER DIALOG ────────────────────────────────────────────────────

  Future<void> _showAddDriverDialog() async {
    final idCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    bool obscure = true;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: Row(
            children: [
              Icon(Icons.person_add_rounded,
                  color: Colors.deepPurple.shade700, size: 22),
              const SizedBox(width: 8),
              const Text('Add Driver',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: idCtrl,
                  textCapitalization: TextCapitalization.characters,
                  decoration: _inputDec('Driver ID', Icons.badge, 'e.g. DRV001'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nameCtrl,
                  decoration: _inputDec('Full Name', Icons.person, 'e.g. Ravi Kumar'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passCtrl,
                  obscureText: obscure,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    hintText: 'Create a password',
                    prefixIcon: Icon(Icons.lock_outline,
                        color: const Color(0xFF1A237E), size: 20),
                    suffixIcon: IconButton(
                      icon: Icon(
                          obscure ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setDs(() => obscure = !obscure),
                    ),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepPurple.shade700,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () async {
                final id = idCtrl.text.trim();
                final name = nameCtrl.text.trim();
                final pass = passCtrl.text;
                if (id.isEmpty || name.isEmpty || pass.isEmpty) return;
                await _firestoreService.addDriver(
                  driverId: id,
                  driverName: name,
                  password: pass,
                );
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Add Driver'),
            ),
          ],
        ),
      ),
    );
  }

  // ─── EDIT DRIVER DIALOG ───────────────────────────────────────────────────

  Future<void> _showEditDriverDialog(dynamic driver) async {
    final idCtrl = TextEditingController(text: driver.driverId);
    final nameCtrl = TextEditingController(text: driver.driverName);
    final passCtrl = TextEditingController(text: driver.password);
    bool obscure = true;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: Row(
            children: [
              Icon(Icons.edit_rounded,
                  color: Colors.blue.shade700, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Edit ${driver.driverName}',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: idCtrl,
                  textCapitalization: TextCapitalization.characters,
                  decoration:
                      _inputDec('Driver ID', Icons.badge, 'e.g. DRV001'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nameCtrl,
                  decoration: _inputDec(
                      'Full Name', Icons.person, 'e.g. Ravi Kumar'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passCtrl,
                  obscureText: obscure,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: Icon(Icons.lock_outline,
                        color: const Color(0xFF1A237E), size: 20),
                    suffixIcon: IconButton(
                      icon: Icon(
                          obscure ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setDs(() => obscure = !obscure),
                    ),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade700,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () async {
                final id = idCtrl.text.trim();
                final name = nameCtrl.text.trim();
                final pass = passCtrl.text;
                if (id.isEmpty || name.isEmpty || pass.isEmpty) return;
                await _firestoreService.updateDriver(
                  docId: driver.id,
                  driverId: id,
                  driverName: name,
                  password: pass,
                );
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Save Changes'),
            ),
          ],
        ),
      ),
    );
  }

  // ─── DELETE DRIVER DIALOG ─────────────────────────────────────────────────

  Future<void> _showDeleteDriverDialog(dynamic driver) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded,
                color: Colors.red.shade600, size: 24),
            const SizedBox(width: 8),
            const Text('Delete Driver',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          'Are you sure you want to delete ${driver.driverName} (${driver.driverId})?',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _firestoreService.deleteDriver(driver.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${driver.driverName} deleted.'),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Widget _sectionLabel(String text) => Text(
    text,
    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
  );

  InputDecoration _inputDec(String label, IconData icon, String hint) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(icon, color: const Color(0xFF1A237E), size: 20),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    );
  }
}

// ─── FAB SWITCHER (shows correct FAB per tab) ──────────────────────────────

class _FABSwitcher extends StatefulWidget {
  final VoidCallback onAddBus;
  final VoidCallback onAddDriver;

  const _FABSwitcher({required this.onAddBus, required this.onAddDriver});

  @override
  State<_FABSwitcher> createState() => _FABSwitcherState();
}

class _FABSwitcherState extends State<_FABSwitcher> {
  @override
  Widget build(BuildContext context) {
    final tabIndex = DefaultTabController.of(context).index;
    final isDriversTab = tabIndex == 1;

    DefaultTabController.of(context).addListener(() {
      if (mounted) setState(() {});
    });

    return FloatingActionButton.extended(
      onPressed: isDriversTab ? widget.onAddDriver : widget.onAddBus,
      backgroundColor:
          isDriversTab ? Colors.deepPurple.shade700 : const Color(0xFF1A237E),
      foregroundColor: Colors.white,
      icon: const Icon(Icons.add),
      label: Text(isDriversTab ? 'Add Driver' : 'Add Bus'),
    );
  }
}


// ─── BUS ADMIN CARD ──────────────────────────────────────────────────────────

class _BusAdminCard extends StatelessWidget {
  final Bus bus;
  final VoidCallback? onManageStops;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _BusAdminCard({
    required this.bus,
    this.onManageStops,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isOnline = bus.hasActiveDriver;
    final color = bus.hasFixedRoute
        ? Colors.teal.shade700
        : const Color(0xFF1A237E);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(18),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: color.withAlpha(20),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    bus.hasFixedRoute
                        ? Icons.route_rounded
                        : Icons.directions_bus,
                    color: color,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        bus.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        bus.route,
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                // Type badge
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: color.withAlpha(18),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    bus.hasFixedRoute ? 'Fixed' : 'Normal',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Live badge
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: isOnline
                        ? Colors.green.shade50
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.circle,
                        size: 7,
                        color: isOnline ? Colors.green : Colors.grey.shade400,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isOnline ? 'Live' : 'Idle',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: isOnline
                              ? Colors.green.shade700
                              : Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (bus.hasFixedRoute) ...[
              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.place, size: 14, color: Colors.green.shade600),
                  const SizedBox(width: 4),
                  Text(
                    bus.startName ?? 'Start',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.arrow_forward, size: 12, color: Colors.grey),
                  const SizedBox(width: 6),
                  Icon(Icons.flag, size: 14, color: Colors.red.shade600),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      bus.endName ?? 'End',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ),
                  if (onManageStops != null)
                    TextButton.icon(
                      onPressed: onManageStops,
                      icon: const Icon(Icons.edit_location_alt, size: 16),
                      label: const Text('Manage Stops'),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.teal.shade700,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        textStyle: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            if (isOnline && bus.activeDriverName != null) ...[
              const SizedBox(height: 6),
              Text(
                'Driver: ${bus.activeDriverName}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
            ],

            // ─── CRUD Actions Row ──────────────────────────────────────
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // Edit button
                TextButton.icon(
                  onPressed: onEdit,
                  icon: Icon(
                    Icons.edit_outlined,
                    size: 17,
                    color: Colors.blue.shade700,
                  ),
                  label: Text(
                    'Edit',
                    style: TextStyle(
                      color: Colors.blue.shade700,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                // Delete button
                TextButton.icon(
                  onPressed: onDelete,
                  icon: Icon(
                    Icons.delete_outline,
                    size: 17,
                    color: Colors.red.shade600,
                  ),
                  label: Text(
                    'Delete',
                    style: TextStyle(
                      color: Colors.red.shade600,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
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

// ─── STOPS MANAGEMENT SCREEN ─────────────────────────────────────────────────

class _StopsManagementScreen extends StatefulWidget {
  final Bus bus;
  const _StopsManagementScreen({required this.bus});

  @override
  State<_StopsManagementScreen> createState() => _StopsManagementScreenState();
}

class _StopsManagementScreenState extends State<_StopsManagementScreen> {
  final _firestoreService = FirestoreService();

  Future<void> _showAddStopDialog(int nextOrder) async {
    final nameCtrl = TextEditingController();
    final latCtrl = TextEditingController();
    final lngCtrl = TextEditingController();

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Add Stop #$nextOrder',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: _inputDec('Stop Name', Icons.place, 'e.g. JNTU'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      TextField(
                        controller: latCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: _inputDec('Latitude', Icons.south, 'e.g. 17.4947'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: lngCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: _inputDec('Longitude', Icons.east, 'e.g. 78.3996'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.map, color: Color(0xFF1A237E), size: 36),
                  tooltip: 'Pick on Map',
                  onPressed: () async {
                    final currentLat = double.tryParse(latCtrl.text);
                    final currentLng = double.tryParse(lngCtrl.text);
                    final result = await showDialog<Map<String, dynamic>>(
                      context: context,
                      builder: (_) => MapPickerModal(initialLat: currentLat, initialLng: currentLng),
                    );
                    if (result != null) {
                      latCtrl.text = result['lat'].toStringAsFixed(6);
                      lngCtrl.text = result['lng'].toStringAsFixed(6);
                    }
                  },
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A237E),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () async {
              final name = nameCtrl.text.trim();
              final lat = double.tryParse(latCtrl.text.trim());
              final lng = double.tryParse(lngCtrl.text.trim());
              if (name.isEmpty || lat == null || lng == null) return;
              await _firestoreService.addStop(
                widget.bus.id,
                BusStop(
                  id: '',
                  name: name,
                  lat: lat,
                  lng: lng,
                  order: nextOrder,
                ),
              );
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Add Stop'),
          ),
        ],
      ),
    );
  }

  Future<void> _moveStop(List<BusStop> stops, int index, int delta) async {
    final targetIndex = index + delta;
    if (targetIndex < 0 || targetIndex >= stops.length) return;
    final a = stops[index];
    final b = stops[targetIndex];
    await _firestoreService.swapStopOrder(
      widget.bus.id,
      a.id,
      a.order,
      b.id,
      b.order,
    );
  }

  Future<void> _showEditStopDialog(BusStop stop) async {
    final nameCtrl = TextEditingController(text: stop.name);
    final latCtrl = TextEditingController(text: stop.lat.toString());
    final lngCtrl = TextEditingController(text: stop.lng.toString());

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.edit, color: Colors.blue.shade700, size: 22),
            const SizedBox(width: 8),
            Text(
              'Edit Stop #${stop.order}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: _inputDec('Stop Name', Icons.place, 'e.g. JNTU'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      TextField(
                        controller: latCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: _inputDec('Latitude', Icons.south, 'e.g. 17.4947'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: lngCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: _inputDec('Longitude', Icons.east, 'e.g. 78.3996'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.map, color: Colors.blue, size: 36),
                  tooltip: 'Pick on Map',
                  onPressed: () async {
                    final currentLat = double.tryParse(latCtrl.text);
                    final currentLng = double.tryParse(lngCtrl.text);
                    final result = await showDialog<Map<String, dynamic>>(
                      context: context,
                      builder: (_) => MapPickerModal(initialLat: currentLat, initialLng: currentLng),
                    );
                    if (result != null) {
                      latCtrl.text = result['lat'].toStringAsFixed(6);
                      lngCtrl.text = result['lng'].toStringAsFixed(6);
                    }
                  },
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue.shade700,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () async {
              final name = nameCtrl.text.trim();
              final lat = double.tryParse(latCtrl.text.trim());
              final lng = double.tryParse(lngCtrl.text.trim());
              if (name.isEmpty || lat == null || lng == null) return;
              await _firestoreService.updateStop(
                widget.bus.id,
                BusStop(
                  id: stop.id,
                  name: name,
                  lat: lat,
                  lng: lng,
                  order: stop.order,
                ),
              );
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDec(String label, IconData icon, String hint) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(icon, color: const Color(0xFF1A237E), size: 20),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: Text(
          '${widget.bus.name} — Stops',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        backgroundColor: const Color(0xFF1A237E),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: StreamBuilder<List<BusStop>>(
        stream: _firestoreService.getStopsStream(widget.bus.id),
        builder: (context, snapshot) {
          final stops = snapshot.data ?? [];

          return Column(
            children: [
              if (stops.isEmpty)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.place_outlined,
                          size: 60,
                          color: Colors.grey.shade300,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No stops added yet',
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Tap + to add the first stop on this route.',
                          style: TextStyle(
                            color: Colors.grey.shade500,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: stops.length,
                    itemBuilder: (_, i) {
                      final stop = stops[i];
                      final isFirst = i == 0;
                      final isLast = i == stops.length - 1;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withAlpha(15),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              // Order number
                              CircleAvatar(
                                radius: 18,
                                backgroundColor: const Color(
                                  0xFF1A237E,
                                ).withAlpha(20),
                                child: Text(
                                  '${stop.order}',
                                  style: const TextStyle(
                                    color: Color(0xFF1A237E),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              // Stop info
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      stop.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14,
                                      ),
                                    ),
                                    Text(
                                      '${stop.lat.toStringAsFixed(4)}, ${stop.lng.toStringAsFixed(4)}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              // Move up / down
                              Column(
                                children: [
                                  SizedBox(
                                    width: 32,
                                    height: 32,
                                    child: IconButton(
                                      padding: EdgeInsets.zero,
                                      icon: const Icon(
                                        Icons.keyboard_arrow_up,
                                        size: 20,
                                      ),
                                      color: isFirst
                                          ? Colors.grey.shade300
                                          : const Color(0xFF1A237E),
                                      onPressed: isFirst
                                          ? null
                                          : () => _moveStop(stops, i, -1),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 32,
                                    height: 32,
                                    child: IconButton(
                                      padding: EdgeInsets.zero,
                                      icon: const Icon(
                                        Icons.keyboard_arrow_down,
                                        size: 20,
                                      ),
                                      color: isLast
                                          ? Colors.grey.shade300
                                          : const Color(0xFF1A237E),
                                      onPressed: isLast
                                          ? null
                                          : () => _moveStop(stops, i, 1),
                                    ),
                                  ),
                                ],
                              ),
                              // Edit
                              IconButton(
                                icon: Icon(
                                  Icons.edit_outlined,
                                  color: Colors.blue.shade700,
                                  size: 20,
                                ),
                                onPressed: () => _showEditStopDialog(stop),
                              ),
                              // Delete
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.red,
                                  size: 22,
                                ),
                                onPressed: () async {
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text('Delete Stop'),
                                      content: Text('Remove "${stop.name}"?'),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, false),
                                          child: const Text('Cancel'),
                                        ),
                                        ElevatedButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, true),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.red,
                                            foregroundColor: Colors.white,
                                          ),
                                          child: const Text('Delete'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirm == true) {
                                    await _firestoreService.deleteStop(
                                      widget.bus.id,
                                      stop.id,
                                    );
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
      floatingActionButton: StreamBuilder<List<BusStop>>(
        stream: _firestoreService.getStopsStream(widget.bus.id),
        builder: (context, snapshot) {
          final nextOrder = (snapshot.data?.length ?? 0) + 1;
          return FloatingActionButton.extended(
            onPressed: () => _showAddStopDialog(nextOrder),
            backgroundColor: const Color(0xFF1A237E),
            foregroundColor: Colors.white,
            icon: const Icon(Icons.add_location_alt),
            label: const Text('Add Stop'),
          );
        },
      ),
    );
  }
}

// ─── DRIVER ADMIN CARD ───────────────────────────────────────────────────────

class _DriverAdminCard extends StatelessWidget {
  final dynamic driver;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _DriverAdminCard({
    required this.driver,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(15),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
        border: Border.all(color: Colors.deepPurple.shade100, width: 1.2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            // Avatar
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: Colors.deepPurple.shade50,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.deepPurple.shade200),
              ),
              child: Center(
                child: Text(
                  driver.driverName.isNotEmpty
                      ? driver.driverName[0].toUpperCase()
                      : '?',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.deepPurple.shade700,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    driver.driverName,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1A237E),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.deepPurple.shade50,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'ID: ${driver.driverId}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.deepPurple.shade700,
                          ),
                        ),
                      ),
                      if (driver.assignedBusId != null) ...[
                        const SizedBox(width: 8),
                        Icon(Icons.directions_bus_rounded,
                            size: 13, color: Colors.grey.shade500),
                        const SizedBox(width: 3),
                        Text(
                          'Assigned',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade600),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            // Actions
            IconButton(
              icon: Icon(Icons.edit_rounded, color: Colors.blue.shade600, size: 20),
              tooltip: 'Edit driver',
              onPressed: onEdit,
            ),
            IconButton(
              icon: Icon(Icons.delete_outline_rounded,
                  color: Colors.red.shade400, size: 20),
              tooltip: 'Delete driver',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

// ─── MAP PICKER MODAL ────────────────────────────────────────────────────────

class MapPickerModal extends StatefulWidget {
  final double? initialLat;
  final double? initialLng;

  const MapPickerModal({super.key, this.initialLat, this.initialLng});

  @override
  State<MapPickerModal> createState() => _MapPickerModalState();
}

class _MapPickerModalState extends State<MapPickerModal> {
  late final WebViewController _webController;
  final TextEditingController _searchController = TextEditingController();

  Future<void> _performSearch() async {
    final query = _searchController.text.trim();
    if (query.isNotEmpty) {
      try {
        List<Location> locations = await locationFromAddress("$query, Hyderabad, Telangana");
        if (locations.isNotEmpty) {
          double lat = locations.first.latitude;
          double lng = locations.first.longitude;
          _webController.runJavaScript('searchAndDropPin($lat, $lng)');
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location not found. Try a different name.')),
          );
        }
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel(
        'LocationPicked',
        onMessageReceived: (JavaScriptMessage message) {
          final data = jsonDecode(message.message);
          Navigator.pop(context, {'lat': data['lat'], 'lng': data['lng']});
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (String url) {
            final latArg = widget.initialLat != null ? widget.initialLat.toString() : 'null';
            final lngArg = widget.initialLng != null ? widget.initialLng.toString() : 'null';
            _webController.runJavaScript('initPickerMap($latArg, $lngArg);');
          },
        ),
      )
      ..loadFlutterAsset('assets/map.html');
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        width: MediaQuery.of(context).size.width,
        child: Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFF1A237E),
            foregroundColor: Colors.white,
            elevation: 0,
            title: TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Search stop (e.g., Koti)',
                hintStyle: TextStyle(color: Colors.white70),
                border: InputBorder.none,
              ),
              onSubmitted: (_) => _performSearch(),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.search),
                onPressed: _performSearch,
              ),
            ],
          ),
          body: Stack(
            children: [
              WebViewWidget(controller: _webController),
              Positioned(
                bottom: 16,
                right: 16,
                child: FloatingActionButton.extended(
                  onPressed: () => Navigator.pop(context), // Let them fallback to exit if no mark click triggers early pop
                  label: const Text('Cancel / Close'),
                  icon: const Icon(Icons.close),
                  backgroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

