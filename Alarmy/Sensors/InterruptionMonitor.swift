import Foundation
import AVFoundation
import CallKit
import Combine
import AlarmyCore
import AudioToolbox

/// Watches the two things that most often make an alarm inaudible: an incoming
/// call, and audio being routed to a device the sleeping user cannot hear
/// (PRD INT-1 … INT-8).
///
/// The app cannot out-prioritise the system's call audio, and it should not try.
/// What it *can* do is (a) never mark such an alarm as missed, (b) restore the
/// alarm the moment the call ends, and (c) tell the user afterwards exactly why
/// their alarm was quiet — which is the difference between a bug report and an
/// explanation.
@MainActor
final class InterruptionMonitor: NSObject, ObservableObject {

    @Published private(set) var isOnCall = false
    @Published private(set) var routeIsExternal = false

    /// Emits the lifecycle events the state machine understands.
    let events = PassthroughSubject<AlarmEvent, Never>()

    private let callObserver = CXCallObserver()
    private var routeObservation: NSObjectProtocol?

    override init() {
        super.init()
        callObserver.setDelegate(self, queue: .main)
        observeRouteChanges()
        updateRouteState()
    }

    deinit {
        if let routeObservation {
            NotificationCenter.default.removeObserver(routeObservation)
        }
    }

    private func observeRouteChanges() {
        routeObservation = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateRouteState()
                self.events.send(.audioRouteChanged)
            }
        }
    }

    private func updateRouteState() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        routeIsExternal = outputs.contains { output in
            switch output.portType {
            case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .headphones,
                 .airPlay, .carAudio, .usbAudio:
                return true
            default:
                return false
            }
        }
    }

    /// Current best guess at why the alarm may not have been heard, recorded on
    /// the occurrence so the history can explain itself (PRD INT-6).
    var suppressionReason: AudioSuppressionReason {
        if isOnCall { return .phoneCall }
        if routeIsExternal { return .audioRoute }
        return .none
    }
}

extension InterruptionMonitor: CXCallObserverDelegate {
    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        Task { @MainActor in
            let active = callObserver.calls.contains { !$0.hasEnded }
            guard active != isOnCall else { return }
            isOnCall = active
            events.send(active ? .callStarted : .callEnded)
        }
    }
}

/// Owns the in-app audio session used while a mission is running.
///
/// AlarmKit plays the alarm tone itself; this exists for the period *after* the
/// user has opened the app and is working through a mission, where the app is
/// responsible for keeping pressure on.
@MainActor
final class AlarmAudioSession: NSObject, AVSpeechSynthesizerDelegate {

    private var player: AVAudioPlayer?
    private let speech = AVSpeechSynthesizer()
    private var vibrationTimer: Timer?
    private var emergencyTimer: Timer?
    private var targetVolume: Float = 1
    private var rampSeconds: TimeInterval = 30
    private var reportError: ((String) -> Void)?

    override init() {
        super.init()
        speech.delegate = self
    }

    func activate() {
        do {
            let session = AVAudioSession.sharedInstance()
            // `.duckOthers` rather than `.mixWithOthers`: an alarm should win.
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            AlarmyLog.sensors.error("Audio session activation failed: \(error.localizedDescription)")
            reportError?("Audio couldn't start. Check your volume and audio route; the system alarm and Mission Guard are separate.")
        }
    }

    /// The playback category cannot forcibly override every accessory route.
    func routeToSpeaker() {
        // Playback cannot override every accessory route. Do not promise otherwise.
        reportError?("Check your connected audio device or disconnect it to hear the alarm on your phone.")
    }

    func play(alarm: Alarm, usesBackup: Bool, onError: @escaping (String) -> Void) {
        stop()
        reportError = onError
        activate()
        let options = alarm.audioOptions ?? AlarmAudioOptions()
        targetVolume = Float(max(0.2, min(1, alarm.volume)))
        rampSeconds = alarm.gentleRamp ? TimeInterval(max(5, min(120, options.rampSeconds))) : 0
        let ids = [usesBackup ? options.backupSoundID : alarm.soundID,
                   options.backupSoundID, SoundLibrary.defaultSoundID]

        for id in ids {
            let sound = SoundLibrary.sound(for: id)
            let stem = (sound.fileName as NSString).deletingPathExtension
            guard let url = Bundle.main.url(forResource: stem, withExtension: "wav") else {
                AlarmyLog.sensors.error("Missing sound: \(sound.fileName, privacy: .public)")
                continue
            }
            do {
                let candidate = try AVAudioPlayer(contentsOf: url)
                candidate.numberOfLoops = -1
                candidate.volume = rampSeconds > 0 ? min(targetVolume, 0.15) : targetVolume
                candidate.prepareToPlay()
                guard candidate.play() else {
                    AlarmyLog.sensors.error("Player refused to start: \(sound.fileName, privacy: .public)")
                    continue
                }
                candidate.setVolume(targetVolume, fadeDuration: rampSeconds)
                player = candidate
                break
            } catch {
                AlarmyLog.sensors.error("Playback failed: \(error.localizedDescription)")
            }
        }
        if player == nil {
            onError("Tone playback failed. Using a system alert in-app; check system volume. Mission Guard remains independent.")
            AudioServicesPlayAlertSound(1005)
            emergencyTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                AudioServicesPlayAlertSound(1005)
            }
        }
        if alarm.vibrationEnabled {
            vibrationTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
        }
        var words: [String] = []
        if options.speaksLabel { words.append(alarm.name) }
        if options.speaksTime { words.append(Date().formatted(date: .omitted, time: .shortened)) }
        if !words.isEmpty {
            player?.setVolume(min(targetVolume, 0.2), fadeDuration: 0.2)
            speech.speak(AVSpeechUtterance(string: words.joined(separator: ". ")))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            player?.setVolume(targetVolume, fadeDuration: rampSeconds)
        }
    }

    func pause() {
        player?.pause()
        speech.pauseSpeaking(at: .immediate)
    }

    func resume() {
        activate()
        if let player, !player.play() { reportError?("Couldn't resume the tone. Check your audio route and volume.") }
        speech.continueSpeaking()
    }

    func stop() {
        player?.stop()
        player = nil
        speech.stopSpeaking(at: .immediate)
        vibrationTimer?.invalidate()
        vibrationTimer = nil
        emergencyTimer?.invalidate()
        emergencyTimer = nil
        reportError = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            AlarmyLog.sensors.error("Audio deactivation failed: \(error.localizedDescription)")
        }
    }
}
