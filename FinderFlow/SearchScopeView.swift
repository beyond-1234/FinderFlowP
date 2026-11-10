import SwiftUI
import AppKit

enum SearchScope: String, CaseIterable {
    case thisFolder          = "Current Folder"
    case thisFolderRecursive = "Current Folder + Subfolders"
    case desktop             = "Desktop"
    case documents           = "Documents"
    case downloads           = "Downloads"
    case home                = "Home Folder"
    case entireMac           = "Whole Mac"

    /// Short label shown on the compact scope menu button.
    var shortLabel: String {
        switch self {
        case .thisFolder:          return "Current Folder"
        case .thisFolderRecursive: return "With Subfolders"
        case .desktop:             return "Desktop"
        case .documents:           return "Documents"
        case .downloads:           return "Downloads"
        case .home:                return "Home"
        case .entireMac:           return "Whole Mac"
        }
    }

    var icon: String {
        switch self {
        case .thisFolder:          return "folder"
        case .thisFolderRecursive: return "folder.fill.badge.plus"
        case .desktop:             return "desktopcomputer"
        case .documents:           return "doc"
        case .downloads:           return "arrow.down.circle"
        case .home:                return "house"
        case .entireMac:           return "externaldrive.connected.to.line.below"
        }
    }

    /// One-line explanation shown in the menu, so the option is self-explanatory.
    var detail: String {
        switch self {
        case .thisFolder:          return "Only files directly in the open folder"
        case .thisFolderRecursive: return "The open folder and everything inside it"
        case .desktop:             return "Your Desktop folder"
        case .documents:           return "Your Documents folder"
        case .downloads:           return "Your Downloads folder"
        case .home:                return "Your whole home folder"
        case .entireMac:           return "Spotlight across every volume"
        }
    }

    func baseURL(currentPath: URL) -> URL {
        let fm = FileManager.default
        switch self {
        case .thisFolder, .thisFolderRecursive:
            return currentPath
        case .desktop:
            return fm.urls(for: .desktopDirectory,  in: .userDomainMask).first ?? currentPath
        case .documents:
            return fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? currentPath
        case .downloads:
            return fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? currentPath
        case .home:
            return fm.homeDirectoryForCurrentUser
        case .entireMac:
            return fm.homeDirectoryForCurrentUser   // unused; Spotlight uses its own scope constant
        }
    }
}

struct SearchScopeView: View {
    let currentPath: URL
    @ObservedObject var searchEngine: SearchEngine

    var body: some View {
        HStack(spacing: 8) {

            // ── Search field (first: this is what you use most) ────────────
            HStack(spacing: 4) {
                if searchEngine.isSearching {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                TextField("Search names… (e.g. report, .pdf)", text: $searchEngine.query)
                    .textFieldStyle(.plain)
                    .resetsCursorOnExit()
                    .onSubmit { runSearch() }
                    .onChange(of: searchEngine.query) { newValue in
                        if newValue.isEmpty {
                            searchEngine.results     = []
                            searchEngine.isSearching = false
                        } else {
                            runSearch()
                        }
                    }

                if !searchEngine.query.isEmpty {
                    Button {
                        searchEngine.query       = ""
                        searchEngine.results     = []
                        searchEngine.isSearching = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .frame(maxWidth: 420)

            // ── Where to search (after the field it modifies) ──────────────
            Menu {
                Picker("Search in", selection: $searchEngine.selectedScope) {
                    ForEach(SearchScope.allCases, id: \.self) { scope in
                        Label {
                            Text(scope.rawValue)
                        } icon: {
                            Image(systemName: scope.icon)
                        }
                        .tag(scope)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: searchEngine.selectedScope.icon)
                        .font(.caption2)
                    Text(searchEngine.selectedScope.shortLabel)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Search in: \(searchEngine.selectedScope.rawValue) — \(searchEngine.selectedScope.detail)")
            .onChange(of: searchEngine.selectedScope) { _ in
                guard !searchEngine.query.isEmpty else { return }
                runSearch()
            }

            // ── Result count badge ────────────────────────────────────────
            if !searchEngine.query.isEmpty && !searchEngine.isSearching {
                Text("\(searchEngine.results.count) found")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        // Re-run "Current Folder" searches when the user navigates elsewhere.
        .onChange(of: currentPath) { newPath in
            guard !searchEngine.query.isEmpty,
                  searchEngine.selectedScope == .thisFolder ||
                  searchEngine.selectedScope == .thisFolderRecursive
            else { return }
            searchEngine.search(
                in: searchEngine.selectedScope.baseURL(currentPath: newPath))
        }
    }

    private func runSearch() {
        searchEngine.search(in: searchEngine.selectedScope.baseURL(currentPath: currentPath))
    }
}
