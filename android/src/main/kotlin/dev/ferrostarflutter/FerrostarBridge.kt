package dev.ferrostarflutter

import android.location.Location
import com.stadiamaps.ferrostar.core.CorrectiveAction
import com.stadiamaps.ferrostar.core.CustomRouteProvider
import com.stadiamaps.ferrostar.core.FerrostarCore
import com.stadiamaps.ferrostar.core.RouteDeviationHandler
import com.stadiamaps.ferrostar.core.http.HttpClientProvider
import com.stadiamaps.ferrostar.core.http.IResponse
import com.stadiamaps.ferrostar.core.location.NavigationLocationProviding
import io.flutter.plugin.common.BinaryMessenger
import java.time.Instant
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonObject
import uniffi.ferrostar.CourseFiltering
import uniffi.ferrostar.DeviationKind
import uniffi.ferrostar.GeographicCoordinate
import uniffi.ferrostar.ManeuverModifier
import uniffi.ferrostar.ManeuverType
import uniffi.ferrostar.NavigationControllerConfig
import uniffi.ferrostar.Route
import uniffi.ferrostar.RouteDeviation
import uniffi.ferrostar.RouteDeviationDetector
import uniffi.ferrostar.RouteDeviationTracking
import uniffi.ferrostar.RouteStep
import uniffi.ferrostar.TripState
import uniffi.ferrostar.WaypointAdvanceMode
import uniffi.ferrostar.createRouteFromOsrm
import uniffi.ferrostar.stepAdvanceDistanceEntryAndExit
import uniffi.ferrostar.stepAdvanceDistanceToEndOfStep

// Headless Flutter <-> Ferrostar bridge, Android side. No MapLibre, no Compose, no
// FusedLocation: the host app's own fixes are pushed in through updateLocation.
// Rerouting is disabled; off-route follows the configurable persistence rule.

/** A "location provider" that locates nothing: fixes arrive from Flutter. */
private class PushLocationProvider : NavigationLocationProviding {
  val flow = MutableSharedFlow<Location>(extraBufferCapacity = 1024)
  override suspend fun lastLocation(): Location? = null
  override fun locationUpdates(intervalMillis: Long): Flow<Location> = flow
}

/** The core never asks for routes (the host app supplies the route). */
private val noRoutes = CustomRouteProvider { _, _ -> throw IllegalStateException("rerouting is disabled") }

private val noHttp = object : HttpClientProvider {
  override suspend fun call(request: uniffi.ferrostar.RouteRequest): IResponse =
      throw IllegalStateException("no network use in the headless bridge")
}

/**
 * The persistence off-route rule as a Ferrostar custom detector: N consecutive fixes with
 * accuracy <= maxTrusted and farther than distanceM start an off-route; once off, one fix
 * <= distanceM clears it. See FerrostarEngineConfig in the Dart package.
 */
class PersistenceOffRouteDetector(
    private val distanceM: Double,
    private val confirmFixes: Int,
    private val maxTrustedAccuracyM: Double,
) : RouteDeviationDetector {
  private var strikes = 0
  private var off = false
  private var lastTs: Instant? = null

  @Synchronized
  override fun checkRouteDeviation(route: Route, tripState: TripState): RouteDeviation {
    if (tripState !is TripState.Navigating) return RouteDeviation.NoDeviation
    val user = tripState.userLocation
    val d = distanceToRoute(user.coordinates, tripState.remainingSteps)
    // The core may evaluate the same fix more than once; count each fix once.
    if (lastTs != user.timestamp) {
      lastTs = user.timestamp
      val beyond = d > distanceM
      val trusted = user.horizontalAccuracy <= maxTrustedAccuracyM
      if (!beyond) strikes = 0 else if (trusted) strikes++
      off = if (off) beyond else strikes >= confirmFixes
    }
    return if (off) RouteDeviation.Deviation(DeviationKind.CompletelyOffRoute(d))
    else RouteDeviation.NoDeviation
  }

  companion object {
    fun distanceToRoute(p: GeographicCoordinate, steps: List<RouteStep>): Double {
      val kx = 111_320 * cos(Math.toRadians(p.lat))
      val ky = 110_574.0
      var best = Double.MAX_VALUE
      for (step in steps) {
        val g = step.geometry
        if (g.size == 1) {
          val dx = (g[0].lng - p.lng) * kx
          val dy = (g[0].lat - p.lat) * ky
          best = min(best, sqrt(dx * dx + dy * dy))
          continue
        }
        for (i in 0 until g.size - 1) {
          val ax = (g[i].lng - p.lng) * kx
          val ay = (g[i].lat - p.lat) * ky
          val bx = (g[i + 1].lng - p.lng) * kx
          val by = (g[i + 1].lat - p.lat) * ky
          val dx = bx - ax
          val dy = by - ay
          val l2 = dx * dx + dy * dy
          val t = if (l2 == 0.0) 0.0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / l2))
          val px = ax + t * dx
          val py = ay + t * dy
          best = min(best, sqrt(px * px + py * py))
        }
      }
      return best
    }
  }
}

