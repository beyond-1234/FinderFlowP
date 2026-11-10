import SwiftUI
import AppKit

// Approximate height of the Table's column header row. Below this strip the pointer
// is over the rows, where the cursor must always be the plain arrow. Erring slightly
// tall keeps us from ever clobbering the header divider's resize cursor.
private let kTableHeaderStripHeight: CGFloat = 30

struct ListView: View {
    let files:         [FileItem]
    @Binding var selectedIDs:      Set<String>
    @Binding var pendingRenameURL: URL?
    let currentPath:   URL
    @Binding var sortField:     SortField
    @Binding var sortAscending: Bool
    let groupBy:       GroupBy
    let onNavigate:    (FileItem) -> Void
    let onBrowseInto:  (URL) -> Void
    let onReload:      () -> Void
    @ObservedObject var fileOps:   FileOperationsService
    @ObservedObject var favorites: FavoritesService

    @State private var sortOrder:       [KeyPathComparator<FileItem>] = [.init(\.name, order: .forward)]
    @State private var renamingID:      String?
    @State private var renameText:      String = ""
    @State private var renameCancelled: Bool   = false
    @FocusState private var renameActive: Bool
    @State private var keyMonitor: Any?

    var body: some View {
        if groupBy != .none {
            GroupedListView(
                files:            files,
                selectedIDs:      $selectedIDs,
                pendingRenameURL: $pendingRenameURL,
                currentPath:      currentPath,
                groupBy:          groupBy,
                onNavigate:       onNavigate,
                onBrowseInto:     onBrowseInto,
                onReload:         onReload,
                fileOps:          fileOps,
                favorites:        favorites
            )
        } else {
            tableView
                .onChange(of: pendingRenameURL) { url in
                    guard let url, let item = files.first(where: { $0.url == url }) else { return }
                    startRename(item: item)
                    pendingRenameURL = nil
                }
        }
    }

    // MARK: - Table (non-grouped)

