import 'dart:async';
import 'dart:convert';

import 'package:ferrostar_flutter/ferrostar_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Replays a bundled sample route through the engine and shows what a host app
/// receives: the banner, the spoken text, progress and off-route state.
///
/// No map, no token, no GPS. It uses [FakeFerrostarNavigationEngine] so it runs
/// on any platform. To drive the real Ferrostar core instead, swap in
/// `PigeonFerrostarNavigationEngine()` (iOS and Android only) and feed it your
/// own location stream.
/// `flutter run --dart-define=AUTOPLAY=true` starts the replay (with one detour)
/// without a tap; used to record the screenshots in the README.
const _autoplay = bool.fromEnvironment('AUTOPLAY');

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) =>
      const MaterialApp(debugShowCheckedModeBanner: false, home: ReplayPage());
}

class ReplayPage extends StatefulWidget {
  const ReplayPage({super.key});

  @override
  State<ReplayPage> createState() => _ReplayPageState();
}

class _ReplayPageState extends State<ReplayPage> {
  final FerrostarNavigationEngine _engine = FakeFerrostarNavigationEngine();
  StreamSubscription<FerrostarEvent>? _sub;
  Timer? _timer;
  List<List<double>> _pts = const [];
  String _routeJson = '';
  int _i = 0;
  int _detourLeft = 0;
  bool _detoured = false;

  FerrostarInstruction? _instruction;
  FerrostarProgress? _progress;
  bool _offRoute = false;
  bool _arrived = false;

  @override
  void initState() {
    super.initState();
    _sub = _engine.events.listen(_onEvent);
    _load();
  }

  Future<void> _load() async {
    final json = await rootBundle.loadString('assets/route.json');
    final route = (jsonDecode(json) as Map)['routes'][0] as Map;
    setState(() {
      _routeJson = json;
      _pts = decodePolyline(route['geometry'] as String, 6);
    });
    if (_autoplay) await _start();
  }

  void _onEvent(FerrostarEvent e) {
    setState(() {
      switch (e) {
        case FerrostarInstruction():
          _instruction = e;
        case FerrostarProgress():
          _progress = e;
        case FerrostarOffRoute():
          _offRoute = e.isOffRoute;
        case FerrostarArrived():
          _arrived = true;
          _timer?.cancel();
        case FerrostarError():
          debugPrint('ferrostar error: ${e.message}');
      }
    });
  }

  Future<void> _start() async {
    _timer?.cancel();
    _i = 0;
    _arrived = false;
    _offRoute = false;
    await _engine.startNavigation(_routeJson);
    _timer = Timer.periodic(const Duration(milliseconds: 40), (_) => _tick());
  }

  void _tick() {
    if (_i >= _pts.length) {
      _timer?.cancel();
      return;
    }
    if (_autoplay && _i == 330 && _detourLeft == 0 && !_detoured) {
      _detoured = true;
      _detourLeft = 60;
    }
    final lat = _pts[_i][0];
    // A detour is just fixes that are far from the line: ~700 m east.
    final lng = _pts[_i][1] + (_detourLeft > 0 ? 0.008 : 0);
    if (_detourLeft > 0) {
      _detourLeft--;
    } else {
      _i++;
    }
    _engine.updateLocation(
      FerrostarFix(
        lat: lat,
        lng: lng,
        accuracyM: 8,
        speedMps: 27,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    _engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ins = _instruction;
    final p = _progress;
    final scheme = Theme.of(context).colorScheme;
    final modifier = '${ins?.type ?? ''} ${ins?.modifier ?? ''}'.trim();
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              color: const Color(0xFF0B3D2E),
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ins == null ? 'Press Start' : modifier.toUpperCase(),
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    ins == null
                        ? 'ferrostar_flutter'
                        : ins.bannerPrimaryText +
                              (ins.exit == null ? '' : '   EXIT ${ins.exit}'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (ins?.spokenText != null && ins!.spokenText!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '\u{1F50A} ${ins.spokenText}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: CustomPaint(
                  painter: _RoutePainter(
                    _pts,
                    _i.clamp(0, _pts.isEmpty ? 0 : _pts.length - 1),
                    _offRoute,
                    scheme.primary,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            if (p != null)
              Text(
                'Next maneuver in ${(p.distanceToNextManeuverM / 1609.34).toStringAsFixed(1)} mi'
                '  \u00B7  ${(p.distanceRemainingM / 1609.34).toStringAsFixed(1)} mi remaining',
                style: const TextStyle(fontSize: 15),
              ),
            const SizedBox(height: 8),
            if (_offRoute)
              const Chip(
                label: Text('OFF ROUTE'),
                backgroundColor: Color(0xFFFFD6D6),
              ),
            if (_arrived)
              const Chip(
                label: Text('ARRIVED'),
                backgroundColor: Color(0xFFD6F5DD),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  FilledButton(
                    onPressed: _routeJson.isEmpty ? null : _start,
                    child: const Text('Start'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: () => _detourLeft = 6,
                    child: const Text('Simulate detour'),
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

/// Draws the route line and the current position. A sketch of what you would do
/// with a real map widget.
class _RoutePainter extends CustomPainter {
  _RoutePainter(this.pts, this.index, this.off, this.color);

  final List<List<double>> pts;
  final int index;
  final bool off;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (pts.length < 2) return;
    var minLat = pts.first[0], maxLat = pts.first[0];
    var minLng = pts.first[1], maxLng = pts.first[1];
    for (final p in pts) {
      minLat = p[0] < minLat ? p[0] : minLat;
      maxLat = p[0] > maxLat ? p[0] : maxLat;
      minLng = p[1] < minLng ? p[1] : minLng;
      maxLng = p[1] > maxLng ? p[1] : maxLng;
    }
    final spanLat = (maxLat - minLat).abs() < 1e-9 ? 1e-9 : maxLat - minLat;
    final spanLng = (maxLng - minLng).abs() < 1e-3 ? 1e-3 : maxLng - minLng;
    Offset at(List<double> p) => Offset(
      size.width * 0.5 +
          (p[1] - (minLng + maxLng) / 2) / spanLng * size.width * 0.5,
      size.height - (p[0] - minLat) / spanLat * size.height,
    );
    final line = Path()..moveTo(at(pts.first).dx, at(pts.first).dy);
    for (final p in pts.skip(1)) {
      final o = at(p);
      line.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: 0.35),
    );
    final done = Path()..moveTo(at(pts.first).dx, at(pts.first).dy);
    for (final p in pts.take(index + 1).skip(1)) {
      final o = at(p);
      done.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      done,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
    final me = at(pts[index]);
    canvas.drawCircle(me, 11, Paint()..color = Colors.white);
    canvas.drawCircle(me, 8, Paint()..color = off ? Colors.red : Colors.blue);
  }

  @override
  bool shouldRepaint(_RoutePainter old) =>
      old.index != index || old.off != off || old.pts != pts;
}