private fun osrmType(t: ManeuverType?): String? =
    when (t) {
      ManeuverType.TURN -> "turn"
      ManeuverType.NEW_NAME -> "new name"
      ManeuverType.DEPART -> "depart"
      ManeuverType.ARRIVE -> "arrive"
      ManeuverType.MERGE -> "merge"
      ManeuverType.ON_RAMP -> "on ramp"
      ManeuverType.OFF_RAMP -> "off ramp"
      ManeuverType.FORK -> "fork"
      ManeuverType.END_OF_ROAD -> "end of road"
      ManeuverType.CONTINUE -> "continue"
      ManeuverType.ROUNDABOUT -> "roundabout"
      ManeuverType.ROTARY -> "rotary"
      ManeuverType.ROUNDABOUT_TURN -> "roundabout turn"
      ManeuverType.NOTIFICATION -> "notification"
      ManeuverType.EXIT_ROUNDABOUT -> "exit roundabout"
      ManeuverType.EXIT_ROTARY -> "exit rotary"
      null -> null
    }

private fun osrmModifier(m: ManeuverModifier?): String? =
    when (m) {
      ManeuverModifier.U_TURN -> "uturn"
      ManeuverModifier.SHARP_RIGHT -> "sharp right"
      ManeuverModifier.RIGHT -> "right"
      ManeuverModifier.SLIGHT_RIGHT -> "slight right"
      ManeuverModifier.STRAIGHT -> "straight"
      ManeuverModifier.SLIGHT_LEFT -> "slight left"
      ManeuverModifier.LEFT -> "left"
      ManeuverModifier.SHARP_LEFT -> "sharp left"
      null -> null
    }

class FerrostarBridge(messenger: BinaryMessenger) : FerrostarHostApi {
  private val flutter = FerrostarFlutterApi(messenger)
  private val location = PushLocationProvider()
  private val scope = CoroutineScope(Dispatchers.Main.immediate)
  private var core: FerrostarCore? = null
  private var stateJob: Job? = null
  private var totalSteps = 0
  private var lastInstructionKey: String? = null
  private var lastOff = false
  private var arrived = false

  companion object {
    fun register(messenger: BinaryMessenger) =
        FerrostarHostApi.setUp(messenger, FerrostarBridge(messenger))

    fun unregister(messenger: BinaryMessenger) = FerrostarHostApi.setUp(messenger, null)
  }