    private var tableView: some View {
        Table(files, selection: $selectedIDs, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { item in
                fileNameCell(for: item)
                    .itemHitArea(item.id)
                    .fileDragOut(item: item, files: files, selectedIDs: selectedIDs)
            }
            .width(min: 140, ideal: 280, max: 600)

            TableColumn("Date Modified", value: \.dateModified) { item in
                Text(item.formattedDateModified).foregroundStyle(.secondary)
            }.width(min: 100, ideal: 148, max: 240)

            TableColumn("Date Created", value: \.dateCreated) { item in
                Text(item.formattedDateCreated).foregroundStyle(.secondary)
            }.width(min: 100, ideal: 148, max: 240)

            TableColumn("Size", value: \.size) { item in
                Text(item.formattedSize).foregroundStyle(.secondary).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.width(min: 50, ideal: 80, max: 140)

            TableColumn("Kind", value: \.kind) { item in
                Text(item.kind).foregroundStyle(.secondary)
            }.width(min: 60, ideal: 110, max: 200)

            TableColumn("Extension", value: \.fileExtension) { item in
                Text(item.fileExtension.isEmpty ? "—" : item.fileExtension.uppercased())
                    .foregroundStyle(.secondary)
            }.width(min: 40, ideal: 68, max: 120)
        }
        .onChange(of: sortOrder) { order in
            guard let first = order.first else { return }
            sortAscending = (first.order == .forward)
            switch first.keyPath {
            case \FileItem.name:          sortField = .name
            case \FileItem.dateModified:  sortField = .dateModified
            case \FileItem.dateCreated:   sortField = .dateCreated
            case \FileItem.size:          sortField = .size
            case \FileItem.kind:          sortField = .kind
            case \FileItem.fileExtension: sortField = .ext
            default: break
            }
        }
        .onChange(of: sortField) { _ in syncSortOrder() }
        .onChange(of: sortAscending) { _ in syncSortOrder() }
        .onChange(of: files) { newFiles in
            if let id = renamingID, !newFiles.contains(where: { $0.id == id }) {
                renamingID = nil
            }
        }
        .onChange(of: renameActive) { active in
            guard !active, let id = renamingID,
                  let item = files.first(where: { $0.id == id }) else { return }
            commitRename(for: item)
        }
        .onAppear {
            syncSortOrder()
            attachKeyboardMonitor()
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.isEmpty {
                FolderBackgroundMenu(currentPath: currentPath)
            } else {
                contextMenu(for: ids)
            }
        }
        primaryAction: { ids in
            guard renamingID == nil else { return }
            if let id = ids.first, let item = files.first(where: { $0.id == id }) {
                onNavigate(item)
            }
        }
        .background(
            Button("") { quickLook(ids: selectedIDs) }
                .keyboardShortcut(.space, modifiers: []).hidden()
        )
    }

    @ViewBuilder
    private func fileNameCell(for item: FileItem) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: item.icon).resizable().frame(width: 16, height: 16)
                .allowsHitTesting(false)
            if renamingID == item.id {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .resetsCursorOnExit()
                    .focused($renameActive)
                    .onSubmit {
                        if let it = files.first(where: { $0.id == renamingID }) {
                            commitRename(for: it)
                        }
                    }
                    .onExitCommand { cancelRename() }
            } else {
                Text(item.name).lineLimit(1)
                    .foregroundStyle(fileOps.isCut && fileOps.clipboardURLs.contains(item.url)
                                     ? Color.secondary : Color.primary)
                    .allowsHitTesting(false)
            }
            TagDotsView(colors: item.tagColors, size: 10)
                .allowsHitTesting(false)
        }
        .opacity(fileOps.isCut && fileOps.clipboardURLs.contains(item.url) ? 0.45 : 1.0)
        .contentShape(Rectangle())
    }

    private func syncSortOrder() {
        let order: SortOrder = sortAscending ? .forward : .reverse
        switch sortField {
        case .name:         sortOrder = [KeyPathComparator(\.name,          order: order)]
        case .dateModified: sortOrder = [KeyPathComparator(\.dateModified,  order: order)]
        case .dateCreated:  sortOrder = [KeyPathComparator(\.dateCreated,   order: order)]
        case .size:         sortOrder = [KeyPathComparator(\.size,          order: order)]
        case .kind:         sortOrder = [KeyPathComparator(\.kind,          order: order)]
        case .ext:          sortOrder = [KeyPathComparator(\.fileExtension, order: order)]
        }
    }

    // MARK: - WinFiles Keyboard Monitor

    private func attachKeyboardMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // When editing text (renaming or search field), let normal keyboard flow through
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextField || responder is NSTextView {
                return event
            }
            guard renamingID == nil else { return event }

            switch event.keyCode {
            case 36: // Enter -> Open selection
                if let firstID = selectedIDs.first, let item = files.first(where: { $0.id == firstID }) {
                    onNavigate(item)
                    return nil
                }
            case 120: // F2 -> Rename
                if let firstID = selectedIDs.first, let item = files.first(where: { $0.id == firstID }) {
                    startRename(item: item)
                    return nil
                }
            case 51: // Backspace / Delete
                let sel = files.filter { selectedIDs.contains($0.id) }
                if !sel.isEmpty {
                    fileOps.trash(sel.map(\.url), reload: onReload)
                    return nil
                }
                // Nothing selected: hand back to the window-level monitor, which
                // treats Backspace as "go to parent folder".
                return event
            case 53: // Escape -> Cancel Cut
                if fileOps.isCut {
                    fileOps.cancelCut()
                    return nil
                }
            default:
                break
            }
            return event
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - Inline rename helpers

    func startRename(item: FileItem) {
        renameCancelled = false
        renamingID      = item.id
        renameText      = item.name
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { renameActive = true }
    }

    private func commitRename(for item: FileItem) {
        renamingID   = nil
        renameActive = false
        guard !renameCancelled else { renameCancelled = false; return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != item.name else { return }
        fileOps.rename(item.url, to: name, reload: onReload)
    }

    private func cancelRename() {
        renameCancelled = true
        renamingID      = nil
    }

    // MARK: - Full macOS context menu

    @ViewBuilder
    func contextMenu(for ids: Set<String>) -> some View {
        ItemMenuContent(
            sel: files.filter { ids.contains($0.id) },
            currentPath: currentPath,
            fileOps: fileOps,
            favorites: favorites,
            onNavigate: onNavigate,
            onBrowseInto: onBrowseInto,
            onReload: onReload,
            onRename: { startRename(item: $0) },
            onQuickLook: { quickLook(ids: $0) },
            onGetInfo: { showGetInfo(for: $0) },
            onConfirmDelete: { names, act in confirmPermanentDelete(names: names, onConfirm: act) },
            onSelect: { self.selectedIDs = $0 }
        )
    }


    /// Open a folder in a separate FinderFlow window (not in Finder).
    @Environment(\.winfilesOpenWindow) private var openWindowBox

    private func openInNewWindow(_ url: URL) {
        openWindowBox.open(url)
    }

    // MARK: - Helpers

    private func quickLook(ids: Set<String>) {
        let urls = files.filter { ids.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { return }
        QuickLookController.shared.show(urls)
    }

    private func showGetInfo(for items: [FileItem]) {
        showGetInfoInFinder(items.map(\.url))
    }
}

// MARK: - Date-grouped list view

struct GroupedListView: View {
    let files:       [FileItem]
    @Binding var selectedIDs:      Set<String>
    @Binding var pendingRenameURL: URL?
    let currentPath: URL
    let groupBy:     GroupBy
    let onNavigate:  (FileItem) -> Void
    let onBrowseInto:(URL) -> Void
    let onReload:    () -> Void
    @ObservedObject var fileOps:   FileOperationsService
    @ObservedObject var favorites: FavoritesService

    @State private var renamingID:      String?
    @State private var renameText:      String = ""
    @State private var renameCancelled: Bool   = false
    @FocusState private var renameActive: Bool

    private var groups: [FileGroup] { groupedItems(files, by: groupBy) }

    var body: some View {
        ScrollViewReader { proxy in
        List(selection: $selectedIDs) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        ZStack(alignment: .leading) {
                            GroupedRow(item: item, isSelected: selectedIDs.contains(item.id))
                                .opacity(renamingID == item.id ? 0 : 1)
                                .allowsHitTesting(false)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .onTapGesture(count: 2) {
                                            guard renamingID == nil else { return }
                                            onNavigate(item)
                                        }
                                        .onTapGesture {
                                            guard renamingID == nil else { return }
                                            selectedIDs = [item.id]
                                        }
                                )
                            if renamingID == item.id {
                                HStack(spacing: 8) {
                                    Image(nsImage: item.icon).resizable().frame(width: 18, height: 18)
                                    TextField("", text: $renameText)
                                        .textFieldStyle(.plain)
                                        .resetsCursorOnExit()
                                        .focused($renameActive)
                                        .onSubmit {
                                            if let it = files.first(where: { $0.id == renamingID }) {
                                                commitGroupedRename(for: it)
                                            }
                                        }
                                        .onExitCommand { cancelGroupedRename() }
                                    Spacer()
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .tag(item.id)
                        .id(item.id)
                        .itemHitArea(item.id)
                        .fileDragOut(item: item, files: files, selectedIDs: selectedIDs)
                        .contextMenu { listContextMenu(item: item) }
                    }
                } header: {
                    DateSectionHeader(title: group.title, count: group.items.count)
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.isEmpty {
                FolderBackgroundMenu(currentPath: currentPath)
            } else {
                if let id = ids.first, let item = files.first(where: { $0.id == id }) {
                    listContextMenu(item: item)
                }
            }
        }
        .onChange(of: selectedIDs) { ids in
            if let id = ids.first {
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .onChange(of: files) { newFiles in
            if let id = renamingID, !newFiles.contains(where: { $0.id == id }) {
                renamingID = nil
            }
        }
        .onChange(of: renameActive) { active in
            guard !active, let id = renamingID,
                  let item = files.first(where: { $0.id == id }) else { return }
            commitGroupedRename(for: item)
        }
        .onChange(of: pendingRenameURL) { url in
            guard let url, let item = files.first(where: { $0.url == url }) else { return }
            startGroupedRename(item: item)
            pendingRenameURL = nil
        }
        .background(
            Button("") {
                let urls = files.filter { selectedIDs.contains($0.id) }.map(\.url)
                if !urls.isEmpty { QuickLookController.shared.show(urls) }
            }
            .keyboardShortcut(.space, modifiers: []).hidden()
        )
        } // ScrollViewReader
    }

    // MARK: - Grouped inline rename helpers

    func startGroupedRename(item: FileItem) {
        renameCancelled = false
        renamingID      = item.id
        renameText      = item.name
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { renameActive = true }
    }

    private func commitGroupedRename(for item: FileItem) {
        renamingID   = nil
        renameActive = false
        guard !renameCancelled else { renameCancelled = false; return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != item.name else { return }
        fileOps.rename(item.url, to: name, reload: onReload)
    }

    private func cancelGroupedRename() {
        renameCancelled = true
        renamingID      = nil
    }

    @ViewBuilder
    private func listContextMenu(item: FileItem) -> some View {
        let sel     = files.filter { selectedIDs.contains($0.id) }
        let targets = sel.isEmpty ? [item] : sel
        ItemMenuContent(
            sel: targets,
            currentPath: currentPath,
            fileOps: fileOps,
            favorites: favorites,
            onNavigate: onNavigate,
            onBrowseInto: onBrowseInto,
            onReload: onReload,
            onRename: { startGroupedRename(item: $0) },
            onQuickLook: { _ in
                let urls = targets.map(\.url)
                if !urls.isEmpty { QuickLookController.shared.show(urls) }
            },
            onGetInfo: { _ in showGetInfoInFinder(targets.map(\.url)) },
            onConfirmDelete: { names, act in confirmPermanentDelete(names: names, onConfirm: act) }
        )
    }
}

struct GroupedRow: View {
    let item:       FileItem
    let isSelected: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: item.icon).resizable().frame(width: 18, height: 18)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.name).font(.system(size: 13)).lineLimit(1)
                        .allowsHitTesting(false)
                    TagDotsView(colors: item.tagColors, size: 9)
                        .allowsHitTesting(false)
                }
                Text(item.kind + (item.isDirectory ? "" : " • \(item.formattedSize)"))
                    .font(.caption).foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
            Spacer()
            Text(item.formattedDateModified)
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Date section header (Finder-style)

struct DateSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
            Spacer()
            Text("\(count) \(count == 1 ? "item" : "items")")
                .font(.system(size: 10))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }
}

