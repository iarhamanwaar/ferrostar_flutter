import AVFoundation
import Combine
import CoreLocation
import FerrostarCore
import FerrostarCoreFFI
import Flutter
import Foundation

// Headless Flutter <-> Ferrostar bridge. No MapLibre, no SwiftUI, no CoreLocation:
// the host app's own location stream is pushed in through `updateLocation`.
// Rerouting is disabled; off-route follows the configurable persistence rule.

/// A location provider that does not locate anything. `push` hands the core a
/// fix received from Flutter.
final class PushLocationProvider: LocationProviding {
    weak var delegate: LocationManagingDelegate?
    var authorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse
    private(set) var lastLocation: UserLocation?
    var lastHeading: Heading?

    func startUpdating() {}
    func stopUpdating() {}

    func push(_ location: UserLocation) {
        lastLocation = location
        delegate?.locationManager(self, didUpdateLocations: [location])
    }
}

/// The core never asks for routes (the host app supplies the route); fail loudly if it does.
private struct NoRouteProvider: CustomRouteProvider {
    func getRoutes(userLocation _: UserLocation, waypoints _: [Waypoint]) async throws -> [Route] {
        throw NSError(domain: "FerrostarFlutter", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "rerouting is disabled"])
    }
}

/// Voice is done by Flutter (flutter_tts) from `onInstruction`; the core stays silent.
private final class SilentSynthesizer: SpeechSynthesizer {
    var isSpeaking = false
    func speak(_: AVSpeechUtterance) {}
    func stopSpeaking(at _: AVSpeechBoundary) -> Bool { true }
}

/// Never reroute: the delegate always answers "do nothing".
private final class NoRerouteDelegate: FerrostarCoreDelegate {
    func core(_: FerrostarCore, didStartWith _: Route) {}
    func core(_: FerrostarCore, correctiveActionForDeviation _: DeviationKind,
              remainingWaypoints _: [Waypoint]) -> CorrectiveAction { .doNothing }
    func core(_: FerrostarCore, loadedAlternateRoutes _: [Route]) {}
}

/// The persistence off-route rule as a Ferrostar custom detector:
/// N consecutive fixes with accuracy <= maxTrusted and > distance from the route
/// start an off-route; once off, one fix <= distance clears it.
final class PersistenceOffRouteDetector: @unchecked Sendable {
    private let distanceM: Double
    private let confirmFixes: Int
    private let maxTrustedAccuracyM: Double
    private let lock = NSLock()
    private var strikes = 0
    private var off = false
    private var lastTimestamp: Date?

    init(distanceM: Double, confirmFixes: Int, maxTrustedAccuracyM: Double) {
        self.distanceM = distanceM
        self.confirmFixes = confirmFixes
        self.maxTrustedAccuracyM = maxTrustedAccuracyM
    }

    func check(_ tripState: TripState) -> RouteDeviation {
        guard case let .navigating(_, user, _, remainingSteps, _, _, _, _, _, _, _) = tripState else {
            return .noDeviation
        }
        let d = PersistenceOffRouteDetector.distanceToRoute(user.coordinates, remainingSteps)
        lock.lock(); defer { lock.unlock() }
        // The core may evaluate the same fix more than once; count each fix once.
        if lastTimestamp != user.timestamp {
            lastTimestamp = user.timestamp
            let beyond = d > distanceM
            let trusted = user.horizontalAccuracy <= maxTrustedAccuracyM
            if !beyond { strikes = 0 } else if trusted { strikes += 1 }
            off = off ? beyond : strikes >= confirmFixes
        }
        return off ? .deviation(kind: .completelyOffRoute(deviationFromRouteLine: d)) : .noDeviation
    }

