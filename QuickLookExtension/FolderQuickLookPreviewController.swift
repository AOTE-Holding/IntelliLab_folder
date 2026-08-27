import AppKit
import Foundation
@preconcurrency import Quartz

private struct FolderPreviewEntry: Decodable {
    let name: String
    let kind: String
    let modified: String
    let size: String
    let isDirectory: Bool
    let sourcePath: String?
}

private struct FolderPreviewPayload: Decodable {
    let folderName: String
    let entries: [FolderPreviewEntry]
    let truncated: Bool
    let errorMessage: String?
    let previewKind: String?
    let textContent: String?
    let textLanguage: String?
    let previewSessionID: String?
    let sourceFolderPath: String?
    let appearance: String?
}

private enum FolderPreviewPalette {
    static let base = dynamic(light: NSColor(red: 247 / 255, green: 249 / 255, blue: 251 / 255, alpha: 1), dark: NSColor(red: 20 / 255, green: 27 / 255, blue: 35 / 255, alpha: 1))
    static let rowHighlight = NSColor(red: 0 / 255, green: 169 / 255, blue: 143 / 255, alpha: 0.18)
    static let primaryText = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let codeBackground = dynamic(light: .white, dark: NSColor(calibratedWhite: 0.08, alpha: 0.82))

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark]) == nil ? light : dark
        }
    }
}

/// Read-only folder rows keep the preview visually calm and deliberately do
/// not draw AppKit's blue selection state; selecting an entry simply changes
/// the active preview in the parent panel.
private final class FolderPreviewRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        FolderPreviewPalette.base.setFill()
        dirtyRect.fill()
    }

}