struct FolderBackgroundMenu: View {
    var currentPath: URL? = nil

    var body: some View {
        Button("New Folder") {
            NotificationCenter.default.post(name: .createNewFolder, object: nil)
        }
        Button("New File") {
            NotificationCenter.default.post(name: .createNewFile, object: nil)
        }
        Divider()
        Button("Open in Terminal") {
            let p = currentPath ?? FileManager.default.homeDirectoryForCurrentUser
            openTerminalAt(p)
        }
    }
}

struct ItemMenuContent: View {
    let sel: [FileItem]
    let currentPath: URL
    @ObservedObject var fileOps: FileOperationsService
    @ObservedObject var favorites: FavoritesService
    let onNavigate: (FileItem) -> Void
    let onBrowseInto: (URL) -> Void
    let onReload: () -> Void
    let onRename: (FileItem) -> Void
    let onQuickLook: (Set<String>) -> Void
    let onGetInfo: ([FileItem]) -> Void
    let onConfirmDelete: ([String], @escaping () -> Void) -> Void
    var onSelect: ((Set<String>) -> Void)? = nil

    var body: some View {
        Group {
            if let item = sel.first {
                let urls = sel.map(\.url)
                primarySection(item: item, urls: urls)
                archiveSection(item: item, urls: urls)
                clipboardSection(item: item, urls: urls)
                destinationSection(item: item, urls: urls)
            } else {
                emptySpaceSection
            }
        }
        .onAppear {
            if !sel.isEmpty {
                onSelect?(Set(sel.map(\.id)))
            }
        }
    }

