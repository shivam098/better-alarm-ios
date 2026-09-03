import Foundation
import AVFoundation
import CoreMotion
import AlarmyCore

/// Reports and requests the permissions missions need.
///
/// Two product rules drive this type:
///
/// * The app explains *why* it needs something before the system prompt appears
///   (PRD PRM-3), so requesting is always a two-step flow in the UI.
/// * A denied permission must never make an alarm uncompletable (PRD PRM-7):
///   callers use `deniedPermissions()` to pick a fallback mission instead.
struct PermissionManager: Sendable {

    func status(for permission: MissionPermission) async -> PermissionStatus {
        switch permission {
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }

        case .motion, .motionFitness:
            guard CMPedometer.isStepCountingAvailable() || CMMotionActivityManager.isActivityAvailable() else {
                return .unavailable
            }
            switch CMMotionActivityManager.authorizationStatus() {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        }
    }

    func deniedPermissions() async -> Set<MissionPermission> {
        var denied: Set<MissionPermission> = []
        for permission in [MissionPermission.camera, .motion, .motionFitness] {
            let status = await self.status(for: permission)
            if status == .denied || status == .unavailable {
                denied.insert(permission)
            }
        }
        return denied
    }

    @discardableResult
    func request(_ permission: MissionPermission) async -> PermissionStatus {
        switch permission {
        case .camera:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            return granted ? .granted : .denied

        case .motion, .motionFitness:
            // CoreMotion has no explicit request API: the prompt appears on
            // first use, so a throwaway query is the request.
            let pedometer = CMPedometer()
            return await withCheckedContinuation { continuation in
                pedometer.queryPedometerData(from: Date().addingTimeInterval(-60), to: Date()) { _, error in
                    continuation.resume(returning: error == nil ? .granted : .denied)
                }
            }
        }
    }
}

enum PermissionStatus: String, Hashable, Sendable {
    case notDetermined
    case granted
    case denied
    /// The hardware or capability simply is not present on this device.
    case unavailable

    var isUsable: Bool { self == .granted }
}
