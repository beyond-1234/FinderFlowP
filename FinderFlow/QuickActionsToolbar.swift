import SwiftUI
import AppKit

// MARK: - Toolbar
//
// Button sizing rule: every toolbar control is a fixed 26x24 hit area so icons line
// up on the same baseline instead of looking alternately wide and narrow. Anything
// that is inherently wider (sort menu, view switcher) keeps its own fixed width.

private let kToolbarButtonSize = CGSize(width: 26, height: 24)

struct QuickActionsToolbar: View {
    @Binding var currentPath:    URL
    let selectedURL:             URL?   // selected folder, nil → currentPath
    let selectedCount:           Int
    let canGoBack:               Bool
    let canGoForward:            Bool
    let onCreateFolder:          () -> Void
    let onCreateFile:            () -> Void
    let onDelete:                () -> Void
    let onCopy:                  () -> Void
    let onCut:                   () -> Void
    let onGoBack:                () -> Void
    let onGoForward:             () -> Void
    @ObservedObject var fileOps: FileOperationsService
    @Binding var viewMode:       ViewMode
    @Binding var sortField:      SortField
    @Binding var sortAscending:  Bool
    @Binding var showHidden:     Bool
    @Binding var groupBy:        GroupBy
    @Binding var folderOrder:    FolderOrder
    @Binding var showPreview:    Bool
    @Binding var showColumnTree: Bool
    let onReload:                () -> Void

    @ObservedObject private var integrations = IntegrationStore.shared

    private var openTarget: URL { selectedURL ?? currentPath }

    var body: some View {
        HStack(spacing: 4) {
            Group {
                creationGroup
                separator
                historyGroup
                separator
                clipboardGroup
                separator
                toolGroup
                separator
                viewGroup
            }

            Spacer(minLength: 8)

            sortGroup
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { integrations.resolveIfNeeded() }
    }

    private var separator: some View {
        Divider().frame(height: 18)
    }

    // MARK: - Groups

    private var creationGroup: some View {
        HStack(spacing: 4) {
            ToolbarActionButton(icon: "folder.badge.plus", label: "New Folder") { onCreateFolder() }
            ToolbarActionButton(icon: "doc.badge.plus", label: "New File") { onCreateFile() }
        }
    }

    private var historyGroup: some View {
        HStack(spacing: 4) {
            ToolbarActionButton(icon: "chevron.left", label: "Back") { onGoBack() }
                .disabled(!canGoBack)
            ToolbarActionButton(icon: "chevron.right", label: "Forward") { onGoForward() }
                .disabled(!canGoForward)
            ToolbarActionButton(icon: "arrow.up", label: "Go to Parent Folder") {
                let p = currentPath.deletingLastPathComponent()
                if p != currentPath { currentPath = p }
            }
            .disabled(currentPath.pathComponents.count <= 1)
            ToolbarActionButton(icon: "arrow.clockwise", label: "Refresh") { onReload() }
        }
    }

    private var clipboardGroup: some View {
        HStack(spacing: 4) {
            ToolbarActionButton(icon: "doc.on.doc", label: "Copy") { onCopy() }
                .disabled(selectedCount == 0)
            ToolbarActionButton(icon: "scissors", label: "Cut") { onCut() }
                .disabled(selectedCount == 0)
            ToolbarActionButton(icon: "doc.on.clipboard", label: "Paste") {
                fileOps.paste(to: currentPath, reload: onReload)
            }
            .disabled(fileOps.pasteboardURLs.isEmpty)
            ToolbarActionButton(icon: "trash", label: "Move to Trash") { onDelete() }
                .disabled(selectedCount == 0)
            ToolbarActionButton(icon: "arrow.uturn.backward", label: "Undo") { fileOps.undo() }
                .disabled(!fileOps.canUndo)
        }
    }

    private var toolGroup: some View {
        HStack(spacing: 4) {
            ForEach(integrations.items(of: .terminal)) { item in
                AppIconToolbarButton(appIcon: item.icon, label: "Open in \(item.integration.name)") {
                    IntegrationLauncher.open(folder: openTarget, using: item)
                }
            }
            ForEach(integrations.items(of: .editor)) { item in
                AppIconToolbarButton(appIcon: item.icon, label: "Open in \(item.integration.name)") {
                    IntegrationLauncher.open(folder: openTarget, using: item)
                }
            }
        }
    }

    private var viewGroup: some View {
        HStack(spacing: 4) {
            Picker("View", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Image(systemName: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 92)
            .fastTooltip("Switch view")

            ToolbarToggleButton(isOn: $showHidden,
                                on: "eye",
                                off: "eye.slash",
                                help: "Show hidden files")

            Menu {
                Picker("Group By", selection: $groupBy) {
                    ForEach(GroupBy.allCases) { g in
                        Text(g.menuTitle).tag(g)
                    }
                }
            } label: {
                Image(systemName: groupBy == .none ? "rectangle.3.group" : "rectangle.3.group.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(groupBy == .none ? Color.primary : Color.accentColor)
                    .frame(width: kToolbarButtonSize.width, height: kToolbarButtonSize.height)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .fastTooltip(groupBy == .none ? "Group By" : "Grouped by \(groupBy.menuTitle)")

            ToolbarToggleButton(isOn: $showPreview,
                                on: "sidebar.trailing",
                                off: "sidebar.trailing",
                                help: "File preview panel")

            if viewMode == .columns {
                ToolbarToggleButton(isOn: $showColumnTree,
                                    on: "sidebar.left",
                                    off: "rectangle.split.1x2",
                                    help: "Folder tree in column view")
            }
        }
    }

    private var sortGroup: some View {
        HStack(spacing: 4) {
            Picker("Sort", selection: $sortField) {
                ForEach(SortField.allCases) { f in Text(f.rawValue).tag(f) }
            }
            .pickerStyle(.menu)
            .frame(width: 118)
            .fastTooltip("Sort by")

            ToolbarActionButton(icon: sortAscending ? "arrow.up" : "arrow.down",
                                label: sortAscending ? "Ascending" : "Descending") {
                sortAscending.toggle()
            }

            Menu {
                Picker("Folders", selection: $folderOrder) {
                    ForEach(FolderOrder.allCases) { o in
                        Text(o.rawValue).tag(o)
                    }
                }
            } label: {
                Image(systemName: folderOrder == .foldersFirst ? "folder.fill"
                      : (folderOrder == .filesFirst ? "doc.fill" : "arrow.up.arrow.down"))
                    .font(.system(size: 12))
                    .frame(width: kToolbarButtonSize.width, height: kToolbarButtonSize.height)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .fastTooltip("Order: \(folderOrder.rawValue)")
        }
    }
}

// MARK: - Uniform toolbar buttons

struct ToolbarActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: kToolbarButtonSize.width, height: kToolbarButtonSize.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .fastTooltip(label)
    }
}

struct ToolbarToggleButton: View {
    @Binding var isOn: Bool
    let on: String
    let off: String
    let help: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: isOn ? on : off)
                .font(.system(size: 12))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .frame(width: kToolbarButtonSize.width, height: kToolbarButtonSize.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .fastTooltip(help)
    }
}

struct AppIconToolbarButton: View {
    let appIcon: NSImage
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
                .frame(width: kToolbarButtonSize.width, height: kToolbarButtonSize.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .fastTooltip(label)
    }
}
