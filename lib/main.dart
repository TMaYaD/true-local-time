import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
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

// --- Geometry -------------------------------------------------------------

class LatLng {
  final double lat, lon;
  const LatLng(this.lat, this.lon);
}

class GlobeGeometry {
  // Faint political boundaries (India's official point of view; only
  // well-defined international boundaries, no disputed lines).
  final List<List<LatLng>> boundaryLines;
  // Prominent timezone outlines.
  final List<List<LatLng>> timezoneRings;
  const GlobeGeometry(this.boundaryLines, this.timezoneRings);
}

Future<GlobeGeometry> loadGlobeGeometry() async {
  Future<List<List<LatLng>>> load(String path) async {
    final lines = <List<LatLng>>[];
    _collectLines(jsonDecode(await rootBundle.loadString(path)), lines);
    return lines;
  }

  return GlobeGeometry(
    await load('assets/geo/boundaries_india_pov.geojson'),
    await load('assets/geo/timezones_simplified.geojson'),
  );
}

// Walks any GeoJSON object (FeatureCollection / GeometryCollection / Feature /
// Polygon / MultiPolygon / LineString / MultiLineString) and appends every
// ring or line as a flat list of points to [out].
void _collectLines(dynamic geo, List<List<LatLng>> out) {
  if (geo is! Map) return;
  switch (geo['type']) {
    case 'FeatureCollection':
      for (final f in (geo['features'] as List)) {
        _collectLines(f, out);
      }
    case 'Feature':
      _collectLines(geo['geometry'], out);
    case 'GeometryCollection':
      for (final g in (geo['geometries'] as List)) {
        _collectLines(g, out);
      }
    case 'LineString':
      out.add(_parseCoords(geo['coordinates'] as List));
    case 'MultiLineString':
      for (final line in (geo['coordinates'] as List)) {
        out.add(_parseCoords(line as List));
      }
    case 'Polygon':
      for (final ring in (geo['coordinates'] as List)) {
        out.add(_parseCoords(ring as List));
      }
    case 'MultiPolygon':
      for (final poly in (geo['coordinates'] as List)) {
        for (final ring in (poly as List)) {
          out.add(_parseCoords(ring as List));
        }
      }
  }
}

// GeoJSON coordinate order is [longitude, latitude].
List<LatLng> _parseCoords(List coords) => [
      for (final c in coords)
        LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
    ];

// --- Projection -----------------------------------------------------------

double _wrap180(double degrees) {
  var d = (degrees + 180) % 360;
  if (d < 0) d += 360;
  return d - 180;
}

/// Orthographic projection of [lat]/[lon] onto a globe drawn equator-on with
/// the meridian [centerLon] facing the viewer, of radius [r] centred at
/// ([cx], [cy]). The point is on the visible (near) hemisphere when
/// `cosc > 0`.
({double x, double y, double cosc}) projectOrtho(
  double lat,
  double lon,
  double centerLon,
  double cx,
  double cy,
  double r,
) {
  final dLon = _wrap180(lon - centerLon) * math.pi / 180;
  final latRad = lat * math.pi / 180;
  final cosLat = math.cos(latRad);
  return (
    x: cx + r * cosLat * math.sin(dLon),
    y: cy - r * math.sin(latRad),
    cosc: cosLat * math.cos(dLon),
  );
}

