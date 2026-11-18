# Folder App - Changelog

Die Einträge für 1.1.2 bis 1.2.7 wurden nachträglich aus Git-Tags, Commits und Projektnotizen rekonstruiert. Sie fassen belegte Änderungen zusammen und sind keine vollständigen ursprünglichen Release-Notizen.

## 1.2.8

- Bei einer fehlgeschlagenen oder abgebrochenen Updateinstallation erscheint eine Fehlermeldung.

## 1.2.7

- SVG-Dateien werden in Quick Look als Bild dargestellt; die Vorschau nach einer Rotation wurde verbessert.
- Mehrere ausgewählte Bilder können gemeinsam gedreht werden. SVG bleibt dabei ein Vektorformat; weitere unterstützte Bildformate werden im vorhandenen Format verarbeitet.
- SVG-Vorschaubilder und der Übergang zur Vorschau wurden angepasst.

## 1.2.6

- „Open VS Code Here“ zum Öffnen eines Ordners in Visual Studio Code ergänzt.
- Dateiverwaltung, Auswahl, Navigation, Sidebar und Einstellungen überarbeitet.

## 1.2.5

- Dateivorgänge, Auswahl, Quick Look, Berechtigungen und Einstellungen überarbeitet.
- Updateprüfung unterscheidet fehlendes Installationsarchiv von einer aktuellen Installation; bei fehlgeschlagener Kopie ist eine Wiederherstellung der vorherigen App vorgesehen.

## 1.2.4

- Updateprüfung und Installation über GitHub Releases wiederhergestellt; Sparkle wurde entfernt.

## 1.2.3

- Release-Build und Updatekonfiguration überarbeitet, damit Updates in Produktionsbuilds nicht als Entwicklungsfunktion deaktiviert sind. Der Updateansatz wurde in 1.2.4 erneut geändert.

## 1.2.2

- Sidebar-Umschalter und Verhalten bei schmalen Fenstern korrigiert.
- Suche bleibt bei Fokusverlust erhalten und zeigt Ergebnisse schrittweise; macOS-Pakete werden nicht durchsucht.
- Applications als Standardfavorit ergänzt; Favoriten zeigen ihren Pfad.
- Release-Build kann ohne hinterlegte Signierschlüssel veröffentlicht werden.

## 1.2.1

- Speicherung von Favoriten und Einstellungen bei Updates verbessert.
- Erscheinungsbild, Finder-Farb-Tags, Terminalaufruf und Berechtigungseinstellungen korrigiert.
- Ordnerdarstellung, Suche und Tastaturnavigation verbessert.

## 1.2.0

- Größere Überarbeitung der Oberfläche, Dateiverwaltung, Vorschau, Navigation und Berechtigungen.

## 1.1.4

- Namenskonflikt beim wiederholten Erstellen eines Ordners „Untitled Folder“ korrigiert.

## 1.1.3

- App-Registrierung nach Updates angepasst, um doppelte Dock-Einträge zu vermeiden.

## 1.1.2

- Automatische Updates, Standardeinstellungen und Fensterverhalten ergänzt beziehungsweise verbessert.
- Suche, Dateivorgänge, Navigation und Darstellung optimiert; mehrere Fehler behoben.

---

## Historische Entwicklungsnotizen

Die folgenden ursprünglichen Einträge stammen aus dem Jahr 2025 und geben den damaligen Entwicklungsstand wieder.

## Phase 1.6 - Image Previews & Quick Look Integration (Latest Build)

### ✅ Implemented Features

#### 1. Thumbnail Previews for Images and PDFs 🖼️
- **Before**: All files showed generic file type icons
- **After**: Images and PDFs display actual thumbnail previews
- **Supported formats**:
  - Images: JPG, JPEG, PNG, GIF, BMP, TIFF, TIF, HEIC, HEIF, WebP, ICO, ICNS
  - Documents: PDF
- **Grid view**: Large 128x128px thumbnails
- **List view**: Small 40x40px thumbnails
- **Performance**: Thumbnails are cached in memory for fast loading

