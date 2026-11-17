import SwiftUI
import AlarmyCore

struct AlarmEditorView: View {
    @EnvironmentObject private var coordinator: AlarmCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Alarm
    @State private var time: Date
    @State private var showingMissionPicker = false

    private let isNew: Bool

    init(alarm: Alarm) {
        _draft = State(initialValue: alarm)
        var components = DateComponents()
        components.hour = alarm.hour
        components.minute = alarm.minute
        _time = State(initialValue: Calendar.current.date(from: components) ?? Date())
        self.isNew = alarm.createdAt.timeIntervalSinceNow > -1
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                }

                Section("Repeat") {
                    WeekdayPicker(selection: $draft.repeatDays)
                    if draft.repeatDays.isEmpty {
                        Text("This alarm will ring once, then turn itself off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Label") {
                    TextField("Alarm", text: $draft.name)
                }

                missionSection
                missionGuardSection
                wakeCheckSection
                snoozeSection
                soundSection

                if !isNew {
                    Section {
                        Button("Delete Alarm", role: .destructive) {
                            Task {
                                await coordinator.delete(draft)
                                dismiss()
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(isNew ? "New Alarm" : "Edit Alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showingMissionPicker) {
                MissionPickerView(mission: $draft.mission)
                    .environmentObject(coordinator)
            }
        }
    }

    // MARK: - Sections

    private var missionSection: some View {
        Section {
            Button {
                showingMissionPicker = true
            } label: {
                HStack {
                    Label(
                        descriptor.displayName,
                        systemImage: descriptor.symbolName
                    )
                    Spacer()
                    Text(draft.mission.difficulty.displayName)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .tint(.primary)

            if draft.mission.type != .none {
                if draft.mission.needsTarget {
                    Label("Register a photo or code target in mission setup.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                Picker("If sensors are unavailable", selection: fallbackBinding) {
                    Text("Choose automatically").tag(MissionType?.none)
                    ForEach(automaticFallbacks, id: \.self) { type in
                        Text(type.displayName).tag(MissionType?.some(type))
                    }
                }
            }
        } header: {
            Text("Mission")
        } footer: {
            Text(descriptor.summary)
        }
    }

    private var missionGuardSection: some View {
        Section {
            Toggle("Mission Guard", isOn: $draft.missionGuard.isEnabled)
                .disabled(draft.mission.type == .none)

            if draft.missionGuard.isEnabled && draft.mission.type != .none {
                Picker("Keep trying for", selection: $draft.missionGuard.windowMinutes) {
                    ForEach(MissionGuardSettings.allowedWindows, id: \.self) { minutes in
                        Text(minutes == 0 ? "Off" : "\(minutes) minutes").tag(minutes)
                    }
                }
                Toggle("Get harder each time", isOn: $draft.missionGuard.escalates)
            }
        } header: {
            Text("Mission Guard")
        } footer: {
            // The single most important explanation in the app: iOS always shows
            // a Stop button we cannot remove, so this is how the alarm still wins.
            Text(guardFooter)
        }
    }

    private var guardFooter: String {
        guard draft.mission.type != .none else {
            return "With no mission, sliding to stop turns the alarm off."
        }
        guard draft.missionGuard.isEnabled && draft.missionGuard.windowMinutes > 0 else {
            return "Without Mission Guard, pressing Stop on the lock screen silences this alarm even if you never got up."
        }
        return "iOS always shows a Stop button that no app can remove. If you press it without finishing your mission, Alarmy comes back — for up to \(draft.missionGuard.windowMinutes) minutes."
    }

    private var snoozeSection: some View {
        Section("Snooze") {
            Toggle("Allow snooze", isOn: $draft.snooze.isEnabled)

            if draft.snooze.isEnabled {
                Stepper("Snooze for \(draft.snooze.duration) min", value: $draft.snooze.duration, in: 1...30)

                Picker("Limit", selection: snoozeLimitBinding) {
                    Text("Unlimited").tag(Int?.none)
                    ForEach(1...5, id: \.self) { limit in
                        Text("\(limit) time\(limit == 1 ? "" : "s")").tag(Int?.some(limit))
                    }

                    private var wakeCheckSection: some View {
                        Section {
                            Toggle("Check I'm still awake", isOn: wakeEnabled)
                            if draft.wakeCheck?.isEnabled == true {
                                Stepper("Check after \(draft.wakeCheck?.delayMinutes ?? 5) min",
                                        value: wakeDelay, in: 1...30)
                                Stepper("Respond within \(draft.wakeCheck?.responseMinutes ?? 1) min",
                                        value: wakeResponse, in: 1...5)
                            }
                        } header: {
                            Text("After dismissal")
                        } footer: {
                            Text("Separate from Mission Guard. After you finish, a system alarm asks if you're still awake. Confirm in the app; Stop alone does not confirm. A second alarm is scheduled in advance if you don't respond.")
                        }
                    }
                }

                Toggle("Each snooze gets shorter", isOn: $draft.snooze.escalating)
                Toggle("Finish the mission before snoozing", isOn: $draft.snooze.costsMission)
            }
        }
    }

    private var soundSection: some View {
        Section("Sound") {
            Picker("Tone", selection: $draft.soundID) {
                ForEach(SoundLibrary.all) { sound in
                    Text(sound.displayName).tag(sound.id)
                }
            }
            Toggle("Start quiet and build up", isOn: $draft.gentleRamp)
            if draft.gentleRamp {
                Stepper("Build up over \(draft.audioOptions?.rampSeconds ?? 30) sec", value: rampSeconds, in: 5...120, step: 5)
            }
            Picker("Backup tone", selection: backupSound) {
                ForEach(SoundLibrary.all) { sound in
                    Text(sound.displayName).tag(sound.id)
                }
            }
            Toggle("Speak alarm label", isOn: speaksLabel)
            Toggle("Speak current time", isOn: speaksTime)
            Toggle("Vibrate", isOn: $draft.vibrationEnabled)
            VStack(alignment: .leading) {
                Text("Volume")
                Slider(value: $draft.volume, in: 0.2...1.0)
            }
            Text("Volume, ramp, vibration and speech apply while the app is running the mission. iOS controls system-alarm volume, vibration and audio routes. Backup tone is also used for Mission Guard and wake-check re-alarms.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private var descriptor: MissionDescriptor {
        MissionLibrary.descriptor(for: draft.mission.type)
    }

    private var automaticFallbacks: [MissionType] {
        draft.mission.type.fallbackChain.filter { $0.requiredPermissions.isEmpty }
    }

    private var fallbackBinding: Binding<MissionType?> {
        Binding(get: { draft.fallbackMission }, set: { draft.fallbackMission = $0 })
    }

    private var snoozeLimitBinding: Binding<Int?> {
        Binding(get: { draft.snooze.limit }, set: { draft.snooze.limit = $0 })
    }

    private func audioBinding<T>(_ keyPath: WritableKeyPath<AlarmAudioOptions, T>) -> Binding<T> {
        Binding(get: { (draft.audioOptions ?? AlarmAudioOptions())[keyPath: keyPath] },
                set: { value in
                    var options = draft.audioOptions ?? AlarmAudioOptions()
                    options[keyPath: keyPath] = value
                    draft.audioOptions = options
                })
    }

    private var rampSeconds: Binding<Int> { audioBinding(\.rampSeconds) }
    private var backupSound: Binding<String> { audioBinding(\.backupSoundID) }
    private var speaksLabel: Binding<Bool> { audioBinding(\.speaksLabel) }
    private var speaksTime: Binding<Bool> { audioBinding(\.speaksTime) }

    private func wakeBinding<T>(_ keyPath: WritableKeyPath<WakeCheckSettings, T>) -> Binding<T> {
        Binding(get: { (draft.wakeCheck ?? WakeCheckSettings())[keyPath: keyPath] },
                set: { value in
                    var settings = draft.wakeCheck ?? WakeCheckSettings()
                    settings[keyPath: keyPath] = value
                    draft.wakeCheck = settings
                })
    }

    private var wakeEnabled: Binding<Bool> { wakeBinding(\.isEnabled) }
    private var wakeDelay: Binding<Int> { wakeBinding(\.delayMinutes) }
    private var wakeResponse: Binding<Int> { wakeBinding(\.responseMinutes) }

    private func save() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        draft.hour = components.hour ?? 7
        draft.minute = components.minute ?? 0
        draft.mission = draft.mission.normalized()
        guard !draft.mission.needsTarget else {
            showingMissionPicker = true
            return
        }
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { draft.name = "Alarm" }

        Task {
            await coordinator.save(draft)
            dismiss()
        }
    }
}

struct WeekdayPicker: View {
    @Binding var selection: Set<Weekday>

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Weekday.allCases, id: \.self) { day in
                Button {
                    if selection.contains(day) { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(String(day.shortName.prefix(1)))
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(
                            Circle().fill(selection.contains(day) ? Color.orange : Color.secondary.opacity(0.15))
                        )
                        .foregroundStyle(selection.contains(day) ? .white : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.shortName)
                .accessibilityAddTraits(selection.contains(day) ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }
}
