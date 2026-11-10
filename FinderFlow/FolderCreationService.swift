import Foundation
import AppKit
import Darwin

// MARK: - Permanent delete confirmation (shared across all views)

func confirmPermanentDelete(names: [String], onConfirm: @escaping () -> Void) {
    let label = names.count == 1 ? "\"\(names[0])\"" : "\(names.count) items"
    let alert = NSAlert()
    alert.messageText     = "Permanently delete \(label)?"
    alert.informativeText = "This cannot be undone. \(names.count == 1 ? "The item" : "The items") will be permanently deleted and cannot be recovered."
    alert.alertStyle      = .warning
    let deleteBtn = alert.addButton(withTitle: "Delete Permanently")
    deleteBtn.hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn { onConfirm() }
}

// MARK: - Action feedback (drives the in-app toast)

struct ActionFeedback {
    let icon: String
    let message: String
}

// MARK: - Safe AppleScript helpers
//
// Filenames on macOS may legally contain double quotes and backslashes. Building
// an AppleScript source string by interpolating a raw path lets a crafted file
// name break out of the string literal and inject arbitrary AppleScript (which
// can run shell commands) — a real code-execution risk when the user merely
// right-clicks a downloaded file. Always wrap untrusted text with this helper so
// it becomes a single, properly escaped AppleScript string literal.

/// Escapes `s` and wraps it in double quotes so it is a safe AppleScript string
/// literal — backslashes first, then quotes.
func appleScriptStringLiteral(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// Opens the native Finder "Get Info" window for each URL, with the path safely
/// escaped against AppleScript injection.
func showGetInfoInFinder(_ urls: [URL]) {
    for url in urls {
        let pathLiteral = appleScriptStringLiteral(url.path)
        let src = """
        tell application "Finder"
            activate
            open information window of (POSIX file \(pathLiteral) as alias)
        end tell
        """
        NSAppleScript(source: src)?.executeAndReturnError(nil)
    }
}

// MARK: - Folder / File creation

class FolderCreationService: ObservableObject {
    @Published var lastCreatedURL:     URL?
    @Published var errorMessage:       String?
    @Published var lastActionFeedback: ActionFeedback?

    func createFolder(at path: URL, name: String = "New Folder") {
        let target = uniqueURL(for: path.appendingPathComponent(name))
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            DispatchQueue.main.async {
                self.lastActionFeedback = ActionFeedback(
                    icon: "folder.badge.plus",
                    message: "Created \"\(target.lastPathComponent)\""
                )
                self.lastCreatedURL = target
            }
        } catch {
            DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
        }
    }

    func createFile(at path: URL, name: String = "untitled.txt") {
        let target = uniqueURL(for: path.appendingPathComponent(name))
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            DispatchQueue.main.async {
                self.errorMessage = "Could not create file at \(target.path)"
            }
            return
        }
        DispatchQueue.main.async {
            self.lastActionFeedback = ActionFeedback(
                icon: "doc.badge.plus",
                message: "Created \"\(target.lastPathComponent)\""
            )
            self.lastCreatedURL = target
        }
    }

    func uniqueURL(for base: URL) -> URL {
        var url = base
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let ext  = base.pathExtension
            let stem = base.deletingPathExtension().lastPathComponent
            let name = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            url = base.deletingLastPathComponent().appendingPathComponent(name)
            counter += 1
        }
        return url
    }
}

// MARK: - File operations (cut / copy / paste / rename / duplicate / undo)

class FileOperationsService: ObservableObject {
    @Published var clipboardURLs:      [URL]           = []
    @Published var isCut:              Bool            = false
    @Published var isBusy:             Bool            = false
    @Published var lastOpURL:          URL?
    @Published var errorMessage:       String?
    @Published var lastActionFeedback: ActionFeedback?

    private let undoMgr = UndoManager()

    var canUndo: Bool { undoMgr.canUndo }
    var canRedo: Bool { undoMgr.canRedo }

