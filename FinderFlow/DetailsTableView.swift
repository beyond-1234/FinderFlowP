import SwiftUI
import AppKit

// MARK: - Configurable details table
//
// SwiftUI's `Table` cannot do two things this view needs:
//   * the user dragging columns into a different order, and
//   * a header right-click menu (Explorer's "choose columns" affordance).
//
// A real NSTableView provides both natively: column reordering is `allowsColumnReordering`,
// and the header menu is `NSTableView.headerView?.menu`. SwiftUI wraps it and keeps the
// selection binding in sync with the rest of the app.

struct DetailsTableView: NSViewRepresentable {
    let files: [FileItem]
    @Binding var selectedIDs: Set<String>
    /// Visible columns in display order.
    let columns: [ColumnKind]
    /// File types present in this folder — decides which column groups the header
    /// menu offers. It never changes the visible columns by itself.
    let availableGroups: [ColumnGroup]
    /// Files per group, shown as a hint in the menu.
    let groupCounts: [ColumnGroup: Int]
    /// Folder whose column override (if any) is in use.
    let currentFolder: URL
    let hasFolderOverride: Bool
    let sortField: SortField
    let sortAscending: Bool
    /// Selected folder/file row for rename and double-click.
    var renamingID: String?
    @Binding var renameText: String

    let onRename: (FileItem) -> Void
    let onCommitRename: (FileItem, String) -> Void
    let onCancelRename: () -> Void
    let onOpen: (FileItem) -> Void
    let onSort: (SortField, Bool) -> Void
    let onReorder: ([ColumnKind]) -> Void
    let onResize: (ColumnKind, CGFloat) -> Void
    let onToggleColumn: (ColumnKind) -> Void
    let onResetColumns: () -> Void
    /// Builds the right-click menu for the given selection (empty = background).
    let makeContextMenu: ([FileItem]) -> NSMenu

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = RenameableTableView()
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.style = .inset
        tableView.rowHeight = 22
        tableView.usesAutomaticRowHeights = false
        tableView.headerView = NSTableHeaderView()
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        // No static menu here: RenameableTableView builds it per right-click so the
        // items reflect the row under the pointer.
        tableView.onCommitRename = { [weak coordinator = context.coordinator] id, text in
            coordinator?.commitRename(id: id, text: text)
        }
        tableView.onCancelRename = { [weak coordinator = context.coordinator] in
            coordinator?.cancelRename()
        }
        tableView.menuProvider = { [weak coordinator = context.coordinator] selection in
            guard let coordinator else { return NSMenu() }
            return coordinator.parent.makeContextMenu(selection)
        }

        // Dragging rows out of the app (to Finder, other apps).
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        context.coordinator.tableView = tableView
        context.coordinator.rebuildColumns()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        guard scrollView.documentView is RenameableTableView else { return }

        coordinator.syncColumnsIfNeeded()
        coordinator.reload(files: files, preservingSelection: selectedIDs)
        coordinator.applySortIndicator(field: sortField, ascending: sortAscending)
        coordinator.attachHeaderMenu()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: DetailsTableView
        weak var tableView: RenameableTableView?

        private var files: [FileItem] = []

        /// Rows currently displayed, exposed so the table view can resolve a
        /// right-click to the FileItems behind it.
        var currentFiles: [FileItem] { files }
        private var visibleColumns: [ColumnKind] = []
        private var isProgrammaticSelection = false
        private var editingRow: Int?

        init(_ parent: DetailsTableView) {
            self.parent = parent
            self.visibleColumns = parent.columns
        }

        // MARK: Columns