    // Split into small computed sections: one giant ViewBuilder expression made the
    // type checker give up ("failed to produce diagnostic").

    /// Open a folder in a separate FinderFlow window (not in Finder).
    @Environment(\.winfilesOpenWindow) private var openWindowBox

    private func openInNewWindow(_ url: URL) {
        openWindowBox.open(url)
    }

    @ViewBuilder
    private func primarySection(item: FileItem, urls: [URL]) -> some View {
        Button("Open") { onNavigate(item) }
        if item.isBrowsableFolder {
            Button("Open in New Window") { openInNewWindow(item.url) }
        } else if item.isPackage {
            Button("Show Package Contents") { onBrowseInto(item.url) }
        }
        Button("Open in Terminal") {
            let target = item.isDirectory ? item.url : currentPath
            openTerminalAt(target)
        }
        Divider()
        Button("Quick Look") { onQuickLook(Set(sel.map(\.id))) }
        Button("Get Info")   { onGetInfo(sel) }
        Divider()
        Button("Rename…")    { onRename(item) }
        Button(sel.count > 1 ? "Duplicate \(sel.count) Items" : "Duplicate") {
            fileOps.duplicate(urls, reload: onReload)
        }
        Button(sel.count > 1 ? "Make \(sel.count) Aliases" : "Make Alias") {
            urls.forEach { fileOps.makeAlias(for: $0, reload: onReload) }
        }
    }

