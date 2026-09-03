import Foundation
import CoreMotion
import AlarmyCore

/// Streams device motion as `AlarmyCore.MotionSample`.
///
/// Converting at the boundary is what lets `ShakeCounter` — and its anti-cheat
/// rules — be unit tested with synthetic data on any machine, with no device
/// and no CoreMotion.
@MainActor
final class MotionService: ObservableObject {

    private let manager = CMMotionManager()
    private var handler: ((MotionSample) -> Void)?

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start(onSample: @escaping (MotionSample) -> Void) {
        guard manager.isDeviceMotionAvailable else {
            AlarmyLog.sensors.error("Device motion unavailable")
            return
        }
        handler = onSample
        manager.deviceMotionUpdateInterval = 1.0 / 50.0

        manager.startDeviceMotionUpdates(to: .main) { motion, _ in
            guard let motion else { return }

            // `userAcceleration` already has gravity removed, so a phone lying
            // still reads ~0 and cannot accumulate shake progress.
            let rotation = motion.rotationRate
            let rotationMagnitude = (
                rotation.x * rotation.x + rotation.y * rotation.y + rotation.z * rotation.z
            ).squareRoot()

            onSample(
                MotionSample(
                    timestamp: motion.timestamp,
                    x: motion.userAcceleration.x,
                    y: motion.userAcceleration.y,
                    z: motion.userAcceleration.z,
                    rotationRate: rotationMagnitude
                )
            )
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        handler = nil
    }

    deinit {
        manager.stopDeviceMotionUpdates()
    }
}

/// Live step counting for the walking mission.
///
/// Uses `startUpdates(from:)` with a start date of *now*, never a historical
/// query. Combined with `StepValidator`'s baseline rule, this is what stops
/// yesterday's steps counting towards this morning's alarm (PRD E29).
@MainActor
final class PedometerService: ObservableObject {

    private let pedometer = CMPedometer()
    private var isRunning = false

    static var isAvailable: Bool { CMPedometer.isStepCountingAvailable() }

    /// - Parameter onUpdate: cumulative steps since `start`, the monotonic
    ///   timestamp, and cadence in steps per second when the OS reports it.
    func start(onUpdate: @escaping (Int, TimeInterval, Double?) -> Void) {
        guard CMPedometer.isStepCountingAvailable(), !isRunning else { return }
        isRunning = true

        pedometer.startUpdates(from: Date()) { data, error in
            guard let data, error == nil else {
                if let error { AlarmyLog.sensors.error("Pedometer: \(error.localizedDescription)") }
                return
            }
            let cadence = data.currentCadence?.doubleValue
            let elapsed = data.endDate.timeIntervalSince(data.startDate)
            Task { @MainActor in
                onUpdate(data.numberOfSteps.intValue, elapsed, cadence)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        pedometer.stopUpdates()
        isRunning = false
    }

    deinit {
        pedometer.stopUpdates()
    }
}
