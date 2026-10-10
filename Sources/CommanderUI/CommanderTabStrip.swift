import AppKit

enum TabPlacement: String, CaseIterable {
    case titlebar, belowTitlebar
    static let preferenceKey = "CommanderTabPlacement"
    var menuTitle: String { self == .titlebar ? "In Window Title Bar" : "Below Window Title Bar" }
}

/// A bounded strip: wheel motion on either axis pans the tabs, never the file panes.
@MainActor
final class TabScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 20
        scrollHorizontally(by: -delta * scale)
    }
    func scrollHorizontally(by delta: CGFloat) {
        let maximum = max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
        contentView.scroll(to: NSPoint(x: min(maximum, max(0, contentView.bounds.minX + delta)), y: 0))
        reflectScrolledClipView(contentView)
    }
}

@MainActor
final class CommanderTabStrip: NSView {
    static let preferredHeight: CGFloat = 26
    private static let tabHeight: CGFloat = 20
    var alignsWithWindowControls = false { didSet { needsLayout = true } }
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onRename: ((UUID) -> Void)?
    var onCloseOthers: ((UUID) -> Void)?
    var onCloseRight: ((UUID) -> Void)?
    var onColor: ((UUID, TabColor?) -> Void)?
    var canInteract: () -> Bool = { true }
    var onNew: (() -> Void)?
    let scrollView = TabScrollView()
    private let document = NSView()
    private let newButton = NSButton(title: "+", target: nil, action: nil)
    private var cells: [TabCell] = []
    private var selected: UUID?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = document
        addSubview(scrollView)
        newButton.target = self
        newButton.action = #selector(addTab)
        newButton.isBordered = false
        newButton.font = .systemFont(ofSize: 18)
        newButton.toolTip = "New Tab (⌘T)"
        newButton.setAccessibilityLabel("New Tab")
        addSubview(newButton)
    }
    convenience init() { self.init(frame: NSRect(x: 0, y: 0, width: 800, height: Self.preferredHeight)) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    @objc private func addTab() { onNew?() }

    func update(tabs: [(UUID, String)], selected: UUID, revealSelection: Bool, colors: [UUID: TabColor] = [:]) {
        self.selected = selected
        // Reuse controls during directory refreshes so hover, accessibility focus, and scroll remain stable.
        let previous = Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0) })
        let ids = Set(tabs.map { $0.0 })
        cells.filter { !ids.contains($0.id) }.forEach { $0.removeFromSuperview() }
        cells = tabs.map { id, title in
            let cell = previous[id] ?? TabCell(id: id)
            cell.configure(title: title, selected: id == selected, color: colors[id])
            cell.hasOtherTabs = tabs.count > 1
            cell.hasTabsToRight = tabs.last?.0 != id
            cell.canInteract = { [weak self] in self?.canInteract() == true }
            cell.onCloseOthers = { [weak self] in self?.onCloseOthers?(id) }
            cell.onCloseRight = { [weak self] in self?.onCloseRight?(id) }
            cell.onColor = { [weak self] color in self?.onColor?(id, color) }
            cell.onSelect = { [weak self] in self?.onSelect?(id) }
            cell.onClose = { [weak self] in self?.onClose?(id) }
            cell.onRename = { [weak self] in self?.onRename?(id) }
            if cell.superview == nil { document.addSubview(cell) }
            return cell
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if revealSelection { self.revealSelection() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }
    override func layout() {
        super.layout()
        // Title-bar accessories are bottom-aligned by AppKit, so centering in
        // our own bounds puts the tabs below the native window controls.
        let centerY: CGFloat
        if alignsWithWindowControls, let closeButton = window?.standardWindowButton(.closeButton) {
            centerY = convert(closeButton.bounds, from: closeButton).midY
        } else {
            centerY = bounds.midY
        }
        let tabY = centerY - Self.tabHeight / 2
        newButton.frame = NSRect(x: max(0, bounds.width - 32), y: tabY, width: 30, height: Self.tabHeight)
        scrollView.frame = NSRect(x: 4, y: 0, width: max(0, bounds.width - 40), height: bounds.height)
        var x: CGFloat = 0
        for cell in cells {
            cell.frame = NSRect(x: x, y: tabY, width: cell.preferredWidth, height: Self.tabHeight)
            x += cell.frame.width + 4
        }
        document.frame = NSRect(x: 0, y: 0, width: max(x, scrollView.contentSize.width), height: bounds.height)
        scrollView.scrollHorizontally(by: 0)
    }
    func revealSelection() {
        guard let cell = cells.first(where: { $0.id == selected }) else { return }
        document.scrollToVisible(cell.frame)
    }
}

