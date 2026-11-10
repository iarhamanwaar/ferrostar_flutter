import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:ferrostar_flutter/src/engine.dart';
import 'package:ferrostar_flutter/src/off_route_rule.dart';

/// Pure-Dart stand-in for the native core. It really follows the route: it
/// parses the OSRM-style JSON, snaps each fix to the line, and emits the same
/// event types the native core does (progress per fix, instruction on step /
/// spoken-trigger change, off-route on state change using [OffRouteRule],
/// arrival). Used by tests and the replay harness; also records calls.
///
/// It is a behavioural reference, not a proof about the native core: the
/// on-device replay (a host-app integration test on a simulator/emulator) is what
/// exercises Ferrostar itself.
class FakeFerrostarNavigationEngine implements FerrostarNavigationEngine {
  final _controller = StreamController<FerrostarEvent>.broadcast(sync: true);

  /// Every call made, for assertions.
  final List<String> calls = [];

  bool _active = false;
  late _Route _route;
  late OffRouteRule _rule;
  int _lastIdx = 0;
  double _maxAlong = 0;
  int _stepIndex = -1;
  int _voiceIdx = -2;
  bool _wasOff = false;
  bool _arrived = false;
  bool _enabled = true;

  @override
  Stream<FerrostarEvent> get events => _controller.stream;

  /// Lets a test inject an arbitrary event (e.g. an error).
  void emit(FerrostarEvent event) => _controller.add(event);

  @override
  Future<void> startNavigation(
    String routeJson, {
    FerrostarEngineConfig config = const FerrostarEngineConfig(),
  }) async {
    calls.add('start');
    _route = _Route.parse(routeJson, config.polylinePrecision);
    _rule = OffRouteRule(config);
    _enabled = config.offRouteEnabled;
    _lastIdx = 0;
    _maxAlong = 0;
    _stepIndex = -1;
    _voiceIdx = -2;
    _wasOff = false;
    _arrived = false;
    _active = true;
  }

  @override
  Future<void> stopNavigation() async {
    calls.add('stop');
    _active = false;
  }

  @override
  Future<void> updateLocation(FerrostarFix fix) async {
    calls.add('fix');
    if (!_active || _arrived) return;
    final snap = _route.snap(fix.lat, fix.lng, _lastIdx);
    _lastIdx = snap.index;

    final off =
        _enabled &&
        _rule.update(distanceM: snap.distanceM, accuracyM: fix.accuracyM);
    if (off != _wasOff) {
      _wasOff = off;
      _controller.add(
        FerrostarOffRoute(isOffRoute: off, distanceFromRouteM: snap.distanceM),
      );
    }
    // Progress only moves forward while on the line.
    if (!off && snap.distanceM <= 250) {
      _maxAlong = math.max(_maxAlong, snap.alongM);
    }
    final step = _route.stepAt(_maxAlong);
    final toManeuver = math.max(0, _route.stepEnd[step] - _maxAlong);
    final remaining = math.max(0, _route.length - _maxAlong);
    _controller.add(
      FerrostarProgress(
        distanceToNextManeuverM: toManeuver.toDouble(),
        distanceRemainingM: remaining.toDouble(),
        durationRemainingS: _route.duration * remaining / _route.length,
        stepIndex: step,
      ),
    );

    final voice = _route.voiceIndex(step, toManeuver.toDouble());
    if (step != _stepIndex || voice != _voiceIdx) {
      _stepIndex = step;
      _voiceIdx = voice;
      _controller.add(_route.instruction(step, voice));
    }

    if (step == _route.steps.length - 1 || remaining < 60) {
      _arrived = true;
      _controller.add(const FerrostarArrived());
    }
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await _controller.close();
  }
}

class _Snap {
  _Snap(this.index, this.distanceM, this.alongM);
  final int index;
  final double distanceM;
  final double alongM;
}

class _Step {
  _Step(this.json);
  final Map<String, dynamic> json;
  double get distance => (json['distance'] as num).toDouble();
}

class _Route {
  _Route(this.pts, this.steps, this.duration) {
    cum = List<double>.filled(pts.length, 0);
    for (var i = 1; i < pts.length; i++) {
      cum[i] = cum[i - 1] + _hav(pts[i - 1], pts[i]);
    }
    length = cum.last;
    final total = steps.fold<double>(0, (a, s) => a + s.distance);
    final scale = total > 0 ? length / total : 1.0;
    var acc = 0.0;
    stepEnd = [for (final s in steps) acc += s.distance * scale];
  }

  factory _Route.parse(String json, int precision) {
    final root = jsonDecode(json) as Map<String, dynamic>;
    final route = (root['routes'] as List).first as Map<String, dynamic>;
    final pts = decodePolyline(route['geometry'] as String, precision);
    final steps = <_Step>[
      for (final leg in route['legs'] as List)
        for (final s in (leg as Map<String, dynamic>)['steps'] as List)
          _Step(s as Map<String, dynamic>),
    ];
    return _Route(pts, steps, (route['duration'] as num).toDouble());
  }

