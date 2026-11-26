import SwiftUI

struct ModulesSettingsPane: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 10) {
            Text("Choose which modules appear in the notch, and drag to set their tab order.")
                .foregroundStyle(.secondary)

            List {
                ForEach($settings.modules) { $configuration in
                    ModuleRow(configuration: $configuration)
                }
                .onMove { source, destination in
                    settings.modules.move(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator)
            }

            HStack {
                Text("\(settings.enabledModules.count) of \(settings.modules.count) enabled")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") { settings.resetModules() }
            }
        }
        .padding(20)
    }
}

private struct ModuleRow: View {
    @Binding var configuration: ModuleConfiguration

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
            Image(systemName: configuration.module.symbolName)
                .frame(width: 22)
                .foregroundStyle(configuration.isEnabled ? Color.accentColor : .secondary)
            Text(configuration.module.displayName)
            Spacer()
            Text("Phase \(configuration.module.phase)")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .foregroundStyle(.secondary)
                .background(.quaternary, in: Capsule())
                .help("Ships in roadmap phase \(configuration.module.phase)")
            Toggle("", isOn: $configuration.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel("Enable \(configuration.module.displayName)")
        }
        .padding(.vertical, 3)
    }
}
