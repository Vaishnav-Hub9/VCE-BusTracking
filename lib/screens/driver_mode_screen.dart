import 'package:flutter/material.dart';
import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/bus_model.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';

class DriverModeScreen extends StatefulWidget {
  final Bus bus;
  // Optional: provided when coming from DriverBusListScreen (driver login flow)
  final String? driverName;
  final String? driverId;

  const DriverModeScreen({
    super.key,
    required this.bus,
    this.driverName,
    this.driverId,
  });

  @override
  State<DriverModeScreen> createState() => _DriverModeScreenState();
}

class _DriverModeScreenState extends State<DriverModeScreen> {
  final _authService = AuthService();
  final _firestoreService = FirestoreService();

  StreamSubscription<Position>? _positionStream;

  bool _isDriving = false;
  bool _isClaiming = true;
  bool _claimFailed = false;
  String _claimError = '';
  String _claimStatus = 'Starting…';

  Position? _currentPosition;
  int _updateCount = 0;
  String? _chosenDirection;
  String? _sessionId; // Phase 9: session logging

  @override
  void initState() {
    super.initState();
    debugPrint('[DriverMode] DriverModeScreen initState — bus=${widget.bus.id}');
    _startFlow();
  }

  @override
  void dispose() {
    debugPrint('[DriverMode] Disposing');
    // Only release bus if driving was active, to avoid phantom Firestore writes
    if (_isDriving) {
      _stopDriving(showSnackbar: false);
    } else {
      // Just cancel the GPS stream, no Firestore operation needed
      _positionStream?.cancel();
    }
    super.dispose();
  }

  // ─── FLOW (GPS-independent claim) ─────────────────────────────────────────

  Future<void> _startFlow() async {
    debugPrint('[DriverMode] _startFlow() started');
    
    // Wait for the widget to finish building before showing a dialog
    await Future.delayed(Duration.zero);

    // Step 1: Phase 3 direction picker for normal buses
    if (!widget.bus.hasFixedRoute) {
      debugPrint('[DriverMode] Normal bus — showing direction picker');
      _setStatus('Choose direction…');
      final dir = await _showDirectionPicker();
      if (!mounted) return;
      if (dir == null) {
        debugPrint('[DriverMode] Direction picker cancelled — leaving screen');
        Navigator.pop(context);
        return;
      }
      _chosenDirection = dir;
      debugPrint('[DriverMode] Direction selected: $_chosenDirection');
    }

    // Step 2: Claim Firestore IMMEDIATELY (no GPS dependency)
    await _claimBus();
  }

  void _setStatus(String status) {
    if (mounted) setState(() => _claimStatus = status);
  }

  // ─── CLAIM ────────────────────────────────────────────────────────────────

