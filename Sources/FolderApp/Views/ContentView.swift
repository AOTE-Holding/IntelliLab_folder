//
//  ContentView.swift
//  Folder
//
//  Main container view
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The browser shown in a Folder window. Tabs are optional and stay disabled
/// until the user enables them in Settings.
struct ContentView: View {
    @StateObject private var viewModel: FileExplorerViewModel
    @StateObject private var searchViewModel: SearchViewModel
    @State private var tabManager: FolderTabManager?
    @EnvironmentObject private var settingsManager: SettingsManager

    init(initialPath: URL? = nil) {
        _viewModel = StateObject(wrappedValue: FileExplorerViewModel(initialPath: initialPath))
        _searchViewModel = StateObject(wrappedValue: SearchViewModel())
    }

    var body: some View {
        Group {
            if tabsEnabled, let tabManager {
                FolderTabContainer(tabManager: tabManager)
            } else {
                FolderBrowserView(viewModel: viewModel, searchViewModel: searchViewModel)
            }
        }
        .onAppear {
            synchronizeTabAvailability()
        }
        .onChange(of: tabsEnabled) { _ in
            synchronizeTabAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFolders)) { notification in
            guard let urls = notification.object as? [URL], let firstURL = urls.first else { return }
            if tabsEnabled {
                if tabManager == nil {
                    tabManager = FolderTabManager(initialPath: viewModel.currentPath)
                }
                tabManager?.openFolders(urls)
            } else {
                viewModel.navigate(to: firstURL)
            }
        }
    }

    private var tabsEnabled: Bool {
        settingsManager.settings.tabsEnabled ?? false
    }

    private func synchronizeTabAvailability() {
        if tabsEnabled {
            if tabManager == nil {
                tabManager = FolderTabManager(initialPath: viewModel.currentPath)
            }
        } else if let activeTab = tabManager?.selectedTab {
            let activePath = activeTab.viewModel.currentPath
            tabManager = nil
            viewModel.navigate(to: activePath)
        }
    }
}

private struct FolderTabContainer: View {
    @ObservedObject var tabManager: FolderTabManager
    @State private var tabKeyMonitor: Any?

    var body: some View {
        Group {
            if let activeTab = tabManager.selectedTab {
                FolderBrowserView(
                    viewModel: activeTab.viewModel,
                    searchViewModel: activeTab.searchViewModel,
                    tabStrip: AnyView(FolderTabStrip(tabManager: tabManager))
                )
                .id(activeTab.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .createFolderTab)) { _ in
            tabManager.createTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeFolderTab)) { _ in
            closeSelectedTab()
        }
        .onAppear {
            installTabKeyboardHandling()
        }
        .onDisappear {
            if let tabKeyMonitor {
                NSEvent.removeMonitor(tabKeyMonitor)
                self.tabKeyMonitor = nil
            }
        }
    }

    private func closeSelectedTab() {
        if tabManager.closeSelectedTab() {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    private func installTabKeyboardHandling() {
        guard tabKeyMonitor == nil else { return }
        tabKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == .command,
                  let character = event.charactersIgnoringModifiers,
                  let number = Int(character),
                  (1...9).contains(number),
                  tabManager.selectTab(number: number) else {
                return event
            }
            return nil
        }
    }
}

private struct FolderTabStrip: View {
    @ObservedObject var tabManager: FolderTabManager

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                        FolderTabButton(
                            tab: tab,
                            number: index + 1,
                            isSelected: tab.id == tabManager.selectedTabID,
                            select: { tabManager.selectedTabID = tab.id }
                        )
                    }
                }
                .frame(minWidth: geometry.size.width, alignment: .center)
            }
        }
        .frame(height: 20)
    }
}

private struct FolderTabButton: View {
    @ObservedObject var tab: FolderTab
    let number: Int
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Text("\(number)")
                .font(.system(size: 10, weight: isSelected ? .semibold : .regular, design: .rounded))
                .foregroundStyle(isSelected ? Color.folderAccent : Color.secondary)
                .frame(width: 18, height: 18)
                .background(isSelected ? Color.folderAccent.opacity(0.14) : Color.clear)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tab \(number)")
    }
}

struct FolderBrowserView: View {
    @ObservedObject var viewModel: FileExplorerViewModel
    @ObservedObject var searchViewModel: SearchViewModel
    let tabStrip: AnyView?
    @StateObject private var clipboardManager = ClipboardManager.shared
    @StateObject private var operationCoordinator = FileOperationCoordinator.shared
    @StateObject private var sidebarManager = SidebarManager.shared
    @StateObject private var volumeManager = VolumeManager.shared
    @State private var keyEventMonitor: Any?
    @State private var showingSearchErrors = false
    @State private var sidebarIsManuallyCollapsed = false
    @State private var appliedDefaultViewMode: AppSettings.DisplayMode?
    @State private var appliedIconSize: Int?
    @State private var appliedHiddenFiles: Bool?
    @EnvironmentObject var settingsManager: SettingsManager

    init(
        viewModel: FileExplorerViewModel,
        searchViewModel: SearchViewModel,
        tabStrip: AnyView? = nil
    ) {
        self.viewModel = viewModel
        self.searchViewModel = searchViewModel
        self.tabStrip = tabStrip
    }