    /// Metres from `p` to the polyline made of all remaining steps.
    static func distanceToRoute(_ p: GeographicCoordinate, _ steps: [RouteStep]) -> Double {
        let kx = 111_320 * cos(p.lat * .pi / 180), ky = 110_574.0
        var best = Double.infinity
        for step in steps {
            let g = step.geometry
            if g.count == 1 {
                let dx = (g[0].lng - p.lng) * kx, dy = (g[0].lat - p.lat) * ky
                best = min(best, (dx * dx + dy * dy).squareRoot())
                continue
            }
            if g.count < 2 { continue }
            for i in 0 ..< g.count - 1 {
                let ax = (g[i].lng - p.lng) * kx, ay = (g[i].lat - p.lat) * ky
                let bx = (g[i + 1].lng - p.lng) * kx, by = (g[i + 1].lat - p.lat) * ky
                let dx = bx - ax, dy = by - ay
                let l2 = dx * dx + dy * dy
                let t = l2 == 0 ? 0 : max(0, min(1, -(ax * dx + ay * dy) / l2))
                let px = ax + t * dx, py = ay + t * dy
                best = min(best, (px * px + py * py).squareRoot())
            }
        }
        return best
    }
}

private func osrmType(_ t: ManeuverType?) -> String? {
    switch t {
    case .turn: "turn"
    case .newName: "new name"
    case .depart: "depart"
    case .arrive: "arrive"
    case .merge: "merge"
    case .onRamp: "on ramp"
    case .offRamp: "off ramp"
    case .fork: "fork"
    case .endOfRoad: "end of road"
    case .continue: "continue"
    case .roundabout: "roundabout"
    case .rotary: "rotary"
    case .roundaboutTurn: "roundabout turn"
    case .notification: "notification"
    case .exitRoundabout: "exit roundabout"
    case .exitRotary: "exit rotary"
    case nil: nil
    }
}

private func osrmModifier(_ m: ManeuverModifier?) -> String? {
    switch m {
    case .uTurn: "uturn"
    case .sharpRight: "sharp right"
    case .right: "right"
    case .slightRight: "slight right"
    case .straight: "straight"
    case .slightLeft: "slight left"
    case .left: "left"
    case .sharpLeft: "sharp left"
    case nil: nil
    }
}

final class FerrostarBridge: FerrostarHostApi {
    private let flutterApi: FerrostarFlutterApi
    private let location = PushLocationProvider()
    private let noReroute = NoRerouteDelegate()
    private var core: FerrostarCore?
    private var sub: AnyCancellable?
    private var totalSteps = 0
    private var lastInstructionKey: String?
    private var lastOff = false
    private var arrived = false

    init(messenger: FlutterBinaryMessenger) {
        flutterApi = FerrostarFlutterApi(binaryMessenger: messenger)
    }

    static func register(messenger: FlutterBinaryMessenger) {
        FerrostarHostApiSetup.setUp(binaryMessenger: messenger, api: FerrostarBridge(messenger: messenger))
    }

    static func unregister(messenger: FlutterBinaryMessenger) {
        FerrostarHostApiSetup.setUp(binaryMessenger: messenger, api: nil)
    }

