import 'package:ferrostar_flutter/src/engine.dart';

/// The persistence off-route rule (see [FerrostarEngineConfig]) as a pure
/// state machine. The native cores implement the same rule inside a custom
/// RouteDeviationDetector; this Dart copy is the reference used by the fake
/// engine and by tests.
class OffRouteRule {
  OffRouteRule(this.config);

  final FerrostarEngineConfig config;
  int _strikes = 0;
  bool _off = false;

  bool get isOffRoute => _off;

  void reset() {
    _strikes = 0;
    _off = false;
  }

  /// Feeds one fix; returns the new off-route state.
  bool update({required double distanceM, required double accuracyM}) {
    final beyond = distanceM > config.offRouteDistanceM;
    final trusted = accuracyM <= config.maxTrustedAccuracyM;
    if (!beyond) {
      _strikes = 0;
    } else if (trusted) {
      _strikes++;
    }
    _off = _off ? beyond : _strikes >= config.offRouteConfirmFixes;
    return _off;
  }
}