    var body: some View {
        Group {
            if settingsManager.settings.showSidebar {
                NativeSidebarSplitView(
                    sidebar: SidebarView(
                        sidebarManager: sidebarManager,
                        fileExplorerViewModel: viewModel
                    ),
                    detail: mainContentArea,
                    isCollapsed: $sidebarIsManuallyCollapsed
                )
            } else {
                mainContentArea
            }
        }
        .overlay {
            if viewModel.isProcessing {
                VStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading…")
                }
                .padding(16)
                .background(.ultraThinMaterial)
                .cornerRadius(12)
            }
        }
        .background(Color.folderBase)
        .preferredColorScheme(colorScheme)
        // The main browser uses the transparent titlebar as usable chrome:
        // navigation is flush with the window top while the native traffic
        // lights remain available over the sidebar.
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            setupKeyboardHandling()
            rememberAppliedViewSettings()
        }
        .onDisappear {
            if let keyEventMonitor {
                NSEvent.removeMonitor(keyEventMonitor)
                self.keyEventMonitor = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToPath"))) { notification in
            if let url = notification.object as? URL { viewModel.navigate(to: url) }
        }
        .onReceive(volumeManager.$lastUnmountedVolumeURL.compactMap { $0 }) { volumeURL in
            viewModel.navigateAwayFromUnmountedVolume(volumeURL)
        }
        .onChange(of: viewModel.currentPath) { newPath in
            // Add to recent locations when navigating
            sidebarManager.addRecentLocation(newPath)

            // Deactivate search when navigating to a new path
            if searchViewModel.isSearchActive {
                searchViewModel.deactivateSearch()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appSettingsDidChange)) { _ in
            applyChangedViewSettings()
        }
        .alert("Search Incomplete", isPresented: $showingSearchErrors) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(searchViewModel.searchErrors.joined(separator: "\n"))
        }
    }

    private var colorScheme: ColorScheme? {
        switch settingsManager.settings.theme {
        case .light:
            return .light
        case .dark:
            return .dark
        case .system:
            return nil // Use system default
        }
    }

    private var mainContentArea: some View {
        VStack(spacing: 0) {
            // Navigation Bar with integrated search
            NavigationBar(
                viewModel: viewModel,
                searchViewModel: searchViewModel,
                isSidebarCollapsed: $sidebarIsManuallyCollapsed
            )
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, tabStrip == nil ? 10 : 0)

            if let tabStrip {
                tabStrip
                    .padding(.horizontal, 16)
                    .padding(.bottom, 2)
            }

            // Thin progress bar for background operations
            if viewModel.isProcessing {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Color.folderAccent)
                    .frame(height: 2)
            }

            // Main Content Area
            if viewModel.isLoading {
                directoryContents
            } else if let error = viewModel.errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.headline)
                    Button("Try Again") {
                        viewModel.refresh()
                    }
                    if viewModel.requiresPermission {
                        Button("Give Access") {
                            if PermissionCenter.shared.requestAccess(to: viewModel.currentPath) {
                                viewModel.refresh()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(28)
                .background(Color.folderSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.folderStroke, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.tagFilterMode != nil {
                // Tag filter mode - showing files with a specific color tag
                Group {
                    if viewModel.viewMode.mode == .iconGrid {
                        TagFilterResultsGridView(viewModel: viewModel)
                    } else {
                        TagFilterResultsListView(viewModel: viewModel)
                    }
                }
            } else if searchViewModel.isSearchActive {
                // Search mode active
                if searchViewModel.searchQuery.isEmpty {
                    // Empty search query: show normal view
                    Group {
                        if viewModel.viewMode.mode == .iconGrid {
                            FileGridView(viewModel: viewModel, searchViewModel: searchViewModel, showDimmed: false)
                        } else {
                            FileListView(viewModel: viewModel, searchViewModel: searchViewModel, showDimmed: false)
                        }
                    }
                } else if searchViewModel.searchResults.isEmpty && !searchViewModel.isSearching {
                    FileEmptyStateView(
                        title: searchViewModel.errorMessage == nil ? "No Results" : "Search Incomplete",
                        message: searchViewModel.errorMessage == nil
                            ? "No items match “\(searchViewModel.searchQuery)”."
                            : "\(searchViewModel.searchErrors.count) location(s) could not be searched.",
                        systemImage: searchViewModel.errorMessage == nil ? "magnifyingglass" : "exclamationmark.triangle",
                        actionTitle: searchViewModel.errorMessage == nil ? "Clear Search" : "Show Details",
                        action: {
                            if searchViewModel.errorMessage == nil {
                                searchViewModel.clearSearch()
                            } else {
                                showingSearchErrors = true
                            }
                        }
                    )
                } else {
                    // Show search results
                    VStack(spacing: 0) {
                        if !searchViewModel.searchErrors.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("\(searchViewModel.searchErrors.count) location(s) could not be searched.")
                                    .font(.caption)
                                Spacer()
                                Button("Details") { showingSearchErrors = true }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.orange.opacity(0.1))
                            .accessibilityElement(children: .combine)
                        }

                        Group {
                            if viewModel.viewMode.mode == .iconGrid {
                                SearchResultsGridView(searchViewModel: searchViewModel, fileExplorerViewModel: viewModel)
                            } else {
                                SearchResultsListView(searchViewModel: searchViewModel, fileExplorerViewModel: viewModel)
                            }
                        }
                    }
                }
            } else {
                // Normal File Grid or List View
                if viewModel.items.isEmpty {
                    FileEmptyStateView(
                        title: "This Folder Is Empty",
                        message: "Use the sidebar or address bar to browse another location.",
                        systemImage: "folder",
                        actionTitle: "Refresh",
                        action: { viewModel.refresh() }
                    )
                } else {
                    directoryContents
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(0)
    }

    @ViewBuilder
    private var directoryContents: some View {
        if viewModel.viewMode.mode == .iconGrid {
            FileGridView(viewModel: viewModel, searchViewModel: searchViewModel, showDimmed: false)
        } else {
            FileListView(viewModel: viewModel, searchViewModel: searchViewModel, showDimmed: false)
        }
    }

    private func setupKeyboardHandling() {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            return handleKeyEvent(event) ? nil : event
        }
    }

    /// Settings are defaults until the user changes one while Folder is open.
    /// At that point the affected browser behavior updates immediately, rather
    /// than making unrelated settings reset the current view or forcing a
    /// directory reload.
    private func rememberAppliedViewSettings() {
        let settings = settingsManager.settings
        appliedDefaultViewMode = settings.defaultViewMode
        appliedIconSize = settings.iconSize
        appliedHiddenFiles = settings.showHiddenFiles
    }

    private func applyChangedViewSettings() {
        let settings = settingsManager.settings

        if appliedDefaultViewMode != settings.defaultViewMode {
            viewModel.viewMode.mode = settings.defaultViewMode == .iconGrid ? .iconGrid : .list
            appliedDefaultViewMode = settings.defaultViewMode
        }

        if appliedIconSize != settings.iconSize {
            viewModel.viewMode.iconSize = settings.iconSize
            appliedIconSize = settings.iconSize
        }

        if appliedHiddenFiles != settings.showHiddenFiles {
            appliedHiddenFiles = settings.showHiddenFiles
            viewModel.refresh()
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Keep Finder-style browser selection and Quick Look on one shared index.
        // Consume the event here so the panel cannot process the same arrow again.
        if QuickLookManager.shared.isPreviewVisible,
           QuickLookManager.navigationDirection(forKeyCode: event.keyCode) != nil,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            return QuickLookManager.shared.handleNavigationKey(event.keyCode)
        }

        // Don't intercept events when a text field is being edited (except for Cmd shortcuts)
        let isTextField = NSApp.keyWindow?.firstResponder is NSTextView ||
                         NSApp.keyWindow?.firstResponder is NSTextField

        let modifiers = event.modifierFlags
        let isCommandPressed = modifiers.contains(.command)
        let isControlPressed = modifiers.contains(.control)
        let isOptionPressed = modifiers.contains(.option)

        // Get keyboard settings
        let shortcuts = settingsManager.settings.keyboardShortcuts

        // Handle Cmd shortcuts even when text field is active
        if isCommandPressed && !isControlPressed {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f":
                // Cmd+F: Activate search (if enabled)
                if shortcuts.searchEnabled {
                    searchViewModel.activateSearch()
                    return true
                }
                return false

            case "c":
                guard !isTextField else { return false }
                copySelectedItems()
                return true

            case "x":
                guard !isTextField else { return false }
                cutSelectedItems()
                return true

            case "v":
                guard !isTextField else { return false }
                operationCoordinator.paste(to: viewModel.currentPath)
                return true

            case "z":
                guard !isTextField else { return false }
                if modifiers.contains(.shift) {
                    ActionHistoryManager.shared.redo()
                } else {
                    ActionHistoryManager.shared.undo()
                }
                return true

            case "a":
                // Cmd+A: Select all items
                if !isTextField {
                    if searchViewModel.isSearchActive && !searchViewModel.searchResults.isEmpty {
                        searchViewModel.selectAll()
                    } else {
                        viewModel.selectAll()
                    }
                    return true
                }
                return false

            case "i":
                guard !isTextField else { return false }
                showGetInfo()
                return true

            default:
                // Command-arrow combinations are browser navigation when
                // Command is chosen as the navigation modifier. They must
                // continue into the arrow-key handling below instead of
                // being swallowed as an unknown menu shortcut.
                break
            }
        }

        // Don't intercept other keys when text field is active
        if isTextField {
            return false
        }

        if event.keyCode == 51 {
            if searchViewModel.isSearchActive && !searchViewModel.selectedItems.isEmpty {
                searchViewModel.deleteSelectedItems()
            } else {
                viewModel.deleteSelectedItems()
            }
            return true
        }

        // Check if navigation modifier is pressed (for folder navigation)
        let navigationModifierPressed = shortcuts.navigationEnabled && (
            (shortcuts.navigationModifier == .control && isControlPressed) ||
            (shortcuts.navigationModifier == .command && isCommandPressed) ||
            (shortcuts.navigationModifier == .option && isOptionPressed)
        )

        switch event.keyCode {
        // Arrow keys
        case 126: // Up arrow
            if navigationModifierPressed {
                viewModel.navigateToParent()
                return true
            } else if shortcuts.arrowKeysEnabled && !isControlPressed && !isCommandPressed && !isOptionPressed {
                if searchViewModel.isSearchActive && !searchViewModel.searchResults.isEmpty {
                    if viewModel.viewMode.mode == .iconGrid {
                        searchViewModel.selectItemAbove(columnsPerRow: calculateGridColumns())
                    } else {
                        searchViewModel.selectPreviousItem()
                    }
                } else {
                    if viewModel.viewMode.mode == .iconGrid {
                        viewModel.selectItemAbove(columnsPerRow: calculateGridColumns())
                    } else {
                        viewModel.selectPreviousItem()
                    }
                }
                return true
            }
            return false

        case 125: // Down arrow
            if navigationModifierPressed {
                navigateIntoSelectedFolder()
                return true
            } else if shortcuts.arrowKeysEnabled && !isControlPressed && !isCommandPressed && !isOptionPressed {
                if searchViewModel.isSearchActive && !searchViewModel.searchResults.isEmpty {
                    if viewModel.viewMode.mode == .iconGrid {
                        searchViewModel.selectItemBelow(columnsPerRow: calculateGridColumns())
                    } else {
                        searchViewModel.selectNextItem()
                    }
                } else {
                    if viewModel.viewMode.mode == .iconGrid {
                        viewModel.selectItemBelow(columnsPerRow: calculateGridColumns())
                    } else {
                        viewModel.selectNextItem()
                    }
                }
                return true
            }
            return false

        case 123: // Left arrow
            if navigationModifierPressed {
                viewModel.navigateToParent()
                return true
            } else if shortcuts.arrowKeysEnabled && !isControlPressed && !isCommandPressed && !isOptionPressed {
                if searchViewModel.isSearchActive && !searchViewModel.searchResults.isEmpty {
                    searchViewModel.selectPreviousItem()
                } else {
                    viewModel.selectPreviousItem()
                }
                return true
            }
            return false

        case 124: // Right arrow
            if navigationModifierPressed {
                navigateIntoSelectedFolder()
                return true
            } else if shortcuts.arrowKeysEnabled && !isControlPressed && !isCommandPressed && !isOptionPressed {
                if searchViewModel.isSearchActive && !searchViewModel.searchResults.isEmpty {
                    searchViewModel.selectNextItem()
                } else {
                    viewModel.selectNextItem()
                }
                return true
            }
            return false

        case 36: // Enter/Return
            if searchViewModel.isSearchActive && !searchViewModel.selectedItems.isEmpty {
                searchViewModel.openSelectedItem(using: viewModel)
            } else {
                viewModel.openSelectedItem()
            }
            return true

        case 53: // Escape
            if searchViewModel.isSearchActive {
                searchViewModel.deactivateSearch()
            } else {
                viewModel.clearSelection()
            }
            return true

        case 49: // Space bar - Quick Look
            showQuickLook()
            return true

        default:
            return false
        }
    }

    private func showGetInfo() {
        let selection: [FileSystemItem]
        if searchViewModel.isSearchActive {
            selection = searchViewModel.searchResults.filter { searchViewModel.selectedItems.contains($0.id) }
        } else {
            selection = viewModel.items.filter { viewModel.selectedItems.contains($0.id) }
        }

        guard selection.count == 1, let item = selection.first else { return }
        FileInfoPanelController.shared.show(item: item)
    }

    // MARK: - Grid Navigation Helper

    private func calculateGridColumns() -> Int {
        // Calculate columns to match LazyVGrid's adaptive layout
        guard let window = NSApp.keyWindow else { return 4 }

        let windowWidth = window.frame.width
        let visibleSidebarWidth: CGFloat = settingsManager.settings.showSidebar
            && !sidebarIsManuallyCollapsed
            && windowWidth > SidebarSplitMetrics.collapseWindowWidth
            ? CGFloat(UserDefaults.standard.double(forKey: SidebarSplitMetrics.widthKey))
            : 0
        let dividerWidth: CGFloat = visibleSidebarWidth > 0 ? SidebarSplitMetrics.dividerWidth : 0

        // Available width for grid content
        let availableWidth = windowWidth - visibleSidebarWidth - dividerWidth

        // Grid uses .padding() which is default 16px on each side
        let horizontalPadding: CGFloat = 16 * 2
        let contentWidth = availableWidth - horizontalPadding

        // Grid item sizing: minimum = iconSize + 40, spacing = 16
        let iconSize = CGFloat(viewModel.viewMode.iconSize)
        let itemMinWidth = iconSize + 40
        let spacing: CGFloat = 16

        // Calculate how many items fit: (contentWidth + spacing) / (itemMinWidth + spacing)
        // We add spacing to contentWidth because the last item doesn't have trailing spacing
        let columns = max(1, Int((contentWidth + spacing) / (itemMinWidth + spacing)))

        return columns
    }

    private func navigateIntoSelectedFolder() {
        if searchViewModel.isSearchActive && !searchViewModel.selectedItems.isEmpty {
            guard let firstSelected = searchViewModel.selectedItems.first,
                  let item = searchViewModel.searchResults.first(where: { $0.id == firstSelected }),
                  item.type == .folder else { return }
            viewModel.navigate(to: item.path)
        } else {
            guard let firstSelected = viewModel.selectedItems.first,
                  let item = viewModel.items.first(where: { $0.id == firstSelected }),
                  item.type == .folder else { return }
            viewModel.navigate(to: item.path)
        }
    }

    private func copySelectedItems() {
        let items = searchViewModel.isSearchActive && !searchViewModel.selectedItems.isEmpty
            ? searchViewModel.searchResults.filter { searchViewModel.selectedItems.contains($0.id) }
            : viewModel.items.filter { viewModel.selectedItems.contains($0.id) }
        guard !items.isEmpty else { return }
        clipboardManager.copy(items: items)
    }

    private func cutSelectedItems() {
        let items = searchViewModel.isSearchActive && !searchViewModel.selectedItems.isEmpty
            ? searchViewModel.searchResults.filter { searchViewModel.selectedItems.contains($0.id) }
            : viewModel.items.filter { viewModel.selectedItems.contains($0.id) }
        guard !items.isEmpty else { return }
        clipboardManager.cut(items: items)
    }

    // MARK: - File Operations

    private func showQuickLook() {
        let items: [FileSystemItem]
        let selected: Set<UUID>

        if searchViewModel.isSearchActive && !searchViewModel.selectedItems.isEmpty {
            items = searchViewModel.searchResults
            selected = searchViewModel.selectedItems
        } else {
            items = viewModel.items
            selected = viewModel.selectedItems
        }

        let isSearchPreview = searchViewModel.isSearchActive && !searchViewModel.selectedItems.isEmpty
        let activeID = isSearchPreview
            ? searchViewModel.lastSelectedItem
            : (viewModel.selectedItemID ?? viewModel.lastSelectedItem)
        guard let startIndex = QuickLookManager.startingPreviewIndex(
            itemIDs: items.map(\.id),
            selectedIDs: selected,
            activeID: activeID
        ) else { return }
        // Capture this before Quick Look becomes the key window. Recalculating from
        // NSApp.keyWindow afterward measures the preview panel and produces a bogus
        // (commonly two-column) vertical navigation offset.
        let quickLookGridColumns = calculateGridColumns()
        QuickLookManager.shared.showPreview(
            for: items,
            startingAt: startIndex,
            selectionDidChange: { index in
                guard items.indices.contains(index) else { return }
                let id = items[index].id
                if isSearchPreview {
                    searchViewModel.selectedItems = [id]
                    searchViewModel.lastSelectedItem = id
                } else {
                    viewModel.selectedItems = [id]
                    viewModel.selectedItemID = id
                    viewModel.lastSelectedItem = id
                }
            },
            navigationTargetForKeyCode: { keyCode in
                let selected = isSearchPreview ? searchViewModel.selectedItems : viewModel.selectedItems
                let activeID = isSearchPreview
                    ? searchViewModel.lastSelectedItem
                    : (viewModel.selectedItemID ?? viewModel.lastSelectedItem)
                guard let current = QuickLookManager.startingPreviewIndex(
                    itemIDs: items.map(\.id),
                    selectedIDs: selected,
                    activeID: activeID
                ),
                      let target = QuickLookManager.browserTargetIndex(
                          current: current,
                          itemCount: items.count,
                          keyCode: keyCode,
                          columnsPerRow: quickLookGridColumns,
                          isGrid: viewModel.viewMode.mode == .iconGrid
                      ) else { return nil }

                let id = items[target].id
                if isSearchPreview {
                    searchViewModel.selectedItems = [id]
                    searchViewModel.lastSelectedItem = id
                } else {
                    viewModel.selectedItems = [id]
                    viewModel.selectedItemID = id
                    viewModel.lastSelectedItem = id
                }
                return target
            }
        )
    }

}

