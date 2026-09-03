import SwiftUI
import AlarmyCore

struct AlarmListView: View {
    @EnvironmentObject private var coordinator: AlarmCoordinator
    @State private var editing: Alarm?
    @State private var showingReliability = false

    var body: some View {
        NavigationStack {
            List {
                if !coordinator.reliabilityIssues.isEmpty {
                    Section {
                        Button {
                            showingReliability = true
                        } label: {
                            ReliabilityBanner(issues: coordinator.reliabilityIssues)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    if coordinator.alarms.isEmpty {
                        EmptyAlarmsView { editing = Alarm() }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(coordinator.alarms) { alarm in
                            AlarmRow(alarm: alarm) { isOn in
                                Task { await coordinator.setEnabled(isOn, for: alarm) }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { editing = alarm }
                        }
                        .onDelete(perform: delete)
                    }
                }

                if let next = nextAlarmDescription {
                    Section {
                        Label(next, systemImage: "clock")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Alarms")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editing = Alarm()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add alarm")
                }
            }
            .sheet(item: $editing) { alarm in
                AlarmEditorView(alarm: alarm)
                    .environmentObject(coordinator)
            }
            .sheet(isPresented: $showingReliability) {
                ReliabilityCheckView()
                    .environmentObject(coordinator)
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        let doomed = offsets.map { coordinator.alarms[$0] }
        Task {
            for alarm in doomed { await coordinator.delete(alarm) }
        }
    }

    /// "Rings in 7 hours 12 minutes" — the single most reassuring thing an alarm
    /// app can show at bedtime (PRD UX-2).
    private var nextAlarmDescription: String? {
        let calculator = AlarmScheduleCalculator()
        let now = Date()
        let next = coordinator.alarms
            .filter(\.isEnabled)
            .compactMap { calculator.nextFireDate(for: $0, after: now) }
            .min()

        guard let next else { return nil }

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2

        guard let interval = formatter.string(from: now, to: next) else { return nil }
        return "Next alarm in \(interval)"
    }
}

private struct AlarmRow: View {
    let alarm: Alarm
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(timeText)
                    .font(.system(size: 44, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(alarm.isEnabled ? .primary : .secondary)

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Label(
                        MissionLibrary.descriptor(for: alarm.mission.type).displayName,
                        systemImage: MissionLibrary.descriptor(for: alarm.mission.type).symbolName
                    )
                    .labelStyle(.titleAndIcon)

                    if alarm.isGuarded {
                        Label("Guarded", systemImage: "shield.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(get: { alarm.isEnabled }, set: onToggle))
                .labelsHidden()
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(timeText), \(subtitle), \(alarm.isEnabled ? "on" : "off")")
    }

    private var timeText: String {
        var components = DateComponents()
        components.hour = alarm.hour
        components.minute = alarm.minute
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(.dateTime.hour().minute())
    }

    private var subtitle: String {
        [alarm.name, alarm.repeatDays.summary].joined(separator: " · ")
    }
}

private struct EmptyAlarmsView: View {
    let create: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "alarm.waves.left.and.right")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("No alarms yet")
                .font(.headline)
            Text("Set one, pick a mission, and Alarmy will keep ringing until you've proved you're awake.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Create your first alarm", action: create)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

private struct ReliabilityBanner: View {
    let issues: [ReliabilityIssue]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: blocking ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(blocking ? .red : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(blocking ? "Your alarms may not go off" : "Reliability check")
                    .font(.subheadline.weight(.semibold))
                Text(issues.first?.title ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var blocking: Bool { issues.contains(where: \.isBlocking) }
}
