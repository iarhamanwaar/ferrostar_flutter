# Contributing

Thanks for helping. Small, focused changes are easiest to review.

* **Bugs:** open an issue with your Flutter version, platform and OS version, the
  Ferrostar version in use, and a route JSON that reproduces it (please use a
  synthetic or public route, not private data).
* **Code:** `flutter test` and `flutter analyze` must pass. The Dart, Swift and
  Kotlin off-route rules must stay behaviourally identical; change all three and
  the tests together.
* **Channel changes:** edit `pigeons/ferrostar_api.dart` and regenerate with
  `dart run pigeon --input pigeons/ferrostar_api.dart`.
* **Ferrostar upgrades:** the core is pinned to an exact version in
  `ios/ferrostar_flutter/Package.swift`, `ios/ferrostar_flutter_spm.rb` and
  `android/build.gradle`. Bump all three together and replay the example on both
  platforms.
