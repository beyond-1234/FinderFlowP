import SwiftUI
import AppKit

struct IconsView: View {
    let files:       [FileItem]
    @Binding var selectedIDs: Set<String>
    let currentPath: URL
    let groupBy:     GroupBy
    let onNavigate:  (FileItem) -> Void
    let onBrowseInto:(URL) -> Void
    let onReload:    () -> Void
    @ObservedObject var fileOps:   FileOperationsService
    @ObservedObject var favorites: FavoritesService

    /// Persisted so the chosen zoom survives navigation and relaunch.
    @AppStorage("ffIconSize") private var iconSize: Double = 64

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if groupBy != .none {
                    LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups) { group in
                            Section {
                                LazyVGrid(columns: columns, spacing: 12) {
                                    ForEach(group.items) { item in
                                        cellView(for: item)
                                    }
                                }
                                .padding(.horizontal, 16)
                            } header: {
                                if !group.title.isEmpty {
                                    DateSectionHeader(title: group.title, count: group.items.count)
                                        .padding(.horizontal, 8)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 12)
                } else {
                    // Ungrouped (default): a direct LazyVGrid inside ScrollView.
                    // Nesting LazyVGrid inside LazyVStack breaks cell virtualization and
                    // forces all hundred+ icons to instantiate immediately, causing visible
                    // stutter when switching into the icon view.
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(files) { item in
                            cellView(for: item)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .contextMenu { FolderBackgroundMenu() }
            .background(
                Button("") { quickLook() }
                    .keyboardShortcut(.space, modifiers: [])
                    .hidden()
            )
            // Control + scroll to zoom, like Finder's icon view.
            .background(IconZoomScrollCatcher { delta in
                adjustZoom(by: delta)
            })

            HStack(spacing: 8) {
                Button { adjustZoom(by: -0.25) } label: {
                    Image(systemName: "minus.magnifyingglass").font(.caption2)
                }
                .buttonStyle(.borderless)
                .fastTooltip("Smaller icons (⌃-scroll or ⌘–)")

                Slider(value: $iconSize, in: 32...160, step: 8)
                    .frame(width: 110)
                    .fastTooltip("Icon size")

                Button { adjustZoom(by: 0.25) } label: {
                    Image(systemName: "plus.magnifyingglass").font(.caption2)
                }
                .buttonStyle(.borderless)
                .fastTooltip("Larger icons (⌃-scroll or ⌘+)")
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .background(
                Group {
                    Button("") { adjustZoom(by: 0.25) }
                        .keyboardShortcut("=", modifiers: .command).hidden()
                    Button("") { adjustZoom(by: -0.25) }
                        .keyboardShortcut("-", modifiers: .command).hidden()
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffZoomIcons)) { note in
            guard let step = note.object as? Double else { return }
            adjustZoom(by: step)
        }
    }

    @ViewBuilder
    private func cellView(for item: FileItem) -> some View {
        IconCell(item: item,
                 iconSize: CGFloat(iconSize),
                 isSelected: selectedIDs.contains(item.id))
            .contentShape(Rectangle())
            .itemHitArea(item.id,
                         isSelected: selectedIDs.contains(item.id),
                         cornerRadius: 6,
                         inset: 0)
            .onTapGesture(count: 2) { onNavigate(item) }
            .fileDragOut(item: item, files: files, selectedIDs: selectedIDs)
            .contextMenu { iconContextMenu(item: item) }
    }

    private func adjustZoom(by step: Double) {
        let next = min(160, max(32, iconSize * (1 + step)))
        // Snap to the slider's 8pt grid so scroll zoom and the slider agree.
        iconSize = (next / 8).rounded() * 8
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: CGFloat(iconSize) + 20,
                            maximum: CGFloat(iconSize) + 40),
                  spacing: 8)]
    }

    private var groups: [FileGroup] { groupedItems(files, by: groupBy) }

    @ViewBuilder
    private func iconContextMenu(item: FileItem) -> some View {
        let sel = files.filter { selectedIDs.contains($0.id) }
        let targets = sel.isEmpty ? [item] : sel
        let urls = targets.map(\.url)
        iconPrimarySection(item: item, targets: targets, urls: urls)
        iconArchiveSection(item: item, targets: targets, urls: urls)
        iconClipboardSection(item: item, targets: targets, urls: urls)
        iconDestructiveSection(item: item, targets: targets, urls: urls)
    }

