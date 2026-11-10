package dev.ferrostarflutter

import io.flutter.embedding.engine.plugins.FlutterPlugin

/** Registers the headless Ferrostar channel with the Flutter engine. */
class FerrostarFlutterPlugin : FlutterPlugin {
  private var messenger: io.flutter.plugin.common.BinaryMessenger? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    messenger = binding.binaryMessenger
    FerrostarBridge.register(binding.binaryMessenger)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    messenger?.let { FerrostarBridge.unregister(it) }
    messenger = null
  }
}
