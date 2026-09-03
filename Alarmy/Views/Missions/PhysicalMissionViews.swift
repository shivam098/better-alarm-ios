import SwiftUI
import AVFoundation
import UIKit
import AlarmyCore

// MARK: - Shake (PRD M-05)

struct ShakeMissionView: View {
    let config: MissionConfig
    let onSolved: () -> Void
    let onFailed: (MissionFailure) -> Void

    @StateObject private var motion = MotionService()
    @State private var counter = ShakeCounter()
    @State private var progress = MissionProgress(current: 0, target: 0, unit: "shakes")
    @State private var warning: String?
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 24) {
            MissionProgressBar(progress: progress)

            Spacer()

            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 92))
                .foregroundStyle(.orange)
                .scaleEffect(pulse ? 1.08 : 0.94)
                .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true), value: pulse)

            Text("Shake your phone")
                .font(.title3.weight(.semibold))

            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                Text("Real shakes only — a twist of the wrist, not a slide across the table.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .foregroundStyle(.white)
        .onAppear {
            counter = ShakeCounter()
            progress = counter.progress(target: config.targetCount)
            pulse = true

            guard motion.isAvailable else {
                onFailed(.sensorUnavailable(.motion))
                return
            }

            motion.start { sample in
                let outcome = counter.consume(sample)
                progress = counter.progress(target: config.targetCount)

                switch outcome {
                case .rejectedMechanical:
                    warning = "That motion looked automated. Shake it yourself."
                    onFailed(.mechanicalMotionDetected)
                case .counted:
                    warning = nil
                    if progress.isComplete {
                        motion.stop()
                        onSolved()
                    }
                case .ignored:
                    break
                }
            }
        }
        .onDisappear { motion.stop() }
    }
}

// MARK: - Walking (PRD M-06)

struct StepsMissionView: View {
    let config: MissionConfig
    let onSolved: () -> Void
    let onFailed: (MissionFailure) -> Void

    @StateObject private var pedometer = PedometerService()
    @State private var progress = MissionProgress(current: 0, target: 0, unit: "steps")
    @State private var warning: String?

    var body: some View {
        VStack(spacing: 24) {
            MissionProgressBar(progress: progress)

            Spacer()

            ZStack {
                Circle()
                    .stroke(.white.opacity(0.12), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: progress.fraction)
                    .stroke(.orange, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.25), value: progress.fraction)

                VStack {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 40))
                    Text("\(progress.current)")
                        .font(.system(size: 46, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("of \(progress.target)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 220, height: 220)

            Text("Get out of bed and walk")
                .font(.title3.weight(.semibold))

            Text(warning ?? "Only steps taken from now count.")
                .font(.footnote)
                .foregroundStyle(warning == nil ? .secondary : .orange)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()
        }
        .foregroundStyle(.white)
        .onAppear {
            guard PedometerService.isAvailable else {
                onFailed(.sensorUnavailable(.motionFitness))
                return
            }

            var local = StepValidator(target: config.targetCount)
            progress = local.progress

            pedometer.start { steps, elapsed, cadence in
                let outcome = local.ingest(cumulativeSteps: steps, at: elapsed, cadenceHz: cadence)
                progress = local.progress

                switch outcome {
                case .rejected(let failure):
                    warning = failure.userMessage
                    onFailed(failure)
                case .credited:
                    warning = nil
                    if local.isComplete {
                        pedometer.stop()
                        onSolved()
                    }
                case .baselineEstablished, .noChange:
                    break
                }
            }
        }
        .onDisappear { pedometer.stop() }
    }
}

// MARK: - Squats (PRD M-07)

struct SquatMissionView: View {
    let config: MissionConfig
    let onSolved: () -> Void
    let onFailed: (MissionFailure) -> Void

    @State private var camera = CameraSession()
    @State private var counter = SquatRepCounter()
    @State private var estimator = PoseEstimator()
    @State private var progress = MissionProgress(current: 0, target: 0, unit: "squats")
    @State private var coaching = "Prop your phone up so your whole body is visible"

    var body: some View {
        VStack(spacing: 18) {
            MissionProgressBar(progress: progress)

            CameraPreview(session: camera.captureSession)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(alignment: .bottom) {
                    Text(coaching)
                        .font(.footnote.weight(.medium))
                        .padding(10)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(10)
                }
                .frame(maxHeight: .infinity)

            Text("\(progress.current) of \(progress.target) squats")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .onAppear(perform: start)
        .onDisappear { camera.stop() }
    }

    private func start() {
        counter = SquatRepCounter()
        progress = counter.progress(target: config.targetCount)

        do {
            try camera.configure(position: .front)
        } catch {
            onFailed(.sensorUnavailable(.camera))
            return
        }

        camera.start { buffer in
            guard let reading = estimator.analyse(buffer) else { return }
            let timestamp = Date().timeIntervalSinceReferenceDate

            let outcome = counter.consume(
                kneeAngleDegrees: reading.kneeAngleDegrees,
                confidence: reading.confidence,
                at: timestamp
            )

            Task { @MainActor in
                progress = counter.progress(target: config.targetCount)
                switch outcome {
                case .counted:
                    coaching = "Good — keep going"
                    if progress.isComplete {
                        camera.stop()
                        onSolved()
                    }
                case .coaching(let message), .lowConfidence(let message):
                    coaching = message
                case .noChange:
                    break
                }
            }
        }
    }
}

/// Live camera preview.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
