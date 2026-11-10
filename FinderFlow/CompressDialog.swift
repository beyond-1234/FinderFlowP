import SwiftUI
import AppKit

// MARK: - Compress dialog
//
// Choices users expect from an archiver's context menu: which tool, which format,
// how hard to compress, and where to write the result.
//
// When the selected tool is a real app with its own compression UI (Keka, BetterZip,
// Archiver, 7-Zip.app) the dialog offers to simply open that app with the selection,
// because those apps' own dialogs are richer than anything we can imitate — this is
// exactly what their Finder extension does.

struct CompressDialog: View {
    let urls: [URL]
    /// Called for the built-in / CLI path.
    let onConfirm: (ArchiveTool, ArchiveFormat, ArchiveLevel?, URL) -> Void
    /// Called when the user wants the third-party app's own UI.
    let onOpenInApp: (ArchiveTool) -> Void
    /// Must be called for every dismissal path — the host window is not a sheet, so
    /// SwiftUI's `dismiss` does nothing here (that was the broken Cancel button).
    let onClose: () -> Void

    /// Detected off the main thread; the dialog opens immediately with the built-in
    /// tool and fills in the rest when probes finish.
    @State private var tools: [ArchiveTool] = [ArchiveToolCatalog.all[0]]
    @State private var isDetecting = true

    @State private var selectedToolID = "builtin"
    @State private var selectedFormatID = "zip"
    @State private var selectedLevelID = "normal"
    @State private var archiveName = ""
    @State private var destinationFolder: URL?
    @State private var useOwnUI = false
    @State private var rememberTool = true

    private var selectedTool: ArchiveTool {
        ArchiveToolCatalog.tool(id: selectedToolID) ?? tools.first ?? ArchiveToolCatalog.all[0]
    }

    private var formats: [ArchiveFormat] {
        selectedTool.formats.isEmpty ? ArchiveToolCatalog.zipFormats : selectedTool.formats
    }

    private var selectedFormat: ArchiveFormat {
        formats.first { $0.id == selectedFormatID } ?? formats[0]
    }

    private var defaultName: String {
        guard let first = urls.first else { return "Archive" }
        return urls.count == 1
            ? first.deletingPathExtension().lastPathComponent
            : "Archive"
    }

    private var resolvedDestination: URL {
        let folder = destinationFolder ?? urls.first?.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser
        let name = archiveName.isEmpty ? defaultName : archiveName
        return folder.appendingPathComponent(name).appendingPathExtension(selectedFormat.id)
    }

    private var toolHasOwnUI: Bool { ArchiveToolCatalog.hasOwnUI(selectedTool) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(urls.count == 1
                 ? "Compress “\(urls[0].lastPathComponent)”"
                 : "Compress \(urls.count) items")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Tool").gridColumnAlignment(.trailing)
                    HStack(spacing: 6) {
                        Picker("", selection: $selectedToolID) {
                            ForEach(tools) { tool in
                                Text(tool.name).tag(tool.id)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: selectedToolID) { _ in
                            if !formats.contains(where: { $0.id == selectedFormatID }) {
                                selectedFormatID = formats.first?.id ?? "zip"
                            }
                            useOwnUI = ArchiveToolCatalog.hasOwnUI(selectedTool)
                        }

                        if isDetecting {
                            ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                        }
                    }
                }

                if toolHasOwnUI {
                    GridRow {
                        Text("").gridColumnAlignment(.trailing)
                        Toggle("Use \(selectedTool.name)'s own compression window", isOn: $useOwnUI)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                    }
                }

                if !(toolHasOwnUI && useOwnUI) {
                    GridRow {
                        Text("Format").gridColumnAlignment(.trailing)
                        Picker("", selection: $selectedFormatID) {
                            ForEach(formats) { format in
                                Text(format.title).tag(format.id)
                            }
                        }
                        .labelsHidden()
                    }

                    if !selectedFormat.levels.isEmpty {
                        GridRow {
                            Text("Compression").gridColumnAlignment(.trailing)
                            Picker("", selection: $selectedLevelID) {
                                ForEach(selectedFormat.levels) { level in
                                    Text(level.title).tag(level.id)
                                }
                            }
                            .labelsHidden()
                        }
                    }

                    GridRow {
                        Text("Save as").gridColumnAlignment(.trailing)
                        TextField("Archive name", text: $archiveName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                    }

                    GridRow {
                        Text("Where").gridColumnAlignment(.trailing)
                        HStack(spacing: 6) {
                            Text(destinationFolder?.path
                                 ?? urls.first?.deletingLastPathComponent().path ?? "—")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 240, alignment: .leading)
                            Button("Choose…") { chooseFolder() }
                        }
                    }
                }
            }

            if !(toolHasOwnUI && useOwnUI) {
                Text(resolvedDestination.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("\(selectedTool.name) will open with the selection and show its own options.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Toggle("Remember this tool", isOn: $rememberTool)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                Spacer()

                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)

                Button(toolHasOwnUI && useOwnUI ? "Open \(selectedTool.name)" : "Compress") {
                    if rememberTool {
                        UserDefaults.standard.set(selectedToolID,
                                                  forKey: "ffArchiveToolID")
                    }
                    if toolHasOwnUI && useOwnUI {
                        onOpenInApp(selectedTool)
                    } else {
                        onConfirm(selectedTool, selectedFormat,
                                  selectedFormat.levels.first { $0.id == selectedLevelID },
                                  resolvedDestination)
                    }
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: prepare)
    }

    private func prepare() {
        archiveName = defaultName
        selectedFormatID = formats.first?.id ?? "zip"
        selectedLevelID = "normal"

        if let remembered = UserDefaults.standard.string(forKey: "ffArchiveToolID") {
            selectedToolID = remembered
        }

        // Probing for archivers must not run on the main thread: it may touch the
        // login shell, which sources rc files and blocks for seconds. That was the
        // long freeze after choosing Keka.
        DispatchQueue.global(qos: .userInitiated).async {
            let found = ArchiveToolCatalog.installedIncludingShellLookup()
            DispatchQueue.main.async {
                if found.count > tools.count { tools = found }
                isDetecting = false
                if !found.contains(where: { $0.id == selectedToolID }) {
                    selectedToolID = found.first?.id ?? "builtin"
                }
                useOwnUI = ArchiveToolCatalog.hasOwnUI(selectedTool)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = destinationFolder
            ?? urls.first?.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            destinationFolder = url
        }
    }
}