private final class FolderPreviewBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        FolderPreviewPalette.base.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@objc(FolderQuickLookPreviewController)
final class FolderQuickLookPreviewController: NSViewController, @preconcurrency QLPreviewingController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    private let folderIconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Folder")
    private let itemCountLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let codeTextView = CopyingTextView()
    private let codeScrollView = NSScrollView()
    private let stateLabel = NSTextField(wrappingLabelWithString: "")
    private let copyFeedbackView = NSVisualEffectView()
    private let copyFeedbackLabel = NSTextField(labelWithString: "✓  Copied")
    private var lastCopiedCodeSelection = ""
    private var copyFeedbackGeneration = 0
    private var clickMonitor: Any?
    private var isPointerSelectingCode = false
    private var payload = FolderPreviewPayload(
        folderName: "Folder", entries: [], truncated: false, errorMessage: nil,
        previewKind: "folder", textContent: nil, textLanguage: nil,
        previewSessionID: nil, sourceFolderPath: nil, appearance: nil
    )

    override func loadView() {
        let root = FolderPreviewBackgroundView(frame: NSRect(x: 0, y: 0, width: 1_040, height: 780))

        folderIconView.image = NSWorkspace.shared.icon(for: .folder)
        folderIconView.imageScaling = .scaleProportionallyUpOrDown
        folderIconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = FolderPreviewPalette.primaryText
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        itemCountLabel.font = .systemFont(ofSize: 11)
        itemCountLabel.textColor = FolderPreviewPalette.secondaryText
        itemCountLabel.translatesAutoresizingMaskIntoConstraints = false

        configureTable()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = FolderPreviewPalette.base
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        codeTextView.frame = NSRect(x: 0, y: 0, width: 980, height: 680)
        codeTextView.minSize = NSSize(width: 0, height: 0)
        codeTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        codeTextView.isVerticallyResizable = true
        codeTextView.isHorizontallyResizable = false
        codeTextView.autoresizingMask = [.width]
        codeTextView.isEditable = false
        codeTextView.isSelectable = true
        codeTextView.delegate = self
        codeTextView.onPointerSelectionBegan = { [weak self] in
            self?.isPointerSelectingCode = true
        }
        codeTextView.onPointerSelectionEnded = { [weak self] in
            guard let self else { return }
            self.isPointerSelectingCode = false
            self.copyCurrentCodeSelectionIfNeeded()
        }
        codeTextView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        // A preview extension does not reliably inherit the panel's effective
        // appearance. Resolve the code palette explicitly so source text never
        // becomes black-on-dark and appears empty.
        codeTextView.textColor = FolderPreviewPalette.primaryText
        codeTextView.backgroundColor = FolderPreviewPalette.codeBackground
        codeTextView.drawsBackground = true
        codeTextView.isRichText = false
        codeTextView.textContainerInset = NSSize(width: 14, height: 12)
        codeTextView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        codeTextView.textContainer?.widthTracksTextView = true

        codeScrollView.documentView = codeTextView
        codeScrollView.hasVerticalScroller = true
        codeScrollView.hasHorizontalScroller = true
        codeScrollView.autohidesScrollers = false
        codeScrollView.scrollerStyle = .legacy
        codeScrollView.borderType = .noBorder
        codeScrollView.drawsBackground = false
        codeScrollView.translatesAutoresizingMaskIntoConstraints = false
        codeScrollView.isHidden = true

        stateLabel.alignment = .center
        stateLabel.textColor = FolderPreviewPalette.secondaryText
        stateLabel.maximumNumberOfLines = 4
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.isHidden = true

        copyFeedbackView.material = .hudWindow
        copyFeedbackView.blendingMode = .withinWindow
        copyFeedbackView.state = .active
        copyFeedbackView.wantsLayer = true
        copyFeedbackView.layer?.cornerRadius = 10
        copyFeedbackView.alphaValue = 0
        copyFeedbackView.isHidden = true
        copyFeedbackView.translatesAutoresizingMaskIntoConstraints = false

        copyFeedbackLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        copyFeedbackLabel.textColor = .labelColor
        copyFeedbackLabel.translatesAutoresizingMaskIntoConstraints = false
        copyFeedbackView.addSubview(copyFeedbackLabel)
        NSLayoutConstraint.activate([
            copyFeedbackLabel.leadingAnchor.constraint(equalTo: copyFeedbackView.leadingAnchor, constant: 12),
            copyFeedbackLabel.trailingAnchor.constraint(equalTo: copyFeedbackView.trailingAnchor, constant: -12),
            copyFeedbackLabel.topAnchor.constraint(equalTo: copyFeedbackView.topAnchor, constant: 7),
            copyFeedbackLabel.bottomAnchor.constraint(equalTo: copyFeedbackView.bottomAnchor, constant: -7)
        ])

        root.addSubview(folderIconView)
        root.addSubview(titleLabel)
        root.addSubview(itemCountLabel)
        root.addSubview(scrollView)
        root.addSubview(codeScrollView)
        root.addSubview(stateLabel)
        root.addSubview(copyFeedbackView)
        NSLayoutConstraint.activate([
            folderIconView.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            folderIconView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            folderIconView.widthAnchor.constraint(equalToConstant: 28),
            folderIconView.heightAnchor.constraint(equalToConstant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: folderIconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: folderIconView.topAnchor, constant: 1),
            itemCountLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            itemCountLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            scrollView.topAnchor.constraint(equalTo: itemCountLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            codeScrollView.topAnchor.constraint(equalTo: itemCountLabel.bottomAnchor, constant: 8),
            codeScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            codeScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            codeScrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            stateLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            stateLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -100),
            copyFeedbackView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            copyFeedbackView.topAnchor.constraint(equalTo: root.topAnchor, constant: 16)
        ])

        view = root
        preferredContentSize = NSSize(width: 1_040, height: 780)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installSelectionClearMonitor()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        removeSelectionClearMonitor()
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping ((any Error)?) -> Void) {
        _ = view
        do {
            payload = try JSONDecoder().decode(FolderPreviewPayload.self, from: Data(contentsOf: url))
            updateContent()
            handler(nil)
        } catch {
            payload = FolderPreviewPayload(
                folderName: "Folder",
                entries: [],
                truncated: false,
                errorMessage: error.localizedDescription,
                previewKind: "folder",
                textContent: nil,
                textLanguage: nil,
                previewSessionID: nil,
                sourceFolderPath: nil,
                appearance: nil
            )
            updateContent()
            handler(nil)
        }
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = FolderPreviewPalette.base
        tableView.gridStyleMask = []
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none
        tableView.rowHeight = 36
        tableView.intercellSpacing = .zero
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.setAccessibilityLabel("Folder contents")

        let definitions: [(String, String, CGFloat, CGFloat)] = [
            ("name", "Name", 520, 220),
            ("modified", "Date Modified", 190, 130),
            ("size", "Size", 90, 68)
        ]
        for definition in definitions {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(definition.0))
            column.title = definition.1
            column.width = definition.2
            column.minWidth = definition.3
            column.resizingMask = .autoresizingMask
            tableView.addTableColumn(column)
        }
    }

    private func updateContent() {
        applyAppearance()
        titleLabel.stringValue = payload.folderName
        if payload.previewKind == "text" {
            folderIconView.image = NSWorkspace.shared.icon(for: .data)
            itemCountLabel.stringValue = payload.textLanguage.map { "\($0) source" } ?? "Text file"
            codeTextView.string = payload.textContent ?? ""
            codeTextView.setSelectedRange(NSRange(location: 0, length: 0))
            codeTextView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            stateLabel.isHidden = true
            scrollView.isHidden = true
            codeScrollView.isHidden = false
            return
        }

        folderIconView.image = NSWorkspace.shared.icon(for: .folder)
        clearCodeSelection()
        codeScrollView.isHidden = true
        let count = payload.entries.count
        itemCountLabel.stringValue = payload.truncated
            ? "Showing the first \(count) items"
            : "\(count) \(count == 1 ? "item" : "items")"

        if let error = payload.errorMessage {
            stateLabel.stringValue = "Folder contents could not be read.\n\(error)"
            stateLabel.textColor = .systemRed
            stateLabel.isHidden = false
            scrollView.isHidden = true
        } else if payload.entries.isEmpty {
            stateLabel.stringValue = "This folder is empty."
            stateLabel.textColor = .secondaryLabelColor
            stateLabel.isHidden = false
            scrollView.isHidden = true
        } else {
            stateLabel.isHidden = true
            scrollView.isHidden = false
        }
        tableView.reloadData()
    }

    private func applyAppearance() {
        switch payload.appearance {
        case "light":
            view.appearance = NSAppearance(named: .aqua)
        case "dark":
            view.appearance = NSAppearance(named: .darkAqua)
        default:
            view.appearance = nil
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        payload.entries.count
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard payload.entries.indices.contains(row), let tableColumn else { return nil }
        let entry = payload.entries[row]
        if tableColumn.identifier.rawValue == "name" {
            return nameCell(for: entry)
        }

        let text: String
        switch tableColumn.identifier.rawValue {
        case "modified": text = entry.modified
        case "size": text = entry.size
        case "kind": text = entry.kind
        default: text = ""
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = FolderPreviewPalette.secondaryText
        label.alignment = tableColumn.identifier.rawValue == "size" ? .right : .left
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.textField = label
        return cell
    }

    private func nameCell(for entry: FolderPreviewEntry) -> NSTableCellView {
        let cell = NSTableCellView()
        let image = entry.sourcePath.map(NSWorkspace.shared.icon(forFile:))
            ?? NSWorkspace.shared.icon(for: entry.isDirectory ? .folder : .data)

        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: entry.name)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = FolderPreviewPalette.primaryText
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(imageView)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 22),
            imageView.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.imageView = imageView
        cell.textField = label
        cell.setAccessibilityLabel(entry.name)
        cell.setAccessibilityHelp(entry.isDirectory ? "Folder" : entry.kind)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        FolderPreviewRowView()
    }

    /// Folder previews are read-only. In a source/text preview, a selection is
    /// an intentional copy gesture, so keep the system pasteboard in sync with
    /// the currently highlighted text without showing a disruptive toast.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              textView === codeTextView else { return }

        // Dragging across text emits many intermediate selections. Wait for the
        // matching mouse-up event so the clipboard receives only the final
        // selection, never a partially highlighted line while the user drags.
        if isPointerSelectingCode { return }
        copyCurrentCodeSelectionIfNeeded()
    }

    private func copyCurrentCodeSelectionIfNeeded() {
        let textView = codeTextView
        let range = textView.selectedRange()
        guard range.length > 0,
              range.location != NSNotFound,
              let selected = (textView.string as NSString?)?.substring(with: range),
              selected != lastCopiedCodeSelection else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selected, forType: .string)
        lastCopiedCodeSelection = selected
        showCopyFeedback()
    }

    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextView === codeTextView else { return }
        clearCodeSelection()
    }

    private func installSelectionClearMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self,
                  event.window === self.view.window,
                  self.payload.previewKind == "text" else { return event }

            let location = self.view.convert(event.locationInWindow, from: nil)
            let hitView = self.view.hitTest(location)
            let clickedCode = hitView === self.codeTextView || hitView?.isDescendant(of: self.codeTextView) == true
            if !clickedCode {
                self.isPointerSelectingCode = false
                self.clearCodeSelection()
            }
            return event
        }
    }

    private func removeSelectionClearMonitor() {
        guard let clickMonitor else { return }
        NSEvent.removeMonitor(clickMonitor)
        self.clickMonitor = nil
    }

    private func clearCodeSelection() {
        guard codeTextView.selectedRange().length > 0 else { return }
        codeTextView.setSelectedRange(NSRange(location: 0, length: 0))
        lastCopiedCodeSelection = ""
    }

    private func showCopyFeedback() {
        copyFeedbackGeneration += 1
        let generation = copyFeedbackGeneration
        copyFeedbackView.isHidden = false
        copyFeedbackView.alphaValue = 0

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            copyFeedbackView.animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.copyFeedbackGeneration == generation else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.copyFeedbackView.animator().alphaValue = 0
            } completionHandler: {
                guard self.copyFeedbackGeneration == generation else { return }
                self.copyFeedbackView.isHidden = true
            }
        }
    }
}

/// NSTextView receives the complete drag sequence, including a mouse-up that
/// occurs outside its bounds. This is more reliable than a Quick Look panel's
/// local event monitor for committing a text selection.
private final class CopyingTextView: NSTextView {
    var onPointerSelectionBegan: (() -> Void)?
    var onPointerSelectionEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onPointerSelectionBegan?()
        super.mouseDown(with: event)
        // NSTextView tracks the drag internally inside mouseDown and returns
        // only after the pointer has been released. This is the reliable
        // commit point for a Quick Look text selection.
        onPointerSelectionEnded?()
    }
}