private enum SidebarSplitMetrics {
    static let widthKey = "com.intellilab.folder.sidebarWidth"
    static let defaultWidth: CGFloat = 200
    static let minimumWidth: CGFloat = 160
    static let maximumWidth: CGFloat = 420
    static let minimumDetailWidth: CGFloat = 400
    static let dividerWidth: CGFloat = 8
    static let magneticWidth: CGFloat = 220
    static let magneticRange: CGFloat = 16
    static let collapseWindowWidth: CGFloat = 520
    static let expandWindowWidth: CGFloat = 560
}

/// AppKit owns divider tracking, so a wide SwiftUI grid is not rebuilt through
/// a SwiftUI drag gesture for every mouse movement.
private struct NativeSidebarSplitView<Sidebar: View, Detail: View>: NSViewRepresentable {
    let sidebar: Sidebar
    let detail: Detail
    @Binding var isCollapsed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(isCollapsed: $isCollapsed) }

    func makeNSView(context: Context) -> FolderNativeSplitView {
        let splitView = FolderNativeSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator
        let coordinator = context.coordinator
        splitView.revealCollapsedSidebar = { [weak coordinator] splitView in
            guard let coordinator else { return false }
            return coordinator.revealManuallyCollapsedSidebar(in: splitView)
        }

        let sidebarHost = NSHostingView(rootView: sidebar)
        let detailHost = NSHostingView(rootView: detail)
        if #available(macOS 13.3, *) {
            // The split view creates its own hosting hierarchy. Its detail
            // host must opt out of the titlebar safe area as well; otherwise
            // the navigation bar is pushed down despite the window itself
            // using a full-size content view.
            detailHost.safeAreaRegions = []
        }
        splitView.addSubview(sidebarHost)
        splitView.addSubview(detailHost)

        let saved = CGFloat(UserDefaults.standard.double(forKey: SidebarSplitMetrics.widthKey))
        let initialWidth = saved > 0 ? saved : SidebarSplitMetrics.defaultWidth
        splitView.setPosition(
            min(max(initialWidth, SidebarSplitMetrics.minimumWidth), SidebarSplitMetrics.maximumWidth),
            ofDividerAt: 0
        )
        return splitView
    }

    func updateNSView(_ splitView: FolderNativeSplitView, context: Context) {
        // State changes from the toolbar must reach AppKit even if SwiftUI has
        // replaced one of the generic hosting-view wrappers during an update.
        context.coordinator.applyManualCollapse(isCollapsed, to: splitView)
        guard splitView.subviews.count == 2,
              let sidebarHost = splitView.subviews[0] as? NSHostingView<Sidebar>,
              let detailHost = splitView.subviews[1] as? NSHostingView<Detail> else { return }
        sidebarHost.rootView = sidebar
        detailHost.rootView = detail
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        private var isCollapsed: Binding<Bool>
        private var pendingSave: DispatchWorkItem?
        private var sidebarIsCollapsedForWindow = false
        private var sidebarIsManuallyCollapsed = false
        private var lastExpandedWidth = SidebarSplitMetrics.defaultWidth

        init(isCollapsed: Binding<Bool>) {
            self.isCollapsed = isCollapsed
        }

        private var isActuallyCollapsed: Bool {
            sidebarIsCollapsedForWindow || sidebarIsManuallyCollapsed
        }

        func applyManualCollapse(_ shouldCollapse: Bool, to splitView: NSSplitView) {
            guard sidebarIsManuallyCollapsed != shouldCollapse,
                  let sidebar = splitView.subviews.first else { return }
            sidebarIsManuallyCollapsed = shouldCollapse
            if shouldCollapse {
                if sidebar.frame.width > 0 { lastExpandedWidth = sidebar.frame.width }
                splitView.setPosition(0, ofDividerAt: 0)
            } else if !sidebarIsCollapsedForWindow {
                splitView.setPosition(clamped(lastExpandedWidth, in: splitView), ofDividerAt: 0)
            }
        }

        /// The collapsed edge remains draggable. Revealing restores the last
        /// usable sidebar width before the native split view tracks the drag.
        func revealManuallyCollapsedSidebar(in splitView: NSSplitView) -> Bool {
            guard sidebarIsManuallyCollapsed, !sidebarIsCollapsedForWindow else { return false }
            sidebarIsManuallyCollapsed = false
            isCollapsed.wrappedValue = false
            splitView.setPosition(clamped(lastExpandedWidth, in: splitView), ofDividerAt: 0)
            return true
        }

        func clamped(_ width: CGFloat, in splitView: NSSplitView) -> CGFloat {
            let maximum = min(
                SidebarSplitMetrics.maximumWidth,
                max(SidebarSplitMetrics.minimumWidth, splitView.bounds.width - SidebarSplitMetrics.minimumDetailWidth)
            )
            return min(max(width, SidebarSplitMetrics.minimumWidth), maximum)
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            isActuallyCollapsed ? 0 : SidebarSplitMetrics.minimumWidth
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            clamped(proposedMaximumPosition, in: splitView)
        }

        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
            subview == splitView.subviews.first
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainSplitPosition proposedPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            guard !isActuallyCollapsed else { return 0 }
            let constrained = clamped(proposedPosition, in: splitView)
            if abs(constrained - SidebarSplitMetrics.magneticWidth) <= SidebarSplitMetrics.magneticRange {
                return SidebarSplitMetrics.magneticWidth
            }
            return constrained
        }

        func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
            view != splitView.subviews.first
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let splitView = notification.object as? NSSplitView,
                  let sidebar = splitView.subviews.first else { return }

            let windowIsNarrow = splitView.bounds.width <= SidebarSplitMetrics.collapseWindowWidth
            if windowIsNarrow, !sidebarIsCollapsedForWindow {
                lastExpandedWidth = sidebar.frame.width
                sidebarIsCollapsedForWindow = true
                splitView.setPosition(0, ofDividerAt: 0)
                return
            }
            // A native divider gesture (for example a double-click on the
            // divider) can collapse the sidebar without passing through the
            // toolbar. Reflect that state so one toolbar click restores it.
            if !sidebarIsCollapsedForWindow,
               sidebar.frame.width < 1,
               !sidebarIsManuallyCollapsed {
                sidebarIsManuallyCollapsed = true
                isCollapsed.wrappedValue = true
                return
            }
            if !windowIsNarrow,
               sidebarIsCollapsedForWindow,
               splitView.bounds.width >= SidebarSplitMetrics.expandWindowWidth {
                sidebarIsCollapsedForWindow = false
                if !sidebarIsManuallyCollapsed {
                    splitView.setPosition(clamped(lastExpandedWidth, in: splitView), ofDividerAt: 0)
                }
                return
            }
            guard !isActuallyCollapsed else { return }

            pendingSave?.cancel()
            let width = sidebar.frame.width
            let save = DispatchWorkItem {
                UserDefaults.standard.set(Double(width), forKey: SidebarSplitMetrics.widthKey)
            }
            pendingSave = save
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: save)
        }
    }
}

