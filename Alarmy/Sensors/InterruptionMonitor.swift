import Foundation
import AVFoundation
import CallKit
import Combine
import AlarmyCore

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
final class AlarmAudioSession {

    private var player: AVAudioPlayer?

    func activate() {
        do {
            let session = AVAudioSession.sharedInstance()
            // `.duckOthers` rather than `.mixWithOthers`: an alarm should win.
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            AlarmyLog.sensors.error("Audio session activation failed: \(error.localizedDescription)")
        }
    }

    /// Forces playback out of headphones and back to the speaker, so an alarm
    /// can never end up audible only in an accessory the user is not wearing
    /// (PRD INT-7).
    func routeToSpeaker() {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
    }

    func play(soundID: String, volume: Double, gentleRamp: Bool) {
        let sound = SoundLibrary.sound(for: soundID)
        let stem = (sound.fileName as NSString).deletingPathExtension
        let ext = (sound.fileName as NSString).pathExtension

        guard let url = Bundle.main.url(forResource: stem, withExtension: ext) else {
            AlarmyLog.sensors.notice("Sound \(sound.fileName, privacy: .public) not bundled")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            // A gentle ramp starts quiet and climbs, so the user is woken rather
            // than startled — but it always reaches full volume (PRD SND-3).
            player.volume = Float(gentleRamp ? min(volume, 0.15) : volume)
            player.prepareToPlay()
            player.play()
            if gentleRamp {
                player.setVolume(Float(volume), fadeDuration: 30)
            }
            self.player = player
        } catch {
            AlarmyLog.sensors.error("Playback failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
