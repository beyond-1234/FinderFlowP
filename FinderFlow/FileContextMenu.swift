import AppKit

// MARK: - Context menu for the details table
//
// The list view is an NSTableView, which needs a real NSMenu — it cannot host a SwiftUI
// View-based menu. This builder reproduces the same items as the SwiftUI menus used by
// the icon and column views, so all three views offer the same actions.
//
// Actions are dispatched through closures captured per NSMenuItem, so no selector
// plumbing or global state is required.

final class FileContextMenuBuilder {

    struct Context {
        let selection: [FileItem]
        let currentPath: URL
        let fileOps: FileOperationsService
        let favorites: FavoritesService
        let onReload: () -> Void
        let onOpen: (FileItem) -> Void
        let onBrowseInto: (URL) -> Void
        let onRename: (FileItem) -> Void
        let onQuickLook: (Set<String>) -> Void
        let onGetInfo: ([FileItem]) -> Void
        let onConfirmDelete: ([String], @escaping () -> Void) -> Void
    }

    static func build(_ ctx: Context) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        guard let item = ctx.selection.first else {
            addEmptySpaceItems(menu, ctx)
            return menu
        }

        let urls = ctx.selection.map(\.url)

        // ── Open / inspect ────────────────────────────────────────────────
        menu.add(action("Open") { ctx.onOpen(item) })
        if item.isBrowsableFolder {
            menu.add(action("Open in New Window") {
                DispatchQueue.main.async { WindowOpener.openWithoutAction(item.url) }
            })
        } else if item.isPackage {
            menu.add(action("Show Package Contents") { ctx.onBrowseInto(item.url) })
        }
        menu.add(action("Open in Terminal") {
            openTerminalAt(item.isDirectory ? item.url : ctx.currentPath)
        })
        menu.add(.separator())
        menu.add(action("Quick Look") { ctx.onQuickLook(Set(ctx.selection.map(\.id))) })
        menu.add(action("Get Info") { ctx.onGetInfo(ctx.selection) })
        menu.add(.separator())
        menu.add(action("Rename…") { ctx.onRename(item) })
        menu.add(action(ctx.selection.count > 1
                        ? "Duplicate \(ctx.selection.count) Items"
                        : "Duplicate") {
            ctx.fileOps.duplicate(urls, reload: ctx.onReload)
        })
        menu.add(action(ctx.selection.count > 1
                        ? "Make \(ctx.selection.count) Aliases"
                        : "Make Alias") {
            urls.forEach { ctx.fileOps.makeAlias(for: $0, reload: ctx.onReload) }
        })

        // ── Archive ───────────────────────────────────────────────────────
        menu.add(action(ctx.selection.count > 1
                        ? "Compress \(ctx.selection.count) Items…"
                        : "Compress “\(item.name)”…") {
            ArchiveDialogPresenter.shared.present(urls: urls,
                                                  fileOps: ctx.fileOps,
                                                  reload: ctx.onReload)
        })
        menu.add(action("Compress to ZIP") {
            ctx.fileOps.compress(urls, reload: ctx.onReload)
        })
        if ctx.selection.count == 1 && item.isArchive {
            menu.add(action("Extract Here") {
                ctx.fileOps.extract(item.url, reload: ctx.onReload)
            })
        }
        menu.add(.separator())
        menu.add(openWithSubmenu(urls: urls, item: item))

        // ── Clipboard ─────────────────────────────────────────────────────
        menu.add(.separator())
        menu.add(action("Cut") { ctx.fileOps.cut(urls) })
        menu.add(action("Copy") { ctx.fileOps.copy(urls) })
        let paste = action("Paste") {
            let dest = (ctx.selection.count == 1 && item.isDirectory)
                ? item.url : ctx.currentPath
            ctx.fileOps.paste(to: dest, reload: ctx.onReload)
        }
        paste.isEnabled = !ctx.fileOps.pasteboardURLs.isEmpty
        menu.add(paste)
        menu.add(.separator())

        let share = NSMenu()
        share.add(action("AirDrop") { ctx.fileOps.shareViaAirDrop(urls) })
        share.add(.separator())
        share.add(action("Share…") { ctx.fileOps.showShareSheet(for: urls) })
        menu.add(submenuItem("Share", share))

