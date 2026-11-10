import 'package:flutter_test/flutter_test.dart';
import 'package:ferrostar_flutter/ferrostar_flutter.dart';
import 'package:ferrostar_flutter/src/messages.g.dart';

import 'replay_helper.dart';

class _FakeHost extends FerrostarHostApi {
  final calls = <String>[];
  FerrostarConfig? config;

  @override
  Future<void> startNavigation(String routeJson, FerrostarConfig config) async {
    calls.add('start');
    this.config = config;
  }

  @override
  Future<void> stopNavigation() async => calls.add('stop');

  @override
  Future<void> updateLocation(
    double lat,
    double lng,
    double accuracyM,
    double? speedMps,
    double? courseDeg,
    int timestampMs,
  ) async => calls.add('fix $lat,$lng,$accuracyM');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('OffRouteRule (persistence rule)', () {
    late OffRouteRule rule;
    setUp(() => rule = OffRouteRule(const FerrostarEngineConfig()));

    test('needs three consecutive trustworthy fixes beyond 250 m', () {
      expect(rule.update(distanceM: 400, accuracyM: 10), isFalse);
      expect(rule.update(distanceM: 400, accuracyM: 10), isFalse);
      expect(rule.update(distanceM: 400, accuracyM: 10), isTrue);
    });

    test('a fix back inside resets the count', () {
      rule
        ..update(distanceM: 400, accuracyM: 10)
        ..update(distanceM: 400, accuracyM: 10)
        ..update(distanceM: 100, accuracyM: 10);
      expect(rule.update(distanceM: 400, accuracyM: 10), isFalse);
    });

    test('poor-accuracy fixes neither confirm nor reset', () {
      rule
        ..update(distanceM: 400, accuracyM: 10)
        ..update(distanceM: 400, accuracyM: 150)
        ..update(distanceM: 400, accuracyM: 10);
      expect(rule.isOffRoute, isFalse);
      expect(rule.update(distanceM: 400, accuracyM: 10), isTrue);
    });

    test(
      'once off, stays off through poor fixes and clears on one near fix',
      () {
        for (var i = 0; i < 3; i++) {
          rule.update(distanceM: 400, accuracyM: 10);
        }
        expect(rule.update(distanceM: 400, accuracyM: 150), isTrue);
        expect(rule.update(distanceM: 200, accuracyM: 10), isFalse);
      },
    );
  });

  group('FakeFerrostarNavigationEngine replaying the synthetic fixture', () {
    final json = loadFerrostarFixture();
    final pts = fixtureGeometry(json);

    test(
      'drives the whole route: exit 247 banner, no off-route, arrives',
      () async {
        final engine = FakeFerrostarNavigationEngine();
        final fixes = [
          ...replayFixes(pts, stepM: 150),
          // A last fix at the destination (route length is arbitrary).
          FerrostarFix(
            lat: pts.last[0],
            lng: pts.last[1],
            accuracyM: 8,
            speedMps: 0,
            courseDeg: 0,
            timestampMs: 1800000000000,
          ),
        ];
        final log = await runReplay(engine, json, fixes);
        // ignore: avoid_print
        print(log.take(12).join('\n'));
        final instr = log.where((l) => l.startsWith('INSTR')).toList();
        expect(instr.first, contains('off ramp/slight right exit=247'));
        expect(
          instr.any((l) => l.contains('take exit 247 on the right')),
          isTrue,
        );
        expect(log.where((l) => l.startsWith('OFFROUTE')), isEmpty);
        expect(log, contains('ARRIVED'));
      },
    );

    test(
      'a 600 m offset starts off-route on the third fix and clears',
      () async {
        final engine = FakeFerrostarNavigationEngine();
        final events = <FerrostarEvent>[];
        engine.events.listen(events.add);
        await engine.startNavigation(json);
        final off = replayFixes(
          pts,
          stepM: 100,
          offsetM: 600,
          from: 100,
          to: 400,
        ).take(5).toList();
        for (final f in off) {
          await engine.updateLocation(f);
        }
        final offEvents = events.whereType<FerrostarOffRoute>().toList();
        expect(offEvents, hasLength(1));
        expect(offEvents.single.isOffRoute, isTrue);
        expect(offEvents.single.distanceFromRouteM, greaterThan(250));
        // First 2 fixes produced none (3-fix rule): only the third did.
        var seen = 0;
        for (final f in off) {
          events.clear();
          await engine.updateLocation(f);
          seen += events.whereType<FerrostarOffRoute>().length;
        }
        expect(seen, 0, reason: 'already off: no repeat events');
        events.clear();
        await engine.updateLocation(
          replayFixes(pts, stepM: 100, from: 100, to: 110).first,
        );
        expect(
          events.whereType<FerrostarOffRoute>().single.isOffRoute,
          isFalse,
        );
      },
    );

    test('two bad-accuracy far fixes never start an off-route', () async {
      final engine = FakeFerrostarNavigationEngine();
      final events = <FerrostarEvent>[];
      engine.events.listen(events.add);
      await engine.startNavigation(json);
      for (final f in replayFixes(
        pts,
        stepM: 100,
        offsetM: 900,
        accuracyM: 180,
        from: 50,
        to: 80,
      ).take(10)) {
        await engine.updateLocation(f);
      }
      expect(events.whereType<FerrostarOffRoute>(), isEmpty);
    });
  });

  group('PigeonFerrostarNavigationEngine', () {
    test('forwards calls and config to the host API', () async {
      final host = _FakeHost();
      final engine = PigeonFerrostarNavigationEngine(host: host);
      addTearDown(engine.dispose);
      await engine.startNavigation('{}');
      await engine.updateLocation(
        const FerrostarFix(lat: 1, lng: 2, accuracyM: 5, timestampMs: 9),
      );
      await engine.stopNavigation();
      expect(host.calls, ['start', 'fix 1.0,2.0,5.0', 'stop']);
      expect(host.config!.offRouteDistanceM, 250);
      expect(host.config!.offRouteConfirmFixes, 3);
      expect(host.config!.maxTrustedAccuracyM, 100);
    });

    test('maps native callbacks to typed events', () async {
      final engine = PigeonFerrostarNavigationEngine(host: _FakeHost());
      addTearDown(engine.dispose);
      final events = <FerrostarEvent>[];
      engine.events.listen(events.add);
      engine
        ..onProgress(10, 20, 30, 2)
        ..onInstruction(
          'off ramp',
          'slight right',
          '247',
          'US 231',
          null,
          'Take exit 247',
          1609,
        )
        ..onOffRoute(true, 400)
        ..onArrived()
        ..onError('boom');
      expect(events, hasLength(5));
      final i = events[1] as FerrostarInstruction;
      expect(i.exit, '247');
      expect(i.modifier, 'slight right');
      expect((events[2] as FerrostarOffRoute).isOffRoute, isTrue);
      expect(events[3], isA<FerrostarArrived>());
      expect((events[4] as FerrostarError).message, 'boom');
    });
  });
}