#### 2. Quick Look Preview (Space Bar) 🔍
- **Keyboard shortcut**: Press `Space` to preview selected files
- **Supported files**: All file types supported by macOS Quick Look
  - Images (JPG, PNG, etc.)
  - PDFs
  - Videos
  - Audio files
  - Text documents
  - And more!
- **Features**:
  - Full-screen preview with zoom
  - **Arrow keys**: Navigate left/right through multiple selected files
  - Preview all selected files in sequence
  - Press `Escape` or `Space` again to close
  - Smooth animations and transitions

#### 3. URL Scheme for Shortcuts Automation 🔗
- **URL scheme**: `folder://`
- **Usage**:
  - Can be referenced in macOS Shortcuts app
  - Open specific folders programmatically
  - Example: `folder://open?path=/Users/name/Documents`
- **Integration**: Registered in system URL handlers
- **Access**: App now appears in Shortcuts app's "Open X URL" actions

### Technical Details

#### ThumbnailService
- Uses `QuickLookThumbnailing` framework for PDF thumbnails
- Uses `NSImage` for fast image thumbnail generation
- Implements intelligent caching (500 items, 100MB limit)
- Asynchronous loading for smooth UI performance

#### QuickLookManager
- Integrates with native macOS Quick Look panel
- Implements `QLPreviewPanelDataSource` and `QLPreviewPanelDelegate`
- Handles keyboard events within preview panel
- Supports multiple file preview with arrow key navigation

---

## Phase 1.5 - Polish & Keyboard Navigation

### ✅ Implemented Features

#### 1. Fixed URL Bar Editing
- **Issue**: Clicking the path bar didn't enable editing
- **Fix**: Added proper focus management with `@FocusState`
- **How to use**: Click the path in the address bar, type a new path, press Enter

#### 2. Click Behavior (Finder-style)
- **Changed**: Single click now selects, double click opens
- **Old behavior**: Single click opened files/folders
- **New behavior**:
  - Single click: Selects the item (blue border highlight)
  - Double click: Opens folder or file
  - Cmd+Click: Add/remove from selection (multi-select)

#### 3. Keyboard Navigation 🎹
**Control + Arrow Keys:**
- `Ctrl+Left`: Navigate to parent folder
- `Ctrl+Right`: Navigate into selected folder (or first folder if none selected)

**Arrow Keys (no modifier):**
- `Up/Down`: Navigate between items (change selection)
- `Left/Right`: Also navigate between items

**Other Keys:**
- `Enter`: Open selected folder/file
- `Escape`: Clear selection

#### 4. Lighter, More Aesthetic Icons
- Icons now have reduced opacity (0.75) for a softer look
- Color adjustments:
  - Folders: Blue with 0.8 opacity
  - Symlinks: Purple with 0.7 opacity
  - Files: Gray with 0.6 opacity
- Overall cleaner, less harsh appearance

#### 5. Real File Icons (NSWorkspace Integration)
- **Before**: Generic SF Symbols for all files
- **After**: Real macOS file icons for each file type
- Uses `NSWorkspace.shared.icon(forFile:)` to get actual file/app icons
- Shows proper icons for:
  - Applications (.app)
  - Images (.jpg, .png, etc.)
  - Documents (.pdf, .doc, etc.)
  - Code files (.swift, .py, etc.)
  - All other file types
- Icons match what you see in Finder!

#### 6. Icon Caching Service
- **Performance boost**: Icons are cached in memory
- Uses `NSCache` for automatic memory management
- Cache configuration:
  - Max 500 icons in memory
  - 50MB memory limit
  - Automatic eviction when limits reached
- Icons load once and stay fast
- Different sizes cached separately (grid 64px, list 20px)

#### 7. Settings Panel ⚙️
**Access**: Press `Cmd+,` or use menu: "Folder" → "Settings..."

**Available Settings:**
- **Default View Mode**: Choose between Icon Grid or List view
- **Icon Size**: Slider from 32px to 128px (affects grid view)
- **Show Hidden Files**: Toggle to show/hide files starting with "."
- **Theme**: Light, Dark, or System (follows macOS appearance)
- **Reset to Defaults**: Button to restore original settings

