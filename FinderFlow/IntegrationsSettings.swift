import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Integrations settings
//
// Lists every tool the app knows about, whether it was found on this Mac, and lets
// the user pin a specific app for any of them. Anything pinned always shows in the
// toolbar; anything not found and not pinned stays hidden.

struct IntegrationsSettingsSection: View {
    @ObservedObject private var store = IntegrationStore.shared

    var body: some View {
        Section("Toolbar apps") {
            Text("Buttons appear only for tools that are actually installed. Detection runs each time a window opens, and uses your login shell PATH, so Homebrew, nvm and ~/.local/bin installs are found.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(IntegrationKind.allCases) { kind in
                DisclosureGroup {
                    let items = IntegrationCatalog.all.filter { $0.kind == kind }
                    ForEach(items) { integration in
                        row(for: integration)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(kind.title)
                        Spacer()
                        let found = store.resolved.filter { $0.integration.kind == kind }.count
                        Text(found == 0 ? "none found" : "\(found) available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Re-detect now") {
                    store.refresh(force: true)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func row(for integration: Integration) -> some View {
        let manual = store.manualPath(for: integration.id)
        let detected = store.item(id: integration.id)
        let available = manual != nil || detected != nil

        HStack(spacing: 8) {
            Image(systemName: available ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(available ? Color.green : Color.secondary)
                .font(.caption)

            VStack(alignment: .leading, spacing: 1) {
                Text(integration.name)
                Text(statusText(integration: integration, manual: manual, detected: detected))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Choose…") {
                _ = store.chooseApp(for: integration)
            }
            .controlSize(.small)

            if manual != nil {
                Button("Clear") {
                    store.setManualPath(nil, for: integration.id)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 1)
    }

    private func statusText(integration: Integration,
                            manual: String?,
                            detected: ResolvedIntegration?) -> String {
        if let manual {
            return "Manual: " + URL(fileURLWithPath: manual).lastPathComponent
        }
        if let detected {
            if let app = detected.appURL {
                return "Detected: " + app.deletingPathExtension().lastPathComponent
            }
            if let cli = detected.cliPath {
                return "Detected CLI: " + cli
            }
        }
        return integration.cli.map { "Not installed (looked for \($0))" } ?? "Not installed"
    }
}
