import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class LocationService {
  static Future<void> initialize() async {
    final service = FlutterBackgroundService();

    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'location_service', // id
      'Location Tracking', // title
      description: 'This channel is used for background location tracking.', // description
      importance: Importance.low,
    );

    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
        FlutterLocalNotificationsPlugin();

    if (Platform.isAndroid) {
       await flutterLocalNotificationsPlugin.initialize(
         const InitializationSettings(
           android: AndroidInitializationSettings('@mipmap/ic_launcher'),
         )
       );
    }

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false, // Only start when driver clicks 'Claim'
        isForegroundMode: true,
        notificationChannelId: 'location_service',
        initialNotificationTitle: 'VCE Bus Tracking',
        initialNotificationContent: 'Sending live location...',
        foregroundServiceTypes: [AndroidForegroundType.location],
      ),
      iosConfiguration: IosConfiguration(),
    );
  }
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(); // Background needs its own Firebase link

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  Timer.periodic(const Duration(seconds: 10), (timer) async {
    // 1. Get location
    Position pos = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high
    );

    // 2. Get the Bus ID saved when the driver logged in
    final prefs = await SharedPreferences.getInstance();
    String? busId = prefs.getString('active_bus_id');

    if (busId != null) {
      // 3. Push to Firestore
      await FirebaseFirestore.instance.collection('buses').doc(busId).update({
        'lat': pos.latitude,
        'lng': pos.longitude,
        'lastUpdated': FieldValue.serverTimestamp(),
      });
    }

    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: "VCE Bus Live",
        content: "Tracking active - ${DateTime.now().hour}:${DateTime.now().minute}",
      );
    }
  });
}
