# ferrostar_flutter

**Turn-by-turn navigation for Flutter with no Mapbox or Google token.**
Bring your own route and your own map; get structured maneuvers (type, side,
exit number), banner and spoken text, trip progress and off-route events.

It is a *headless* bridge to the open-source
[Ferrostar](https://github.com/stadiamaps/ferrostar) navigation core (Rust, with
Swift and Kotlin bindings). It draws nothing and speaks nothing: your UI, your
map and your TTS stay yours.

> Ferrostar is (c) Stadia Maps and contributors, BSD-3-Clause. This package is an
> independent bridge, not affiliated with or endorsed by Stadia Maps.
> Pinned core: **0.59.0** (pre-1.0, expect API churn; the pin is deliberate).

## Why this one

Navigation packages for Flutter usually fall into two groups: ones that wrap a
vendor SDK (Mapbox, Google, NextBillion, Magic Lane) and need that vendor's token,
map and UI, and ones that only fetch a route from OSRM or Valhalla and stop there.
This package covers the part in between, following a route you already have.

| | ferrostar_flutter | Vendor SDK wrappers | OSRM / Valhalla clients |
|---|---|---|---|
| Vendor token or account | none | required | none |
| Works with any map widget | yes | usually their own | n/a |
| Maneuvers, banner, spoken text | yes | yes | no |
| Off-route events | yes, configurable | yes, built in | no |
| Follows a route you supply (fixed corridor) | yes | partly | n/a |
| Reroutes on its own | no, by design | yes | n/a |
| Draws UI / plays audio | no | yes | no |

(Comparison from public package pages as of November 2026; check each package for
its current state.)

Built for fixed routes such as permitted oversize loads, where the driver must
*not* be rerouted onto a road the permit does not allow.

## Quick start

```dart
final engine = PigeonFerrostarNavigationEngine();
engine.events.listen((e) {
  switch (e) {
    case FerrostarInstruction():   // show e.bannerPrimaryText, e.exit, say e.spokenText
    case FerrostarProgress():      // distance to next maneuver / remaining
    case FerrostarOffRoute():      // e.isOffRoute
    case FerrostarArrived():
    case FerrostarError():
  }
});

await engine.startNavigation(routeJson);          // OSRM-style JSON
// from your own location stream (geolocator, background_locator, ...):
await engine.updateLocation(FerrostarFix(
  lat: p.latitude, lng: p.longitude, accuracyM: p.accuracy,
  speedMps: p.speed, timestampMs: p.timestamp.millisecondsSinceEpoch,
));
```

The core never reads the device location itself: **you** feed GPS fixes. Rerouting
is always disabled; a deviation only raises an event and the app decides.

### Where the route JSON comes from

Anything that produces OSRM-style JSON with banner and voice instructions. With
a [Valhalla](https://github.com/valhalla/valhalla) server:

```
POST /route
{"locations":[{"lat":..,"lon":..},{"lat":..,"lon":..}],
 "costing":"truck", "format":"osrm",
 "banner_instructions":true, "voice_instructions":true,
 "directions_options":{"units":"miles"}}
```

If you already have a fixed line (a permit, a delivery corridor), convert it to
the same JSON yourself: a polyline6 geometry plus `legs[].steps[]` with a
`maneuver`, `bannerInstructions` and `voiceInstructions`. The test fixture in
`test/fixtures/` is a complete small example.

Exit numbers and ramp sides are only as good as your route data: a plain
centreline carries neither, so add them from OpenStreetMap
(`highway=motorway_junction` `ref`, `*_link` ways) if you need them.

### Sample output

Replaying the bundled test route (150 m between fixes):

```
INSTR off ramp/slight right exit=247 "US 321"  trig=3219m say="In 2 miles, take exit 247 on the right onto US 321."
INSTR off ramp/slight right exit=247 "US 321"  trig=1609m say="In a mile, take exit 247 on the right onto US 321."
INSTR off ramp/slight right exit=247 "US 321"  trig=805m  say="In a half mile, take exit 247 on the right onto US 321."
INSTR off ramp/slight right exit=247 "US 321"  trig=150m  say="Take exit 247 on the right onto US 321."
```

## Using it with a map

The engine is map-agnostic. You draw the route line and the position puck with
whatever you use (`maplibre`, `flutter_map`, Google Maps) and move the camera on
`FerrostarProgress`. A free keyless setup is MapLibre with a public style such as
OpenFreeMap. A sketch (not part of the package, adapt to your map widget):

```dart
// 1. decode the route line you started navigation with
final line = decodePolyline(route['geometry'], 6);   // [[lat, lng], ...]
// 2. draw `line` with your map's line layer
// 3. on each location update: engine.updateLocation(...) and move the puck
```

`example/` runs a full replay (banner, spoken text, progress, a simulated
detour) with no map at all.

## Off-route detection (configurable)

Ferrostar's stock detectors are single-fix checks. This package installs a
persistence rule instead, through `FerrostarEngineConfig`:

| option | default | meaning |
|---|---|---|
| `offRouteEnabled` | true | false = no deviation tracking |
| `offRouteDistanceM` | 250 | farther than this from the remaining route = "beyond" |
| `maxTrustedAccuracyM` | 100 | fixes with worse horizontal accuracy neither confirm nor clear |
| `offRouteConfirmFixes` | 3 | consecutive trusted beyond-fixes that start an off-route (1 = single-fix) |

Once off route, the first fix within `offRouteDistanceM` clears it. The same rule
is implemented in Swift, Kotlin and Dart (`OffRouteRule`, used by the fake).

## Testing without a device

`FakeFerrostarNavigationEngine` follows a route in pure Dart and emits the same
events, so UI and BLoC tests need no device. It is a behavioural reference, not a
proof about the native core.

## Platform setup

* **Android**: `minSdk 25`; the host app must enable core library desugaring
  (`isCoreLibraryDesugaringEnabled = true` and
  `coreLibraryDesugaring "com.android.tools:desugar_jdk_libs:2.1.5"`), because the
  core uses `java.time`.
* **iOS 16+**, two ways:
  * **Swift Package Manager** (`flutter config --enable-swift-package-manager`):
    nothing else to do.
  * **CocoaPods**: Ferrostar publishes no CocoaPods spec, so add one line to
    your `ios/Podfile`:
    ```ruby
    require File.expand_path('.symlinks/plugins/ferrostar_flutter/ios/ferrostar_flutter_spm', __dir__)
    post_install do |installer|
      ferrostar_flutter_link_spm(installer)
      # ...your existing post_install
    end
    ```
    You need this if a dependency (for example Firebase's Flutter plugins) cannot
    share Swift packages with this one.

## Known limits (0.1.x)

* The core evaluates deviation a fix late, so an off-route event arrives about
  one second after the rule is met.
* Minimum OS is iOS 16 and Android 7.1 (API 25), set by Ferrostar.
* Adds about 2 MB per Android ABI and about 3 MB to an iOS app (our measurement
  on one app; yours will differ).
* No audio, no map UI, no CarPlay or Android Auto yet.
* `flutter run` on the iOS simulator failed at link time in our app for a reason
  we have not found; building and installing the app separately worked. Reports
  welcome.
* Tested on the iOS simulator and an Android emulator by replaying a recorded
  route; **not yet tested in a vehicle**.

## Regenerating the channel

`dart run pigeon --input pigeons/ferrostar_api.dart`

## License

BSD-3-Clause (see LICENSE). Ferrostar itself is BSD-3-Clause.
