//
//  NavigationBar.swift
//  Folder
//
//  Address bar and navigation controls
//

import SwiftUI
import AppKit

private struct BreadcrumbContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct NavigationBar: View {
    @ObservedObject var viewModel: FileExplorerViewModel
    @ObservedObject var searchViewModel: SearchViewModel
    /// Ob die Sidebar tatsächlich zu ist. Das schmale Fenster klappt sie auch
    /// ohne Zutun des Nutzers zu — die Leiste muss dann ebenso einrücken.
    var isSidebarActuallyCollapsed: Bool = false
    /// Schaltet die Sidebar um. Bewusst ein Befehl und kein Zustand — welcher
    /// Zustand gilt, weiss nur die Aufteilung selbst.
    var toggleSidebar: () -> Void = {}
    @EnvironmentObject var settingsManager: SettingsManager
    @State private var editingPath: String = ""
    @State private var isEditingPath = false
    @State private var didCopyPath = false
    @State private var pathCopyGeneration = 0
    @State private var hoveredBreadcrumbPath: String?
    @State private var breadcrumbHoverGeneration = 0
    @State private var breadcrumbContentWidth: CGFloat = 0
    @State private var mouseEventMonitor: Any?
    @FocusState private var isPathFieldFocused: Bool
    @FocusState private var isSearchFieldFocused: Bool
    @FocusState private var navigationButtonFocused: Bool?
    @Namespace private var focusNamespace

    /// Ob die Sidebar gerade wirklich zu sehen ist — abgeschaltet und
    /// eingeklappt sind zwei Wege zum selben Bild.
    private var isSidebarVisible: Bool {
        settingsManager.settings.showSidebar && !isSidebarActuallyCollapsed
    }

    var body: some View {
        HStack(spacing: 6) {
            // Sidebar toggle button
            Button(action: toggleSidebar) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)
            }
            .buttonStyle(FolderChromeButtonStyle())
            .help(isSidebarActuallyCollapsed ? "Show sidebar" : "Hide sidebar")
            .accessibilityLabel(isSidebarActuallyCollapsed ? "Show sidebar" : "Hide sidebar")

            // Der Umschalter gehört zur Sidebar, die Pfeile zur Navigation.
            // Der Strich trennt die beiden — aber nur, solange es die Sidebar
            // zu sehen gibt. Ist sie zu, trennt er nichts mehr und macht die
            // Leiste am Fensterrand nur unruhig.
            if isSidebarVisible {
                Divider()
                    .frame(height: 20)
                    .padding(.horizontal, 2)
            }