private final class FolderNativeSplitView: NSSplitView {
    var revealCollapsedSidebar: ((FolderNativeSplitView) -> Bool)?

    override var dividerThickness: CGFloat { SidebarSplitMetrics.dividerWidth }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let isCollapsed = subviews.first?.frame.width ?? 0 < 1
        let revealZoneWidth = max(dividerThickness + 4, 12)
        guard isCollapsed, location.x <= revealZoneWidth,
              let revealCollapsedSidebar else {
            super.mouseDown(with: event)
            return
        }

        // A click on the edge must stay a click. Only a real horizontal drag
        // reveals the sidebar, then continues as a native divider drag.
        guard let window else { return }
        let startX = location.x
        var didReveal = false
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: .greatestFiniteMagnitude,
            mode: .eventTracking
        ) { [weak self] trackedEvent, stop in
            guard let self else {
                stop.pointee = true
                return
            }
            guard let trackedEvent else {
                stop.pointee = true
                return
            }
            if trackedEvent.type == .leftMouseUp {
                stop.pointee = true
                return
            }
            let trackedLocation = self.convert(trackedEvent.locationInWindow, from: nil)
            guard didReveal || trackedLocation.x - startX >= 3 else { return }
            if !didReveal {
                guard revealCollapsedSidebar(self) else {
                    stop.pointee = true
                    return
                }
                didReveal = true
            }
            self.setPosition(trackedLocation.x, ofDividerAt: 0)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // A subtle visual affordance remains on the collapsed left edge.
        guard subviews.first?.frame.width ?? 0 < 1 else { return }
        let grip = NSRect(x: 1, y: bounds.midY - 17, width: 3, height: 34)
        NSColor.secondaryLabelColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func drawDivider(in rect: NSRect) {
        let separator = NSColor.separatorColor
        separator.setFill()
        NSRect(x: rect.midX.rounded(.down), y: rect.minY, width: 1, height: rect.height).fill()

        let grip = NSRect(x: rect.midX - 1.5, y: rect.midY - 17, width: 3, height: 34)
        NSColor.secondaryLabelColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

private struct FileLoadingStateView: View {
    var body: some View {
        Color.folderBase
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Loading folder contents")
    }
}

private struct FileEmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(Color.folderAccent)
                .frame(width: 68, height: 68)
                .background(Color.folderAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(title).font(.headline.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .tint(.folderAccent)
        }
        .padding(28)
        .background(Color.folderSurface)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.folderStroke, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Search Results Views

struct SearchResultsGridView: View {
    @ObservedObject var searchViewModel: SearchViewModel
    @ObservedObject var fileExplorerViewModel: FileExplorerViewModel
    @StateObject private var clipboardManager = ClipboardManager.shared

    private let spacing: CGFloat = 16
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: CGFloat(fileExplorerViewModel.viewMode.iconSize + 40)), spacing: spacing)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: spacing) {
                ForEach(Array(searchViewModel.searchResults), id: \.id) { (item: FileSystemItem) in
                    FileGridItem(item: item, isSelected: searchViewModel.isSelected(item), clipboardManager: clipboardManager, isDimmed: false, iconSize: CGFloat(fileExplorerViewModel.viewMode.iconSize))
                        .overlay {
                            Color.clear
                                .multiFileDrag(
                                    urls: searchViewModel.isSelected(item)
                                        ? searchViewModel.searchResults.filter { searchViewModel.selectedItems.contains($0.id) }.map { $0.path }
                                        : [item.path],
                                    enabled: true,
                                    onSingleClick: { modifiers in handleSearchItemClick(item, modifiers: modifiers) },
                                    onDoubleClick: {
                                        fileExplorerViewModel.openItem(item)
                                    }
                                )
                        }
                        .contextMenu {
                            FileContextMenu(
                                item: item,
                                viewModel: fileExplorerViewModel,
                                clipboardManager: clipboardManager,
                                allItems: searchViewModel.searchResults,
                                selectedItemIDs: searchViewModel.selectedItems,
                                searchViewModel: searchViewModel
                            )
                        }
                }
            }
            .padding()
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        searchViewModel.clearSelection()
                    }
            )
        }
    }

    private func handleSearchItemClick(
        _ item: FileSystemItem,
        modifiers modifierFlags: NSEvent.ModifierFlags = NSEvent.modifierFlags
    ) {
        NSApp.keyWindow?.makeFirstResponder(nil)

        if modifierFlags.contains(.shift) {
            if let lastSelected = searchViewModel.lastSelectedItem,
               let lastItem = searchViewModel.searchResults.first(where: { $0.id == lastSelected }) {
                searchViewModel.selectRange(from: lastItem, to: item)
            } else {
                searchViewModel.toggleSelection(for: item)
            }
        } else if modifierFlags.contains(.command) {
            searchViewModel.toggleSelection(for: item)
        } else {
            searchViewModel.selectOnly(item)
        }
    }
}

