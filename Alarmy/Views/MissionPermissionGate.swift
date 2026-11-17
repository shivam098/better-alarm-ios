import SwiftUI
import UIKit
import AlarmyCore

struct MissionPermissionGate<Content: View>: View {
    let permissions: Set<MissionPermission>
    let onFallback: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var blocked: [MissionPermission: PermissionStatus]?

    var body: some View {
        Group {
            if let blocked, blocked.isEmpty {
                content()
            } else if let blocked {
                VStack(spacing: 16) {
                    ForEach(blocked.keys.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { permission in
                        Text("\(permission.displayName) access needed").font(.headline)
                        Text(permission.rationale).font(.footnote)
                        if blocked[permission] == .notDetermined {
                            Button("Allow \(permission.displayName)") {
                                Task {
                                    await PermissionManager().request(permission)
                                    await refresh()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                        }
                    }
                    Button("Use a backup mission", action: onFallback)
                        .buttonStyle(.bordered)
                }
                .multilineTextAlignment(.center)
            } else {
                ProgressView()
            }
        }
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private func refresh() async {
        var result: [MissionPermission: PermissionStatus] = [:]
        for permission in permissions {
            let status = await PermissionManager().status(for: permission)
            if status != .granted { result[permission] = status }
        }
        blocked = result
    }
}