            // Back button
            Button(action: { viewModel.navigateBack() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .medium))
            }
            .buttonStyle(FolderChromeButtonStyle())
            .disabled(!viewModel.canGoBack)
            .help("Back")
            .accessibilityLabel("Back")

            // Forward button
            Button(action: { viewModel.navigateForward() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .medium))
            }
            .buttonStyle(FolderChromeButtonStyle())
            .disabled(!viewModel.canGoForward)
            .help("Forward")
            .accessibilityLabel("Forward")

            // Up/Parent button
            Button(action: { viewModel.navigateToParent() }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 16, weight: .medium))
            }
            .buttonStyle(FolderChromeButtonStyle())
            .help("Parent folder")
            .accessibilityLabel("Parent folder")

            Divider()
                .frame(height: 20)

            // Address bar / Search bar
            HStack {
                // Search icon - clickable to activate search
                Button(action: {
                    if !searchViewModel.isSearchActive {
                        searchViewModel.activateSearch()
                    }
                }) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(searchViewModel.isSearchActive ? Color.folderAccent : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Search (Cmd+F)")

                if searchViewModel.isSearchActive {
                    // Search mode
                    TextField("Search in current folder...", text: $searchViewModel.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($isSearchFieldFocused)
                        .onChange(of: searchViewModel.searchQuery) { _ in
                            searchViewModel.search(in: viewModel.currentPath)
                        }
                        .onExitCommand {
                            // Escape to exit search
                            searchViewModel.deactivateSearch()
                        }

                        // Keep a fixed slot for the activity indicator. Scaling a
                        // ProgressView changes its visual size but not its layout
                        // size, which used to make the search field jump while a
                        // search was running.
                        ZStack {
                            if searchViewModel.isSearching {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel("Searching")
                            }
                        }
                        .frame(width: 16, height: 16)

                    if !searchViewModel.searchQuery.isEmpty {
                        Button(action: { searchViewModel.clearSearch() }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                } else if isEditingPath {
                    // Path editing mode
                    TextField("Path", text: $editingPath)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($isPathFieldFocused)
                        .onSubmit {
                            navigateToPath()
                        }
                        .onExitCommand {
                            // Cancel editing on Escape key
                            editingPath = viewModel.currentPath.path
                            isEditingPath = false
                            isPathFieldFocused = false
                        }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                                    HStack(spacing: 4) {
                                        if index > 0 {
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 9, weight: .semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                        Text(crumb.title)
                                            .font(.system(size: 13))
                                            .foregroundStyle(breadcrumbColor(for: crumb.url))
                                    }
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 2)
                                    .padding(.vertical, 2)
                                        .background(
                                            Color.folderAccent.opacity(hoveredBreadcrumbPath == crumb.url.path ? 0.20 : 0),
                                            in: RoundedRectangle(cornerRadius: 4)
                                        )
                                        .animation(
                                            hoveredBreadcrumbPath == crumb.url.path
                                                ? .easeInOut(duration: 0.38).repeatForever(autoreverses: true)
                                                : .easeOut(duration: 0.12),
                                            value: hoveredBreadcrumbPath == crumb.url.path
                                        )
                                        .overlay {
                                            BreadcrumbInteractionHandler(
                                                onDropDestination: crumb.url,
                                                onSingleClick: {
                                                    if let selectedItem = selectedPathItem,
                                                       crumb.url.standardizedFileURL == selectedItem.path.standardizedFileURL,
                                                       selectedItem.type != .folder {
                                                        viewModel.openItem(selectedItem)
                                                    } else {
                                                        viewModel.navigate(to: crumb.url)
                                                    }
                                                },
                                                onDoubleClick: { copyBreadcrumbPath(crumb.url.path) },
                                                onTripleClick: { copyBreadcrumbPath(crumb.url.path) },
                                                onDragEntered: { beginBreadcrumbHover(at: crumb.url) },
                                                onDragExited: { endBreadcrumbHover(at: crumb.url) },
                                                onDrop: { sources, forceCopy in
                                                    endBreadcrumbHover(at: crumb.url)
                                                    FileOperationCoordinator.shared.drop(sources, into: crumb.url, forceCopy: forceCopy)
                                                }
                                            )
                                        }
                                        .id(crumb.url.standardizedFileURL.path)
                                }
                            }
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: BreadcrumbContentWidthKey.self,
                                        value: proxy.size.width
                                    )
                                }
                            )
                        }
                        .onAppear { scrollBreadcrumbsToCurrentEnd(using: proxy) }
                        .onChange(of: viewModel.currentPath) { _ in
                            scrollBreadcrumbsToCurrentEnd(using: proxy)
                        }
                        .onChange(of: viewModel.selectedItems) { _ in
                            // Selecting a file appends it as the final path
                            // segment. Keep that exact item visible instead
                            // of leaving the scroll position at its parent.
                            scrollBreadcrumbsToCurrentEnd(using: proxy)
                        }
                        .onPreferenceChange(BreadcrumbContentWidthKey.self) { width in
                            breadcrumbContentWidth = width
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                    .overlay(alignment: .trailing) {
                        GeometryReader { proxy in
                            let emptyWidth = max(0, proxy.size.width - breadcrumbContentWidth)
                            Color.clear
                                .frame(width: emptyWidth)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    startEditing()
                                }
                                .frame(
                                    maxWidth: .infinity,
                                    maxHeight: .infinity,
                                    alignment: .trailing
                                )
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(viewModel.currentPath.path)
                    .accessibilityHint("Click a path to navigate. Double-click a path to copy it. Click empty space to edit the address.")
                    .help("Click a path to navigate · Double-click a path to copy · Click empty space to edit")

                    Button(action: startEditing) {
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Edit path")
                    .accessibilityLabel("Edit path")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .overlay(alignment: .trailing) {
                if didCopyPath {
                    Label("Copied", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.folderAccent, in: Capsule())
                        .shadow(color: .black.opacity(0.20), radius: 5, y: 2)
                        .padding(.trailing, 30)
                        .transition(.move(edge: .trailing).combined(with: .scale(scale: 0.88)).combined(with: .opacity))
                        .accessibilityLabel("Path copied")
                }
            }
            .animation(.spring(response: 0.30, dampingFraction: 0.70), value: didCopyPath)
            .background(Color.folderElevated)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(searchViewModel.isSearchActive || isEditingPath ? Color.folderAccent.opacity(0.72) : Color.folderStroke, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onChange(of: isEditingPath) { newValue in
                if newValue {
                    // Focus the text field when entering edit mode
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms delay
                        isPathFieldFocused = true
                    }
                }
            }
            .onChange(of: searchViewModel.isSearchActive) { isActive in
                if isActive {
                    // Focus search field when activating search
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms delay
                        isSearchFieldFocused = true
                    }
                }
            }
            .onChange(of: isSearchFieldFocused) { isFocused in
                // Den Fokus zu verlieren ist kein Schliessen der Suche.
                //
                // Wer in die Trefferliste klickt, will einen Treffer ansehen —
                // nicht seine Eingabe verlieren. Vorher wurde hier alles
                // gelöscht, und man stand wieder im Ordner, in dem man getippt
                // hatte. Geschlossen wird nur mit Escape oder über das ✕.
                //
                // Bei leerem Feld gibt es nichts zu bewahren; dann darf ein
                // Klick daneben die Suche wie gewohnt zumachen.
                if searchViewModel.isSearchActive && !isFocused,
                   searchViewModel.searchQuery.isEmpty {
                    searchViewModel.deactivateSearch()
                }
            }

            Divider()
                .frame(height: 20)

            // View mode toggle (shows target state, not current state)
            Button(action: { viewModel.toggleViewMode() }) {
                Image(systemName: viewModel.viewMode.mode == .iconGrid ? "list.bullet" : "square.grid.2x2")
                    .font(.system(size: 16))
            }
            .buttonStyle(FolderChromeButtonStyle())
            .help("Toggle view mode")
            .accessibilityLabel(viewModel.viewMode.mode == .iconGrid ? "Switch to list view" : "Switch to icon view")

            // Refresh button
            Button(action: { viewModel.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16))
            }
            .buttonStyle(FolderChromeButtonStyle())
            .help("Refresh")
            .accessibilityLabel("Refresh folder")
        }
        .focusScope(focusNamespace)
        .onAppear {
            // Remove focus from all navigation buttons
            navigationButtonFocused = nil
            setupMouseHandling()
        }
        .onDisappear {
            if let mouseEventMonitor {
                NSEvent.removeMonitor(mouseEventMonitor)
                self.mouseEventMonitor = nil
            }
        }
        .padding(5)
        .background(Color.folderSurface)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.folderStroke, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(height: 48)
        // Nur bei eingeklappter Sidebar beginnt die Leiste am Fensterrand —
        // dort, wo macOS seine Ampelknöpfe setzt. Ist die Sidebar offen, hält
        // sie den Abstand schon selbst.
        //
        // Die Einrückung sitzt bewusst HIER, nach dem Hintergrund: davor hätte
        // sie nur den Inhalt verschoben, während die helle Fläche weiter unter
        // den Knöpfen durchgelaufen wäre.
        .padding(.leading, isSidebarVisible ? 0 : WindowControls.leadingInset)
        .onChange(of: viewModel.currentPath) { newPath in
            // Reset editing state when path changes externally
            if isEditingPath {
                isEditingPath = false
                isPathFieldFocused = false
            }
            editingPath = newPath.path
            endBreadcrumbHover()
        }
    }

    private func startEditing() {
        cancelPendingPathCopy()
        editingPath = viewModel.currentPath.path
        isEditingPath = true
        // Clear selection to prevent conflicts with Enter key
        viewModel.clearSelection()
    }

    private func copyBreadcrumbPath(_ path: String) {
        copyPath(path)
    }

    private func breadcrumbColor(for url: URL) -> Color {
        let normalizedURL = url.standardizedFileURL

        // A selected child is contextual information, not the location: the
        // current directory stays primary white while the selected file (or
        // folder) receives the IntelliLab accent.
        if let selectedItem = selectedPathItem,
           normalizedURL == selectedItem.path.standardizedFileURL {
            return .folderAccent
        }

        if normalizedURL == viewModel.currentPath.standardizedFileURL {
            return .primary
        }

        return .secondary
    }

    private func scrollBreadcrumbsToCurrentEnd(using proxy: ScrollViewProxy) {
        let finalBreadcrumbID = breadcrumbs.last?.url.standardizedFileURL.path
        Task { @MainActor in
            // Wait for the new path segments to enter the ScrollView before
            // anchoring. Leading segments then naturally disappear first,
            // keeping the destination folder completely visible.
            await Task.yield()
            if let finalBreadcrumbID {
                proxy.scrollTo(finalBreadcrumbID, anchor: .trailing)
            }
        }
    }

    private func showPathCopyFeedback() {
        pathCopyGeneration += 1
        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
            didCopyPath = true
        }
    }

    private func copyPath(_ path: String) {
        showPathCopyFeedback()
        let copyGeneration = pathCopyGeneration
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard copyGeneration == pathCopyGeneration else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                didCopyPath = false
            }
        }
    }

    private func cancelPendingPathCopy() {
        pathCopyGeneration += 1
        withAnimation(.easeOut(duration: 0.12)) {
            didCopyPath = false
        }
    }

    private func beginBreadcrumbHover(at url: URL) {
        guard url.standardizedFileURL != viewModel.currentPath.standardizedFileURL else { return }

        breadcrumbHoverGeneration += 1
        let hoverGeneration = breadcrumbHoverGeneration
        withAnimation(.easeInOut(duration: 0.16)) {
            hoveredBreadcrumbPath = url.path
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard hoverGeneration == breadcrumbHoverGeneration,
                  hoveredBreadcrumbPath == url.path else { return }
            viewModel.navigate(to: url)
        }
    }

    private func endBreadcrumbHover(at url: URL? = nil) {
        guard url == nil || hoveredBreadcrumbPath == url?.path else { return }
        breadcrumbHoverGeneration += 1
        withAnimation(.easeOut(duration: 0.12)) {
            hoveredBreadcrumbPath = nil
        }
    }

    private func setupMouseHandling() {
        guard mouseEventMonitor == nil else { return }

        mouseEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window,
                  let fieldEditor = window.firstResponder as? NSTextView else {
                return event
            }

            let fieldEditorFrame = fieldEditor.convert(fieldEditor.bounds, to: nil)
            let clickedOutsideActiveField = !fieldEditorFrame.contains(event.locationInWindow)

            if isEditingPath && clickedOutsideActiveField {
                editingPath = viewModel.currentPath.path
                isEditingPath = false
                isPathFieldFocused = false
            }

            // Nur eine leere Suche schliesst sich beim Klick daneben — eine
            // getippte bleibt stehen. Siehe die Begründung weiter oben.
            if searchViewModel.isSearchActive && clickedOutsideActiveField,
               searchViewModel.searchQuery.isEmpty {
                searchViewModel.deactivateSearch()
                isSearchFieldFocused = false
            }

            return event
        }
    }

    private var breadcrumbs: [(title: String, url: URL)] {
        let components = viewModel.currentPath.standardizedFileURL.pathComponents
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        var result = components.enumerated().map { index, component in
            if index > 0 { current.appendPathComponent(component, isDirectory: true) }
            let title = index == 0 ? "Mac" : component
            return (title, current)
        }

        // A single selected child is useful context even before it is opened.
        // Show every file type as the final segment so the path mirrors the
        // active selection; selecting multiple items leaves the location path
        // unchanged.
        if let selectedItem = selectedPathItem {
            result.append((selectedItem.name, selectedItem.path))
        }

        return result
    }

    private var selectedPathItem: FileSystemItem? {
        guard viewModel.selectedItems.count == 1,
              let selectedID = viewModel.selectedItems.first,
              let selectedItem = viewModel.items.first(where: { $0.id == selectedID }),
              selectedItem.path.deletingLastPathComponent().standardizedFileURL == viewModel.currentPath.standardizedFileURL else {
            return nil
        }
        return selectedItem
    }

    private func navigateToPath() {
        // Trim whitespace
        let trimmedPath = editingPath.trimmingCharacters(in: .whitespacesAndNewlines)

        // Exit editing mode first
        isEditingPath = false
        isPathFieldFocused = false

        // Don't navigate if empty or unchanged
        guard !trimmedPath.isEmpty, trimmedPath != viewModel.currentPath.path else {
            return
        }

        // Resolve URL
        guard let url = FileSystemService.shared.resolveURL(from: trimmedPath) else {
            // Invalid path - show error or just reset
            editingPath = viewModel.currentPath.path
            return
        }

        // Navigate to the resolved URL
        viewModel.navigate(to: url)
    }
}

