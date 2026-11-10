import 'dart:async';

import 'package:ferrostar_flutter/src/engine.dart';
import 'package:ferrostar_flutter/src/messages.g.dart';

/// [FerrostarNavigationEngine] backed by the native Ferrostar core over the
/// Pigeon channel (iOS: Swift, Android: Kotlin).
class PigeonFerrostarNavigationEngine extends FerrostarFlutterApi
    implements FerrostarNavigationEngine {
  PigeonFerrostarNavigationEngine({FerrostarHostApi? host})
    : _host = host ?? FerrostarHostApi() {
    FerrostarFlutterApi.setUp(this);
  }

  final FerrostarHostApi _host;
  final _controller = StreamController<FerrostarEvent>.broadcast(sync: true);

  @override
  Stream<FerrostarEvent> get events => _controller.stream;

  @override
  Future<void> startNavigation(
    String routeJson, {
    FerrostarEngineConfig config = const FerrostarEngineConfig(),
  }) => _host.startNavigation(
    routeJson,
    FerrostarConfig(
      offRouteEnabled: config.offRouteEnabled,
      offRouteDistanceM: config.offRouteDistanceM,
      offRouteConfirmFixes: config.offRouteConfirmFixes,
      maxTrustedAccuracyM: config.maxTrustedAccuracyM,
      polylinePrecision: config.polylinePrecision,
    ),
  );

  @override
  Future<void> stopNavigation() => _host.stopNavigation();

  @override
  Future<void> updateLocation(FerrostarFix fix) => _host.updateLocation(
    fix.lat,
    fix.lng,
    fix.accuracyM,
    fix.speedMps,
    fix.courseDeg,
    fix.timestampMs,
  );

  @override
  Future<void> dispose() async {
    FerrostarFlutterApi.setUp(null);
    await _controller.close();
  }

  @override
  void onProgress(
    double distanceToNextManeuverM,
    double distanceRemainingM,
    double durationRemainingS,
    int stepIndex,
  ) => _add(
    FerrostarProgress(
      distanceToNextManeuverM: distanceToNextManeuverM,
      distanceRemainingM: distanceRemainingM,
      durationRemainingS: durationRemainingS,
      stepIndex: stepIndex,
    ),
  );

  @override
  void onInstruction(
    String? type,
    String? modifier,
    String? exit,
    String bannerPrimaryText,
    String? bannerSecondaryText,
    String? spokenText,
    double distanceTriggerM,
  ) => _add(
    FerrostarInstruction(
      type: type,
      modifier: modifier,
      exit: exit,
      bannerPrimaryText: bannerPrimaryText,
      bannerSecondaryText: bannerSecondaryText,
      spokenText: spokenText,
      distanceTriggerM: distanceTriggerM,
    ),
  );

  @override
  void onOffRoute(bool isOffRoute, double distanceFromRouteM) => _add(
    FerrostarOffRoute(
      isOffRoute: isOffRoute,
      distanceFromRouteM: distanceFromRouteM,
    ),
  );

  @override
  void onArrived() => _add(const FerrostarArrived());

  @override
  void onError(String message) => _add(FerrostarError(message));

  void _add(FerrostarEvent e) {
    if (!_controller.isClosed) _controller.add(e);
  }
}
