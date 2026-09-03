import SwiftUI
import UIKit
import AlarmyCore

struct SettingsView: View {
    @EnvironmentObject private var coordinator: AlarmCoordinator
    @StateObject private var challenges = ChallengeHistoryStore()
    @State private var showingReliability = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showingReliability = true
                    } label: {
                        HStack {
                            Label("Reliability Check", systemImage: "shield.checkerboard")
                            Spacer()
                            if coordinator.reliabilityIssues.isEmpty {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Text("\(coordinator.reliabilityIssues.count)")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(.orange, in: Capsule())
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .tint(.primary)
                } footer: {
                    Text("Checks everything that could stop an alarm from going off.")
                }

                Section("Missions") {
                    // The product's central commitment, stated where a user
                    // would expect to find a paywall (PRD MON-1 … MON-5).
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("All missions are free")
                            Text("Every mission, every difficulty. No subscription, no ads, nothing locked.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "gift").foregroundStyle(.orange)
                    }

                    Button("Forget challenge history") { challenges.reset() }
                        .tint(.primary)
                }

                Section {
                    NavigationLink {
                        PrivacyView()
                    } label: {
                        Label("Privacy", systemImage: "hand.raised")
                    }
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About Alarmy", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingReliability) {
                ReliabilityCheckView().environmentObject(coordinator)
            }
        }
    }
}

/// One screen that answers "will my alarm actually go off?" (PRD REL-9).
struct ReliabilityCheckView: View {
    @EnvironmentObject private var coordinator: AlarmCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                if coordinator.reliabilityIssues.isEmpty {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.green)
                            Text("You're all set")
                                .font(.headline)
                            Text("Your alarms will break through Silent Mode and Focus, and will survive a restart.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                } else {
                    ForEach(coordinator.reliabilityIssues) { issue in
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(issue.title, systemImage: issue.isBlocking ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(issue.isBlocking ? .red : .orange)

                                Text(issue.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                action(for: issue)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("What Alarmy can and can't do") {
                    FactRow(
                        symbol: "checkmark",
                        text: "Rings through Silent Mode, Focus and Do Not Disturb.",
                        tint: .green
                    )
                    FactRow(
                        symbol: "checkmark",
                        text: "Survives a restart and works with the app closed.",
                        tint: .green
                    )
                    FactRow(
                        symbol: "checkmark",
                        text: "Comes back if you press Stop without finishing your mission.",
                        tint: .green
                    )
                    FactRow(
                        symbol: "xmark",
                        text: "Cannot remove the system Stop button — no app can. Mission Guard is the answer to it.",
                        tint: .secondary
                    )
                    FactRow(
                        symbol: "xmark",
                        text: "Cannot be heard over a phone call. Your alarm resumes the moment the call ends.",
                        tint: .secondary
                    )
                    FactRow(
                        symbol: "xmark",
                        text: "Cannot ring if the phone is switched off or the battery is flat.",
                        tint: .secondary
                    )
                }
            }
            .navigationTitle("Reliability Check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func action(for issue: ReliabilityIssue) -> some View {
        switch issue {
        case .alarmPermissionMissing:
            Button("Grant alarm permission") {
                Task { await coordinator.requestAlarmAuthorization() }
            }
            .buttonStyle(.borderedProminent)

        case .alarmPermissionDenied, .missionPermissionDenied:
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.bordered)

        case .missionGuardOff, .platformTooOld:
            EmptyView()
        }
    }
}

private struct FactRow: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        Label {
            Text(text).font(.footnote)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}

struct PrivacyView: View {
    var body: some View {
        List {
            Section {
                Text("Alarmy works entirely on your device.")
                    .font(.headline)
            }

            Section("What stays on your phone") {
                FactRow(symbol: "iphone", text: "Photos taken for missions are compared on-device and never saved or uploaded.", tint: .green)
                FactRow(symbol: "iphone", text: "Registered codes are stored as a salted hash, never as the code itself.", tint: .green)
                FactRow(symbol: "iphone", text: "Camera frames for squat counting are processed live and discarded.", tint: .green)
                FactRow(symbol: "iphone", text: "Your alarm history and statistics never leave the device.", tint: .green)
            }

            Section("What we don't do") {
                FactRow(symbol: "xmark", text: "No accounts. No advertising. No third-party analytics.", tint: .secondary)
                FactRow(symbol: "xmark", text: "No microphone access, ever.", tint: .secondary)
                FactRow(symbol: "xmark", text: "No location tracking.", tint: .secondary)
            }

            Section {
                Text("Permissions are only used while a mission that needs them is running, and every mission has a backup that needs no permissions at all.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "alarm.waves.left.and.right")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("Alarmy")
                        .font(.title2.weight(.semibold))
                    Text("An alarm you can't sleep through.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }

            Section("How Mission Guard works") {
                Text("""
                iOS always shows a Stop button on an alarm, and no third-party app can remove it. \
                So instead of trying to, Alarmy schedules a chain of follow-up alarms at the same time \
                as your alarm. Finishing your mission cancels them. Pressing Stop does not.

                That is the whole trick, and it is why Alarmy keeps working even if the app is closed, \
                the phone is restarted, or you press Stop half-asleep.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("Version") {
                LabeledContent("App", value: Bundle.main.appVersion)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
