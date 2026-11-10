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
    return Scaffold(
      appBar: AppBar(title: const Text('ferrostar_flutter replay')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              child: ListTile(
                title: Text(
                  ins == null
                      ? 'Press Start'
                      : '${ins.type ?? ''} ${ins.modifier ?? ''}'.trim(),
                ),
                subtitle: Text(
                  ins == null
                      ? ''
                      : '${ins.bannerPrimaryText}'
                            '${ins.exit == null ? '' : '  (exit ${ins.exit})'}'
                            '\n${ins.spokenText ?? ''}',
                ),
                isThreeLine: true,
              ),
            ),
            if (p != null)
              Text(
                'Next maneuver in ${(p.distanceToNextManeuverM / 1609.34).toStringAsFixed(1)} mi, '
                '${(p.distanceRemainingM / 1609.34).toStringAsFixed(1)} mi remaining',
              ),
            const SizedBox(height: 8),
            if (_offRoute) const Chip(label: Text('OFF ROUTE')),
            if (_arrived) const Chip(label: Text('ARRIVED')),
            const Spacer(),
            Row(
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
          ],
        ),
      ),
    );
  }
}
