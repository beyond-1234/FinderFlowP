<div align="center">

<img src="docs/assets/icon.png" alt="FinderFlowP" width="120" height="120" />

# FinderFlowP

**The power of Windows File Explorer and KDE Dolphin, crafted natively for macOS.**

A blazing-fast, customized macOS file manager for developers, power users, and anyone who prefers keyboard-first navigation and instant mouse interactions without sacrificing native macOS design.

[![Platform](https://img.shields.io/badge/macOS-13.0%2B-2D52E0)](https://github.com/beyond-1234/FinderFlowP)
![Universal](https://img.shields.io/badge/Universal-Apple%20Silicon%20%2B%20Intel-444)
[![License](https://img.shields.io/badge/License-MIT-444)](LICENSE)
[![Repo](https://img.shields.io/badge/GitHub-beyond--1234%2FFinderFlowP-blue)](https://github.com/beyond-1234/FinderFlowP)

`macOS 13+` · `Apple Silicon + Intel (Universal)` · `Native Swift / SwiftUI + AppKit` · `Free & Open Source (MIT)`

</div>

---

## Highlights

FinderFlowP is a customized, bloat-free fork of FinderFlow engineered specifically to bridge the gap between Windows / Linux file-management conventions and native macOS aesthetics.

### ⌨️ Windows & KDE Dolphin Keyboard Conventions

| Shortcut | Action | Details |
|---|---|---|
| <kbd>Enter</kbd> | **Open / Enter Folder** | Opens documents in default apps; enters folders directly without <kbd>⌘O</kbd> / <kbd>⌘↓</kbd> |
| <kbd>F2</kbd> | **Rename** | Instant inline rename on the selected item |
| <kbd>Delete</kbd> | **Move to Trash** | Deletes selection to Trash without needing <kbd>⌘⌫</kbd> |
| <kbd>Shift</kbd> + <kbd>Delete</kbd> | **Delete Permanently** | Permanent deletion with safety confirmation |
| <kbd>Backspace</kbd> / <kbd>Alt</kbd> + <kbd>↑</kbd> | **Go to Parent Folder** | Navigates up when no search or rename field is focused |
| <kbd>⌘</kbd> + <kbd>A</kbd> | **Toggle Select All** | First press selects all items; second press deselects all |
| <kbd>Esc</kbd> | **Deselect / Cancel Cut** | Clears active selection or cancels clipboard cut state |
| <kbd>Space</kbd> | **Quick Look** | Native macOS Quick Look preview |

---

### ✂️ Real Cut, Copy & Paste Engine

* **Windows-Style Visual Feedback**: Pressing <kbd>⌘X</kbd> gives cut items **45% visual translucency**. Pressing <kbd>Esc</kbd> cancels the cut state.
* **Non-Blocking Background Transfer Engine**: Fast chunked file transfers across disks and volumes with symlink preservation, bundle integrity verification, and safe rollback on error.
* **Live Transfer Progress Panel**: Floating HUD showing active byte progress, real-time transfer speed (MB/s), estimated time remaining (ETA), progress bar, and one-click Cancel.

---

### 🖱️ Zero-Latency Mouse Router & Selection

* **0ms Instant Selection**: Mouse-down immediately highlights items without waiting for double-click disambiguation windows.
* **Right-Click Pre-Selection**: Right-clicking an item selects it *before* the context menu appears, guaranteeing the menu actions always match the highlighted item.
* **Middle-Click to Open**: Middle-clicking any file or folder directly opens it.
* **Empty Space Click to Deselect**: Clicking any blank area immediately clears selection.
* **Control Protection**: Interactive widgets (zoom buttons, slider, scrollers) are fully shielded against click-through or unintended selection changes.

---

### 📋 AppKit Details List View (Table)

* **Native `NSTableView` Architecture**: Custom high-performance `DetailsTableView` implementation.
* **Reorder & Resize Columns**: Drag column headers to reorder; drag dividers to resize with live width persistence.
* **Smart Extension-Based Column Groups**: Right-click table headers to enable or disable columns grouped by relevance:
  * **General**: Name, Date Modified, Date Created, Size, Kind, Extension, Permissions, Path
  * **Images & Documents**: Dimensions, Page Count
  * **Audio & Video**: Duration, Title, Artist, Album
  * **Applications**: App Version
* **Stable Layouts with Per-Folder Overrides**: Global default column layout remains stable across folders, with optional persistent overrides per folder.

---

### 🖼️ High-Performance Icon Grid View

* **Instant Virtualization**: Virtualized `LazyVGrid` rendering only visible icons for thousands of files.
* **Smooth Trackpad & Wheel Zooming**: Hold <kbd>⌃ Control</kbd> and scroll or pinch to zoom between 32pt and 160pt. Built with a continuous delta accumulator and debounced background persistence for 60/120 FPS responsiveness.
* **Zoom Slider & Shortcuts**: Bottom zoom bar with <kbd>−</kbd>, slider, and <kbd>+</kbd> buttons, plus <kbd>⌘+</kbd> and <kbd>⌘−</kbd> shortcuts.

---

### ⚡ Zero-Delay View Switcher & Theme Vibrancy

* **0.00s Instant Switching**: Persistent dual-view container retains both List and Icon views in memory. Switching via the toolbar segmented control takes literally 0 seconds with zero lag.
* **Unified macOS Wallpaper Tinting**: Both List and Icon views naturally inherit macOS window vibrancy and desktop wallpaper tinting, in both Light and Dark modes.

---

### 🛠️ Terminal, Editor & Archiving Integrations

* **Dynamic Tool Detection**: Automatically detects installed terminals (`kitty`, `iTerm2`, `Terminal`, `Ghostty`, `Warp`) and editors (`VS Code`, `Cursor`, `Sublime Text`).
* **Kitty Terminal First-Class Support**: Spawns kitty instances seamlessly via `--single-instance=no`.
* **Advanced Compression Dialog**: Supports system `.zip` / `.tar` alongside external archivers (**Keka**, **7-Zip**, **BetterZip**) with format, level, and destination controls.
* **"Open With" Menu**: In-memory cached LaunchServices queries for instant menu popups, custom application picker, and per-extension defaults.

---

### 📝 Built-in Code Editor & Markdown Viewer

* **Integrated Code Editor**: Syntax highlighting for dozens of languages, multi-tab interface, fuzzy command palette (<kbd>⌘⇧P</kbd>), and Sublime-style minimap.
* **Rendered Markdown Viewer**: Clean GitHub/Obsidian-style reader with live preview, internal `.md` link navigation, and an editable mode with <kbd>⌘S</kbd> auto-save.

---

## Privacy & System Footprint

* **100% Offline & Local**: No analytics, no telemetry, no tracking, no network calls.
* **No Auto-Updaters**: Sparkle updater removed; self-hosted and cleanly reproducible.
* **Minimal Memory Usage**: Lightweight native footprint (~50-60 MB idle).

---

## Installation & Build

### Requirements

* macOS 13.0 (Ventura) or later (macOS 14+ recommended)
* Apple Silicon (M1/M2/M3/M4) or Intel Mac

### Build from Source

Clone the repository and build using the bundled build script:

```bash
git clone https://github.com/beyond-1234/FinderFlowP.git
cd FinderFlowP

# Build, assemble DMG / bundle, sign, and install to /Applications/FinderFlowP.app:
./build_app.sh
```

Or open in Xcode:

```bash
open FinderFlow.xcodeproj
```

### First Launch (Gatekeeper)

If macOS blocks the newly compiled app on first run, remove the quarantine attribute:

```bash
xattr -dr com.apple.quarantine /Applications/FinderFlowP.app
```

---

## License

MIT License © 2026. Forked and enhanced from [FinderFlow](https://github.com/Gtarafdar/FinderFlow) by Gobinda Tarafdar.
See [LICENSE](LICENSE) for details.