@MainActor
private final class TabCell: NSView, NSMenuDelegate {
    var hasOtherTabs = false
    var hasTabsToRight = false
    var canInteract: () -> Bool = { true }
    var onCloseOthers: (() -> Void)?
    var onCloseRight: (() -> Void)?
    var onColor: ((TabColor?) -> Void)?
    private var color: TabColor?
    private var colorPicker: TabColorPicker?
    let id: UUID
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onRename: (() -> Void)?
    private let button = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    var preferredWidth: CGFloat { min(280, max(110, button.attributedTitle.size().width + 44)) }
    init(id: UUID) {
        self.id = id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        button.isBordered = false
        button.font = .systemFont(ofSize: 12)
        button.lineBreakMode = .byTruncatingMiddle
        button.target = self
        button.action = #selector(select)
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 15)
        closeButton.target = self
        closeButton.action = #selector(close)
        addSubview(button)
        addSubview(closeButton)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        for (title, action) in [
            ("Close Tab", #selector(close)),
            ("Close Other Tabs", #selector(closeOthers)),
            ("Close Tabs to the Right", #selector(closeRight))
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        menu.addItem(.separator())
        let rename = menu.addItem(withTitle: "Rename Tab…", action: #selector(rename), keyEquivalent: "")
        rename.target = self
        let picker = TabColorPicker()
        picker.onChoose = { [weak self, weak menu] color in
            menu?.cancelTracking()
            self?.onColor?(color)
        }
        colorPicker = picker
        let palette = NSMenuItem()
        palette.view = picker
        menu.addItem(palette)
        self.menu = menu
        button.menu = menu
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    private var isSelected = false
    func configure(title: String, selected: Bool, color: TabColor?) {
        guard button.title != title || isSelected != selected || self.color != color else { return }
        self.color = color
        button.title = title
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(selected ? "Selected tab" : "Tab")
        closeButton.setAccessibilityLabel("Close \(title)")
        closeButton.toolTip = "Close Tab"
        isSelected = selected
        updateColor()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColor() }
    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let tint = color?.nsColor ?? NSColor.controlAccentColor
            let background = color != nil ? tint.withAlphaComponent(isSelected ? 0.38 : 0.18)
                : (isSelected ? tint.withAlphaComponent(0.23) : NSColor.labelColor.withAlphaComponent(0.06))
            layer?.backgroundColor = background.cgColor
            layer?.borderWidth = color != nil ? 1 : 0
            layer?.borderColor = tint.withAlphaComponent(isSelected ? 0.95 : 0.45).cgColor
        }
    }
    override func layout() {
        super.layout()
        button.frame = NSRect(x: 8, y: 0, width: max(0, bounds.width - 34), height: bounds.height)
        closeButton.frame = NSRect(x: bounds.width - 26, y: 0, width: 24, height: bounds.height)
    }
    func menuWillOpen(_ menu: NSMenu) {
        let enabled = canInteract()
        for item in menu.items where item.action != nil {
            item.isEnabled = enabled
            if item.action == #selector(closeOthers) { item.isEnabled = enabled && hasOtherTabs }
            if item.action == #selector(closeRight) { item.isEnabled = enabled && hasTabsToRight }
        }
        colorPicker?.update(selected: color, enabled: enabled)
    }
    @objc private func closeOthers() { onCloseOthers?() }
    @objc private func closeRight() { onCloseRight?() }
    @objc private func select() { onSelect?() }
    @objc private func close() { onClose?() }
    @objc private func rename() { onRename?() }
}
