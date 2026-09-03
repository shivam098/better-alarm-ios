import SwiftUI
import AlarmyCore

@main
struct AlarmyApp: App {
    @StateObject private var coordinator = AlarmCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(coordinator)
                .task { await coordinator.bootstrap() }
                // A ringing alarm takes over the whole app. There is no way to
                // navigate around it, because "just open a different screen"
                // would be a way to ignore the alarm (PRD MEN-4).
                .fullScreenCover(item: $coordinator.session) { session in
                    MissionRunnerView(session: session)
                        .environmentObject(coordinator)
                        .interactiveDismissDisabled()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            Task {
                switch phase {
                case .background:
                    await coordinator.noteAppLifecycle(.appBackgrounded)
                case .active:
                    await coordinator.noteAppLifecycle(.appForegrounded)
                    await coordinator.reconcile()
                default:
                    break
                }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var coordinator: AlarmCoordinator

    var body: some View {
        TabView {
            AlarmListView()
                .tabItem { Label("Alarms", systemImage: "alarm") }

            HistoryView()
                .tabItem { Label("History", systemImage: "chart.bar") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.orange)
        .overlay(alignment: .top) {
            if let banner = coordinator.banner {
                BannerView(message: banner) { coordinator.banner = nil }
            }
        }
    }
}

/// Explanations, never bare errors (PRD UX-6).
struct BannerView: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .transition(.move(edge: .top).combined(with: .opacity))
        .task {
            try? await Task.sleep(for: .seconds(6))
            dismiss()
        }
    }
}
