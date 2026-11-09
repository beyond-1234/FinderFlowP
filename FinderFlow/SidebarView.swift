import SwiftUI

enum SidebarItem: Hashable {
    case location(URL)
    case drive(URL)
    case pinned(URL)
    case recent(URL)

    var folderURL: URL {
        switch self {
        case .location(let url), .drive(let url), .pinned(let url), .recent(let url):
            return url
        }
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

    var body: some View {
        List(selection: $selection) {

            // ── System locations ──────────────────────────────────────────
            Section("Favorites") {
                ForEach(systemLocations, id: \.self) { url in
                    SidebarRow(url: url)
                        .tag(SidebarItem.location(url))
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
                Section("Pinned") {
                    ForEach(favorites.pinnedURLs, id: \.self) { url in
                        SidebarRow(url: url)
                            .tag(SidebarItem.pinned(url))
                            .contextMenu {
                                Button("Remove from Pinned") { favorites.unpin(url) }
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
        .onAppear { loadRecent() }
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

    private var systemLocations: [URL] {
        let fm = FileManager.default
        return [
            fm.homeDirectoryForCurrentUser,
            fm.urls(for: .desktopDirectory,  in: .userDomainMask).first,
            fm.urls(for: .documentDirectory, in: .userDomainMask).first,
            fm.urls(for: .downloadsDirectory, in: .userDomainMask).first,
        ].compactMap { $0 }
    }

    private var mountedVolumes: [MountedVolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return []
        }
        return urls.compactMap { url in
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
