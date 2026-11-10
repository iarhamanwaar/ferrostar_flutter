import 'dart:async';

/// Tunables for the native core.
///
/// Off-route detection replaces Ferrostar's stock single-fix detectors with a
/// persistence rule, and rerouting is always disabled (a deviation only
/// produces an event; the host app decides what to do):
///
/// * a fix counts as "beyond" when it is farther than [offRouteDistanceM]
///   from the remaining route line;
/// * a fix whose horizontal accuracy is worse than [maxTrustedAccuracyM]
///   neither confirms nor clears an off-route;
/// * [offRouteConfirmFixes] consecutive trustworthy beyond-fixes start an
///   off-route (1 reproduces a single-fix detector);
/// * once off route, the first fix back within [offRouteDistanceM] clears it.
///
/// The defaults (250 m, 3 fixes, 100 m) suit long-haul trucking where a lone
/// GPS jump should not raise an alarm; tune them for your use case.
class FerrostarEngineConfig {
  const FerrostarEngineConfig({
    this.offRouteEnabled = true,
    this.offRouteDistanceM = 250,
    this.offRouteConfirmFixes = 3,
    this.maxTrustedAccuracyM = 100,
    this.polylinePrecision = 6,
  });

  /// False disables deviation tracking (no [FerrostarOffRoute] events).
  final bool offRouteEnabled;
  final double offRouteDistanceM;
  final int offRouteConfirmFixes;
  final double maxTrustedAccuracyM;

  /// Polyline precision of the route JSON (Valhalla 6, OSRM 5).
  final int polylinePrecision;
}

/// One GPS fix from the app's own location stream.
class FerrostarFix {
  const FerrostarFix({
    required this.lat,
    required this.lng,
    required this.accuracyM,
    required this.timestampMs,
    this.speedMps,
    this.courseDeg,
  });

  final double lat;
  final double lng;
  final double accuracyM;
  final double? speedMps;
  final double? courseDeg;
  final int timestampMs;
}

sealed class FerrostarEvent {
  const FerrostarEvent();
}

class FerrostarProgress extends FerrostarEvent {
  const FerrostarProgress({
    required this.distanceToNextManeuverM,
    required this.distanceRemainingM,
    required this.durationRemainingS,
    required this.stepIndex,
  });

  final double distanceToNextManeuverM;
  final double distanceRemainingM;
  final double durationRemainingS;
  final int stepIndex;
}

class FerrostarInstruction extends FerrostarEvent {
  const FerrostarInstruction({
    required this.bannerPrimaryText,
    required this.distanceTriggerM,
    this.type,
    this.modifier,
    this.exit,
    this.bannerSecondaryText,
    this.spokenText,
  });

  /// Valhalla/OSRM maneuver type ("off ramp", "fork", "turn" ...).
  final String? type;

  /// "slight right", "left", "straight" ...
  final String? modifier;

  /// First exit number, e.g. "247".
  final String? exit;
  final String bannerPrimaryText;
  final String? bannerSecondaryText;
  final String? spokenText;
  final double distanceTriggerM;
}

class FerrostarOffRoute extends FerrostarEvent {
  const FerrostarOffRoute({
    required this.isOffRoute,
    required this.distanceFromRouteM,
  });

  final bool isOffRoute;
  final double distanceFromRouteM;
}

class FerrostarArrived extends FerrostarEvent {
  const FerrostarArrived();
}

class FerrostarError extends FerrostarEvent {
  const FerrostarError(this.message);
  final String message;
}

/// Headless navigation core.
///
/// The app feeds [updateLocation]; the core answers on [events]. It never
/// reroutes: a deviation only produces a [FerrostarOffRoute] event.
abstract class FerrostarNavigationEngine {
  Stream<FerrostarEvent> get events;

  /// Parses an OSRM-style route JSON (Valhalla `format=osrm` with banner and
  /// voice instructions) and starts a session. Throws a `PlatformException`
  /// on a route the core cannot parse.
  Future<void> startNavigation(
    String routeJson, {
    FerrostarEngineConfig config = const FerrostarEngineConfig(),
  });

  Future<void> stopNavigation();

  Future<void> updateLocation(FerrostarFix fix);

  Future<void> dispose();
}