struct SearchResultsListView: View {
    @ObservedObject var searchViewModel: SearchViewModel
    @ObservedObject var fileExplorerViewModel: FileExplorerViewModel
    @StateObject private var clipboardManager = ClipboardManager.shared

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(searchViewModel.searchResults), id: \.id) { (item: FileSystemItem) in
                    FileListRow(item: item, isSelected: searchViewModel.isSelected(item), clipboardManager: clipboardManager, fileExplorerViewModel: fileExplorerViewModel, isDimmed: false)
                        .overlay {
                            Color.clear
                                .multiFileDrag(
                                    urls: searchViewModel.isSelected(item)
                                        ? searchViewModel.searchResults.filter { searchViewModel.selectedItems.contains($0.id) }.map { $0.path }
                                        : [item.path],
                                    enabled: true,
                                    onSingleClick: { modifiers in handleSearchItemClick(item, modifiers: modifiers) },
                                    onDoubleClick: {
                                        fileExplorerViewModel.openItem(item)
                                    }
                                )
                        }
                        .contextMenu {
                            FileContextMenu(
                                item: item,
                                viewModel: fileExplorerViewModel,
                                clipboardManager: clipboardManager,
                                allItems: searchViewModel.searchResults,
                                selectedItemIDs: searchViewModel.selectedItems,
                                searchViewModel: searchViewModel
                            )
                        }
                }
            }
            .padding(.horizontal)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        searchViewModel.clearSelection()
                    }
            )
        }
    }

    private func handleSearchItemClick(
        _ item: FileSystemItem,
        modifiers modifierFlags: NSEvent.ModifierFlags = NSEvent.modifierFlags
    ) {
        NSApp.keyWindow?.makeFirstResponder(nil)

        if modifierFlags.contains(.shift) {
            if let lastSelected = searchViewModel.lastSelectedItem,
               let lastItem = searchViewModel.searchResults.first(where: { $0.id == lastSelected }) {
                searchViewModel.selectRange(from: lastItem, to: item)
            } else {
                searchViewModel.toggleSelection(for: item)
            }
        } else if modifierFlags.contains(.command) {
            searchViewModel.toggleSelection(for: item)
        } else {
            searchViewModel.selectOnly(item)
        }
    }
}

