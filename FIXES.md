# Folder App - Fixes & Improvements Checklist

> Legacy snapshot. The authoritative, current checklist is `APP_REVIEW_AND_ROADMAP.md`.

> Consolidated from CHANGELOG.md — Known Issues, Limitations, and Planned Phases

---

## 🐛 Current Limitations (Phase 2 Scope)

### Search & Clipboard
- [ ] **Instant Search (Cmd+F)** — Search as you type with live results
- [ ] **Copy/Cut/Paste Operations** (Cmd+C / Cmd+X / Cmd+V)
- [ ] **Drag & Drop Support** — Files between Folder windows and other apps
- [ ] **Visual Feedback for Cut Items** — Dimmed/highlighted state for cut files

---

## 🎨 UI/UX Polish (Minor Issues)

### Settings Panel
- [ ] **Icon Size Slider Live Update** — Changes should reflect immediately without switching view modes
- [ ] **Show Hidden Files Auto-Refresh** — Toggle should refresh the current view automatically
- [ ] **Prevent Duplicate Settings Windows** — Clicking Settings (Cmd+,) multiple times opens multiple windows

### Swift Compiler Warnings
- [ ] **Fix Sendable Warning for NSCache** — Cosmetic Swift 6 concurrency warning in icon/thumbnail caching

---

## 🖱️ Context Menu & Advanced Interaction (Phase 4 Scope)

- [ ] **Right-Click Context Menu** — Standard macOS context menu with:
  - [ ] Open / Open With
  - [ ] Copy / Cut / Paste
  - [ ] Move to Trash / Delete
  - [ ] Get Info
  - [ ] Rename
  - [ ] Compress
  - [ ] Share
  - [ ] Tags
  - [ ] Copy as Pathname

---

## 🏷️ Phase 3: Tags & Favorites (After Phase 2)

### Tag System
- [ ] **Tag Creation & Assignment** — Create custom tags, apply to files/folders
- [ ] **Native macOS Tag Integration** — Read/write Finder tags (colors, names)
- [ ] **Tag Filtering** — Filter file list by selected tags

### Favorites & Recents
- [ ] **Favorites Sidebar** — Pinned folders for quick access (like Finder sidebar)
- [ ] **Recent Items Tracking** — Recently opened folders/files with timestamps
- [ ] **Smart Folders** — Saved searches / dynamic folders based on criteria

---

## 🔧 Technical Debt & Architecture

### Performance
- [x] **Immediate File Selection** — Grid/list selection now happens on native mouse-down, accepts the first click in an inactive window, and does not rebuild the entire view for rename timing
- [x] **Read-only Folder Quick Look** — Previewed folder contents can only be viewed and scrolled; rows cannot be selected or opened
- [x] **Selected-item Quick Look** — Space opens the actively selected file or folder rather than always starting at the first visible item
- [x] **Quick Look Prewarming** — Current-folder file previews are prepared in a throttled background queue, with the clicked file warmed first
- [x] **Stable Quick Look Zoom** — The preview uses the visible file tile as its native source transition, avoiding distorted high-resolution transition images
- [x] **Read-only Browser** — Copy, move, delete, rename, duplicate, compression, rotation, paste, new-folder creation and file drag/drop are disabled
- [x] **Background Thumbnail Generation** — Image decoding and Quick Look thumbnail generation run outside the main thread
- [ ] **Virtualized List/Grid** — Only render visible items for large directories (1000+ files)

### Code Quality
- [ ] **Swift 6 Full Concurrency Compliance** — Resolve all Sendable/data-race warnings
- [ ] **Unit Tests** — Core services (FileManager, ThumbnailService, IconCache)
- [ ] **Integration Tests** — Keyboard navigation, URL scheme handling

### Accessibility
- [ ] **VoiceOver Support** — Proper labels, traits, and navigation order
- [ ] **Keyboard Focus Indicators** — Visible focus rings on all interactive elements
- [ ] **High Contrast / Reduce Motion** — Respect system accessibility settings

---

## 📦 Distribution & Build

### App Bundle
- [ ] **Proper Code Signing** — Developer ID signing for Gatekeeper
- [ ] **Notarization** — Apple notarization for distribution outside App Store
- [ ] **Sparkle Updates** — Auto-update framework integration

### Packaging
- [ ] **Homebrew Formula** — `brew install folder`
- [ ] **MacPorts Portfile** — Alternative package manager support
- [ ] **DMG Installer** — Drag-to-Applications experience with background image

---

## 🌐 Future Enhancements (Backlog)

### Cloud & Sync
- [ ] **iCloud Sync** — Sync favorites, tags, settings across devices
- [ ] **Network Shares (SMB/AFP/NFS)** — Browse mounted network volumes natively

### Advanced Features
- [ ] **File Preview Plugins** — Extensible preview for code, markdown, CSV, etc.
- [ ] **Batch Rename** — Multi-file rename with patterns/regex
- [ ] **Folder Comparison** — Diff two directories visually
- [ ] **Terminal Integration** — `folder` CLI with fuzzy search, `cd` integration

### Automation
- [ ] **App Intents** — Native Shortcuts actions (beyond URL scheme)
- [ ] **AppleScript Dictionary** — Full scripting support
- [ ] **Focus Filters** — Auto-open project folders based on Focus mode

---

## 📋 Quick Reference: Phase Priorities

| Phase | Focus | Key Deliverables |
|-------|-------|------------------|
| **1.6** ✅ | Thumbnails, Quick Look, URL Scheme | Done |
| **2** 🎯 | Search, Clipboard, Drag & Drop | Next |
| **3** ⏳ | Tags, Favorites, Recents | After 2 |
| **4** ⏳ | Context Menu, Polish | After 3 |
| **5+** 📦 | Distribution, Cloud, Plugins | Future |

---

## ✅ How to Use This Checklist

1. **Pick a phase** — Work sequentially (Phase 2 → 3 → 4)
2. **Check off items** — Mark `[x]` when complete
3. **Update CHANGELOG.md** — Move completed items to "Implemented Features"
4. **Add new discoveries** — Append to relevant section as you work

---

*Generated from CHANGELOG.md · Last updated: 2025*