        let tags = NSMenu()
        for color in FileItem.colorMenuOrder {
            let entry = action(color) {
                ctx.fileOps.toggleColorTag(color, on: urls, reload: ctx.onReload)
            }
            let applied = !ctx.selection.isEmpty
                && ctx.selection.allSatisfy { $0.hasColorTag(color) }
            entry.state = applied ? .on : .off
            tags.add(entry)
        }
        tags.add(.separator())
        let clearTags = action("Clear Tags") {
            ctx.fileOps.clearTags(on: urls, reload: ctx.onReload)
        }
        clearTags.isEnabled = !ctx.selection.allSatisfy { $0.tagNames.isEmpty }
        tags.add(clearTags)
        menu.add(submenuItem("Tags", tags))

        // ── Sidebar / path ────────────────────────────────────────────────
        menu.add(.separator())
        if item.isDirectory {
            if ctx.favorites.isPinned(item.url) {
                menu.add(action("Remove from Sidebar") {
                    ctx.favorites.unpin(item.url)
                })
            } else {
                menu.add(action("Add to Sidebar") {
                    ctx.favorites.pin(item.url)
                })
            }
        }
        menu.add(action("Show in Finder") {
            NSWorkspace.shared.selectFile(item.url.path, inFileViewerRootedAtPath: "")
        })
        menu.add(action(ctx.selection.count > 1
                        ? "Copy \(ctx.selection.count) Paths"
                        : "Copy Path") {
            ctx.fileOps.copyPath(urls.map(\.path).joined(separator: "\n"))
        })

        // ── Destructive ───────────────────────────────────────────────────
        menu.add(.separator())
        menu.add(action("Move to Trash") {
            ctx.fileOps.trash(urls, reload: ctx.onReload)
        })
        menu.add(action("Delete Permanently…") {
            ctx.onConfirmDelete(ctx.selection.map(\.name)) {
                ctx.fileOps.permanentlyDelete(urls, reload: ctx.onReload)
            }
        })

        return menu
    }

    // MARK: Empty space

    private static func addEmptySpaceItems(_ menu: NSMenu, _ ctx: Context) {
        let paste = action("Paste") {
            ctx.fileOps.paste(to: ctx.currentPath, reload: ctx.onReload)
        }
        paste.isEnabled = !ctx.fileOps.pasteboardURLs.isEmpty
        menu.add(paste)

        if ctx.fileOps.canUndo { menu.add(action("Undo") { ctx.fileOps.undo() }) }
        if ctx.fileOps.canRedo { menu.add(action("Redo") { ctx.fileOps.redo() }) }
        menu.add(.separator())
        menu.add(action("Refresh") { ctx.onReload() })
    }

    // MARK: Open With

    private static func openWithSubmenu(urls: [URL], item: FileItem) -> NSMenuItem {
        let submenu = NSMenu()
        let apps = OpenWithService.applications(for: item.url)

        if let remembered = OpenWithService.rememberedApp(for: item.url) {
            submenu.add(action("\(remembered.deletingPathExtension().lastPathComponent) (always)") {
                OpenWithService.open(urls, with: remembered)
            })
            submenu.add(.separator())
        }

        if apps.isEmpty {
            let none = NSMenuItem(title: "No apps registered for this type",
                                  action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.add(none)
        } else {
            for app in apps.prefix(8) {
                submenu.add(action(app.deletingPathExtension().lastPathComponent) {
                    OpenWithService.open(urls, with: app)
                })
            }
        }

        submenu.add(.separator())

        let always = NSMenu()
        for app in apps.prefix(8) {
            always.add(action(app.deletingPathExtension().lastPathComponent) {
                OpenWithService.remember(app: app, forExtension: item.fileExtension)
                OpenWithService.open(urls, with: app)
            })
        }
        if OpenWithService.rememberedApp(for: item.url) != nil {
            always.add(.separator())
            always.add(action("Forget choice") {
                OpenWithService.forget(extension: item.fileExtension)
            })
        }
        submenu.add(submenuItem("Always open .\(item.fileExtension.lowercased()) with", always))

        submenu.add(.separator())
        submenu.add(action("Other App or Executable…") {
            guard let app = OpenWithService.chooseApp() else { return }
            OpenWithService.open(urls, with: app)
        })

        return submenuItem("Open With", submenu)
    }

    // MARK: Helpers

    /// An NSMenuItem whose work is done by a captured closure.
    private static func action(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, handler: handler)
    }

    private static func submenuItem(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// NSMenuItem that runs a closure. NSMenuItem is target/action based, so this subclass
/// forwards its own selector to the stored block.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func invoke() { handler() }
}

extension NSMenu {
    /// Append an item. Keeps the builder readable; NSMenu only has `addItem(_:)`.
    func add(_ item: NSMenuItem) {
        addItem(item)
    }
}
