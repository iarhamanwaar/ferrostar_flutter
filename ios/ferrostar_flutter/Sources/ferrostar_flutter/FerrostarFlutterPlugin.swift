import Flutter

/// Registers the headless Ferrostar channel with the Flutter engine.
public class FerrostarFlutterPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        FerrostarBridge.register(messenger: registrar.messenger())
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        FerrostarBridge.unregister(messenger: registrar.messenger())
    }
}
