import SwiftUI
import AppKit

// MARK: - Compress dialog
//
// Replaces the old one-click "always zip next to the selection" behaviour with the
// choices users expect from an archiver's context menu: which tool, which format,
// how hard to compress, and where to write the result.

struct CompressDialog: View {
    let urls: [URL]
    let onConfirm: (ArchiveTool, ArchiveFormat, ArchiveLevel?, URL) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var tools: [ArchiveTool] = ArchiveToolCatalog.installed()
    @State private var selectedToolID = "builtin"
    @State private var selectedFormatID = "zip"
    @State private var selectedLevelID = "normal"
    @State private var archiveName = ""
    @State private var destinationFolder: URL?
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
        let base = urls.count == 1
            ? first.deletingPathExtension().lastPathComponent
            : "Archive"
        return base
    }

    private var resolvedDestination: URL {
        let folder = destinationFolder ?? urls.first?.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser
        let name = archiveName.isEmpty ? defaultName : archiveName
        return folder.appendingPathComponent(name).appendingPathExtension(selectedFormat.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(urls.count == 1
                 ? "Compress “\(urls[0].lastPathComponent)”"
                 : "Compress \(urls.count) items")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Tool").gridColumnAlignment(.trailing)
                    Picker("", selection: $selectedToolID) {
                        ForEach(tools) { tool in
                            Text(tool.name).tag(tool.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedToolID) { _ in
                        // Keep the format valid for the newly chosen tool.
                        if !formats.contains(where: { $0.id == selectedFormatID }) {
                            selectedFormatID = formats.first?.id ?? "zip"
                        }
                    }
                }

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
                        Text(destinationFolder?.path ?? urls.first?.deletingLastPathComponent().path ?? "—")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 240, alignment: .leading)
                        Button("Choose…") { chooseFolder() }
                    }
                }
            }

            Text(resolvedDestination.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack {
                Toggle("Remember this tool", isOn: $rememberTool)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Compress") {
                    if rememberTool {
                        UserDefaults.standard.set(selectedToolID,
                                                  forKey: "winfilesArchiveToolID")
                    }
                    onConfirm(selectedTool, selectedFormat,
                              selectedFormat.levels.first { $0.id == selectedLevelID },
                              resolvedDestination)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedTool.id != "builtin" &&
                          selectedTool.bundleIDs.isEmpty &&
                          selectedTool.cli == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if let remembered = UserDefaults.standard.string(forKey: "winfilesArchiveToolID"),
               tools.contains(where: { $0.id == remembered }) {
                selectedToolID = remembered
            }
            archiveName = defaultName
            selectedFormatID = formats.first?.id ?? "zip"
            selectedLevelID = "normal"
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
