import SwiftUI
import AVFoundation
import CoreImage
import UIKit
import AlarmyCore

// MARK: - Photo (PRD M-08)

/// Photograph a place you registered — the bathroom sink, the kettle, the front
/// door. Getting there is the point; the photo is just proof.
///
/// Reference images never leave the device, and the comparison runs entirely
/// on-device with Vision (PRD PRI-1, PRI-2).
struct PhotoMissionView: View {
    let config: MissionConfig
    let onSolved: () -> Void
    let onFailed: (MissionFailure) -> Void

    @StateObject private var targets = PhotoTargetStore()
    @State private var camera = CameraSession()
    @State private var latestFrame: CVPixelBuffer?
    @State private var message = "Go to the place you registered and take the photo"
    @State private var matched = 0

    private let verifier = PhotoVerifier()

    var body: some View {
        VStack(spacing: 16) {
            MissionProgressBar(progress: MissionProgress(current: matched, target: config.targetCount, unit: "photos"))

            if reference == nil {
                ContentUnavailableView {
                    Label("No photo target set", systemImage: "camera.badge.ellipsis")
                } description: {
                    Text("Register a place in the alarm's settings before using this mission.")
                } actions: {
                    Button("Use a backup mission") { onFailed(.notRecognised("a saved target")) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                CameraPreview(session: camera.captureSession)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .frame(maxHeight: .infinity)

                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(action: capture) {
                    Label("Take photo", systemImage: "camera.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(.orange, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
        .onAppear(perform: start)
        .onDisappear { camera.stop() }
    }

    private var reference: Data? {
        config.referenceAssetIDs.compactMap { targets.data(for: $0) }.first
    }

    private func start() {
        guard reference != nil else { return }
        do {
            try camera.configure(position: .back)
        } catch {
            onFailed(.sensorUnavailable(.camera))
            return
        }
        camera.start { buffer in latestFrame = buffer }
    }

    private func capture() {
        guard let buffer = latestFrame, let reference,
              let image = CameraSession.cgImage(from: buffer) else { return }

        let result = verifier.verify(candidate: image, against: reference)

        if result.isMatch {
            matched += 1
            message = "Matched."
            if matched >= max(1, config.targetCount) {
                camera.stop()
                onSolved()
            }
        } else if let failure = result.failure {
            message = failure.userMessage
            onFailed(failure)
        }
    }
}

// MARK: - Barcode / QR (PRD M-09)

/// Scan a code you stuck somewhere far from bed.
///
/// The registered payload is stored as a salted hash, never as the raw code, so
/// a leak of the app's storage does not reveal what the user scans (PRD PRI-4).
struct CodeMissionView: View {
    let config: MissionConfig
    let onSolved: () -> Void
    let onFailed: (MissionFailure) -> Void

    @StateObject private var targets = PhotoTargetStore()
    @State private var camera = CameraSession()
    @State private var message = "Point the camera at your registered code"
    @State private var scanned = 0
    @State private var lastRejectedAt = Date.distantPast

    var body: some View {
        VStack(spacing: 16) {
            MissionProgressBar(progress: MissionProgress(current: scanned, target: config.targetCount, unit: "codes"))

            if config.referenceAssetIDs.isEmpty {
                ContentUnavailableView {
                    Label("No code registered", systemImage: "qrcode")
                } description: {
                    Text("Register a QR code or barcode in the alarm's settings before using this mission.")
                } actions: {
                    Button("Use a backup mission") { onFailed(.notRecognised("a registered code")) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                CameraPreview(session: camera.captureSession)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(.orange, lineWidth: 3)
                            .padding(40)
                    }
                    .frame(maxHeight: .infinity)

                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.white)
        .onAppear(perform: start)
        .onDisappear { camera.stop() }
    }

    private func start() {
        guard !config.referenceAssetIDs.isEmpty else { return }
        do {
            try camera.configure(position: .back, scanCodes: true)
        } catch {
            onFailed(.sensorUnavailable(.camera))
            return
        }

        camera.start(onCode: { payload in
            Task { @MainActor in handle(payload) }
        })
    }

    private func handle(_ payload: String) {
        let hash = PhotoTargetStore.hash(payload)
        guard config.referenceAssetIDs.contains(hash) else {
            // Rate-limited so sweeping past the wrong code does not spam failures.
            guard Date().timeIntervalSince(lastRejectedAt) > 2 else { return }
            lastRejectedAt = Date()
            message = "That's not the code you registered."
            onFailed(.targetMismatch("code"))
            return
        }

        scanned += 1
        message = "Scanned."
        if scanned >= max(1, config.targetCount) {
            camera.stop()
            onSolved()
        }
    }
}

// MARK: - Target storage

/// Stores photo feature prints and hashed code payloads for camera missions.
///
/// Nothing here is an image and nothing here is a raw code: feature prints
/// cannot be turned back into a photograph, and codes are stored only as
/// salted hashes (PRD PRI-1, PRI-4).
@MainActor
final class PhotoTargetStore: ObservableObject {

    private static let directoryName = "mission-targets"
    private static let saltKey = "com.alarmy.target-salt"

    @Published private(set) var identifiers: [String] = []

    private let directory: URL

    init() {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AlarmStore.appGroupID)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent(PhotoTargetStore.directoryName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        refresh()
    }

    func refresh() {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        identifiers = contents.sorted()
    }

    func data(for identifier: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(identifier))
    }

    @discardableResult
    func store(_ data: Data, identifier: String = UUID().uuidString) -> String {
        try? data.write(to: directory.appendingPathComponent(identifier), options: .atomic)
        refresh()
        return identifier
    }

    func delete(_ identifier: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(identifier))
        refresh()
    }

    /// Salted hash of a scanned payload. The salt is generated once per install,
    /// so identical codes on two devices do not produce the same identifier.
    nonisolated static func hash(_ payload: String) -> String {
        let defaults = UserDefaults(suiteName: AlarmStore.appGroupID) ?? .standard
        let salt: String
        if let existing = defaults.string(forKey: saltKey) {
            salt = existing
        } else {
            salt = UUID().uuidString
            defaults.set(salt, forKey: saltKey)
        }

        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (salt + payload).utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        return String(format: "code-%016llx", value)
    }
}

extension CameraSession {
    /// Converts a captured frame for Vision. Kept here so no view has to know
    /// about pixel buffers.
    static func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        return CIContext().createCGImage(ciImage, from: ciImage.extent)
    }
}
