import SwiftUI

enum SidebarItem: Hashable {
    case place(URL)
    case location(URL)
    case drive(URL)
    case pinned(URL)
    case recent(URL)

    var folderURL: URL {
        switch self {
        case .place(let url), .location(let url), .drive(let url),
             .pinned(let url), .recent(let url):
            return url
        }
    }
}

// MARK: - Standard user places (Dolphin-style)

/// The default user folders, like Dolphin's Places panel: Home first, then the
/// XDG-style user directories. Only folders that actually exist are listed.
struct UserPlace: Identifiable, Hashable {
    let id: String
    let url: URL
    let title: String
    let symbol: String

    static func standard() -> [UserPlace] {
        let fm = FileManager.default
        var places: [UserPlace] = []

        func add(_ key: String, _ symbol: String, _ url: URL?, _ fallbackTitle: String) {
            guard let url, fm.fileExists(atPath: url.path) else { return }
            places.append(UserPlace(id: key,
                                    url: url,
                                    title: fallbackTitle,
                                    symbol: symbol))
        }

        // Home first — that is the "user space" root in Dolphin.
        add("home", "house.fill", fm.homeDirectoryForCurrentUser, "Home")

        let userDomain = FileManager.SearchPathDomainMask.userDomainMask
        add("desktop",   "menubar.dock.rectangle",
            fm.urls(for: .desktopDirectory,   in: userDomain).first, "Desktop")
        add("downloads", "arrow.down.circle.fill",
            fm.urls(for: .downloadsDirectory, in: userDomain).first, "Downloads")
        add("documents", "doc.text.fill",
            fm.urls(for: .documentDirectory,  in: userDomain).first, "Documents")
        add("pictures",  "photo.fill",
            fm.urls(for: .picturesDirectory,  in: userDomain).first, "Pictures")
        add("music",     "music.note",
            fm.urls(for: .musicDirectory,     in: userDomain).first, "Music")
        add("movies",    "film.fill",
            fm.urls(for: .moviesDirectory,    in: userDomain).first, "Movies")

        // Applications is not a user document folder, but it is a Dolphin-style
        // place people expect right below the user folders.
        let apps = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if fm.fileExists(atPath: apps.path) {
            places.append(UserPlace(id: "applications",
                                    url: apps,
                                    title: "Applications",
                                    symbol: "square.grid.2x2.fill"))
        }

        // Trash / Recycle Bin (Dolphin / Windows Explorer convention)
        if let trash = fm.urls(for: .trashDirectory, in: userDomain).first,
           fm.fileExists(atPath: trash.path) {
            places.append(UserPlace(id: "trash",
                                    url: trash,
                                    title: "Trash",
                                    symbol: "trash.fill"))
        }

        return places
    }
}

// MARK: - Favorites service (pinned folders)

class FavoritesService: ObservableObject {
    @Published var pinnedURLs: [URL] = []

    init() { load() }