    // MARK: Clipboard

    func copy(_ urls: [URL]) {
        clipboardURLs = urls; isCut = false
        writeToPasteboard(urls)
        let label = urls.count == 1 ? "\"\(urls[0].lastPathComponent)\"" : "\(urls.count) items"
        lastActionFeedback = ActionFeedback(icon: "doc.on.doc", message: "Copied \(label)")
    }

    func cut(_ urls: [URL]) {
        clipboardURLs = urls; isCut = true
        writeToPasteboard(urls)
        let label = urls.count == 1 ? "\"\(urls[0].lastPathComponent)\"" : "\(urls.count) items"
        lastActionFeedback = ActionFeedback(icon: "scissors", message: "Cut \(label)")
    }

    func cancelCut() {
        clipboardURLs = []
        isCut = false
    }

    private func writeToPasteboard(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
    }

    var pasteboardURLs: [URL] {
        (NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? clipboardURLs
    }

    // MARK: Paste

    /// Paste runs off the main thread: `FileManager.copyItem` blocks for as long as
    /// the data takes to write, and doing that on the main queue froze the whole
    /// window (and delayed the completion toast behind the copy).
    ///
    /// While the copy is in flight `isBusy` is true, which lets the directory watcher
    /// skip its reloads so the half-written destination file never shows up as an
    /// empty icon.
    func paste(to destination: URL, reload: @escaping () -> Void) {
        let sources = pasteboardURLs
        guard !sources.isEmpty, !isBusy else { return }
        let wasCut = isCut

        let job = OperationJob(
            title: (wasCut ? "Moving " : "Copying ") + describe(sources),
            detail: destination.lastPathComponent
        )
        OperationProgressStore.shared.add(job)
        TransferSizing.measureInBackground(sources, for: job)

        isBusy = true
        lastActionFeedback = ActionFeedback(icon: "doc.on.clipboard",
                                            message: wasCut ? "Moving…" : "Copying…")

        DispatchQueue.global(qos: .userInitiated).async {
            var pasted: [URL] = []
            var failure: Error?

            do {
                pasted = try TransferEngine.transfer(
                    sources,
                    to: destination,
                    mode: wasCut ? .move : .copy,
                    job: job,
                    pathAllocator: { self.uniqueURL(for: $0) }
                )
            } catch {
                failure = error
            }

            DispatchQueue.main.async {
                self.isBusy = false

                if let failure {
                    job.finish(failed: true, message: failure.localizedDescription)
                    if !(failure is TransferEngine.TransferError) {
                        self.errorMessage = failure.localizedDescription
                    } else {
                        self.errorMessage = failure.localizedDescription
                    }
                }

                guard !pasted.isEmpty else { reload(); return }

                if wasCut { self.clipboardURLs = []; self.isCut = false }

                if wasCut {
                    let pairs = zip(sources, pasted).map { ($0, $1) }
                    self.undoMgr.registerUndo(withTarget: self) { _ in
                        for (orig, dest) in pairs {
                            try? FileManager.default.moveItem(at: dest, to: orig)
                        }
                        reload()
                    }
                } else {
                    self.undoMgr.registerUndo(withTarget: self) { _ in
                        pasted.forEach { try? FileManager.default.removeItem(at: $0) }
                        reload()
                    }
                }
                self.undoMgr.setActionName(wasCut ? "Move" : "Paste")
                self.objectWillChange.send()

                let count = pasted.count
                let label = count == 1 ? "\"\(pasted[0].lastPathComponent)\"" : "\(count) items"
                self.lastActionFeedback = ActionFeedback(
                    icon: "doc.on.clipboard",
                    message: (wasCut ? "Moved " : "Pasted ") + label
                )
                self.lastOpURL = pasted.first
                job.finish()
                reload()

                // Drop finished jobs from the panel shortly after.
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    OperationProgressStore.shared.remove(job)
                }
            }
        }
    }

