# ferrostar_flutter

A **headless** Flutter bridge to the [Ferrostar](https://github.com/stadiamaps/ferrostar)
navigation core. Your Flutter UI and your map stay as they are; the native core
supplies structured maneuvers (type, modifier, exit number), banner and spoken
text, trip progress and off-route events.

> Ferrostar is (c) Stadia Maps and contributors, BSD-3-Clause. This package is an
> independent bridge and is not affiliated with or endorsed by Stadia Maps.
> Pinned core: **0.59.0** (pre-1.0, expect API churn; the pin is deliberate).

## How it works

* `startNavigation(routeJson, config)` takes an OSRM-style route (Valhalla
  `format=osrm` with `banner_instructions` and `voice_instructions`).
* **You** feed GPS fixes with `updateLocation(...)`. The core never uses
  CoreLocation / FusedLocation itself.
* Events on `engine.events`: `FerrostarProgress`, `FerrostarInstruction`,
  `FerrostarOffRoute` (state changes only), `FerrostarArrived`, `FerrostarError`.
* **Rerouting is always disabled.** A deviation only raises an event.
* No audio: spoken text is delivered in `FerrostarInstruction.spokenText`; use
  your own TTS.

## Off-route detection (configurable)

Ferrostar's stock detectors are single-fix checks. This package installs a
persistence rule instead, through `FerrostarEngineConfig`:

| option | default | meaning |
|---|---|---|
| `offRouteEnabled` | true | false = no deviation tracking |
| `offRouteDistanceM` | 250 | farther than this from the remaining route = "beyond" |
| `maxTrustedAccuracyM` | 100 | fixes with worse horizontal accuracy neither confirm nor clear |
| `offRouteConfirmFixes` | 3 | consecutive trusted beyond-fixes that start an off-route (1 = single-fix) |

Once off route, the first fix within `offRouteDistanceM` clears it. The same
rule is implemented in Swift (`PersistenceOffRouteDetector` -> custom
`RouteDeviationDetector`), Kotlin and Dart (`OffRouteRule`, used by the fake).

## Testing

`FakeFerrostarNavigationEngine` follows a route in pure Dart and emits the same
events, so UI and BLoC tests need no device. `flutter test` in this package
replays a real route through it.

## Platform requirements

* **iOS 16+**, Swift Package Manager only (Ferrostar ships no CocoaPods spec).
  Host apps must have SPM enabled (`flutter config --enable-swift-package-manager`).
* **Android minSdk 25**, host app must enable core library desugaring
  (`isCoreLibraryDesugaringEnabled = true` + `coreLibraryDesugaring
  "com.android.tools:desugar_jdk_libs:2.1.5"`), because the core uses `java.time`.

## Regenerating the channel

`dart run pigeon --input pigeons/ferrostar_api.dart`

## License

BSD-3-Clause (see LICENSE). Ferrostar itself is BSD-3-Clause.