    @ViewBuilder
    private func iconPrimarySection(item: FileItem, targets: [FileItem], urls: [URL]) -> some View {
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
        Button("Quick Look") { QuickLookController.shared.show(urls) }
        Button("Get Info")   { showGetInfo(for: targets) }
        Divider()
        Button("Rename…")  { promptRename(item: item) }
        Button(targets.count > 1 ? "Duplicate \(targets.count) Items" : "Duplicate") {
            fileOps.duplicate(urls, reload: onReload)
        }
        Button(targets.count > 1 ? "Make \(targets.count) Aliases" : "Make Alias") {
            urls.forEach { fileOps.makeAlias(for: $0, reload: onReload) }
        }
    }

    @ViewBuilder
    private func iconArchiveSection(item: FileItem, targets: [FileItem], urls: [URL]) -> some View {
        Button(targets.count > 1 ? "Compress \(targets.count) Items…" : "Compress “\(item.name)”…") {
            ArchiveDialogPresenter.shared.present(urls: urls, fileOps: fileOps, reload: onReload)
        }
        Button("Compress to ZIP") {
            fileOps.compress(urls, reload: onReload)
        }
        if targets.count == 1 && item.isArchive {
            Button("Extract Here") { fileOps.extract(item.url, reload: onReload) }
        }
        Divider()
        Menu("Open With") {
            OpenWithMenuContent(urls: urls, item: item)
        }
    }

    @ViewBuilder
    private func iconClipboardSection(item: FileItem, targets: [FileItem], urls: [URL]) -> some View {
        Divider()
        Button("Cut")   { fileOps.cut(urls) }
        Button("Copy")  { fileOps.copy(urls) }
        Button("Paste") {
            let dest = (targets.count == 1 && item.isDirectory) ? item.url : currentPath
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
            TagMenuContent(targets: targets, fileOps: fileOps, onReload: onReload)
        }
    }

    @ViewBuilder
    private func iconDestructiveSection(item: FileItem, targets: [FileItem], urls: [URL]) -> some View {
        Divider()
        if item.isBrowsableFolder {
            if favorites.isPinned(item.url) {
                Button("Remove from Sidebar") { favorites.unpin(item.url) }
            } else {
                Button("Add to Sidebar") { favorites.pin(item.url) }
            }
        }
        Button("Show in Finder") {
            NSWorkspace.shared.selectFile(item.url.path, inFileViewerRootedAtPath: "")
        }
        Button(targets.count > 1 ? "Copy \(targets.count) Paths" : "Copy Path") {
            fileOps.copyPath(urls.map(\.path).joined(separator: "\n"))
        }
        Divider()
        Button("Move to Trash", role: .destructive) {
            fileOps.trash(urls, reload: onReload)
        }
        Button("Delete Permanently…", role: .destructive) {
            confirmPermanentDelete(names: targets.map(\.name)) {
                fileOps.permanentlyDelete(urls, reload: onReload)
            }
        }
    }


    /// Open a folder in a separate FinderFlow window (not in Finder).
    @Environment(\.ffOpenWindow) private var openWindowBox

    private func openInNewWindow(_ url: URL) {
        if let box = openWindowBox {
            box.open(url)
        } else {
            // No SwiftUI action in reach: ask the delegate to present a window.
            WindowOpener.openWithoutAction(url)
        }
    }

    private func quickLook() {
        let urls = files.filter { selectedIDs.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { return }
        QuickLookController.shared.show(urls)
    }

    private func promptRename(item: FileItem) {
        let alert = NSAlert()
        alert.messageText     = "Rename \"\(item.name)\""
        alert.informativeText = "Enter a new name:"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        tf.stringValue = item.name; tf.selectText(nil)
        alert.accessoryView = tf
        alert.window.initialFirstResponder = tf
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != item.name else { return }
        fileOps.rename(item.url, to: name, reload: onReload)
    }

    private func showGetInfo(for items: [FileItem]) {
        showGetInfoInFinder(items.map(\.url))
    }
}

struct IconCell: View {
    let item: FileItem; let iconSize: CGFloat; let isSelected: Bool
    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: item.icon).resizable()
                    .frame(width: iconSize, height: iconSize)
                    .allowsHitTesting(false)
                if !item.tagColors.isEmpty {
                    TagDotsView(colors: item.tagColors, size: 10)
                        .offset(x: 2, y: 2)
                        .allowsHitTesting(false)
                }
            }
            Text(item.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .allowsHitTesting(false)
        }
        .padding(6).frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