  final List<List<double>> pts; // [lat, lng]
  final List<_Step> steps;
  final double duration;
  late final List<double> cum;
  late final double length;
  late final List<double> stepEnd;

  int stepAt(double along) {
    for (var i = 0; i < stepEnd.length; i++) {
      if (along < stepEnd[i]) return i;
    }
    return steps.length - 1;
  }

  /// Index of the voice instruction to speak: the one with the smallest
  /// trigger distance that is still >= the distance to the maneuver.
  int voiceIndex(int step, double toManeuverM) {
    final v = (steps[step].json['voiceInstructions'] as List?) ?? const [];
    var best = -1;
    for (var i = 0; i < v.length; i++) {
      final d = ((v[i] as Map)['distanceAlongGeometry'] as num).toDouble();
      if (toManeuverM <= d) best = i;
    }
    return best;
  }

  FerrostarInstruction instruction(int step, int voice) {
    final j = steps[step].json;
    final banner = ((j['bannerInstructions'] as List?) ?? const []).isEmpty
        ? null
        : (j['bannerInstructions'] as List).first as Map<String, dynamic>;
    final primary = banner?['primary'] as Map<String, dynamic>?;
    final secondary = banner?['secondary'] as Map<String, dynamic>?;
    String? exit;
    for (final c in (primary?['components'] as List?) ?? const []) {
      if ((c as Map)['type'] == 'exit-number') exit = c['text'] as String?;
    }
    final v = (j['voiceInstructions'] as List?) ?? const [];
    final spoken = voice >= 0 && voice < v.length ? v[voice] as Map : null;
    return FerrostarInstruction(
      type: primary?['type'] as String?,
      modifier: primary?['modifier'] as String?,
      exit: exit,
      bannerPrimaryText: (primary?['text'] as String?) ?? '',
      bannerSecondaryText: secondary?['text'] as String?,
      spokenText: spoken?['announcement'] as String?,
      distanceTriggerM:
          ((spoken?['distanceAlongGeometry'] ??
                      banner?['distanceAlongGeometry'] ??
                      0)
                  as num)
              .toDouble(),
    );
  }

  /// Nearest point on the line, searching a window around [hint] first and the
  /// whole line only when the window finds nothing close.
  _Snap snap(double lat, double lng, int hint) {
    var best = _scan(
      lat,
      lng,
      math.max(0, hint - 50),
      math.min(pts.length - 1, hint + 3000),
    );
    if (best.distanceM > 150) best = _scan(lat, lng, 0, pts.length - 1);
    return best;
  }

  _Snap _scan(double lat, double lng, int from, int to) {
    final kx = 111320 * math.cos(lat * math.pi / 180);
    const ky = 110574.0;
    var bd = double.infinity;
    var bi = from;
    var ba = 0.0;
    for (var i = from; i < to; i++) {
      final ax = (pts[i][1] - lng) * kx, ay = (pts[i][0] - lat) * ky;
      final bx = (pts[i + 1][1] - lng) * kx, by = (pts[i + 1][0] - lat) * ky;
      final dx = bx - ax, dy = by - ay;
      final l2 = dx * dx + dy * dy;
      final t = l2 == 0 ? 0.0 : (-(ax * dx + ay * dy) / l2).clamp(0.0, 1.0);
      final px = ax + t * dx, py = ay + t * dy;
      final d = math.sqrt(px * px + py * py);
      if (d < bd) {
        bd = d;
        bi = i;
        ba = cum[i] + t * (cum[i + 1] - cum[i]);
      }
    }
    return _Snap(bi, bd, ba);
  }
}

double _hav(List<double> a, List<double> b) {
  const r = 6371008.8;
  final p1 = a[0] * math.pi / 180, p2 = b[0] * math.pi / 180;
  final dp = p2 - p1, dl = (b[1] - a[1]) * math.pi / 180;
  final h =
      math.pow(math.sin(dp / 2), 2) +
      math.cos(p1) * math.cos(p2) * math.pow(math.sin(dl / 2), 2);
  return 2 * r * math.asin(math.sqrt(h));
}

/// Decodes an encoded polyline to [lat, lng] pairs.
List<List<double>> decodePolyline(String s, int precision) {
  final f = math.pow(10, precision).toDouble();
  final out = <List<double>>[];
  var i = 0, lat = 0, lng = 0;
  int next() {
    var shift = 0, result = 0, b = 0;
    do {
      b = s.codeUnitAt(i++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    return (result & 1) != 0 ? ~(result >> 1) : result >> 1;
  }

  while (i < s.length) {
    lat += next();
    lng += next();
    out.add([lat / f, lng / f]);
  }
  return out;
}
