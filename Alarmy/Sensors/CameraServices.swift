import Foundation
import AVFoundation
import Vision
import CoreImage
import UIKit
import AlarmyCore

/// Shared camera capture used by the squat, photo and code-scanning missions.
///
/// One session, three consumers. Frames are handed to a delegate and never
/// written to disk: nothing the camera sees leaves the device or outlives the
/// mission (PRD PRI-1, PRI-2).
final class CameraSession: NSObject {

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let queue = DispatchQueue(label: "com.alarmy.camera")

    private var frameHandler: ((CVPixelBuffer) -> Void)?
    private var codeHandler: ((String) -> Void)?

    var captureSession: AVCaptureSession { session }

    func configure(position: AVCaptureDevice.Position = .front, scanCodes: Bool = false) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            throw CameraError.unavailable
        }
        session.addInput(input)

        if scanCodes {
            guard session.canAddOutput(metadataOutput) else { throw CameraError.unavailable }
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: queue)
            metadataOutput.metadataObjectTypes = [.qr, .ean13, .ean8, .code128, .code39, .pdf417, .aztec]
        } else {
            guard session.canAddOutput(output) else { throw CameraError.unavailable }
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            session.addOutput(output)
        }
    }

    func start(onFrame: ((CVPixelBuffer) -> Void)? = nil, onCode: ((String) -> Void)? = nil) {
        frameHandler = onFrame
        codeHandler = onCode
        queue.async { [session] in
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    func stop() {
        frameHandler = nil
        codeHandler = nil
        queue.async { [session] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    enum CameraError: Error, LocalizedError {
        case unavailable

        var errorDescription: String? {
            "The camera isn't available. Alarmy will switch to a backup mission."
        }
    }
}

extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameHandler?(buffer)
    }
}

extension CameraSession: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        for object in metadataObjects {
            guard let readable = object as? AVMetadataMachineReadableCodeObject,
                  let value = readable.stringValue else { continue }
            codeHandler?(value)
        }
    }
}

/// Turns camera frames into knee angles for `SquatRepCounter`.
///
/// All inference is on-device with Vision. The rep-counting rules themselves
/// live in `AlarmyCore` so they can be tested without a camera.
struct PoseEstimator {

    struct Reading {
        let kneeAngleDegrees: Double
        let confidence: Double
    }

    func analyse(_ pixelBuffer: CVPixelBuffer) -> Reading? {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first,
              let points = try? observation.recognizedPoints(.all) else { return nil }

        // Use whichever leg the camera can see best.
        let legs: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
            (.leftHip, .leftKnee, .leftAnkle),
            (.rightHip, .rightKnee, .rightAnkle)
        ]

        var best: Reading?
        for (hipJoint, kneeJoint, ankleJoint) in legs {
            guard let hip = points[hipJoint], let knee = points[kneeJoint], let ankle = points[ankleJoint],
                  hip.confidence > 0.1, knee.confidence > 0.1, ankle.confidence > 0.1 else { continue }

            let angle = PoseEstimator.angle(
                a: CGPoint(x: hip.location.x, y: hip.location.y),
                vertex: CGPoint(x: knee.location.x, y: knee.location.y),
                b: CGPoint(x: ankle.location.x, y: ankle.location.y)
            )
            let confidence = Double(min(hip.confidence, min(knee.confidence, ankle.confidence)))

            if best == nil || confidence > best!.confidence {
                best = Reading(kneeAngleDegrees: angle, confidence: confidence)
            }
        }
        return best
    }

    /// Interior angle at `vertex`, in degrees.
    static func angle(a: CGPoint, vertex: CGPoint, b: CGPoint) -> Double {
        let v1 = CGPoint(x: a.x - vertex.x, y: a.y - vertex.y)
        let v2 = CGPoint(x: b.x - vertex.x, y: b.y - vertex.y)
        let dot = v1.x * v2.x + v1.y * v2.y
        let magnitude = (v1.x * v1.x + v1.y * v1.y).squareRoot() * (v2.x * v2.x + v2.y * v2.y).squareRoot()
        guard magnitude > 0 else { return 180 }
        let cosine = max(-1, min(1, dot / magnitude))
        return Double(acos(cosine)) * 180 / .pi
    }
}

/// Compares a freshly-taken photo against the reference the user registered.
///
/// Uses Vision's feature prints, which run entirely on device. Reference images
/// are stored in the app container and never uploaded (PRD M-08, PRI-1).
///
/// Two checks beyond similarity, because a photo mission is trivially defeated
/// otherwise:
///
/// * a very dark frame is rejected outright rather than matching by accident;
/// * a frame that looks like a photo *of a screen* is rejected, so the user
///   cannot photograph a saved picture of their bathroom sink.
struct PhotoVerifier {

    struct Result {
        let isMatch: Bool
        let similarity: Float
        let failure: MissionFailure?
    }

    var similarityThreshold: Float = 0.35

    func verify(candidate: CGImage, against referenceData: Data) -> Result {
        if let brightnessFailure = brightnessCheck(candidate) {
            return Result(isMatch: false, similarity: 0, failure: brightnessFailure)
        }
        if looksLikeAScreen(candidate) {
            return Result(isMatch: false, similarity: 0, failure: .looksLikeAScreen)
        }

        guard let candidatePrint = featurePrint(for: candidate),
              let reference = try? NSKeyedUnarchiver.unarchivedObject(
                  ofClass: VNFeaturePrintObservation.self, from: referenceData
              ) else {
            return Result(isMatch: false, similarity: 0, failure: .notRecognised("that photo"))
        }

        var distance = Float.greatestFiniteMagnitude
        do {
            try candidatePrint.computeDistance(&distance, to: reference)
        } catch {
            return Result(isMatch: false, similarity: 0, failure: .notRecognised("that photo"))
        }

        // Vision returns a distance; smaller is more similar.
        let isMatch = distance <= similarityThreshold
        return Result(
            isMatch: isMatch,
            similarity: distance,
            failure: isMatch ? nil : .targetMismatch("target")
        )
    }

    func featurePrint(for image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return request.results?.first
    }

    /// Archived form suitable for storing as a reference target.
    func referenceData(for image: CGImage) -> Data? {
        guard let print = featurePrint(for: image) else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: print, requiringSecureCoding: true)
    }

    private func brightnessCheck(_ image: CGImage) -> MissionFailure? {
        let ciImage = CIImage(cgImage: image)
        let extent = ciImage.extent
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: CIVector(cgRect: extent)
        ]), let output = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        CIContext().render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let luminance = (0.299 * Double(bitmap[0]) + 0.587 * Double(bitmap[1]) + 0.114 * Double(bitmap[2])) / 255
        return luminance < 0.06 ? .tooDark : nil
    }

    /// A cheap moiré/rectangle heuristic. Not foolproof, and deliberately biased
    /// towards letting a genuine photo through rather than blocking a user who
    /// is standing in their kitchen at 6am.
    private func looksLikeAScreen(_ image: CGImage) -> Bool {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.4
        request.maximumObservations = 3
        request.minimumConfidence = 0.85
        request.minimumSize = 0.7

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])

        // A single very large, very confident, very rectangular region filling
        // most of the frame is characteristic of pointing a camera at a display.
        return (request.results ?? []).contains { $0.boundingBox.width * $0.boundingBox.height > 0.75 }
    }
}
