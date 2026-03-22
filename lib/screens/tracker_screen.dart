import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' show asin, atan2, cos, pi, sin, sqrt;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/bus_model.dart';
import '../models/bus_stop_model.dart';
import '../services/firestore_service.dart';

class TrackerScreen extends StatefulWidget {
  final Bus bus;

  const TrackerScreen({super.key, required this.bus});

  @override
  State<TrackerScreen> createState() => _TrackerScreenState();
}

class _TrackerScreenState extends State<TrackerScreen> {
  late final WebViewController _webController;
  final _firestoreService = FirestoreService();
  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();

  StreamSubscription<Position>? _positionStream;
  StreamSubscription<List<BusStop>>? _stopsSubscription;

  Position? _userPosition;
  Bus? _latestBus;
  List<BusStop> _stops = [];
  bool _mapReady = false;
  bool _fixedRouteDrawn = false;
  bool _isNavigating = false;

  // Phase 2/4: nearest stop
  BusStop? _nearestStop;

  // Distance / ETA from live directions
  String? _routeDistance;
  String? _routeDuration;

  // Phase 4: walking info
  String? _walkDistance;
  String? _walkDuration;
  String? _walkStopName;

  // Phase 5: detection states
  bool _busOffRoute = false;
  bool _reachedStop = false;
  bool _boarded = false;
  bool _hasNotifiedProximity = false;

  BusStop? _selectedReminderStop; 
  double _reminderDistanceMeters = 1000.0; // Default 1km
  bool _isReminderActive = false;

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _initWebView();
    _startTracking();