// MARK: - Tag Filter Results Views

struct TagFilterResultsGridView: View {
    @ObservedObject var viewModel: FileExplorerViewModel
    @StateObject private var clipboardManager = ClipboardManager.shared

    private let spacing: CGFloat = 16
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: CGFloat(viewModel.viewMode.iconSize + 40)), spacing: spacing)]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header showing which tag is being filtered
            if let tagColor = viewModel.tagFilterMode {
                HStack {
                    Circle()
                        .fill(Color(hex: tagColor.rawValue))
                        .frame(width: 12, height: 12)
                    Text("\(tagColor.displayName) Tagged Items")
                        .font(.headline)
                    Text("(\(viewModel.tagFilteredItems.count) items)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Exit") {
                        viewModel.exitTagFilterMode()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()
            }

            ZStack {
                // Background tap catcher
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.clearSelection()
                    }

                ScrollView {
                    LazyVGrid(columns: columns, spacing: spacing) {
                        ForEach(Array(viewModel.tagFilteredItems), id: \.id) { (item: FileSystemItem) in
                            FileGridItem(item: item, isSelected: viewModel.isSelected(item), clipboardManager: clipboardManager, isDimmed: false, iconSize: CGFloat(viewModel.viewMode.iconSize))
                                .overlay {
                                    Color.clear.multiFileDrag(
                                        urls: [item.path],
                                        onSingleClick: { modifiers in handleItemClick(item, modifiers: modifiers) },
                                        onDoubleClick: { viewModel.openItem(item) }
                                    )
                                }
                                .contextMenu {
                                    FileContextMenu(item: item, viewModel: viewModel, clipboardManager: clipboardManager)
                                }
                        }
                    }
                    .padding()
                }
            }
        }
    }

    private func handleItemClick(
        _ item: FileSystemItem,
        modifiers modifierFlags: NSEvent.ModifierFlags = NSEvent.modifierFlags
    ) {

        if modifierFlags.contains(.shift) {
            if let lastSelected = viewModel.lastSelectedItem,
               let lastItem = viewModel.tagFilteredItems.first(where: { $0.id == lastSelected }) {
                // Range selection within tag filtered items
                guard let startIndex = viewModel.tagFilteredItems.firstIndex(where: { $0.id == lastItem.id }),
                      let endIndex = viewModel.tagFilteredItems.firstIndex(where: { $0.id == item.id }) else {
                    return
                }
                let range = startIndex < endIndex ? startIndex...endIndex : endIndex...startIndex
                for index in range {
                    viewModel.selectedItems.insert(viewModel.tagFilteredItems[index].id)
                }
                viewModel.lastSelectedItem = item.id
            } else {
                viewModel.toggleSelection(for: item)
            }
        } else if modifierFlags.contains(.command) {
            viewModel.toggleSelection(for: item)
        } else {
            viewModel.selectOnly(item)
        }
    }
}