    func load() {
        pinnedURLs = (UserDefaults.standard.stringArray(forKey: "pinnedFolders") ?? [])
            .compactMap { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func pin(_ url: URL) {
        guard url.hasDirectoryPath, !pinnedURLs.contains(url) else { return }
        pinnedURLs.insert(url, at: 0)
        save()
    }

    func unpin(_ url: URL) {
        pinnedURLs.removeAll { $0 == url }
        save()
    }

    func isPinned(_ url: URL) -> Bool { pinnedURLs.contains(url) }

    private func save() {
        UserDefaults.standard.set(pinnedURLs.map(\.path), forKey: "pinnedFolders")
    }
}

// MARK: - Sidebar view

struct SidebarView: View {
    @Binding var currentPath:     URL
    @Binding var selection:       SidebarItem?
    @Binding var activeTagFilter: String?
    let usedTagNames: [String]
    @EnvironmentObject var favorites: FavoritesService
    @State private var recentFolders: [URL] = []
    @State private var mountedVolumes: [MountedVolumeInfo] = []

    var body: some View {
        List(selection: $selection) {

            // ── Places (Dolphin-style default user folders) ────────────────
            Section("Places") {
                ForEach(userPlaces) { place in
                    PlaceRow(place: place)
                        .tag(SidebarItem.place(place.url))
                        .contextMenu {
                            Button("Open in New Window") {
                                openInNewWindow(place.url)
                            }
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(place.url.path, forType: .string)
                                NotificationCenter.default.post(name: .ffCopyPathFeedback,
                                                                object: nil)
                            }
                            if place.id == "trash" {
                                Divider()
                                Button("Empty Trash…", role: .destructive) {
                                    emptyTrash()
                                }
                            }
                        }
                }
            }

            // ── Drives & Devices (Windows/Dolphin style) ───────────────────
            if !mountedVolumes.isEmpty {
                Section("Drives & Locations") {
                    ForEach(mountedVolumes) { vol in
                        VolumeSidebarRow(volume: vol, onEject: {
                            unmountVolume(vol.url)
                        })
                            .tag(SidebarItem.drive(vol.url))
                            .contextMenu {
                                if vol.isRemovable {
                                    Button("Eject “\(vol.name)”") {
                                        unmountVolume(vol.url)
                                    }
                                }
                            }
                    }
                }
            }

            // ── User-pinned folders ───────────────────────────────────────
            if !favorites.pinnedURLs.isEmpty {
                Section("Favorites") {
                    ForEach(favorites.pinnedURLs, id: \.self) { url in
                        SidebarRow(url: url)
                            .tag(SidebarItem.pinned(url))
                            .contextMenu {
                                Button("Remove from Favorites") { favorites.unpin(url) }
                            }
                    }
                    .onDelete { idx in
                        idx.forEach { favorites.unpin(favorites.pinnedURLs[$0]) }
                    }
                }
            }

            // ── Recent ────────────────────────────────────────────────────
            if !recentFolders.isEmpty {
                Section("Recent") {
                    ForEach(recentFolders.prefix(8), id: \.self) { url in
                        SidebarRow(url: url)
                            .tag(SidebarItem.recent(url))
                    }
                }
            }

            // ── Tags (only when files in current folder are tagged) ────────
            if !usedTagNames.isEmpty {
                Section("Tags") {
                    ForEach(usedTagNames, id: \.self) { tag in
                        tagRow(tag: tag)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear {
            loadRecent()
            refreshVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            refreshVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            refreshVolumes()
        }
        .onChange(of: selection) { item in
            guard let url = item?.folderURL, url != currentPath else { return }
            // Defer so the sidebar list is not rebuilt inside its own selection update.
            DispatchQueue.main.async {
                if currentPath != url { currentPath = url }
            }
        }
        .onChange(of: currentPath) { path in
            guard path.hasDirectoryPath else { return }
            DispatchQueue.main.async { addToRecent(path) }
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

    /// Computed once. This is a plain stored value now: as a computed property it ran
    /// a FileManager existence check for every user folder on every layout pass, which
    /// made window resizing stutter.
    private static let cachedPlaces: [UserPlace] = UserPlace.standard()

    private var userPlaces: [UserPlace] { Self.cachedPlaces }

    private func refreshVolumes() {
        DispatchQueue.global(qos: .utility).async {
            let keys: [URLResourceKey] = [
                .volumeNameKey,
                .volumeIsRemovableKey,
                .volumeIsEjectableKey,
                .volumeIsInternalKey,
                .volumeAvailableCapacityKey,
                .volumeTotalCapacityKey
            ]
            guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
                return
            }
            let vols = urls.compactMap { url -> MountedVolumeInfo? in
                guard let vals = try? url.resourceValues(forKeys: Set(keys)),
                      let name = vals.volumeName,
                      let total = vals.volumeTotalCapacity, total > 0 else {
                    return nil
                }
                let avail = Int64(vals.volumeAvailableCapacity ?? 0)
                let isEjectable = (vals.volumeIsRemovable == true) ||
                                  (vals.volumeIsEjectable == true) ||
                                  (vals.volumeIsInternal == false && url.path != "/")
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                return MountedVolumeInfo(
                    name: name,
                    url: url,
                    isRemovable: isEjectable,
                    totalBytes: Int64(total),
                    availableBytes: avail,
                    icon: icon
                )
            }
            DispatchQueue.main.async {
                self.mountedVolumes = vols
            }
        }
    }

    private func unmountVolume(_ url: URL) {
        // If currentPath is inside this volume, navigate back to Home first to close
        // folder watchers, directory handles, and avoid broken path states.
        if currentPath.path.hasPrefix(url.path) {
            currentPath = FileManager.default.homeDirectoryForCurrentUser
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var success = false

            // 1. Native AppKit unmount & eject
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                success = true
            } catch {
                // Expected for certain DMGs (e.g. Jianying installer) or busy disks
            }

            // 2. diskutil eject (standard macOS volume eject tool)
            if !success {
                let p = Process()
                p.launchPath = "/usr/sbin/diskutil"
                p.arguments = ["eject", url.path]
                try? p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    success = true
                }
            }

            // 3. hdiutil detach (specifically designed for disk images such as .dmg)
            if !success {
                let p = Process()
                p.launchPath = "/usr/bin/hdiutil"
                p.arguments = ["detach", url.path]
                try? p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    success = true
                }
            }

            // 4. hdiutil detach -force (for disk images with lingering daemon/preview locks)
            if !success {
                let p = Process()
                p.launchPath = "/usr/bin/hdiutil"
                p.arguments = ["detach", url.path, "-force"]
                try? p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    success = true
                }
            }

            // 5. diskutil unmount force (for non-DMG volumes that are busy)
            if !success {
                let p = Process()
                p.launchPath = "/usr/sbin/diskutil"
                p.arguments = ["unmount", "force", url.path]
                try? p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    success = true
                }
            }

            DispatchQueue.main.async {
                self.refreshVolumes()
            }
        }
    }

    private func emptyTrash() {
        let alert = NSAlert()
        alert.messageText = "Empty Trash?"
        alert.informativeText = "Are you sure you want to permanently erase the items in the Trash?"
        alert.alertStyle = .warning
        let btn = alert.addButton(withTitle: "Empty Trash")
        btn.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let script = NSAppleScript(source: "tell application \"Finder\" to empty trash")
            var err: NSDictionary?
            script?.executeAndReturnError(&err)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .refreshDirectory, object: currentPath)
                NotificationCenter.default.post(name: .ffTrashDidChange, object: nil)
            }
        }
    }

    private func loadRecent() {
        recentFolders = (UserDefaults.standard.stringArray(forKey: "recentFolders") ?? [])
            .compactMap { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func addToRecent(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: "recentFolders") ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(20)), forKey: "recentFolders")
        recentFolders = Array(paths.prefix(8)).compactMap { URL(fileURLWithPath: $0) }
    }

    @ViewBuilder
    private func tagRow(tag: String) -> some View {
        let isActive = activeTagFilter == tag
        let dotColor = FileItem.colorForTagName(tag) ?? Color(nsColor: .systemGray)
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 11, height: 11)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
            Text(tag)
                .font(.system(size: 12))
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            Spacer()
            if isActive {
                Image(systemName: "checkmark")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .listRowBackground(isActive ? Color.accentColor.opacity(0.1) : Color.clear)
        .onTapGesture {
            activeTagFilter = isActive ? nil : tag
        }
    }
}