    if (widget.bus.hasFixedRoute) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _promptBoardingStatus();
      });
    }
  }

  Future<void> _initNotifications() async {
    const AndroidInitializationSettings androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initSettings = InitializationSettings(android: androidSettings);
    await _notificationsPlugin.initialize(initSettings);
    _notificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
  }

  Future<void> _triggerBusAlert(String stopName) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'bus_alerts', 'Bus Arrivals', importance: Importance.max, priority: Priority.high,
    );
    await _notificationsPlugin.show(
      0, 'Bus Approaching! 🚌', 'Your bus is near $stopName.',
      const NotificationDetails(android: androidDetails),
    );
  }

  void _promptBoardingStatus() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Boarding Status', style: TextStyle(fontWeight: FontWeight.bold)),
        content: const Text('Did you already board the bus?'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context); // User did NOT board the bus
            },
            child: const Text('No, waiting for it', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _handleInitialBoarding();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A237E),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Yes, I am on it'),
          ),
        ],
      ),
    );
  }

  void _handleInitialBoarding() {
    if (!mounted) return;
    setState(() => _boarded = true);
    
    // Determine destination based on travelDirection
    double? destLat = widget.bus.endLat;
    double? destLng = widget.bus.endLng;
    if (widget.bus.travelDirection == 'backward') {
      destLat = widget.bus.startLat;
      destLng = widget.bus.startLng;
    }
    
    if (destLat != null && destLng != null && _mapReady) {
      _webController.runJavaScript('setManualBoarded(true, $destLat, $destLng);');
    } else {
       // fallback if map not ready yet
       Future.delayed(const Duration(milliseconds: 1500), () {
          if (mounted && destLat != null && destLng != null) {
              _webController.runJavaScript('setManualBoarded(true, $destLat, $destLng);');
          }
       });
    }
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _stopsSubscription?.cancel();
    super.dispose();
  }

  // ─── WEBVIEW ──────────────────────────────────────────────────────────────

  void _initWebView() {
    _webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            setState(() => _mapReady = true);
            _updateMapIfReady();
            _drawFixedRouteIfReady();
          },
          onWebResourceError: (error) {
            debugPrint('WebView error: ${error.description}');
          },
        ),
      )
      // Live route info (distance/ETA)
      ..addJavaScriptChannel(
        'RouteInfo',
        onMessageReceived: (JavaScriptMessage msg) {
          try {
            final data = jsonDecode(msg.message) as Map<String, dynamic>;
            if (!mounted) return;
            setState(() {
              _routeDistance = data['distance'] as String?;
              _routeDuration = data['duration'] as String?;
            });
          } catch (e) {
            debugPrint('RouteInfo error: $e');
          }
        },
      )
      // Walking nav info (Phase 4)
      ..addJavaScriptChannel(
        'WalkInfo',
        onMessageReceived: (JavaScriptMessage msg) {
          try {
            final data = jsonDecode(msg.message) as Map<String, dynamic>;
            if (!mounted) return;
            setState(() {
              _walkStopName = data['stopName'] as String?;
              _walkDistance = data['distance'] as String?;
              _walkDuration = data['duration'] as String?;
            });
          } catch (e) {
            debugPrint('WalkInfo error: $e');
          }
        },
      )
      // Phase 5: off-route alert
      ..addJavaScriptChannel(
        'OffRouteAlert',
        onMessageReceived: (JavaScriptMessage msg) {
          if (!mounted) return;
          setState(() => _busOffRoute = msg.message == 'off');
        },
      )
      // Phase 5: stop arrival
      ..addJavaScriptChannel(
        'StopArrived',
        onMessageReceived: (JavaScriptMessage msg) {
          if (!mounted) return;
          setState(() {
            _reachedStop = true;
            _isNavigating = false;
            _walkStopName = msg.message;
          });
        },
      )
      // Phase 5: boarding detection via JS - REMOVED per strict instructions
      // Students must manually click the dialog button to set boarded status.

      ..loadFlutterAsset('assets/map.html');
  }

  // ─── TRACKING ─────────────────────────────────────────────────────────────

  Future<void> _fetchBusLocation() async {
    try {
      final doc = await FirebaseFirestore.instance.collection('buses').doc(widget.bus.id).get();
      if (!doc.exists) return;
      
      final bus = Bus.fromFirestore(doc);
      if (!mounted) return;

      if (bus.lat != null && bus.lng != null && 
          _isReminderActive && _selectedReminderStop != null) {
        double distance = Geolocator.distanceBetween(
          bus.lat!, bus.lng!, 
          _selectedReminderStop!.lat, _selectedReminderStop!.lng
        );
        if (distance <= _reminderDistanceMeters) {
          _triggerBusAlert(_selectedReminderStop!.name);
          setState(() {
            _isReminderActive = false; // Turn off alarm so it doesn't spam
            _selectedReminderStop = null;
          });
        }
      }

      setState(() => _latestBus = bus);
      _updateMapIfReady();
      
      if (_mapReady) {
        _webController.runJavaScript('recenterCamera();');
      }
    } catch (e) {
      debugPrint('Error fetching bus location: $e');
    }
  }

  void _startTracking() {
    _fetchBusLocation();

    _initUserLocation();

    // Phase 1+4: load stops for fixed-route buses
    if (widget.bus.hasFixedRoute) {
      _stopsSubscription =
          _firestoreService.getStopsStream(widget.bus.id).listen((stops) {
        if (!mounted) return;
        setState(() {
          _stops = stops;
          _fixedRouteDrawn = false; // re-draw if stops changed
        });
        _drawFixedRouteIfReady();
        _updateNearestStop();
      });
    }
  }

  Future<void> _initUserLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;

    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
    );

    _positionStream =
        Geolocator.getPositionStream(locationSettings: locationSettings).listen(
      (position) {
        if (!mounted) return;
        setState(() => _userPosition = position);
        _updateMapIfReady();
        _updateNearestStop();
      },
    );
  }

  // ─── MAP UPDATES ──────────────────────────────────────────────────────────

  void _updateMapIfReady() {
    if (!_mapReady || !mounted) return;
    final bus = _latestBus;
    if (bus == null || !bus.hasActiveDriver || bus.lat == null || bus.lng == null) {
      return;
    }

    if (_userPosition != null) {
      _webController.runJavaScript(
        'updateBusRoute(${_userPosition!.latitude}, ${_userPosition!.longitude}, ${bus.lat}, ${bus.lng});',
      );
    } else {
      _webController.runJavaScript('centerMap(${bus.lat}, ${bus.lng});');
    }
  }

  void _drawFixedRouteIfReady() {
    if (!_mapReady || _fixedRouteDrawn) return;

    List<Map<String, dynamic>> routeData = [];

    if (_stops.isNotEmpty) {
      routeData = _stops
          .map((s) => {'name': s.name, 'lat': s.lat, 'lng': s.lng, 'order': s.order})
          .toList();
    } else if (widget.bus.hasFixedRoute && widget.bus.startLat != null && widget.bus.endLat != null) {
      routeData = [
        {'name': widget.bus.startName ?? 'Start', 'lat': widget.bus.startLat, 'lng': widget.bus.startLng, 'order': 0},
        {'name': widget.bus.endName ?? 'End', 'lat': widget.bus.endLat, 'lng': widget.bus.endLng, 'order': 1},
      ];
    } else {
      return;
    }

    final stopsJson = jsonEncode(routeData);
    _webController.runJavaScript('drawFixedRoute(${jsonEncode(stopsJson)});');
    _webController.runJavaScript('drawStops(${jsonEncode(stopsJson)});');
    setState(() => _fixedRouteDrawn = true);
  }

  // Phase 4: calculate nearest stop using Haversine
  void _updateNearestStop() {
    if (_userPosition == null) return;

    List<BusStop> stopsToCheck = _stops;

    if (stopsToCheck.isEmpty && widget.bus.hasFixedRoute && widget.bus.startLat != null && widget.bus.endLat != null) {
      stopsToCheck = [
        BusStop(
          id: 'start',
          name: widget.bus.startName ?? 'Start',
          lat: widget.bus.startLat!,
          lng: widget.bus.startLng!,
          order: 0,
        ),
        BusStop(
          id: 'end',
          name: widget.bus.endName ?? 'End',
          lat: widget.bus.endLat!,
          lng: widget.bus.endLng!,
          order: 1,
        ),
      ];
    }

    if (stopsToCheck.isEmpty) return;

    BusStop? nearest;
    double minDist = double.infinity;
    for (final stop in stopsToCheck) {
      final d = _haversineMeters(
        _userPosition!.latitude,
        _userPosition!.longitude,
        stop.lat,
        stop.lng,
      );
      if (d < minDist) {
        minDist = d;
        nearest = stop;
      }
    }
    if (!mounted) return;
    
    if (_nearestStop?.id != nearest?.id) {
      _hasNotifiedProximity = false;
    }
    
    setState(() => _nearestStop = nearest);

    if (minDist < 500 && !_hasNotifiedProximity && _isNavigating) {
      _triggerBusAlert(_nearestStop?.name ?? "your stop");
      _hasNotifiedProximity = true;
    }
  }

  double _haversineMeters(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLng = (lng2 - lng1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) *
            cos(lat2 * pi / 180) *
            sin(dLng / 2) *
            sin(dLng / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  // Phase 4: trigger walking navigation
  void _navigateToNearestStop() {
    if (_userPosition == null || _nearestStop == null) return;
    setState(() => _isNavigating = true);
    _webController.runJavaScript(
      'navigateToStop(${_userPosition!.latitude}, ${_userPosition!.longitude}, '
      '${_nearestStop!.lat}, ${_nearestStop!.lng}, "${_nearestStop!.name}");',
    );
  }

  double _reminderMinutes = 1.0;

  void _showReminderDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Text('🔔 Remind Me', style: TextStyle(color: Colors.indigo, fontWeight: FontWeight.bold)),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_stops.isEmpty)
                    const Text('No stops available for this route.', style: TextStyle(color: Colors.red))
                  else
                    DropdownButton<BusStop>(
                      isExpanded: true,
                      hint: const Text('Select your stop'),
                      value: _selectedReminderStop ?? _stops.first,
                      items: _stops.map((stop) {
                        return DropdownMenuItem<BusStop>(
                          value: stop,
                          child: Text(stop.name, overflow: TextOverflow.ellipsis),
                        );
                      }).toList(),
                      onChanged: (val) {
                        setDialogState(() => _selectedReminderStop = val);
                      },
                    ),
                  const SizedBox(height: 16),
                  Slider(
                    value: _reminderDistanceMeters,
                    min: 500,
                    max: 3000,
                    divisions: 5,
                    activeColor: Colors.teal,
                    onChanged: (val) {
                      setDialogState(() => _reminderDistanceMeters = val);
                    },
                  ),
                  Text('Alert me when bus is ${(_reminderDistanceMeters/1000).toStringAsFixed(1)} km away', 
                    style: const TextStyle(color: Colors.teal),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
              actions: [
  TextButton(
    onPressed: () => Navigator.pop(context), 
    child: const Text('Cancel', style: const TextStyle(color: Colors.grey))
  ),
  ElevatedButton(
    style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
    onPressed: () {
      setState(() {
        _isReminderActive = true;
      });
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reminder set for ${(_reminderDistanceMeters/1000).toStringAsFixed(1)} km!'))
      );
    },
    child: const Text('Create', style: const TextStyle(color: Colors.white)),
  ),
],
            );
          }
        );
      }
    );
  }

  // ─── BUILD ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final bus = _latestBus;
    final isOnline = bus != null && bus.hasActiveDriver;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.bus.name,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: const Color(0xFF1A237E),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh Location',
            onPressed: () async {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Getting latest location...'), duration: Duration(seconds: 1)),
              );
              await _fetchBusLocation();
            },
          ),
          IconButton(
            icon: const Icon(Icons.notifications_active),
            onPressed: () => _showReminderDialog(context),
          ),
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isOnline
                  ? Colors.green.withAlpha(50)
                  : Colors.red.withAlpha(50),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isOnline
                    ? Colors.green.shade300
                    : Colors.red.shade300,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle,
                    size: 8,
                    color: isOnline ? Colors.green : Colors.red),
                const SizedBox(width: 5),
                Text(
                  isOnline ? 'Live' : 'Offline',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isOnline
                        ? Colors.green.shade100
                        : Colors.red.shade100,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          // Map
          Stack(
            children: [
              WebViewWidget(controller: _webController),
              Positioned(
                top: 16,
                right: 16,
                child: FloatingActionButton(
                  mini: true,
                  backgroundColor: Colors.white,
                  onPressed: () {
                    _webController.runJavaScript('recenterCamera()');
                  },
                  child: const Icon(Icons.refresh, color: Colors.teal),
                ),
              ),
            ],
          ),

          // Phase 5: off-route banner
          if (_busOffRoute && !_boarded)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                color: Colors.orange.shade700,
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: Colors.white, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        '⚠️ Bus is off the expected route',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Phase 5: BOARDED banner
          if (_boarded)
            Positioned(
              top: _busOffRoute ? 52 : 12,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.teal.shade700,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                      BoxShadow(color: Colors.black.withAlpha(40), blurRadius: 8, offset: const Offset(0, 4)),
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.directions_bus_rounded, color: Colors.white, size: 24),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'You are on the bus. Enjoy your ride!',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Phase 5: Stop reached panel
          if (_reachedStop && !_boarded)
            Positioned(
              top: _busOffRoute ? 52 : 12,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.green.shade700,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_rounded,
                        color: Colors.white, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '✅ You reached ${_walkStopName ?? "the stop"}! Waiting for bus...',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Offline overlay
          if (!isOnline)
            Container(
              color: Colors.black.withAlpha(120),
              child: Center(
                child: Container(
                  margin: const EdgeInsets.all(32),
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withAlpha(30),
                          blurRadius: 20),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                            color: Colors.red.shade50,
                            shape: BoxShape.circle),
                        child: Icon(Icons.wifi_off_rounded,
                            size: 44, color: Colors.red.shade400),
                      ),
                      const SizedBox(height: 20),
                      const Text('Bus is Offline',
                          style: TextStyle(
                              fontSize: 20, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Text(
                        'No active driver for this bus.\nTracking will resume automatically\nwhen a driver starts.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade600,
                            height: 1.5),
                      ),
                      const SizedBox(height: 20),
                      const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Color(0xFF1A237E)),
                      ),
                      const SizedBox(height: 8),
                      Text('Waiting for driver...',
                          style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade500)),
                    ],
                  ),
                ),
              ),
            ),

          // Bottom info bar (when online)
          if (isOnline)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Phase 4: Navigate to Stop button
                  if (bus.hasFixedRoute &&
                      _nearestStop != null &&
                      _userPosition != null &&
                      !_reachedStop && 
                      !_boarded)
                    Padding(
                      padding:
                          const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed:
                              _isNavigating ? null : _navigateToNearestStop,
                          icon: Icon(
                            _isNavigating
                                ? Icons.directions_walk
                                : Icons.near_me_rounded,
                            size: 18,
                          ),
                          label: Text(
                            _isNavigating
                                ? 'Navigating to ${_nearestStop!.name}...'
                                : 'Navigate to ${_nearestStop!.name}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.teal.shade700,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(
                                vertical: 12),
                          ),
                        ),
                      ),
                    ),

                  // Phase 4: Walking info panel
                  if (_isNavigating &&
                      _walkDistance != null &&
                      !_reachedStop)
                    Padding(
                      padding:
                          const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.teal.shade700,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisAlignment:
                              MainAxisAlignment.spaceEvenly,
                          children: [
                            _walkChip(Icons.directions_walk,
                                _walkDistance!, 'Walk dist'),
                            Container(
                                width: 1,
                                height: 28,
                                color: Colors.white24),
                            _walkChip(Icons.access_time_rounded,
                                _walkDuration ?? '...', 'Walk time'),
                          ],
                        ),
                      ),
                    ),

                  // Bottom card: bus info + distance/ETA
                  Container(
                    margin: const EdgeInsets.all(16),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withAlpha(30),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Bus info row
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1A237E)
                                    .withAlpha(20),
                                borderRadius:
                                    BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.directions_bus,
                                  color: Color(0xFF1A237E), size: 22),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    bus.hasFixedRoute
                                        ? bus.directionLabel
                                        : bus.route,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Driver: ${bus.activeDriverName ?? "Unknown"}',
                                    style: TextStyle(
                                        color: Colors.grey.shade600,
                                        fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: Colors.green.shade50,
                                borderRadius:
                                    BorderRadius.circular(16),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.circle,
                                      size: 8,
                                      color: Colors.green.shade600),
                                  const SizedBox(width: 4),
                                  Text('LIVE',
                                      style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color:
                                              Colors.green.shade700)),
                                ],
                              ),
                            ),
                          ],
                        ),

                        // Distance & ETA row
                        if (_routeDistance != null ||
                            _routeDuration != null) ...[
                          const SizedBox(height: 10),
                          const Divider(height: 1),
                          const SizedBox(height: 10),
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceEvenly,
                            children: [
                              if (_routeDistance != null)
                                _statChip(
                                    icon: Icons.straighten_rounded,
                                    label: 'Distance',
                                    value: _routeDistance!,
                                    color: const Color(0xFF1A237E)),
                              if (_routeDistance != null &&
                                  _routeDuration != null)
                                Container(
                                    width: 1,
                                    height: 36,
                                    color: Colors.grey.shade200),
                              if (_routeDuration != null)
                                _statChip(
                                    icon: Icons.access_time_rounded,
                                    label: 'ETA',
                                    value: _routeDuration!,
                                    color: Colors.orange.shade700),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _statChip({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade500,
                    fontWeight: FontWeight.w500)),
          ],
        ),
        const SizedBox(height: 3),
        Text(value,
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: color)),
      ],
    );
  }

  Widget _walkChip(IconData icon, String value, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(icon, size: 14, color: Colors.white70),
            const SizedBox(width: 4),
            Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(
                color: Colors.white70, fontSize: 10)),
      ],
    );
  }
}
