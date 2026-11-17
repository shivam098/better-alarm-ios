import SwiftUI
import AlarmyCore

/// The mission catalogue.
///
/// Every mission is shown as available, because every mission *is* available:
/// there is no premium tier, no locked card and no "upgrade to unlock"
/// (PRD MON-1 … MON-5). Each card states its difficulty and the permissions it
/// needs before the user picks it (PRD UX-9).
struct MissionPickerView: View {
    @EnvironmentObject private var coordinator: AlarmCoordinator
    @Environment(\.dismiss) private var dismiss

    @Binding var mission: MissionConfig
    @State private var previewing = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(MissionCategory.ordered, id: \.self) { category in
                    let descriptors = MissionLibrary.all.filter { $0.category == category }
                    if !descriptors.isEmpty {
                        Section(category.displayName) {
                            ForEach(descriptors) { descriptor in
                                MissionCard(
                                    descriptor: descriptor,
                                    isSelected: descriptor.type == mission.type,
                                    isDenied: !descriptor.permissions.isDisjoint(with: coordinator.deniedPermissions)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { select(descriptor.type) }
                            }
                        }
                    }
                }

                Section("Difficulty") {
                    Picker("Difficulty", selection: $mission.difficulty) {
                        ForEach(MissionDifficulty.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if mission.type == .combination {
                    CombinationEditor(mission: $mission)
                } else if mission.type != .none {
                    Section("Mission setup") {
                        MissionConfigurationFields(config: $mission)
                    }
                }

                Section {
                    Button {
                        previewing = true
                    } label: {
                        Label("Try it now", systemImage: "play.circle")
                    }
                    .disabled(mission.type == .none)
                } footer: {
                    // Practising before bed is how a user finds out a mission is
                    // too hard for 6am *before* they oversleep (PRD MSN-8).
                    Text("Practise a mission without setting an alarm.")
                }
            }
            .navigationTitle("Mission")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $previewing) {
                MissionPreviewView(config: mission.normalized())
            }
        }
    }

    private func select(_ type: MissionType) {
        guard mission.type != type else { return }
        mission.type = type
        mission.referenceAssetIDs = []
        mission.targetCount = MissionConfig.defaultTargetCount(for: type)
        if type != .combination { mission.children = [] }
        if type == .combination && mission.children.isEmpty {
            mission.children = [MissionConfig(type: .math), MissionConfig(type: .shake)]
        }
    }
}

private struct MissionCard: View {
    let descriptor: MissionDescriptor
    let isSelected: Bool
    let isDenied: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: descriptor.symbolName)
                .font(.title2)
                .frame(width: 34)
                .foregroundStyle(isSelected ? .orange : .secondary)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(descriptor.displayName)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                    Spacer()
                    IntensityMeter(level: descriptor.intensity)
                }

                Text(descriptor.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !descriptor.permissions.isEmpty {
                    Label(
                        descriptor.permissions
                            .map(\.displayName)
                            .sorted()
                            .joined(separator: ", "),
                        systemImage: isDenied ? "exclamationmark.triangle.fill" : "lock.shield"
                    )
                    .font(.caption2)
                    .foregroundStyle(isDenied ? .orange : .secondary)
                }
            }

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The 1–5 difficulty meter required on every mission card (PRD UX-9).
private struct IntensityMeter: View {
    let level: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { step in
                RoundedRectangle(cornerRadius: 1)
                    .fill(step <= level ? Color.orange : Color.secondary.opacity(0.2))
                    .frame(width: 5, height: 10)
            }
        }
        .accessibilityLabel("Intensity \(level) of 5")
    }
}

private struct CombinationEditor: View {
    @Binding var mission: MissionConfig

    var body: some View {
        Section {
            ForEach(Array(mission.children.enumerated()), id: \.offset) { index, child in
                VStack(alignment: .leading) {
                    Picker("Step \(index + 1)", selection: binding(for: index)) {
                        ForEach(MissionLibrary.all.filter { $0.type != .none && $0.type != .combination }) { option in
                            Text(option.displayName).tag(option.type)
                        }
                    }
                    Picker("Difficulty", selection: $mission.children[index].difficulty) {
                        ForEach(MissionDifficulty.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    MissionConfigurationFields(config: $mission.children[index])
                }
                .deleteDisabled(mission.children.count <= 2)
            }
            .onDelete { offsets in
                mission.children.remove(atOffsets: offsets)
            }

            if mission.children.count < 5 {
                Button {
                    mission.children.append(MissionConfig(type: .math))
                } label: {
                    Label("Add a step", systemImage: "plus.circle")
                }
            }
        } header: {
            Text("Steps")
        } footer: {
            Text("Between 2 and 5 missions, completed in order.")
        }
    }

    private func binding(for index: Int) -> Binding<MissionType> {
        Binding(
            get: { mission.children[index].type },
            set: { newType in
                mission.children[index] = MissionConfig(type: newType, difficulty: mission.difficulty)
            }
        )
    }
}

struct MissionConfigurationFields: View {
    @Binding var config: MissionConfig
    @State private var registering = false

    var body: some View {
        Stepper("Repetitions: \(config.targetCount)", value: $config.targetCount,
                in: MissionConfig.targetRange(for: config.type))
        if config.type == .typing {
            TextField("Custom sentences (one per line)", text: sentences, axis: .vertical)
                .lineLimit(3...6)
            Text("Leave blank for built-in phrases. Sentences stay on this device.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if config.type == .photo || config.type == .qr {
            Button(config.referenceAssetIDs.isEmpty ? "Register a target" : "Replace registered target") {
                registering = true
            }
            Text(config.referenceAssetIDs.isEmpty ? "A target is required before saving." : "Target registered on this device.")
                .font(.caption).foregroundStyle(.secondary)
                .sheet(isPresented: $registering) {
                    TargetRegistrationView(type: config.type) { identifier in
                        config.referenceAssetIDs = [identifier]
                    }
                }
        }
    }

    private var sentences: Binding<String> {
        Binding(get: { (config.customSentences ?? []).joined(separator: "\n") },
                set: { config.customSentences = $0.components(separatedBy: .newlines) })
    }
}

extension MissionCategory {
    static var ordered: [MissionCategory] { [.none, .mental, .visual, .physical, .location, .mixed] }
}

extension MissionType: Identifiable {
    public var id: String { rawValue }
}