final class TrashStateStore: ObservableObject {
    static let shared = TrashStateStore()
    @Published var itemCount: Int = 0
    var isEmpty: Bool { itemCount == 0 }

    private let trashURL = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first

    init() {
        refresh()
        NotificationCenter.default.addObserver(forName: .ffTrashDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        NotificationCenter.default.addObserver(forName: .refreshDirectory, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            var count = 0
            if let trashURL = self.trashURL {
                if let urls = try? FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    count = urls.count
                } else {
                    let script = NSAppleScript(source: "tell application \"Finder\" to count of items in trash")
                    var err: NSDictionary?
                    if let res = script?.executeAndReturnError(&err) {
                        count = Int(res.int32Value)
                    }
                }
            }
            DispatchQueue.main.async {
                if self.itemCount != count {
                    self.itemCount = count
                }
            }
        }
    }
}

struct TrashIconView: View {
    let isEmpty: Bool

    var body: some View {
        ZStack {
            if isEmpty {
                // Empty state: clean, flat wireframe outline in secondary tone
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
            } else {
                // Full state: filled solid wastebasket with hierarchical shading
                Image(systemName: "trash.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.85))
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// A default user folder row: localised name when the system has one, and the
/// folder's own icon so Home/Desktop/Downloads look like they do in Finder.
struct PlaceRow: View {
    let place: UserPlace
    @ObservedObject private var trashState = TrashStateStore.shared

    private static var nameCache: [String: String] = [:]
    private static var iconCache: [String: NSImage] = [:]

    private var displayName: String {
        if let cached = Self.nameCache[place.id] { return cached }
        let name: String
        if let localized = try? place.url.resourceValues(forKeys: [.localizedNameKey])
            .localizedName, !localized.isEmpty {
            name = localized
        } else {
            name = place.title
        }
        Self.nameCache[place.id] = name
        return name
    }

    private var icon: NSImage {
        if let cached = Self.iconCache[place.id] { return cached }
        let image = NSWorkspace.shared.icon(forFile: place.url.path)
        image.size = NSSize(width: 16, height: 16)
        Self.iconCache[place.id] = image
        return image
    }

    var body: some View {
        if place.id == "trash" {
            HStack(spacing: 8) {
                TrashIconView(isEmpty: trashState.isEmpty)
                Text(displayName)
                    .lineLimit(1)
                Spacer()
                if trashState.itemCount > 0 {
                    Text("\(trashState.itemCount)")
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor)))
                }
            }
            .fastTooltip(trashState.isEmpty ? "Trash (Empty)" : "Trash (\(trashState.itemCount) items)")
        } else {
            Label {
                Text(displayName).lineLimit(1)
            } icon: {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }
        }
    }
}

struct SidebarRow: View {
    let url: URL

    private var displayName: String {
        url.lastPathComponent.isEmpty ? "Macintosh HD" : url.lastPathComponent
    }

    /// Sidebar rows are re-evaluated on every layout pass (window resize!), and
    /// NSWorkspace.icon hits the disk. Keep the resolved icon per path.
    private static var iconCache: [String: NSImage] = [:]

    private var icon: NSImage {
        let key = url.path
        if let cached = Self.iconCache[key] { return cached }
        let image = NSWorkspace.shared.icon(forFile: key)
        image.size = NSSize(width: 16, height: 16)
        Self.iconCache[key] = image
        return image
    }

    var body: some View {
        Label {
            Text(displayName).lineLimit(1)
        } icon: {
            Image(nsImage: icon)
                .resizable().frame(width: 16, height: 16)
        }
    }
}

struct MountedVolumeInfo: Hashable, Identifiable {
    var id: String { url.path }
    let name: String
    let url: URL
    let isRemovable: Bool
    let totalBytes: Int64
    let availableBytes: Int64
    let icon: NSImage

    var usagePercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(totalBytes - availableBytes) / Double(totalBytes)
    }

    var availableString: String {
        ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
    }

    var totalString: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

struct VolumeSidebarRow: View {
    let volume: MountedVolumeInfo
    var onEject: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(nsImage: volume.icon)
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(volume.name)
                    .lineLimit(1)
                    .font(.body)
                Spacer()
                if volume.isRemovable {
                    Button {
                        onEject?()
                    } label: {
                        Image(systemName: "eject.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .fastTooltip("Eject “\(volume.name)”")
                }
            }
            if volume.totalBytes > 0 {
                ProgressView(value: volume.usagePercent)
                    .progressViewStyle(.linear)
                HStack {
                    Text("\(volume.availableString) free")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Total \(volume.totalString)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
