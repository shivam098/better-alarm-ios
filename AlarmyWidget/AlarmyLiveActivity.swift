import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents
import AlarmKit
import AlarmyCore

/// The Live Activity AlarmKit shows on the Lock Screen and in the Dynamic Island
/// while an alarm is active.
///
/// Its job is to make the *state of the mission* visible without unlocking the
/// phone — "12/30 steps" is far more motivating than a bare alarm label, and it
/// is also the honest answer to "have I actually turned this off yet?" (PRD UX-1).
@main
struct AlarmyWidgetBundle: WidgetBundle {
    var body: some Widget {
        AlarmyLiveActivity()
    }
}

struct AlarmyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        // AlarmKit drives this activity: the attributes type is the same one the
        // app passes to `AlarmManager.AlarmConfiguration`.
        ActivityConfiguration(for: AlarmAttributes<AlarmyMetadata>.self) { context in
            LockScreenView(attributes: context.attributes)
                .padding()
                .activityBackgroundTint(.black.opacity(0.85))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: symbol(for: context.attributes.metadata))
                        .font(.title2)
                        .foregroundStyle(.orange)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(missionName(for: context.attributes.metadata))
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Finish your mission to turn this off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "alarm.fill").foregroundStyle(.orange)
            } compactTrailing: {
                Image(systemName: symbol(for: context.attributes.metadata))
            } minimal: {
                Image(systemName: "alarm.fill").foregroundStyle(.orange)
            }
        }
    }

    private func symbol(for metadata: AlarmyMetadata?) -> String {
        guard let raw = metadata?.missionType, let type = MissionType(rawValue: raw) else {
            return "alarm.fill"
        }
        return MissionLibrary.descriptor(for: type).symbolName
    }

    private func missionName(for metadata: AlarmyMetadata?) -> String {
        guard let raw = metadata?.missionType, let type = MissionType(rawValue: raw) else {
            return "Alarm"
        }
        return MissionLibrary.descriptor(for: type).displayName
    }
}

struct LockScreenView: View {
    let attributes: AlarmAttributes<AlarmyMetadata>

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "alarm.waves.left.and.right")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isWatchdog {
                    Label("You stopped this without finishing", systemImage: "shield.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()
        }
    }

    private var metadata: AlarmyMetadata? { attributes.metadata }

    private var isWatchdog: Bool { metadata?.role == "watchdog" }

    private var title: String {
        guard let raw = metadata?.missionType, let type = MissionType(rawValue: raw), type != .none else {
            return "Alarm"
        }
        return MissionLibrary.descriptor(for: type).displayName
    }

    private var subtitle: String {
        guard let metadata, let type = MissionType(rawValue: metadata.missionType), type != .none else {
            return "Slide to stop"
        }
        let unit: String
        switch type {
        case .steps: unit = "steps"
        case .squat: unit = "squats"
        case .shake: unit = "shakes"
        case .qr: unit = "codes"
        case .photo: unit = "photos"
        default: unit = "to solve"
        }
        return "\(metadata.targetCount) \(unit)"
    }
}
