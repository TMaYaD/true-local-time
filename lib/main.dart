import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

void main() => runApp(const TrueLocalTimeApp());

class TrueLocalTimeApp extends StatelessWidget {
  const TrueLocalTimeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'True Local Time',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Position? _position;
  String? _error;
  Timer? _ticker;
  StreamSubscription<Position>? _positionSub;
  DateTime _utcNow = DateTime.now().toUtc();

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _utcNow = DateTime.now().toUtc());
    });
    _initLocation();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _positionSub?.cancel();
    super.dispose();
  }

  Future<void> _initLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        setState(() => _error = 'Location services are disabled.');
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        setState(() => _error = 'Location permission denied.');
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      setState(() {
        _position = pos;
        _error = null;
      });
      _positionSub = Geolocator.getPositionStream().listen(
        (pos) => setState(() => _position = pos),
      );
    } catch (e) {
      setState(() => _error = 'Failed to get location: $e');
    }
  }

  // Local solar time = UTC shifted by 4 minutes per degree of longitude
  // (east of Greenwich is ahead, west is behind).
  DateTime get _localSolarTime {
    final longitude = _position?.longitude ?? 0;
    return _utcNow.add(Duration(seconds: (longitude * 4 * 60).round()));
  }

  @override
  Widget build(BuildContext context) {
    final time = _localSolarTime;
    final position = _position;
    final coords = position == null
        ? (_error ?? 'Locating…')
        : 'Lat ${position.latitude.toStringAsFixed(5)}    '
            'Lon ${position.longitude.toStringAsFixed(5)}';

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                DateFormat('EEEE, d MMMM yyyy').format(time),
                style: const TextStyle(fontSize: 18),
              ),
              const SizedBox(height: 12),
              Text(
                DateFormat('HH:mm:ss').format(time),
                style: const TextStyle(
                  fontSize: 76,
                  fontWeight: FontWeight.bold,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                coords,
                style: const TextStyle(fontSize: 15),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