    func startNavigation(routeJson: String, config: FerrostarConfig) throws {
        stopNavigation()
        guard let data = routeJson.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routes = root["routes"] as? [[String: Any]], let first = routes.first
        else {
            throw PigeonError(code: "bad_route", message: "routeJson is not an OSRM response", details: nil)
        }
        let routeData = try JSONSerialization.data(withJSONObject: first)
        let wpData = try JSONSerialization.data(withJSONObject: root["waypoints"] ?? [])
        let route: Route
        do {
            route = try Route.initFromOsrm(route: routeData, waypoints: wpData,
                                           polylinePrecision: UInt32(config.polylinePrecision))
        } catch {
            throw PigeonError(code: "parse_failed", message: "\(error)", details: nil)
        }
        totalSteps = route.steps.count

        let detector = PersistenceOffRouteDetector(
            distanceM: config.offRouteDistanceM,
            confirmFixes: Int(config.offRouteConfirmFixes),
            maxTrustedAccuracyM: config.maxTrustedAccuracyM
        )
        let navConfig = SwiftNavigationControllerConfig(
            waypointAdvance: .waypointWithinRange(100),
            stepAdvanceCondition: stepAdvanceDistanceEntryAndExit(
                distanceToEndOfStep: 30, distanceAfterEndOfStep: 5, minimumHorizontalAccuracy: 100),
            arrivalStepAdvanceCondition: stepAdvanceDistanceToEndOfStep(
                distance: 10, minimumHorizontalAccuracy: 100),
            routeDeviationTracking: config.offRouteEnabled
                ? .custom(detector: { _, trip in detector.check(trip) })
                : .none,
            snappedLocationCourseFiltering: .snapToRoute
        )
        let core = FerrostarCore(
            customRouteProvider: NoRouteProvider(),
            locationProvider: location,
            navigationControllerConfig: navConfig,
            spokenInstructionObserver: SpokenInstructionObserver(
                synthesizer: SilentSynthesizer(), isMuted: true, managesAudioSession: false)
        )
        core.delegate = noReroute
        self.core = core
        lastInstructionKey = nil
        lastOff = false
        arrived = false

        sub = core.$state.compactMap { $0 }.sink { [weak self] s in self?.handle(s) }
        do {
            try core.startNavigation(route: route)
        } catch {
            throw PigeonError(code: "start_failed", message: "\(error)", details: nil)
        }
    }

    func stopNavigation() {
        sub?.cancel()
        sub = nil
        core?.stopNavigation()
        core = nil
    }

    func updateLocation(lat: Double, lng: Double, accuracyM: Double, speedMps: Double?,
                        courseDeg: Double?, timestampMs: Int64) throws {
        guard core != nil else { return }
        location.push(UserLocation(
            coordinates: GeographicCoordinate(lat: lat, lng: lng),
            horizontalAccuracy: accuracyM,
            courseOverGround: courseDeg.map {
                CourseOverGround(degrees: UInt16(max(0, min(359, $0))), accuracy: nil)
            },
            timestamp: Date(timeIntervalSince1970: Double(timestampMs) / 1000),
            speed: speedMps.map { Speed(value: $0, accuracy: nil) }
        ))
    }

    private func handle(_ state: NavigationState) {
        switch state.tripState {
        case let .navigating(_, _, _, remainingSteps, _, progress, _, deviation, visual, spoken, _):
            let off: Bool
            let dist: Double
            switch deviation {
            case .noDeviation: off = false; dist = 0
            case let .deviation(kind):
                off = true
                switch kind {
                case let .completelyOffRoute(d): dist = d
                case let .offStepOnRoute(d): dist = d
                }
            }
            if off != lastOff {
                lastOff = off
                flutterApi.onOffRoute(isOffRoute: off, distanceFromRouteM: dist) { _ in }
            }
            flutterApi.onProgress(
                distanceToNextManeuverM: progress.distanceToNextManeuver,
                distanceRemainingM: progress.distanceRemaining,
                durationRemainingS: progress.durationRemaining,
                stepIndex: Int64(max(0, totalSteps - remainingSteps.count))
            ) { _ in }
            if let v = visual {
                let key = "\(v.primaryContent.text)|\(spoken?.utteranceId.uuidString ?? "")"
                if key != lastInstructionKey {
                    lastInstructionKey = key
                    flutterApi.onInstruction(
                        type: osrmType(v.primaryContent.maneuverType),
                        modifier: osrmModifier(v.primaryContent.maneuverModifier),
                        exit: v.primaryContent.exitNumbers.first,
                        bannerPrimaryText: v.primaryContent.text,
                        bannerSecondaryText: v.secondaryContent?.text,
                        spokenText: spoken?.text,
                        distanceTriggerM: spoken?.triggerDistanceBeforeManeuver
                            ?? v.triggerDistanceBeforeManeuver
                    ) { _ in }
                }
            }
        case .complete:
            if !arrived {
                arrived = true
                flutterApi.onArrived { _ in }
            }
        case .idle:
            break
        }
    }
}