  override fun startNavigation(routeJson: String, config: FerrostarConfig) {
    stopNavigation()
    val root =
        try {
          Json.parseToJsonElement(routeJson).jsonObject
        } catch (e: Exception) {
          throw FlutterError("bad_route", "routeJson is not JSON: ${e.message}", null)
        }
    val first =
        (root["routes"] as? JsonArray)?.firstOrNull()?.jsonObject
            ?: throw FlutterError("bad_route", "routeJson has no routes[0]", null)
    val waypoints = root["waypoints"] ?: JsonArray(emptyList())
    val route =
        try {
          createRouteFromOsrm(
              first.toString().toByteArray(),
              waypoints.toString().toByteArray(),
              config.polylinePrecision.toUInt(),
          )
        } catch (e: Exception) {
          throw FlutterError("parse_failed", e.toString(), null)
        }
    totalSteps = route.steps.size

    val detector =
        PersistenceOffRouteDetector(
            config.offRouteDistanceM,
            config.offRouteConfirmFixes.toInt(),
            config.maxTrustedAccuracyM,
        )
    val navConfig =
        NavigationControllerConfig(
            WaypointAdvanceMode.WaypointWithinRange(100.0),
            stepAdvanceDistanceEntryAndExit(30u, 5u, 100u),
            stepAdvanceDistanceToEndOfStep(10u, 100u),
            if (config.offRouteEnabled) RouteDeviationTracking.Custom(detector)
            else RouteDeviationTracking.None,
            CourseFiltering.SNAP_TO_ROUTE,
        )
    val c = FerrostarCore(noRoutes, noHttp, location, navConfig)
    // Never reroute: always "do nothing" (the default would fetch new routes).
    c.deviationHandler = RouteDeviationHandler { _, _, _ -> CorrectiveAction.DoNothing }
    // Voice is done by Flutter (flutter_tts) from onInstruction; no observer set.
    core = c
    lastInstructionKey = null
    lastOff = false
    arrived = false

    stateJob = scope.launch { c.state.collect { s -> handle(s.tripState) } }
    c.startNavigation(route)
  }

  override fun stopNavigation() {
    stateJob?.cancel()
    stateJob = null
    core?.stopNavigation()
    core = null
  }

  override fun updateLocation(
      lat: Double,
      lng: Double,
      accuracyM: Double,
      speedMps: Double?,
      courseDeg: Double?,
      timestampMs: Long,
  ) {
    if (core == null) return
    // Built as a Ferrostar UserLocation directly would bypass the provider; the core's
    // provider contract is android.location.Location, so wrap the fix in one.
    val loc = Location("flutter").apply {
      latitude = lat
      longitude = lng
      accuracy = accuracyM.toFloat()
      if (speedMps != null) speed = speedMps.toFloat()
      if (courseDeg != null) bearing = courseDeg.toFloat()
      time = timestampMs
    }
    location.flow.tryEmit(loc)
  }

  private fun handle(t: TripState) {
    when (t) {
      is TripState.Navigating -> {
        val dev = t.deviation
        val off = dev is RouteDeviation.Deviation
        val dist =
            when (dev) {
              is RouteDeviation.Deviation ->
                  when (val k = dev.kind) {
                    is DeviationKind.CompletelyOffRoute -> k.deviationFromRouteLine
                    is DeviationKind.OffStepOnRoute -> k.deviationFromStepLine
                  }
              else -> 0.0
            }
        if (off != lastOff) {
          lastOff = off
          flutter.onOffRoute(off, dist) {}
        }
        flutter.onProgress(
            t.progress.distanceToNextManeuver,
            t.progress.distanceRemaining,
            t.progress.durationRemaining,
            max(0, totalSteps - t.remainingSteps.size).toLong(),
        ) {}
        val v = t.visualInstruction
        if (v != null) {
          val key = "${v.primaryContent.text}|${t.spokenInstruction?.utteranceId ?: ""}"
          if (key != lastInstructionKey) {
            lastInstructionKey = key
            flutter.onInstruction(
                osrmType(v.primaryContent.maneuverType),
                osrmModifier(v.primaryContent.maneuverModifier),
                v.primaryContent.exitNumbers.firstOrNull(),
                v.primaryContent.text,
                v.secondaryContent?.text,
                t.spokenInstruction?.text,
                t.spokenInstruction?.triggerDistanceBeforeManeuver
                    ?: v.triggerDistanceBeforeManeuver,
            ) {}
          }
        }
      }
      is TripState.Complete ->
          if (!arrived) {
            arrived = true
            flutter.onArrived {}
          }
      is TripState.Idle -> {}
    }
  }
}