        func rebuildColumns() {
            guard let tableView else { return }

            // Remember live widths before tearing anything down, so re-adding a column
            // keeps the width the user set rather than snapping back to the stored one.
            var liveWidths: [ColumnKind: CGFloat] = [:]
            for column in tableView.tableColumns {
                if let kind = ColumnKind(rawValue: column.identifier.rawValue) {
                    liveWidths[kind] = column.width
                }
            }

            tableView.tableColumns.forEach { tableView.removeTableColumn($0) }

            let config = ColumnConfigStore.shared.config(forFolder: parent.currentFolder)
            for kind in visibleColumns {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(kind.rawValue))
                column.title = kind.title
                column.width = liveWidths[kind] ?? config.width(for: kind)
                column.minWidth = kind.minWidth
                column.resizingMask = .userResizingMask
                column.headerCell.alignment = kind.alignment == .right ? .right : .left
                if kind.sortField != nil {
                    column.sortDescriptorPrototype = NSSortDescriptor(key: kind.rawValue,
                                                                      ascending: true)
                }
                tableView.addTableColumn(column)
            }
        }

        /// Rebuild only when the visible *set* of columns differs. A pure reorder moves
        /// the existing NSTableColumns in place, which keeps their live widths intact —
        /// rebuilding on reorder is what used to wipe a width the user had just dragged.
        func syncColumnsIfNeeded() {
            let desired = parent.columns
            guard desired != visibleColumns else { return }

            let sameSet = Set(desired) == Set(visibleColumns) && desired.count == visibleColumns.count
            if sameSet {
                reorderColumns(to: desired)
                visibleColumns = desired
                return
            }

            // The column set changed: capture the live widths first so the rebuild
            // cannot drop an in-flight resize.
            captureLiveWidths()
            visibleColumns = desired
            rebuildColumns()
        }

        /// Move existing columns into `desired` order without recreating them.
        private func reorderColumns(to desired: [ColumnKind]) {
            guard let tableView else { return }
            for (targetIndex, kind) in desired.enumerated() {
                let identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
                guard let currentIndex = tableView.tableColumns.firstIndex(where: {
                    $0.identifier == identifier
                }) else { continue }
                if currentIndex != targetIndex {
                    tableView.moveColumn(currentIndex, toColumn: targetIndex)
                }
            }
        }

        /// Persist whatever widths the table currently has.
        private func captureLiveWidths() {
            guard let tableView else { return }
            for column in tableView.tableColumns {
                guard let kind = ColumnKind(rawValue: column.identifier.rawValue) else { continue }
                ColumnConfigStore.shared.setWidth(column.width,
                                                  for: kind,
                                                  forFolder: parent.currentFolder)
            }
        }

        func attachHeaderMenu() {
            guard let tableView, let header = tableView.headerView else { return }
            let menu = NSMenu()
            let current = Set(visibleColumns)

            let title = NSMenuItem(title: "Show Columns", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)

            // One section per file-type group that actually occurs in this folder.
            // Everything listed here is a *candidate*; nothing is turned on for you.
            for group in parent.availableGroups {
                let groupItem = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
                groupItem.isEnabled = false
                menu.addItem(groupItem)

                for kind in group.columns {
                    let item = NSMenuItem(title: "   " + kind.title,
                                          action: #selector(toggleColumn(_:)),
                                          keyEquivalent: "")
                    item.target = self
                    item.representedObject = kind.rawValue
                    item.state = current.contains(kind) ? .on : .off
                    // Name is the anchor column and cannot be hidden.
                    item.isEnabled = kind != .name
                    if let count = parent.groupCounts[group], group != .general {
                        item.toolTip = "\(count) matching file\(count == 1 ? "" : "s") in this folder"
                    }
                    menu.addItem(item)
                }
            }

            menu.addItem(.separator())
            let resetTitle = parent.hasFolderOverride
                ? "Use Default Columns for This Folder"
                : "Reset Default Columns"
            let reset = NSMenuItem(title: resetTitle,
                                   action: #selector(resetColumns),
                                   keyEquivalent: "")
            reset.target = self
            menu.addItem(reset)

            header.menu = menu
        }

        @objc private func toggleColumn(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let kind = ColumnKind(rawValue: raw) else { return }
            parent.onToggleColumn(kind)
        }

        @objc private func resetColumns() {
            parent.onResetColumns()
        }

        // MARK: Data

        func reload(files newFiles: [FileItem], preservingSelection: Set<String>) {
            let identityChanged = !sameIdentity(newFiles)
            files = newFiles

            if identityChanged {
                tableView?.reloadData()
                applySelection(preservingSelection)
            } else {
                // The row list is unchanged, but the *selection* may not be: ⌘A, Escape,
                // keyboard navigation and undo all change selectedIDs without touching
                // the file list. Pushing it here is what keeps the blue highlight in
                // step with the status bar. Guarded so a selection made inside the table
                // (which already updated the rows) is not fought over.
                syncSelectionIfNeeded(preservingSelection)
            }

            tableView?.reloadData(forRowIndexes: IndexSet(integersIn: 0..<max(files.count, 0)),
                                  columnIndexes: IndexSet(integersIn: 0..<visibleColumns.count))
        }

        /// Apply `ids` to the table only when the table disagrees with it.
        private func syncSelectionIfNeeded(_ ids: Set<String>) {
            guard let tableView else { return }
            let desired = IndexSet(files.enumerated().compactMap { ids.contains($1.id) ? $0 : nil })
            guard tableView.selectedRowIndexes != desired else { return }
            applySelection(ids)
        }

        private func sameIdentity(_ newFiles: [FileItem]) -> Bool {
            guard newFiles.count == files.count else { return false }
            for (a, b) in zip(newFiles, files) where a.id != b.id { return false }
            return true
        }

        private func applySelection(_ ids: Set<String>) {
            guard let tableView else { return }
            isProgrammaticSelection = true
            defer { isProgrammaticSelection = false }
            tableView.deselectAll(nil)
            for (row, file) in files.enumerated() where ids.contains(file.id) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: true)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { files.count }

        func tableView(_ tableView: NSTableView,
                       viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard let columnID = tableColumn?.identifier.rawValue,
                  let kind = ColumnKind(rawValue: columnID),
                  row < files.count else { return nil }
            let file = files[row]

            if kind == .name, parent.renamingID == file.id {
                return makeRenameCell(file: file, tableColumn: tableColumn)
            }

            let cell = tableView.makeView(withIdentifier: tableColumn!.identifier, owner: self) as? ColumnCellView
                ?? ColumnCellView(identifier: tableColumn!.identifier)
            cell.configure(kind: kind, file: file, row: row)
            return cell
        }

        private func makeRenameCell(file: FileItem, tableColumn: NSTableColumn?) -> NSView {
            let field = NSTextField()
            field.stringValue = parent.renameText
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = .systemFont(ofSize: 12)
            field.target = self
            field.action = #selector(renameCommitted(_:))
            field.identifier = NSUserInterfaceItemIdentifier(file.id)
            // Focus after the row view has been installed.
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
            return field
        }

        @objc private func renameCommitted(_ sender: NSTextField) {
            guard let id = sender.identifier?.rawValue,
                  let file = files.first(where: { $0.id == id }) else { return }
            commitRename(id: id, text: sender.stringValue)
            _ = file
        }

        func commitRename(id: String, text: String) {
            guard let file = files.first(where: { $0.id == id }) else { return }
            parent.onCommitRename(file, text)
        }

        func cancelRename() {
            parent.onCancelRename()
        }

        // MARK: Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isProgrammaticSelection, let tableView else { return }
            var ids = Set<String>()
            for row in tableView.selectedRowIndexes where row < files.count {
                ids.insert(files[row].id)
            }
            parent.selectedIDs = ids
        }

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let tableView, tableView.clickedRow >= 0,
                  tableView.clickedRow < files.count else { return }
            parent.onOpen(files[tableView.clickedRow])
        }

        // MARK: Sorting

        func applySortIndicator(field: SortField, ascending: Bool) {
            guard let tableView else { return }
            for column in tableView.tableColumns {
                guard let kind = ColumnKind(rawValue: column.identifier.rawValue) else { continue }
                if kind.sortField == field {
                    tableView.setIndicatorImage(
                        NSImage(named: ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"),
                        in: column)
                } else {
                    tableView.setIndicatorImage(nil, in: column)
                }
            }
        }

        func tableView(_ tableView: NSTableView,
                       sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key,
                  let kind = ColumnKind(rawValue: key),
                  let field = kind.sortField else { return }
            parent.onSort(field, descriptor.ascending)
        }

        // MARK: Column drag / resize

        func tableViewColumnDidMove(_ notification: Notification) {
            guard let tableView else { return }
            let order = tableView.tableColumns.compactMap {
                ColumnKind(rawValue: $0.identifier.rawValue)
            }
            // Adopt the table's new order immediately, so the next updateNSView sees
            // "already correct" and does not try to reorder or rebuild underneath the
            // user's drag.
            visibleColumns = order
            parent.onReorder(order)
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                  let kind = ColumnKind(rawValue: column.identifier.rawValue) else { return }
            // Persist straight away; rebuilds read the live width, so no extra state is
            // needed here and a following reorder cannot discard it.
            ColumnConfigStore.shared.setWidth(column.width,
                                              for: kind,
                                              forFolder: parent.currentFolder)
        }

        // MARK: Drag out

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < files.count else { return nil }
            var urls: [URL] = []
            if tableView.selectedRowIndexes.contains(row) {
                for selected in tableView.selectedRowIndexes where selected < files.count {
                    urls.append(files[selected].url)
                }
            } else {
                urls = [files[row].url]
            }
            let item = NSPasteboardItem()
            let data = try? NSKeyedArchiver.archivedData(withRootObject: urls.map(\.absoluteString),
                                                          requiringSecureCoding: false)
            if let data {
                item.setData(data, forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
            }
            return item
        }
    }
}