struct TagFilterResultsListView: View {
    @ObservedObject var viewModel: FileExplorerViewModel
    @StateObject private var clipboardManager = ClipboardManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header showing which tag is being filtered
            if let tagColor = viewModel.tagFilterMode {
                HStack {
                    Circle()
                        .fill(Color(hex: tagColor.rawValue))
                        .frame(width: 12, height: 12)
                    Text("\(tagColor.displayName) Tagged Items")
                        .font(.headline)
                    Text("(\(viewModel.tagFilteredItems.count) items)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Exit") {
                        viewModel.exitTagFilterMode()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()
            }

            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.clearSelection()
                    }

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.tagFilteredItems), id: \.id) { (item: FileSystemItem) in
                            FileListRow(item: item, isSelected: viewModel.isSelected(item), clipboardManager: clipboardManager, fileExplorerViewModel: viewModel, isDimmed: false)
                                .overlay {
                                    Color.clear.multiFileDrag(
                                        urls: [item.path],
                                        onSingleClick: { modifiers in handleItemClick(item, modifiers: modifiers) },
                                        onDoubleClick: { viewModel.openItem(item) }
                                    )
                                }
                                .contextMenu {
                                    FileContextMenu(item: item, viewModel: viewModel, clipboardManager: clipboardManager)
                                }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private func handleItemClick(
        _ item: FileSystemItem,
        modifiers modifierFlags: NSEvent.ModifierFlags = NSEvent.modifierFlags
    ) {

        if modifierFlags.contains(.shift) {
            if let lastSelected = viewModel.lastSelectedItem,
               let lastItem = viewModel.tagFilteredItems.first(where: { $0.id == lastSelected }) {
                // Range selection within tag filtered items
                guard let startIndex = viewModel.tagFilteredItems.firstIndex(where: { $0.id == lastItem.id }),
                      let endIndex = viewModel.tagFilteredItems.firstIndex(where: { $0.id == item.id }) else {
                    return
                }
                let range = startIndex < endIndex ? startIndex...endIndex : endIndex...startIndex
                for index in range {
                    viewModel.selectedItems.insert(viewModel.tagFilteredItems[index].id)
                }
                viewModel.lastSelectedItem = item.id
            } else {
                viewModel.toggleSelection(for: item)
            }
        } else if modifierFlags.contains(.command) {
            viewModel.toggleSelection(for: item)
        } else {
            viewModel.selectOnly(item)
        }
    }
}
