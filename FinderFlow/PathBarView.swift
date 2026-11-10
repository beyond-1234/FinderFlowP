import SwiftUI
import AppKit

struct PathBarView: View {
    @Binding var currentPath: URL
    @State private var isEditing = false
    @State private var editText = ""
    /// Set when the user leaves the field with an uncommitted path, so we can ask
    /// instead of silently discarding what they typed.
    @State private var pendingPathToConfirm: URL?
    @FocusState private var editFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
                .font(.caption)

            if isEditing {
                TextField("Path", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($editFocused)
                    .resetsCursorOnExit()
                    .onSubmit { commitEdit() }
                    .onExitCommand { cancelEdit() }
                    .onChange(of: editFocused) { focused in
                        // Losing focus no longer discards the typed path: ask first.
                        guard !focused, isEditing else { return }
                        promptToNavigate()
                    }
            } else {
                breadcrumbs
            }

            Spacer()

            Button { copyPathToClipboard() } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
            .fastTooltip("Copy full path")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(pathComponents, id: \.path) { component in
                    Button {
                        currentPath = component
                    } label: {
                        Text(displayName(for: component))
                            .font(.system(size: 12))
                            .foregroundStyle(component == currentPath ? .primary : .secondary)
                    }
                    .buttonStyle(.borderless)

                    if component != pathComponents.last {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .onTapGesture(count: 2) {
            beginEditing()
        }
    }

    private func displayName(for url: URL) -> String {
        if url.lastPathComponent == ".Trash" { return "Trash" }
        return url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent
    }

    private var pathComponents: [URL] {
        var components: [URL] = []
        var url = currentPath
        components.append(url)
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            components.insert(url, at: 0)
        }
        return components
    }

    private func beginEditing() {
        editText = currentPath.path
        isEditing = true
        DispatchQueue.main.async { editFocused = true }
    }

    // MARK: - Commit / cancel

    /// Enter: navigate straight away when the path is valid.
    private func commitEdit() {
        guard let target = resolve(editText) else {
            focusStillInvalid()
            return
        }
        currentPath = target
        isEditing = false
        editFocused = false
    }

    /// Leaving the field: keep what was typed and offer to go there.
    private func promptToNavigate() {
        guard let target = resolve(editText) else {
            // Nothing usable typed — keep the bar in edit mode so the user can fix it.
            isEditing = false
            editFocused = false
            return
        }
        guard target.standardizedFileURL != currentPath.standardizedFileURL else {
            isEditing = false
            editFocused = false
            return
        }
        pendingPathToConfirm = target
        presentConfirm(for: target)
    }

    private func presentConfirm(for target: URL) {
        let alert = NSAlert()
        alert.messageText = "Go to this folder?"
        alert.informativeText = target.path
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        let go = alert.runModal() == .alertFirstButtonReturn
        isEditing = false
        editFocused = false
        if go {
            currentPath = target
        }
    }

    private func focusStillInvalid() {
        // Invalid path on Enter: stay in the field, select the text for editing.
        isEditing = true
        DispatchQueue.main.async { editFocused = true }
    }

    private func cancelEdit() {
        isEditing = false
        editFocused = false
    }

    /// Turn typed text into an existing, browsable folder URL.
    private func resolve(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        let url = URL(fileURLWithPath: expanded)
        return FileItem.isBrowsableFolder(url) ? url : nil
    }

    private func copyPathToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentPath.path, forType: .string)
        // Fire the same feedback notification the context-menu "Copy Path"
        // actions use, so this button shows the "Path copied" toast too.
        NotificationCenter.default.post(name: .ffCopyPathFeedback, object: nil)
    }
}
