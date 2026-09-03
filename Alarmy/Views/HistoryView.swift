import SwiftUI
import AlarmyCore

/// History and statistics.
///
/// The design rule here is honesty (PRD MEN-1, HIS-3): a morning where the user
/// pressed Stop and went back to sleep must look different from a morning where
/// they got up. Most alarm apps blur these together; this one refuses to.
struct HistoryView: View {
    @EnvironmentObject private var coordinator: AlarmCoordinator
    @State private var showingClearConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatisticsSummary(statistics: coordinator.statistics)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }

                if resolved.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No wake-ups yet",
                            systemImage: "chart.bar",
                            description: Text("Once your alarms start ringing, you'll see exactly how each morning went.")
                        )
                    }
                } else {
                    Section("Recent mornings") {
                        ForEach(resolved) { occurrence in
                            OccurrenceRow(occurrence: occurrence)
                        }
                    }

                    Section {
                        Button("Clear History", role: .destructive) { showingClearConfirmation = true }
                    } footer: {
                        Text("History is stored only on this device.")
                    }
                }
            }
            .navigationTitle("History")
            .confirmationDialog(
                "Delete all history?",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task { await coordinator.clearHistory() }
                }
            } message: {
                Text("Your streaks and statistics will be reset. This can't be undone.")
            }
        }
    }

    private var resolved: [AlarmOccurrence] {
        coordinator.occurrences.filter { $0.outcome != nil }
    }
}

struct StatisticsSummary: View {
    let statistics: WakeStatistics

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                StatTile(
                    value: "\(Int(statistics.completionRate * 100))%",
                    label: "Woke up properly",
                    tint: .green
                )
                StatTile(
                    value: "\(statistics.currentStreak)",
                    label: statistics.currentStreak == 1 ? "Day streak" : "Day streak",
                    tint: .orange
                )
            }

            HStack(spacing: 12) {
                StatTile(
                    value: "\(Int(statistics.silentDismissalRate * 100))%",
                    label: "Silenced without waking",
                    tint: statistics.silentDismissalRate > 0.2 ? .red : .secondary
                )
                StatTile(
                    value: averageWakeText,
                    label: "Average wake time",
                    tint: .blue
                )
            }

            if let time = statistics.averageTimeToComplete {
                Label(
                    "Missions take you about \(Int(time.rounded())) seconds",
                    systemImage: "timer"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if statistics.silentDismissalRate > 0.2 {
                // The most useful thing statistics can do is tell the user their
                // current setup is not working, and suggest a fix (PRD HIS-3).
                Label(
                    "You're silencing alarms without finishing the mission. Try a physical mission, or turn on Mission Guard.",
                    systemImage: "lightbulb"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var averageWakeText: String {
        guard let minutes = statistics.averageWakeMinuteOfDay else { return "—" }
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

private struct StatTile: View {
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

private struct OccurrenceRow: View {
    let occurrence: AlarmOccurrence

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(occurrence.scheduledAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)

                HStack(spacing: 6) {
                    Text(occurrence.outcome?.displayName ?? "Pending")
                    Text("·")
                    Text(MissionLibrary.descriptor(for: occurrence.missionType).displayName)
                    if occurrence.snoozeCount > 0 {
                        Text("· \(occurrence.snoozeCount) snooze\(occurrence.snoozeCount == 1 ? "" : "s")")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let explanation = occurrence.audioSuppression.userExplanation {
                    Text(explanation)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                if let substituted = occurrence.substitutedFrom {
                    Text("Switched from \(substituted.displayName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !occurrence.deliveryTier.isReliable {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Delivered without full reliability")
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch occurrence.outcome {
        case .completed: return "checkmark.circle.fill"
        case .dismissedUnverified: return "xmark.circle.fill"
        case .snoozed: return "zzz"
        case .missed: return "bell.slash.fill"
        case nil: return "clock"
        }
    }

    private var tint: Color {
        switch occurrence.outcome {
        case .completed: return .green
        case .dismissedUnverified: return .red
        case .snoozed: return .orange
        case .missed: return .gray
        case nil: return .secondary
        }
    }
}