// MARK: - Cell view

final class ColumnCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private var iconWidth: NSLayoutConstraint!
    private var labelGap: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        addSubview(iconView)
        addSubview(label)

        iconWidth = iconView.widthAnchor.constraint(equalToConstant: 16)
        labelGap = label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            iconWidth,

            labelGap,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(kind: ColumnKind, file: FileItem, row: Int) {
        label.alignment = kind.alignment
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)

        // Only the Name column shows a file icon, like the old SwiftUI table. The icon
        // is collapsed (not just hidden) so other columns are not indented by an empty
        // 16pt gutter.
        let showsIcon = (kind == .name)
        iconView.isHidden = !showsIcon
        iconView.image = showsIcon ? file.icon : nil
        iconWidth.constant = showsIcon ? 16 : 0
        labelGap.constant = showsIcon ? 6 : 0

        switch kind {
        case .name:
            label.stringValue = file.name
            label.textColor = .labelColor
        case .dateModified:
            label.stringValue = file.formattedDateModified
        case .dateCreated:
            label.stringValue = file.formattedDateCreated
        case .dateAdded:
            label.stringValue = file.formattedDateModified
        case .size:
            label.stringValue = file.formattedSize
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        case .kind:
            label.stringValue = file.kind
        case .fileExtension:
            label.stringValue = file.fileExtension.isEmpty
                ? "—" : file.fileExtension.uppercased()
        case .permissions:
            label.stringValue = file.formattedPermissions
        case .path:
            label.stringValue = file.url.deletingLastPathComponent().path
        case .dimensions, .duration, .title, .artist, .album, .pageCount, .version:
            label.stringValue = ColumnValueLoader.shared.value(for: kind, item: file) ?? "—"
        }
    }
}

