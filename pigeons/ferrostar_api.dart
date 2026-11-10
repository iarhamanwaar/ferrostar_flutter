// Pigeon definition for the headless Ferrostar bridge.
//
// Regenerate with:  dart run pigeon --input pigeons/ferrostar_api.dart
//
// The host app's own location stream feeds the native core through
// [FerrostarHostApi.updateLocation]; the core never touches CoreLocation or
// FusedLocation. Rerouting is always disabled in the core. Off-route is
// decided by a configurable persistence rule ([FerrostarConfig]).
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartOptions: DartOptions(),
    swiftOut:
        'ios/ferrostar_flutter/Sources/ferrostar_flutter/Messages.g.swift',
    kotlinOut: 'android/src/main/kotlin/dev/ferrostarflutter/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'dev.ferrostarflutter'),
    dartPackageName: 'ferrostar_flutter',
  ),
)
class FerrostarConfig {
  FerrostarConfig({
    this.offRouteEnabled = true,
    this.offRouteDistanceM = 250,
    this.offRouteConfirmFixes = 3,
    this.maxTrustedAccuracyM = 100,
    this.polylinePrecision = 6,
  });

  /// False turns deviation tracking off entirely (no off-route events).
  bool offRouteEnabled;

  /// A fix farther than this from the route line counts as beyond it.
  double offRouteDistanceM;

  /// Consecutive trustworthy fixes beyond [offRouteDistanceM] that start an
  /// off-route.
  int offRouteConfirmFixes;

  /// A fix whose horizontal accuracy is worse than this proves nothing either
  /// way (neither confirms nor clears).
  double maxTrustedAccuracyM;

  /// Polyline precision of the route JSON geometry (Valhalla: 6, OSRM: 5).
  int polylinePrecision;
}

@HostApi()
abstract class FerrostarHostApi {
  /// Parses [routeJson] (OSRM-style, one route) and starts a headless
  /// navigation session. Replaces any session in progress. Throws if the
  /// route cannot be parsed.
  void startNavigation(String routeJson, FerrostarConfig config);

  void stopNavigation();

  /// One GPS fix from the app's own location stream.
  void updateLocation(
    double lat,
    double lng,
    double accuracyM,
    double? speedMps,
    double? courseDeg,
    int timestampMs,
  );
}

@FlutterApi()
abstract class FerrostarFlutterApi {
  /// Fired on every accepted fix.
  void onProgress(
    double distanceToNextManeuverM,
    double distanceRemainingM,
    double durationRemainingS,
    int stepIndex,
  );

  /// Fired when the core's current visual/spoken instruction changes.
  /// [type] / [modifier] are the Valhalla/OSRM names ("off ramp", "slight
  /// right"); [exit] is the first exit number/name or null.
  void onInstruction(
    String? type,
    String? modifier,
    String? exit,
    String bannerPrimaryText,
    String? bannerSecondaryText,
    String? spokenText,
    double distanceTriggerM,
  );

  /// Fired on every off-route state CHANGE (and nowhere else).
  void onOffRoute(bool isOffRoute, double distanceFromRouteM);

  void onArrived();

  /// Native-side failure that does not fit a call response.
  void onError(String message);
}
