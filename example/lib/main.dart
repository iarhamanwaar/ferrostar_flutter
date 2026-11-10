import 'package:ferrostar_flutter/ferrostar_flutter.dart';
import 'package:flutter/widgets.dart';

/// Stub: feed `routeJson` (OSRM-style) and your own GPS fixes to the engine
/// and listen to `engine.events`. See the README for the full flow.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final engine = PigeonFerrostarNavigationEngine();
  engine.events.listen((e) => debugPrint('$e'));
  // await engine.startNavigation(routeJson);
  // await engine.updateLocation(FerrostarFix(...));
  runApp(const SizedBox());
}
