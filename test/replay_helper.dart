import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:ferrostar_flutter/ferrostar_flutter.dart';

const ferrostarFixturePath = 'test/fixtures/synthetic_route_ferrostar.json';

const _fixturePath = String.fromEnvironment(
  'FERROSTAR_FIXTURE',
  defaultValue: ferrostarFixturePath,
);

const _fixtureJson = String.fromEnvironment('FERROSTAR_FIXTURE_JSON');

/// Fixture JSON: from `--dart-define=FERROSTAR_FIXTURE_JSON=...` (emulators
/// cannot read host paths) or from the file at [_fixturePath].
String loadFerrostarFixture() => _fixtureJson.isNotEmpty
    ? _fixtureJson
    : File(_fixturePath).readAsStringSync();

/// Route vertices of the fixture as [lat, lng].
List<List<double>> fixtureGeometry(String json) {
  final r = (jsonDecode(json) as Map<String, dynamic>)['routes'] as List;
  return decodePolyline(
    (r.first as Map<String, dynamic>)['geometry'] as String,
    6,
  );
}

/// Simulated GPS fixes along [pts], one every [stepM] metres of travel at
/// [speedMps], with [offsetM] of sideways (perpendicular) offset and [accuracyM].
Iterable<FerrostarFix> replayFixes(
  List<List<double>> pts, {
  double stepM = 100,
  double speedMps = 27,
  double offsetM = 0,
  double accuracyM = 8,
  int from = 0,
  int? to,
}) sync* {
  var t = 1700000000000;
  var carry = 0.0;
  final end = to ?? pts.length - 1;
  for (var i = from; i < end; i++) {
    final a = pts[i], b = pts[i + 1];
    final dLat = (b[0] - a[0]) * 110574;
    final dLng = (b[1] - a[1]) * 111320 * math.cos(a[0] * math.pi / 180);
    final len = math.sqrt(dLat * dLat + dLng * dLng);
    var pos = stepM - carry;
    while (pos <= len) {
      final f = pos / len;
      yield FerrostarFix(
        // Perpendicular (left of travel) offset in metres.
        lat:
            a[0] +
            (b[0] - a[0]) * f +
            (len == 0 ? 0 : -dLng / len * offsetM) / 110574,
        lng:
            a[1] +
            (b[1] - a[1]) * f +
            (len == 0 ? 0 : dLat / len * offsetM) /
                (111320 * math.cos(a[0] * math.pi / 180)),
        accuracyM: accuracyM,
        speedMps: speedMps,
        courseDeg: 0,
        timestampMs: t += (stepM / speedMps * 1000).round(),
      );
      pos += stepM;
    }
    carry = len - (pos - stepM);
  }
}

/// Dev-only harness: starts [engine] on the fixture, feeds every fix and
/// returns a printable transcript of the instruction / off-route / arrival
/// events (progress events are summarised, not listed).
Future<List<String>> runReplay(
  FerrostarNavigationEngine engine,
  String routeJson,
  Iterable<FerrostarFix> fixes,
) async {
  final log = <String>[];
  var progress = 0;
  final sub = engine.events.listen((e) {
    switch (e) {
      case FerrostarProgress():
        progress++;
      case FerrostarInstruction():
        log.add(
          'INSTR ${e.type ?? "-"}/${e.modifier ?? "-"} exit=${e.exit ?? "-"} '
          '"${e.bannerPrimaryText}" trig=${e.distanceTriggerM.round()}m '
          'say="${e.spokenText ?? ""}"',
        );
      case FerrostarOffRoute():
        log.add('OFFROUTE ${e.isOffRoute} ${e.distanceFromRouteM.round()}m');
      case FerrostarArrived():
        log.add('ARRIVED');
      case FerrostarError():
        log.add('ERROR ${e.message}');
    }
  });
  await engine.startNavigation(routeJson);
  for (final f in fixes) {
    await engine.updateLocation(f);
  }
  await engine.stopNavigation();
  await sub.cancel();
  log.add('progress events: $progress');
  return log;
}