// MARK: - Table view with right-click selection

final class RenameableTableView: NSTableView {
    var onCommitRename: ((String, String) -> Void)?
    var onCancelRename: (() -> Void)?
    /// Supplies the menu for the rows currently relevant to this right-click.
    var menuProvider: (([FileItem]) -> NSMenu)?

    /// Right-click selects the clicked row first, so menu actions target what the user
    /// actually pointed at.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)

        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        // Build from the live selection so the menu matches the highlight the user sees.
        let files = (dataSource as? DetailsTableView.Coordinator)?.currentFiles ?? []
        let selected = selectedRowIndexes.compactMap { index -> FileItem? in
            index < files.count ? files[index] : nil
        }
        return menuProvider?(selected)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Toggle select-all on ⌘A: first press selects all, second press clears.
        // NSTableView's built-in performKeyEquivalent would otherwise unconditionally
        // select-all every time, ignoring the toggle behaviour.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            if let delegate = delegate as? DetailsTableView.Coordinator {
                let allIDs = Set(delegate.currentFiles.map(\.id))
                if !allIDs.isEmpty {
                    if delegate.parent.selectedIDs == allIDs {
                        delegate.parent.selectedIDs.removeAll()
                    } else {
                        delegate.parent.selectedIDs = allIDs
                    }
                    return true
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36: // Return opens
            if let delegate = delegate as? DetailsTableView.Coordinator {
                delegate.handleDoubleClick(nil)
                return
            }
        case 51: // Delete
            if let delegate = delegate as? DetailsTableView.Coordinator,
               delegate.parent.selectedIDs.isEmpty {
                NotificationCenter.default.post(name: .ffNavigateUp, object: nil)
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }
}

extension Notification.Name {
    static let ffNavigateUp = Notification.Name("ffNavigateUp")
}