    @ViewBuilder
    private func archiveSection(item: FileItem, urls: [URL]) -> some View {
        Button(sel.count > 1 ? "Compress \(sel.count) Items…" : "Compress “\(item.name)”…") {
            ArchiveDialogPresenter.shared.present(urls: urls, fileOps: fileOps, reload: onReload)
        }
        Button("Compress to ZIP") {
            fileOps.compress(urls, reload: onReload)
        }
        if sel.count == 1 && item.isArchive {
            Button("Extract Here") { fileOps.extract(item.url, reload: onReload) }
        }
        Divider()
        Menu("Open With") {
            OpenWithMenuContent(urls: urls, item: item)
        }
    }

    @ViewBuilder
    private func clipboardSection(item: FileItem, urls: [URL]) -> some View {
        Divider()
        Button("Cut") { fileOps.cut(urls) }
        Button("Copy") { fileOps.copy(urls) }
        Button("Paste") {
            let dest = (sel.count == 1 && item.isDirectory) ? item.url : currentPath
            fileOps.paste(to: dest, reload: onReload)
        }
        .disabled(fileOps.pasteboardURLs.isEmpty)
        Divider()
        Menu("Share") {
            Button("AirDrop") { fileOps.shareViaAirDrop(urls) }
            Divider()
            Button("Share…") { fileOps.showShareSheet(for: urls) }
        }
        Divider()
        Menu("Tags") {
            TagMenuContent(targets: sel, fileOps: fileOps, onReload: onReload)
        }
    }

    @ViewBuilder
    private func destinationSection(item: FileItem, urls: [URL]) -> some View {
        Divider()
        if item.isDirectory {
            if favorites.isPinned(item.url) {
                Button("Remove from Sidebar") { favorites.unpin(item.url) }
            } else {
                Button("Add to Sidebar") { favorites.pin(item.url) }
            }
        }
        Button("Show in Finder") {
            NSWorkspace.shared.selectFile(item.url.path, inFileViewerRootedAtPath: "")
        }
        Button(sel.count > 1 ? "Copy \(sel.count) Paths" : "Copy Path") {
            fileOps.copyPath(urls.map(\.path).joined(separator: "\n"))
        }
        Divider()
        Button("Move to Trash", role: .destructive) {
            fileOps.trash(urls, reload: onReload)
        }
        Button("Delete Permanently…", role: .destructive) {
            onConfirmDelete(sel.map(\.name)) {
                fileOps.permanentlyDelete(urls, reload: onReload)
            }
        }
    }

    @ViewBuilder
    private var emptySpaceSection: some View {
        Button("Paste") { fileOps.paste(to: currentPath, reload: onReload) }
            .disabled(fileOps.pasteboardURLs.isEmpty)
        if fileOps.canUndo { Button("Undo") { fileOps.undo() } }
        if fileOps.canRedo { Button("Redo") { fileOps.redo() } }
        Divider()
        Button("Refresh") { onReload() }
    }
}