    private func describe(_ urls: [URL]) -> String {
        urls.count == 1
            ? "\"\(urls[0].lastPathComponent)\""
            : "\(urls.count) items"
    }

    // MARK: Rename

    func rename(_ url: URL, to newName: String, reload: @escaping () -> Void) {
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            undoMgr.registerUndo(withTarget: self) { _ in
                try? FileManager.default.moveItem(at: newURL, to: url)
                reload()
            }
            undoMgr.setActionName("Rename")
            objectWillChange.send()
            DispatchQueue.main.async {
                self.lastActionFeedback = ActionFeedback(
                    icon: "pencil",
                    message: "Renamed to \"\(newName)\""
                )
                self.lastOpURL = newURL
                reload()
            }
        } catch {
            DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
        }
    }

    // MARK: Duplicate

    func duplicate(_ urls: [URL], reload: @escaping () -> Void) {
        var created: [URL] = []
        for url in urls {
            let stem = url.deletingPathExtension().lastPathComponent
            let ext  = url.pathExtension
            let name = ext.isEmpty ? "\(stem) copy" : "\(stem) copy.\(ext)"
            let dest = uniqueURL(for: url.deletingLastPathComponent().appendingPathComponent(name))
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                created.append(dest)
            } catch {
                DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
            }
        }
        guard !created.isEmpty else { return }
        undoMgr.registerUndo(withTarget: self) { _ in
            created.forEach { try? FileManager.default.removeItem(at: $0) }
            reload()
        }
        undoMgr.setActionName("Duplicate")
        objectWillChange.send()
        let count = created.count
        let label = count == 1 ? "\"\(created[0].lastPathComponent)\"" : "\(count) items"
        DispatchQueue.main.async {
            self.lastActionFeedback = ActionFeedback(icon: "plus.square.on.square", message: "Duplicated \(label)")
            self.lastOpURL = created.first
            reload()
        }
    }

    // MARK: Trash

    func trash(_ urls: [URL], reload: @escaping () -> Void) {
        var pairs: [(orig: URL, trash: URL)] = []
        for url in urls {
            var trashURL: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
                if let t = trashURL as? URL { pairs.append((url, t)) }
            } catch {
                DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
            }
        }
        guard !pairs.isEmpty else { return }
        undoMgr.registerUndo(withTarget: self) { _ in
            pairs.forEach { try? FileManager.default.moveItem(at: $0.trash, to: $0.orig) }
            reload()
        }
        undoMgr.setActionName("Move to Trash")
        objectWillChange.send()
        let count = pairs.count
        let label = count == 1 ? "\"\(pairs[0].orig.lastPathComponent)\"" : "\(count) items"
        DispatchQueue.main.async {
            self.lastActionFeedback = ActionFeedback(icon: "trash", message: "Trashed \(label)")
            reload()
        }
    }

    // MARK: - Extract archive

    func extract(_ url: URL, reload: @escaping () -> Void) {
        let dest = url.deletingLastPathComponent()
        guard archiveKind(for: url) != nil else {
            errorMessage = "FinderFlow can't extract this file type."
            return
        }

        let job = OperationJob(title: "Extracting “\(url.lastPathComponent)”",
                               detail: dest.lastPathComponent)
        OperationProgressStore.shared.add(job)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 {
            job.setTotal(size)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let entries = try self.listArchiveEntries(url)
                guard !entries.isEmpty else {
                    throw ArchiveToolError(message: "This archive is empty.")
                }
                guard entries.allSatisfy(archiveEntryIsSafe) else {
                    throw ArchiveToolError(message: "This archive can't be extracted because it contains an unsafe path.")
                }
                let top = archiveTopLevelNames(entries)
                let collisions = top.filter {
                    FileManager.default.fileExists(atPath: dest.appendingPathComponent($0).path)
                }
                DispatchQueue.main.async {
                    if !collisions.isEmpty && !self.confirmExtractOverwrite(collisions) {
                        job.finish(message: "Cancelled")
                        return
                    }
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try self.extractArchive(url, into: dest, replacing: collisions)
                            DispatchQueue.main.async {
                                job.finish()
                                reload()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                                    OperationProgressStore.shared.remove(job)
                                }
                            }
                        } catch {
                            DispatchQueue.main.async {
                                job.finish(failed: true, message: error.localizedDescription)
                                self.errorMessage = error.localizedDescription
                            }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    job.finish(failed: true, message: error.localizedDescription)
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Compress

    /// Compress with the built-in zipper. Exposed so the archive dialog can call it
    /// after asking the user for format / level / destination.
    func compress(_ urls: [URL],
                  to destination: URL,
                  using tool: ArchiveTool,
                  format: ArchiveFormat,
                  level: ArchiveLevel?,
                  reload: @escaping () -> Void) {
        guard !urls.isEmpty else { return }

        let job = OperationJob(title: "Compressing " + describe(urls),
                               detail: destination.lastPathComponent)
        OperationProgressStore.shared.add(job)
        TransferSizing.measureInBackground(urls, for: job)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ArchiveRunner.run(tool: tool,
                                      format: format,
                                      level: level,
                                      urls: urls,
                                      destination: destination,
                                      job: job)
                DispatchQueue.main.async {
                    job.finish()
                    reload()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        OperationProgressStore.shared.remove(job)
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: destination)
                DispatchQueue.main.async {
                    job.finish(failed: true, message: error.localizedDescription)
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Quick, silent .zip next to the selection (the old one-click behaviour).
    func compress(_ urls: [URL], reload: @escaping () -> Void) {
        guard let first = urls.first else { return }
        let base    = first.deletingLastPathComponent()
        let names   = urls.map(\.lastPathComponent)
        let zipName = urls.count == 1
            ? first.deletingPathExtension().lastPathComponent + ".zip"
            : "Archive.zip"
        let dest = uniqueURL(for: base.appendingPathComponent(zipName))
        // Still validate the names through _ = arguments so a name that would break the
        // zip command line is rejected before any work starts.
        guard zipArguments(archivePath: dest.path, names: names) != nil else {
            errorMessage = "One of these items can't be compressed because its name isn't allowed."
            return
        }
        let job = OperationJob(title: "Compressing " + describe(urls),
                               detail: dest.lastPathComponent)
        OperationProgressStore.shared.add(job)
        TransferSizing.measureInBackground(urls, for: job)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ArchiveRunner.run(tool: ArchiveToolCatalog.all[0],
                                      format: ArchiveToolCatalog.all[0].formats[0],
                                      level: nil,
                                      urls: urls,
                                      destination: dest,
                                      job: job)
                DispatchQueue.main.async {
                    job.finish()
                    reload()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        OperationProgressStore.shared.remove(job)
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: dest)
                DispatchQueue.main.async {
                    job.finish(failed: true, message: error.localizedDescription)
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Make Alias (symlink)

    func makeAlias(for url: URL, reload: @escaping () -> Void) {
        let stem = url.deletingPathExtension().lastPathComponent
        let ext  = url.pathExtension
        let name = ext.isEmpty ? "\(stem) alias" : "\(stem) alias.\(ext)"
        let dest = uniqueURL(for: url.deletingLastPathComponent().appendingPathComponent(name))
        do {
            try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: url)
            DispatchQueue.main.async { reload() }
        } catch { DispatchQueue.main.async { self.errorMessage = error.localizedDescription } }
    }

    // MARK: - Tags (Finder-compatible: real color tags, multiple per file, toggle)

    /// Toggle a standard Finder color tag on the given files, mirroring Finder:
    /// if EVERY file already has the color it is removed from all; otherwise it is
    /// added to all. Other tags on the file (additional colors, custom text tags)
    /// are always preserved.
    func toggleColorTag(_ colorName: String, on urls: [URL], reload: @escaping () -> Void) {
        guard !urls.isEmpty,
              let number = FileItem.colorNameToLabel[colorName.lowercased()] else { return }
        let canonical = FileItem.labelToColorName[number] ?? colorName
        let target    = canonical.lowercased()

        DispatchQueue.global(qos: .userInitiated).async {
            let allHave = urls.allSatisfy { url in
                self.readTagNames(url).contains { $0.lowercased() == target }
            }
            for url in urls {
                var names = self.readTagNames(url)
                names.removeAll { $0.lowercased() == target }   // de-dupe / remove existing
                if !allHave { names.append(canonical) }          // add unless we're toggling off
                self.writeTags(names, to: url)
            }
            DispatchQueue.main.async {
                self.lastActionFeedback = ActionFeedback(
                    icon:    allHave ? "tag.slash" : "tag.fill",
                    message: allHave ? "Removed \(canonical) tag" : "Tagged \(canonical)"
                )
                reload()
            }
        }
    }

    /// Remove every tag (colors + custom) from the given files.
    func clearTags(on urls: [URL], reload: @escaping () -> Void) {
        guard !urls.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for url in urls { self.writeTags([], to: url) }
            DispatchQueue.main.async {
                self.lastActionFeedback = ActionFeedback(icon: "tag.slash", message: "Cleared tags")
                reload()
            }
        }
    }

    /// Current tag names. The system returns plain display names (e.g. "Red",
    /// "Work") with any color-index suffix already stripped.
    private func readTagNames(_ url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    /// Write tags, encoding each of the 7 standard colors as "Name\nNumber" so
    /// macOS registers a REAL color tag (verified: a plain "Red" string is stored
    /// as a colorless custom tag, while "Red\n6" sets the red swatch / labelNumber
    /// 6). Custom (non-color) tags are written through unchanged.
    private func writeTags(_ names: [String], to url: URL) {
        let encoded: [String] = names.map { name in
            if let num = FileItem.colorNameToLabel[name.lowercased()] {
                let canonical = FileItem.labelToColorName[num] ?? name
                return "\(canonical)\n\(num)"
            }
            return name
        }
        try? (url as NSURL).setResourceValue(encoded as NSArray, forKey: .tagNamesKey)
    }

    // MARK: - Copy path to clipboard

    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        // Post with object:nil — Swift structs don't bridge through NSNotification.object
        // (id in ObjC), so the receiver can't cast them back. ContentView hardcodes the toast.
        NotificationCenter.default.post(name: .ffCopyPathFeedback, object: nil)
    }

    // MARK: - Share

    func showShareSheet(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        DispatchQueue.main.async {
            guard let win = NSApp.keyWindow, let view = win.contentView else { return }
            NSSharingServicePicker(items: urls.map { $0 as NSURL })
                .show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
    }

    func shareViaAirDrop(_ urls: [URL]) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls.map { $0 as NSURL })
    }

    // MARK: - Permanent delete (no undo — caller must confirm first)

    func permanentlyDelete(_ urls: [URL], reload: @escaping () -> Void) {
        var deleted: [URL] = []
        for url in urls {
            do {
                try FileManager.default.removeItem(at: url)
                deleted.append(url)
            } catch {
                DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
            }
        }
        guard !deleted.isEmpty else { return }
        let count = deleted.count
        let label = count == 1 ? "\"\(deleted[0].lastPathComponent)\"" : "\(count) items"
        DispatchQueue.main.async {
            self.lastActionFeedback = ActionFeedback(icon: "trash.fill", message: "Permanently deleted \(label)")
            reload()
        }
    }

    // MARK: Undo / Redo

    func undo() {
        let name = undoMgr.undoActionName
        undoMgr.undo()
        objectWillChange.send()
        let msg = name.isEmpty ? "Undone" : "Undone: \(name)"
        lastActionFeedback = ActionFeedback(icon: "arrow.uturn.backward", message: msg)
    }

    func redo() {
        let name = undoMgr.redoActionName
        undoMgr.redo()
        objectWillChange.send()
        let msg = name.isEmpty ? "Redone" : "Redone: \(name)"
        lastActionFeedback = ActionFeedback(icon: "arrow.uturn.forward", message: msg)
    }

    // MARK: Helpers

    /// Names must be unique within the destination folder. This probes rather than
    /// reserving, so two windows pasting the same file into the same folder at the same
    /// moment can both pick the same name; the loser fails loudly instead of
    /// overwriting. Acceptable for now — see the review notes.
    private func uniqueURL(for base: URL) -> URL {
        var url = base; var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let ext  = base.pathExtension
            let stem = base.deletingPathExtension().lastPathComponent
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            url = base.deletingLastPathComponent().appendingPathComponent(name)
            n += 1
        }
        return url
    }

    private enum ArchiveKind {
        case zip
        case tar
    }

    private struct ArchiveToolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func archiveKind(for url: URL) -> ArchiveKind? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") { return .zip }
        if name.hasSuffix(".tar")
            || name.hasSuffix(".tgz")
            || name.hasSuffix(".tar.gz")
            || name.hasSuffix(".tar.bz2")
            || name.hasSuffix(".tar.xz")
            || name.hasSuffix(".gz")
            || name.hasSuffix(".bz2")
            || name.hasSuffix(".xz") {
            return .tar
        }
        return nil
    }

    private func confirmExtractOverwrite(_ names: [String]) -> Bool {
        let alert = NSAlert()
        let label = names.count == 1 ? "\"\(names[0])\"" : "\(names.count) items"
        alert.messageText = "Replace existing \(label)?"
        alert.informativeText = "Extracting will replace items already in this folder. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func listArchiveEntries(_ url: URL) throws -> [String] {
        let output: String
        switch archiveKind(for: url) {
        case .zip:
            output = try runTool("/usr/bin/unzip", ["-Z1", "--", url.path])
        case .tar:
            output = try runTool("/usr/bin/tar", ["-tf", url.path])
        case nil:
            throw ArchiveToolError(message: "FinderFlow can't extract this file type.")
        }
        return output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    private func extractArchive(_ url: URL, into dest: URL, replacing collisions: [String]) throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory
            .appendingPathComponent("finderflow-extract-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        switch archiveKind(for: url) {
        case .zip:
            try runTool("/usr/bin/unzip", ["-qq", "--", url.path, "-d", temp.path])
        case .tar:
            try runTool("/usr/bin/tar", ["-xf", url.path, "-C", temp.path])
        case nil:
            throw ArchiveToolError(message: "FinderFlow can't extract this file type.")
        }

        if try treeContainsEscapingSymlink(temp) {
            throw ArchiveToolError(message: "This archive can't be extracted because it contains a link that points outside the archive.")
        }
        copyQuarantine(from: url, onto: temp)

        let allowed = Set(collisions)
        for name in try fm.contentsOfDirectory(atPath: temp.path) {
            let source = temp.appendingPathComponent(name)
            let target = dest.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) {
                guard allowed.contains(name) else {
                    throw ArchiveToolError(message: "Couldn't extract because \"\(name)\" already exists.")
                }
                try fm.removeItem(at: target)
            }
            try fm.moveItem(at: source, to: target)
        }
    }

    private func treeContainsEscapingSymlink(_ root: URL) throws -> Bool {
        let fm = FileManager.default
        func walk(_ dir: URL) throws -> Bool {
            let kids = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                options: []
            )
            for kid in kids {
                let values = try kid.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values.isSymbolicLink == true {
                    if symlinkEscapesRoot(kid, root: root) { return true }
                    continue
                }
                if values.isDirectory == true, try walk(kid) { return true }
            }
            return false
        }
        return try walk(root)
    }

    private func copyQuarantine(from source: URL, onto root: URL) {
        let key = "com.apple.quarantine"
        let length = getxattr(source.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return }
        var bytes = [UInt8](repeating: 0, count: length)
        let read = bytes.withUnsafeMutableBytes { buffer -> ssize_t in
            guard let base = buffer.baseAddress else { return -1 }
            return getxattr(source.path, key, base, length, 0, XATTR_NOFOLLOW)
        }
        guard read > 0 else { return }

        func apply(_ url: URL) {
            _ = bytes.withUnsafeBytes { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return -1 }
                return setxattr(url.path, key, base, read, 0, XATTR_NOFOLLOW)
            }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values?.isSymbolicLink == true { return }
            guard values?.isDirectory == true,
                  let kids = try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: []
                  ) else { return }
            kids.forEach(apply)
        }
        apply(root)
    }

    @discardableResult
    private func runTool(_ launchPath: String,
                         _ arguments: [String],
                         currentDirectory: URL? = nil,
                         job: OperationJob? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let group = DispatchGroup()
        var outData = Data()
        var errData = Data()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        // Wait with cancellation support and a SIGKILL escalation, so a tool that
        // ignores SIGTERM cannot wedge the transfer queue forever.
        var cancelled = false
        if let job {
            var terminatedAt: Date?
            while process.isRunning {
                Thread.sleep(forTimeInterval: 0.2)
                if job.isCancelled {
                    cancelled = true
                    process.terminate()
                    terminatedAt = Date()
                    break
                }
            }
            if let terminatedAt, process.isRunning,
               Date().timeIntervalSince(terminatedAt) > 3 {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        process.waitUntilExit()
        group.wait()

        if cancelled { throw ArchiveToolError(message: "Cancelled") }

        let output = String(decoding: outData, as: UTF8.self)
        let errorText = String(decoding: errData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw ArchiveToolError(message: errorText.isEmpty ? "Couldn't read this archive." : errorText)
        }
        return output
    }

    /// Run a tool and report progress by sampling the output file's growing size.
    /// Archivers have no machine-readable progress on stdout, but the archive they are
    /// writing does grow, which is enough for a trustworthy bar.
    @discardableResult
    func runToolWithProgress(_ launchPath: String,
                                     _ arguments: [String],
                                     currentDirectory: URL?,
                                     outputFile: URL,
                                     job: OperationJob) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()

        // Sample while the tool runs.
        var lastSize: Int64 = 0
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.25)
            if job.isCancelled {
                process.terminate()
                break
            }
            let size = ((try? FileManager.default
                .attributesOfItem(atPath: outputFile.path))?[.size] as? Int64) ?? 0
            if size > lastSize {
                job.setReportedOutput(size)
                lastSize = size
            }
        }
        process.waitUntilExit()

        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if job.isCancelled { throw ArchiveToolError(message: "Cancelled") }
        guard process.terminationStatus == 0 else {
            throw ArchiveToolError(message: errorText.isEmpty ? "The archive tool failed." : errorText)
        }
        if let size = (try? FileManager.default
            .attributesOfItem(atPath: outputFile.path)[.size] as? Int64) {
            job.setReportedOutput(size)
        }
        return errorText
    }
}

// MARK: - Quick Look bridge

import Quartz

final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()
    private(set) var urls: [URL] = []

    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.delegate   = self
        panel.isVisible ? panel.reloadData() : panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        (urls.indices.contains(index) ? urls[index] : urls[0]) as NSURL
    }
}

// MARK: - QL responder chain shim

import SwiftUI

struct QLResponderSetup: NSViewRepresentable {
    func makeNSView(context: Context) -> _QLResponderView { _QLResponderView() }
    func updateNSView(_ nsView: _QLResponderView, context: Context) {}
}

final class _QLResponderView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let w = window else { return }
        if !(w.nextResponder is _QLResponderView) {
            nextResponder   = w.nextResponder
            w.nextResponder = self
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLookController.shared
        panel.delegate   = QuickLookController.shared
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}