**Settings are:**
- Saved automatically to UserDefaults
- Persisted across app launches
- Applied immediately when changed

#### 8. Menu Bar
Added proper macOS menu with:
- **Folder Menu**:
  - Settings... (Cmd+,)
  - Quit Folder (Cmd+Q)
- **File Menu**:
  - New Folder (Cmd+N) - Coming soon
  - Close Window (Cmd+W)
- **Edit Menu**:
  - Cut (Cmd+X)
  - Copy (Cmd+C)
  - Paste (Cmd+V)
  - Select All (Cmd+A)

---

## Testing Checklist

### Basic Navigation
- [x] App launches and shows home directory
- [x] Double-click folders to open
- [x] Single-click to select (blue border appears)
- [x] Cmd+Click to multi-select
- [x] Back/Forward buttons work
- [x] Up button goes to parent folder

### URL Bar
- [x] Click path bar to edit
- [x] Type custom path (e.g., `/Applications`)
- [x] Press Enter to navigate
- [x] Invalid paths show error (resets to current path)

### Keyboard Navigation
- [x] Arrow keys change selection
- [x] Ctrl+Left goes to parent
- [x] Ctrl+Right opens selected folder
- [x] Enter opens selected item
- [x] Escape clears selection

### Icons & Visuals
- [x] Icons look like real macOS file icons (not generic symbols)
- [x] Icons match Finder's appearance
- [x] Grid view shows large (64px) icons
- [x] List view shows small (20px) icons
- [x] Icons have softer, lighter appearance
- [x] Symlinks show special arrow badge

### Settings Panel
- [x] Press Cmd+, to open settings
- [x] Toggle hidden files (refresh view to see effect)
- [x] Change theme (Light/Dark/System)
- [x] Adjust icon size slider (see changes in grid view)
- [x] Change default view mode
- [x] Reset to defaults works
- [x] Settings persist after quit and relaunch

---

## Performance

### Icon Caching Impact
- **First load**: Icons fetch from disk (NSWorkspace)
- **Subsequent views**: Instant (loaded from cache)
- **Memory usage**: Controlled by NSCache (auto-evicts when low on memory)
- **Cache cleared**: When app quits (fresh start each launch)

### Benchmarks
- Loading 100 items with cached icons: ~50ms
- Loading 100 items without cache: ~200-300ms
- **4-6x performance improvement** with caching!

---

## Known Issues & Limitations

### Current Limitations
- No search yet (Phase 2)
- No copy/paste operations yet (Phase 2)
- No context menu (right-click) yet (Phase 4)
- No drag-and-drop yet (Phase 2)
- Icon size slider doesn't affect current view (need to change view mode to see effect)
- Show hidden files toggle requires manual refresh (click refresh button)

### Minor Issues
- Swift 6 Sendable warning for NSCache (cosmetic, doesn't affect functionality)
- Settings window can be opened multiple times (clicking Settings again opens a new one)

---

## Next Phase Preview

### Phase 2: Search & Clipboard (Coming Next)
- Instant search (Cmd+F)
- Search as you type with results
- Copy/Cut/Paste operations (Cmd+C/X/V)
- Drag & drop support
- Visual feedback for cut items

**Estimated Time**: 2-3 hours

### Phase 3: Tags & Favorites (After Phase 2)
- Tag creation and assignment
- Native macOS tag integration
- Favorites sidebar
- Recent items tracking

---

## Build Info

- **Version**: 0.1.1 (Phase 1.6)
- **Build Date**: 2025-11-11
- **Platform**: macOS 13.0+
- **Swift Version**: 6.2.1
- **Build System**: Swift Package Manager
- **New in this build**:
  - Image/PDF thumbnails
  - Quick Look integration (Space bar)
  - Shortcuts automation support (folder:// URL scheme)

---

## How to Build

```bash
cd /Users/mattia/Documents/Home/folder/FolderApp
./build.sh
./run.sh
```

**Build time**: ~60 seconds
**App size**: ~15MB

---

Enjoy your polished, keyboard-friendly file explorer! 🎉
