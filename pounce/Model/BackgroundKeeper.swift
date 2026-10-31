import CoreLocation
import Foundation
import Observation

/// ios has no background mode for plain network connections, so this keeps
/// coarse location updates on while something is open (as other ssh clients
/// do). the locations are ignored: never stored, logged or sent.
@MainActor final class BackgroundKeeper: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var wanted = false
    private var watching: Task<Void, Never>?
    private(set) var isRunning = false

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "keepAlive") }

    override init() {
        super.init()
        manager.delegate = self
        // as coarse and rare as possible: only being on matters.
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
        manager.showsBackgroundLocationIndicator = true
    }

    func watch() {
        guard watching == nil else { return }
        watching = Task { [weak self] in
            let changes = Observations { @MainActor in
                AppModel.shared.hasOpenConnections
            }
            for await needed in changes {
                guard let self else { return }
                self.wanted = needed
                if needed { self.start() } else { self.stop() }
            }
        }
    }

    /// asks for location right away so the prompt shows up next to the switch.
    func settingChanged() {
        guard Self.isEnabled else { return stop() }
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        start()
    }

    private func start() {
        guard wanted, Self.isEnabled, !isRunning else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            // starts from the authorization callback once answered.
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.allowsBackgroundLocationUpdates = true
            manager.startUpdatingLocation()
            isRunning = true
            log.info("keeping connections alive in the background")
        default:
            log.info("location denied, connections will pause in the background")
        }
    }

    private func stop() {
        guard isRunning else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isRunning = false
    }

    // MARK: `CLLocationManagerDelegate`

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            switch self.manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: start()
            case .notDetermined: break
            default: stop()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}
}