  Future<void> _claimBus() async {
    debugPrint('[DriverMode] _claimBus() — resolving driver identity');
    _setStatus('Checking authentication…');

    // ── Resolve driver identity ──────────────────────────────────────────────
    // Priority 1: widget.driverId/driverName (from DriverLoginScreen — no Firebase)
    // Priority 2: Firebase Auth (student-who-is-driver legacy path)
    String userId;
    String userName;

    if (widget.driverId != null && widget.driverName != null) {
      // Driver login path — use the Firestore-based session identity
      userId = widget.driverId!;
      userName = widget.driverName!;
      debugPrint('[DriverMode] Driver session path: id=$userId name=$userName');
    } else {
      // Firebase Auth path (fallback)
      final user = _authService.currentUser;
      if (user == null) {
        debugPrint('[DriverMode] ERROR — no Firebase user and no driver session');
        _setFailed(
          'Authentication error.\nPlease log out and log in again as a Driver.',
        );
        return;
      }
      userId = user.uid;
      userName = user.displayName ?? user.email ?? 'Driver';
      debugPrint('[DriverMode] Firebase auth path: uid=$userId name=$userName');
    }

    _setStatus('Claiming bus in Firestore…');

    bool success = false;
    try {
      debugPrint('[DriverMode] Attempting Firestore update (5s timeout)…');
      success = await _firestoreService
          .claimBus(
            widget.bus.id,
            userId,
            userName,
            travelDirection: _chosenDirection,
          )
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              debugPrint('[DriverMode] claimBus() timed out');
              return false;
            },
          );
    } catch (e) {
      debugPrint('[DriverMode] claimBus() threw exception: $e');
      success = false;
      if (mounted) {
        if (e.toString().contains('already_driving_other_bus')) {
          _setFailed('You are already driving another bus.\nPlease stop driving that bus before claiming a new one.');
        } else {
          _setFailed('Firestore write failed: $e\n\nCheck your internet connection.');
        }
      }
      return;
    }

    if (!mounted) return;

    if (success) {
      debugPrint('[DriverMode] Firestore update SUCCESS — starting GPS in background');
      
      // Phase 9: start session logging (fire-and-forget)
      _startSessionLogging(userId: userId, userName: userName);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('active_bus_id', widget.bus.id);
      FlutterBackgroundService().startService();

      setState(() {
        _isClaiming = false;
        _isDriving = true;
      });
      // GPS starts AFTER claim — non-blocking
      _startLocationUpdates();
    } else {

      debugPrint('[DriverMode] claimBus() returned false — bus already taken or write failed');
      _setFailed('Could not claim this bus.\nIt may already have an active driver, or Firestore write was blocked.');
    }
  }

  void _setFailed(String reason) {
    debugPrint('[DriverMode] Claim FAILED: $reason');
    if (mounted) {
      setState(() {
        _isClaiming = false;
        _claimFailed = true;
        _claimError = reason;
      });
    }
  }

  // Phase 9: fire-and-forget session start
  void _startSessionLogging({
    required String userId,
    required String userName,
  }) {
    _firestoreService
        .startSession(
          driverId: widget.driverId ?? userId,
          driverName: widget.driverName ?? userName,
          busId: widget.bus.id,
          busName: widget.bus.name,
          route: widget.bus.route,
          direction: _chosenDirection,
        )
        .then((id) => _sessionId = id)
        .catchError((e) {
          debugPrint('[DriverMode] startSession error: $e');
          return ''; // catchError requires return type String
        });
  }

  // ─── GPS (runs in background after claim succeeds) ─────────────────────────

  Future<void> _startLocationUpdates() async {
    debugPrint('[DriverMode] _startLocationUpdates() — checking service');

    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    debugPrint('[DriverMode] Location service enabled: $serviceEnabled');
    if (!serviceEnabled) {
      _showError('Location services are disabled. Bus is claimed but GPS updates are paused.');
      return;
    }

    debugPrint('[DriverMode] Requesting location permission');
    LocationPermission permission = await Geolocator.checkPermission();
    debugPrint('[DriverMode] Current permission: $permission');
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      debugPrint('[DriverMode] Permission after request: $permission');
      if (permission == LocationPermission.denied) {
        _showError('Location permission denied. Bus is claimed but GPS is off.');
        return;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      _showError('Location permission permanently denied. Open Settings to enable "Allow all the time".');
      return;
    }
    if (permission == LocationPermission.whileInUse) {
      _showError('Background tracking requires "Allow all the time" access. Please update in App Settings.');
    }

    debugPrint('[DriverMode] Permission granted — starting position stream');
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5,
    );

    _positionStream = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      (Position position) {
        if (!mounted) return;
        debugPrint('[DriverMode] GPS update #${_updateCount + 1}: ${position.latitude}, ${position.longitude}');
        
        // ─── SMART AUTO-DIRECTION DETECTION ─────────────────────────────────────
        if (widget.bus.hasFixedRoute && _chosenDirection == null) {
          if (widget.bus.startLat != null && widget.bus.startLng != null &&
              widget.bus.endLat != null && widget.bus.endLng != null) {
            
            final distToStart = Geolocator.distanceBetween(
              position.latitude, position.longitude,
              widget.bus.startLat!, widget.bus.startLng!,
            );
            final distToEnd = Geolocator.distanceBetween(
              position.latitude, position.longitude,
              widget.bus.endLat!, widget.bus.endLng!,
            );

            _chosenDirection = distToStart < distToEnd ? 'forward' : 'backward';
            debugPrint('[DriverMode] Auto-detected direction: $_chosenDirection');
          }
        }
        
        setState(() {
          _currentPosition = position;
          _updateCount++;
        });
        _firestoreService.updateBusLocation(
          widget.bus.id,
          position.latitude,
          position.longitude,
          travelDirection: _chosenDirection,
        ).then((_) {
          debugPrint('[DriverMode] Firestore lat/lng update success');
        }).catchError((e) {
          debugPrint('[DriverMode] Firestore lat/lng update error: $e');
        });
      },
      onError: (e) {
        debugPrint('[DriverMode] GPS stream error: $e');
        _showError('GPS error: $e');
      },
    );
  }

  // ─── STOP DRIVING ────────────────────────────────────────────────────────

  Future<void> _stopDriving({bool showSnackbar = true}) async {
    debugPrint('[DriverMode] _stopDriving() called');
    await _positionStream?.cancel();
    _positionStream = null;

    FlutterBackgroundService().invoke("stopService");
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('active_bus_id');

    // Resolve driver identity for bus release
    final driverId = widget.driverId ?? _authService.currentUser?.uid;
    if (driverId != null) {
      debugPrint('[DriverMode] Releasing bus in Firestore');
      try {
        await _firestoreService.releaseBus(widget.bus.id, driverId);
        debugPrint('[DriverMode] Bus released successfully');
      } catch (e) {
        debugPrint('[DriverMode] releaseBus() error: $e');
      }
    }

    // Phase 9: end session logging
    if (_sessionId != null) {
      _firestoreService.endSession(_sessionId!, _updateCount).catchError((e) {
        debugPrint('[DriverMode] endSession error: $e');
      });
      _sessionId = null;
    }

    if (mounted) {
      setState(() => _isDriving = false);
      if (showSnackbar) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Stopped driving. Bus released.'),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
          ),
        );
        Navigator.pop(context);
      }
    }
  }

  void _showError(String message) {
    debugPrint('[DriverMode] showError: $message');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  // ─── DEBUG: FORCE CLAIM (bypasses all checks) ─────────────────────────────

  Future<void> _forceClaim() async {
    debugPrint('[DriverMode] FORCE CLAIM triggered');
    
    // Support both Driver session and Firebase Auth paths
    final userId = widget.driverId ?? _authService.currentUser?.uid;
    final userName = widget.driverName ?? _authService.currentUser?.displayName ?? 'Debug Driver';

    if (userId == null) {
      _showError('Not logged in (Driver session missing)');
      return;
    }

    try {
      await _firestoreService.forceClaimBus(
        busId: widget.bus.id,
        userId: userId,
        userName: userName,
        travelDirection: _chosenDirection,
      );
      debugPrint('[DriverMode] FORCE CLAIM Firestore write done — checking...');
      if (mounted) {
        setState(() {
          _isClaiming = false;
          _isDriving = true;
          _claimFailed = false;
        });
        _startLocationUpdates();
      }
    } catch (e) {
      debugPrint('[DriverMode] FORCE CLAIM error: $e');
      _showError('Force claim failed: $e');
    }
  }

  // ─── DIRECTION PICKER ─────────────────────────────────────────────────────

  Future<String?> _showDirectionPicker() {
    final startName = widget.bus.startName ?? 'Start';
    final endName = widget.bus.endName ?? 'End';

    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Choose Direction',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Which direction are you driving today?',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
            const SizedBox(height: 20),
            _directionButton(ctx: ctx, value: 'forward',
                from: startName, to: endName, color: Colors.teal.shade700),
            const SizedBox(height: 12),
            _directionButton(ctx: ctx, value: 'backward',
                from: endName, to: startName, color: Colors.orange.shade700),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Widget _directionButton({
    required BuildContext ctx,
    required String value,
    required String from,
    required String to,
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
            Icon(Icons.circle, size: 10, color: Colors.green.shade600),
            const SizedBox(width: 8),
            Expanded(
              child: Text(from,
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: color, fontSize: 14)),
            ),
            Icon(Icons.arrow_forward_rounded, color: color, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(to,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: color, fontSize: 14)),
            ),
            const SizedBox(width: 8),
            Icon(Icons.flag, size: 10, color: Colors.red.shade600),
          ],
        ),
      ),
    );
  }

  // ─── BUILD ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: Text('Driving: ${widget.bus.name}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: Colors.orange.shade800,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (_isDriving) {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Stop Driving?'),
                  content: const Text(
                      'This will release the bus and stop sharing your location.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Keep Driving')),
                    ElevatedButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _stopDriving();
                      },
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white),
                      child: const Text('Stop & Exit'),
                    ),
                  ],
                ),
              );
            } else {
              Navigator.pop(context);
            }
          },
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    // ── Claiming state ───────────────────────────────────────────────────────
    if (_isClaiming) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Color(0xFF1A237E)),
              const SizedBox(height: 20),
              Text(
                _claimStatus,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w500),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'This should take less than 5 seconds.',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
              ),
              const SizedBox(height: 32),
              // ── Debug: Force Claim button ──────────────────────────────────
              OutlinedButton.icon(
                onPressed: _forceClaim,
                icon: const Icon(Icons.bug_report_outlined, size: 16),
                label: const Text('Force Claim (Debug)',
                    style: TextStyle(fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.orange.shade700,
                  side: BorderSide(color: Colors.orange.shade300),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // ── Claim failed state ───────────────────────────────────────────────────
    if (_claimFailed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                    color: Colors.red.shade50, shape: BoxShape.circle),
                child: Icon(Icons.block_rounded,
                    size: 56, color: Colors.red.shade400),
              ),
              const SizedBox(height: 24),
              const Text('Could Not Start',
                  style: TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              Text(
                _claimError.isNotEmpty
                    ? _claimError
                    : 'This bus may already have an active driver.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                    height: 1.5),
              ),
              const SizedBox(height: 28),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back, size: 18),
                      label: const Text('Go Back'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        // retry
                        setState(() {
                          _isClaiming = true;
                          _claimFailed = false;
                          _claimError = '';
                          _claimStatus = 'Retrying…';
                        });
                        _claimBus();
                      },
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Retry'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1A237E),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // ── Debug: Force Claim button ────────────────────────────────
              TextButton.icon(
                onPressed: () {
                  setState(() {
                    _isClaiming = true;
                    _claimFailed = false;
                    _claimStatus = 'Force claiming…';
                  });
                  _forceClaim();
                },
                icon: const Icon(Icons.bug_report_outlined, size: 16),
                label: const Text('Force Claim (Debug)'),
                style: TextButton.styleFrom(
                    foregroundColor: Colors.orange.shade700),
              ),
            ],
          ),
        ),
      );
    }

    // ── Driving state ────────────────────────────────────────────────────────
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.green.shade300, width: 3),
            ),
            child: Icon(Icons.gps_fixed_rounded,
                size: 56, color: Colors.green.shade600),
          ),
          const SizedBox(height: 24),
          const Text('You are driving!',
              style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A237E))),
          const SizedBox(height: 8),
          Text('Your location is being shared in real-time',
              style:
                  TextStyle(fontSize: 14, color: Colors.grey.shade600)),

          // Direction chip
          if (_chosenDirection != null) ...[
            const SizedBox(height: 12),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.teal.shade50,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.teal.shade200),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.navigation_rounded,
                      size: 16, color: Colors.teal.shade700),
                  const SizedBox(width: 6),
                  Text(
                    _chosenDirection == 'forward'
                        ? '${widget.bus.startName ?? "Start"} → ${widget.bus.endName ?? "End"}'
                        : '${widget.bus.endName ?? "End"} → ${widget.bus.startName ?? "Start"}',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.teal.shade800),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 32),

          _infoCard(icon: Icons.directions_bus, label: 'Bus',
              value: widget.bus.name, color: Colors.blue),
          const SizedBox(height: 12),
          _infoCard(icon: Icons.route, label: 'Route',
              value: widget.bus.route, color: Colors.purple),
          const SizedBox(height: 12),
          _infoCard(
            icon: Icons.location_on,
            label: 'GPS Position',
            value: _currentPosition != null
                ? '${_currentPosition!.latitude.toStringAsFixed(5)}, ${_currentPosition!.longitude.toStringAsFixed(5)}'
                : 'Waiting for GPS… (bus is claimed ✓)',
            color: Colors.green,
          ),
          const SizedBox(height: 12),
          _infoCard(icon: Icons.sync, label: 'Location Updates Sent',
              value: '$_updateCount', color: Colors.orange),

          const Spacer(),

          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton.icon(
              onPressed: () => _stopDriving(),
              icon: const Icon(Icons.stop_circle_rounded, size: 24),
              label: const Text('Stop Driving',
                  style:
                      TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade600,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                elevation: 3,
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _infoCard({
    required IconData icon,
    required String label,
    required String value,
    required MaterialColor color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withAlpha(10),
              blurRadius: 8,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
                color: color.shade50,
                borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, color: color.shade700, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade500,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(value,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
