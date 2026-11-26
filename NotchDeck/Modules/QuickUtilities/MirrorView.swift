import SwiftUI

/// Expanded Mirror: a mirrored webcam preview. The camera runs only while this tab is open.
struct MirrorModuleView: View {
    let tokens: ThemeTokens

    @Environment(CameraMirrorStore.self) private var mirror

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black)

            switch mirror.access {
            case .granted:
                CameraPreview(session: mirror.session.session)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .opacity(mirror.isRunning ? 1 : 0)
                if let error = mirror.errorMessage {
                    message(symbol: "video.slash", title: error, detail: nil)
                } else if !mirror.isRunning {
                    ProgressView().controlSize(.small)
                }
            case .notDetermined:
                VStack(spacing: 8) {
                    message(symbol: "camera", title: "Check how you look before a call",
                            detail: "NotchDeck needs camera access. The camera only runs while this tab is open.")
                    NotchPillButton(title: "Allow Camera", symbol: "camera.fill", tokens: tokens, prominent: true) {
                        Task { await mirror.requestAccess() }
                    }
                }
            case .denied:
                VStack(spacing: 8) {
                    message(symbol: "video.slash", title: "Camera access is off",
                            detail: "Allow NotchDeck in System Settings → Privacy & Security → Camera.")
                    NotchPillButton(title: "Open System Settings", symbol: "gearshape", tokens: tokens) {
                        mirror.openPrivacySettings()
                    }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if mirror.access == .granted, mirror.cameras.count > 1 {
                Menu {
                    ForEach(mirror.cameras) { camera in
                        Button {
                            mirror.select(camera)
                        } label: {
                            if camera.id == mirror.selectedID {
                                Label(camera.name, systemImage: "checkmark")
                            } else {
                                Text(camera.name)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "camera.on.rectangle")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(6)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(8)
                .help("Choose camera")
            }
        }
        .onAppear { mirror.viewAppeared() }
        .onDisappear { mirror.viewDisappeared() }
    }

    private func message(symbol: String, title: String, detail: String?) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(tokens.secondaryText)
            Text(title).font(.system(size: 12.5, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(tokens.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .foregroundStyle(.white)
    }
}
