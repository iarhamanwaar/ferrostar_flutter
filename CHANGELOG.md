## 0.1.2

* README rewritten for clarity: why, install, 30-second tour, FAQ, honest limits.
* Screenshots and a demo GIF recorded from the example app on an iOS simulator.
* Example is now a runnable app (`ios/` and `android/` added) with a route
  drawing, banner and a simulated detour.
* iOS: `Package.swift` now depends on `FlutterFramework` as current Flutter
  requires of Swift Package Manager plugins.
* Added CONTRIBUTING.md.

## 0.1.1

* README rewritten: comparison with other navigation packages, quick start,
  route sources, iOS setup via Swift Package Manager or CocoaPods, known limits.
* `example/` is now a working replay app (banner, spoken text, progress, a
  simulated detour) with a widget test; no map or token needed.
* Test fixture is a synthetic route.
* pub.dev topics and issue tracker added.

## 0.1.0

* Initial release: headless bridge (start/stop/updateLocation; progress,
  instruction, off-route, arrived events) over Ferrostar 0.59.0.
