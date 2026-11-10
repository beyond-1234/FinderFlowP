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
                                NSWorkspace.shared.open(place.url)
                            }
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(place.url.path, forType: .string)
                                NotificationCenter.default.post(name: .ffCopyPathFeedback,
                                                                object: nil)
                            }
                        }
                }
            }

            // ── Drives & Devices (Windows/Dolphin style) ───────────────────
            if !mountedVolumes.isEmpty {
                Section("Drives & Locations") {
                    ForEach(mountedVolumes) { vol in
                        VolumeSidebarRow(volume: vol)
                            .tag(SidebarItem.drive(vol.url))
                            .contextMenu {
                                if vol.isRemovable {
                                    Button("Eject \"\(vol.name)\"") {
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

    private var userPlaces: [UserPlace] { UserPlace.standard() }

    private func refreshVolumes() {
        DispatchQueue.global(qos: .utility).async {
            let keys: [URLResourceKey] = [
                .volumeNameKey,
                .volumeIsRemovableKey,
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
                let isRemovable = vals.volumeIsRemovable ?? false
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                return MountedVolumeInfo(
                    name: name,
                    url: url,
                    isRemovable: isRemovable,
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
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
        } catch {
            print("Failed to unmount: \(error)")
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

/// A default user folder row: localised name when the system has one, and the
/// folder's own icon so Home/Desktop/Downloads look like they do in Finder.
struct PlaceRow: View {
    let place: UserPlace

    private var displayName: String {
        // macOS localises standard folders via the URL resource; fall back to our label.
        if let localized = try? place.url.resourceValues(forKeys: [.localizedNameKey])
            .localizedName, !localized.isEmpty {
            return localized
        }
        return place.title
    }

    var body: some View {
        Label {
            Text(displayName).lineLimit(1)
        } icon: {
            Image(nsImage: NSWorkspace.shared.icon(forFile: place.url.path))
                .resizable()
                .frame(width: 16, height: 16)
        }
    }
}

struct SidebarRow: View {
    let url: URL
    private var displayName: String {
        url.lastPathComponent.isEmpty ? "Macintosh HD" : url.lastPathComponent
    }
    var body: some View {
        Label {
            Text(displayName).lineLimit(1)
        } icon: {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
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
                    Image(systemName: "eject.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