// --- Home screen ----------------------------------------------------------

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

  GlobeGeometry? _geometry;
  bool _geoLoadFailed = false;
  // Longitude currently facing the viewer at the centre of the globe.
  double? _centerLon;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _utcNow = DateTime.now().toUtc());
    });
    _initLocation();
    loadGlobeGeometry().then((g) {
      if (mounted) setState(() => _geometry = g);
    }).catchError((_) {
      if (mounted) setState(() => _geoLoadFailed = true);
    });
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
        setState(() {
          _error = 'Location services are disabled.';
          _centerLon ??= 0;
        });
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        setState(() {
          _error = 'Location permission denied.';
          _centerLon ??= 0;
        });
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      setState(() {
        _position = pos;
        _error = null;
        _centerLon ??= pos.longitude;
      });
      _positionSub = Geolocator.getPositionStream().listen((pos) {
        setState(() {
          _position = pos;
          _centerLon ??= pos.longitude;
        });
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to get location: $e';
        _centerLon ??= 0;
      });
    }
  }

  double get _effectiveCenterLon => _centerLon ?? _position?.longitude ?? 0;

  // True local time = UTC shifted by 4 minutes per degree of the longitude
  // currently at the centre of the globe (east is ahead, west is behind).
  DateTime get _localSolarTime =>
      _utcNow.add(Duration(seconds: (_effectiveCenterLon * 4 * 60).round()));

  // Dragging right brings westward meridians into view, so centreLon drops.
  // A drag across the globe's radius sweeps 90 degrees of longitude.
  void _rotate(double dxPixels, double radius) {
    setState(() {
      _centerLon = _wrap180(_effectiveCenterLon - dxPixels * (90.0 / radius));
    });
  }

  void _resetRotation() {
    setState(() => _centerLon = _position?.longitude ?? 0);
  }

  static String _formatLon(double lon) {
    final hemisphere = lon >= 0 ? 'E' : 'W';
    return '${lon.abs().toStringAsFixed(2)}° $hemisphere';
  }

  @override
  Widget build(BuildContext context) {
    final time = _localSolarTime;
    final centerLon = _effectiveCenterLon;
    final atGps = _position != null &&
        _centerLon != null &&
        (_centerLon! - _position!.longitude).abs() < 1e-4;

    final String bottomLabel;
    if (_geoLoadFailed) {
      bottomLabel = 'Map data unavailable';
    } else if (_geometry == null) {
      bottomLabel = 'Loading map…';
    } else {
      bottomLabel =
          _formatLon(centerLon) + (atGps ? '   ·   your location' : '');
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Column(
                children: [
                  Text(
                    DateFormat('EEEE, d MMMM yyyy').format(time),
                    style: const TextStyle(fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    DateFormat('HH:mm:ss').format(time),
                    style: const TextStyle(
                      fontSize: 64,
                      fontWeight: FontWeight.bold,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final side =
                        math.min(constraints.maxWidth, constraints.maxHeight);
                    final radius = side / 2;
                    return SizedBox(
                      width: side,
                      height: side,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: GestureDetector(
                              onHorizontalDragUpdate: (d) =>
                                  _rotate(d.delta.dx, radius),
                              child: CustomPaint(
                                painter: GlobePainter(
                                  geometry: _geometry,
                                  centerLon: centerLon,
                                  position: _position,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            right: 6,
                            bottom: 6,
                            child: _ResetButton(onTap: _resetRotation),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 12),
              child: Column(
                children: [
                  Text(
                    bottomLabel,
                    style: const TextStyle(fontSize: 15),
                    textAlign: TextAlign.center,
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        _error!,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white54),
                        textAlign: TextAlign.center,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- Globe painter --------------------------------------------------------

class GlobePainter extends CustomPainter {
  final GlobeGeometry? geometry;
  final double centerLon;
  final Position? position;

  GlobePainter({
    required this.geometry,
    required this.centerLon,
    required this.position,
  });

  late double _cx, _cy, _r;

  ({double x, double y, double cosc}) _project(double lat, double lon) =>
      projectOrtho(lat, lon, centerLon, _cx, _cy, _r);

  // Where the segment a->b crosses the visible horizon, clamped to the limb.
  Offset _horizon(
      ({double x, double y, double cosc}) a,
      ({double x, double y, double cosc}) b) {
    final t = a.cosc / (a.cosc - b.cosc);
    var x = a.x + (b.x - a.x) * t;
    var y = a.y + (b.y - a.y) * t;
    final dx = x - _cx, dy = y - _cy;
    final d = math.sqrt(dx * dx + dy * dy);
    if (d > 0) {
      x = _cx + dx / d * _r;
      y = _cy + dy / d * _r;
    }
    return Offset(x, y);
  }

  // Appends a ring's visible segments to [path], breaking it where the ring
  // passes behind the horizon.
  void _addRing(Path path, List<LatLng> ring) {
    ({double x, double y, double cosc})? prev;
    for (final pt in ring) {
      final cur = _project(pt.lat, pt.lon);
      final curVisible = cur.cosc > 0;
      if (prev == null) {
        if (curVisible) path.moveTo(cur.x, cur.y);
      } else {
        final prevVisible = prev.cosc > 0;
        if (prevVisible && curVisible) {
          path.lineTo(cur.x, cur.y);
        } else if (prevVisible && !curVisible) {
          final h = _horizon(prev, cur);
          path.lineTo(h.dx, h.dy);
        } else if (!prevVisible && curVisible) {
          final h = _horizon(prev, cur);
          path.moveTo(h.dx, h.dy);
          path.lineTo(cur.x, cur.y);
        }
      }
      prev = cur;
    }
  }

  Path _buildPath(List<List<LatLng>> rings) {
    final path = Path();
    for (final ring in rings) {
      _addRing(path, ring);
    }
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    _cx = size.width / 2;
    _cy = size.height / 2;
    _r = math.min(_cx, _cy) - 2;
    final center = Offset(_cx, _cy);

    // Ocean disc.
    canvas.drawCircle(center, _r, Paint()..color = const Color(0xFF0A1B2E));

    canvas.save();
    canvas.clipPath(
        Path()..addOval(Rect.fromCircle(center: center, radius: _r)));

    final geo = geometry;
    if (geo != null) {
      // Faint political boundaries underneath.
      canvas.drawPath(
        _buildPath(geo.boundaryLines),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6
          ..color = Colors.white24,
      );
      // Prominent timezone outlines on top.
      canvas.drawPath(
        _buildPath(geo.timezoneRings),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3
          ..color = const Color(0xFF7FB3D5),
      );
    }

    final pos = position;
    if (pos != null) {
      // Blue meridian at the device longitude, painted on the globe so it
      // rotates with it.
      final meridian = <LatLng>[
        for (var lat = -90.0; lat <= 90.0; lat += 2.0)
          LatLng(lat, pos.longitude),
      ];
      final meridianPath = Path();
      _addRing(meridianPath, meridian);
      canvas.drawPath(
        meridianPath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = Colors.lightBlueAccent,
      );

      // Device location: blue dot inside a blue circle, hidden on the far side.
      final marker = _project(pos.latitude, pos.longitude);
      if (marker.cosc > 0) {
        final spot = Offset(marker.x, marker.y);
        canvas.drawCircle(
          spot,
          9,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Colors.lightBlueAccent,
        );
        canvas.drawCircle(spot, 3.5, Paint()..color = Colors.lightBlueAccent);
      }
    }

    canvas.restore();

    // Globe outline on top.
    canvas.drawCircle(
      center,
      _r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(GlobePainter old) =>
      old.centerLon != centerLon ||
      old.geometry != geometry ||
      old.position != position;
}

// --- Reset button ---------------------------------------------------------

class _ResetButton extends StatelessWidget {
  final VoidCallback onTap;
  const _ResetButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: const SizedBox(
        width: 40,
        height: 40,
        child: CustomPaint(painter: _ResetButtonPainter()),
      ),
    );
  }
}

class _ResetButtonPainter extends CustomPainter {
  const _ResetButtonPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(
        center, size.width / 2, Paint()..color = const Color(0xCC0A1B2E));
    canvas.drawCircle(
      center,
      11,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Colors.lightBlueAccent,
    );
    canvas.drawCircle(center, 4.5, Paint()..color = Colors.lightBlueAccent);
  }

  @override
  bool shouldRepaint(_ResetButtonPainter oldDelegate) => false;
}