private struct BreadcrumbInteractionHandler: NSViewRepresentable {
    let onDropDestination: URL
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void
    let onTripleClick: () -> Void
    let onDragEntered: () -> Void
    let onDragExited: () -> Void
    let onDrop: ([URL], Bool) -> Void

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.onDropDestination = onDropDestination
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        view.onTripleClick = onTripleClick
        view.onDragEntered = onDragEntered
        view.onDragExited = onDragExited
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ view: InteractionView, context: Context) {
        view.onDropDestination = onDropDestination
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        view.onTripleClick = onTripleClick
        view.onDragEntered = onDragEntered
        view.onDragExited = onDragExited
        view.onDrop = onDrop
    }

    final class InteractionView: NSView {
        var onDropDestination = URL(fileURLWithPath: "/")
        var onSingleClick: () -> Void = {}
        var onDoubleClick: () -> Void = {}
        var onTripleClick: () -> Void = {}
        var onDragEntered: () -> Void = {}
        var onDragExited: () -> Void = {}
        var onDrop: ([URL], Bool) -> Void = { _, _ in }
        private var isHovering = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([.fileURL, .URL, NSPasteboard.PasteboardType("NSFilenamesPboardType")])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseUp(with event: NSEvent) {
            switch event.clickCount {
            case 1:
                // Commit the click only after the pointer is released. This
                // keeps the breadcrumb's AppKit view alive for the full click
                // and makes every ancestor segment (Desktop, ylli, …)
                // navigate deterministically. Do not defer through a run-loop
                // queue: an enclosing horizontal scroll view may be tracking
                // at that moment and drop the delayed callback.
                onSingleClick()
            case 2:
                onDoubleClick()
            case 3:
                onTripleClick()
            default:
                break
            }
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            let urls = droppedURLs(from: sender.draggingPasteboard)
            let destination = onDropDestination
            let operation = FileDropValidation.operation(
                for: urls,
                into: destination,
                forceCopy: NSEvent.modifierFlags.contains(.option)
            )
            guard operation != [] else { return [] }
            if !isHovering {
                isHovering = true
                onDragEntered()
            }
            return operation
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            FileDropValidation.operation(
                for: droppedURLs(from: sender.draggingPasteboard),
                into: onDropDestination,
                forceCopy: NSEvent.modifierFlags.contains(.option)
            )
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            finishHover()
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            FileDropValidation.operation(
                for: droppedURLs(from: sender.draggingPasteboard),
                into: onDropDestination,
                forceCopy: NSEvent.modifierFlags.contains(.option)
            ) != []
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let sources = droppedURLs(from: sender.draggingPasteboard)
            guard FileDropValidation.operation(
                for: sources,
                into: onDropDestination,
                forceCopy: NSEvent.modifierFlags.contains(.option)
                  ) != [] else { return false }
            finishHover()
            onDrop(sources, NSEvent.modifierFlags.contains(.option))
            return true
        }

        private func finishHover() {
            guard isHovering else { return }
            isHovering = false
            onDragExited()
        }

        private func droppedURLs(from pasteboard: NSPasteboard) -> [URL] {
            if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !objects.isEmpty {
                return objects
            }

            let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
            if let paths = pasteboard.propertyList(forType: filenames) as? [String] {
                return paths.map(URL.init(fileURLWithPath:))
            }

            return []
        }
    }
}
