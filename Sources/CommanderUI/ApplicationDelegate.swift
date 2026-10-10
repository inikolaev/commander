import AppKit
import FileManagerCore
import Sparkle

@MainActor
public final class ApplicationDelegate: NSObject, NSApplicationDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private var mainWindow: CommanderWindowController?
    private let exitCoordinator = ExitCoordinator()
    private var updaterController: SPUStandardUpdaterController!
    private var updateAccessory: NSTitlebarAccessoryViewController?
    private var appearanceMenuItems: [CommanderAppearanceMode: NSMenuItem] = [:]

    public override init() {
        super.init()
        // Delay starting Sparkle until the main window exists so scheduled updates can
        // be represented by a quiet title-bar reminder rather than an alert.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Load the bundled icon directly so a cached development-build icon in
        // Launch Services cannot leave the running app with the generic Dock tile.
        if let iconName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let iconURL = Bundle.main.resourceURL?.appendingPathComponent(iconName),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        CommanderAppearancePreference.applyToApplication()
        installMenu()
        let controller = CommanderWindowController()
        mainWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.start()
        updaterController.startUpdater()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = mainWindow, let window = controller.window else { return .terminateNow }
        controller.isExitPromptVisible = true
        exitCoordinator.request(window: window, operationInProgress: controller.fileOperationInProgress) { confirmed in
            controller.isExitPromptVisible = false
            if confirmed { controller.prepareForTermination { sender.reply(toApplicationShouldTerminate: $0) } }
            else { sender.reply(toApplicationShouldTerminate: false) }
        }
        return .terminateLater
    }

    public var supportsGentleScheduledUpdateReminders: Bool { true }

    public func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Scheduled checks should never interrupt the user with a window.
        false
    }

    public func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // User-initiated checks are shown by Sparkle normally. For scheduled checks,
        // expose the available update quietly in the main window title bar.
        guard !handleShowingUpdate, updateAccessory == nil,
              let window = mainWindow?.window else { return }

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        accessory.view = UpdateAvailableButton(
            target: updaterController,
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        )
        window.addTitlebarAccessoryViewController(accessory)
        updateAccessory = accessory
        mainWindow?.layoutTabStrip()
    }

    public func standardUserDriverWillFinishUpdateSession() {
        updateAccessory?.removeFromParent()
        updateAccessory = nil
        mainWindow?.layoutTabStrip()
    }

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Commander")
        appMenu.addItem(withTitle: "About Commander", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let checkForUpdates = appMenu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdates.target = updaterController
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Commander", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Commander", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Tab", action: #selector(CommanderWindowController.newTab(_:)), keyEquivalent: "t")
        file.addItem(withTitle: "Close Tab", action: #selector(CommanderWindowController.closeTab(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Rename Tab…", action: #selector(CommanderWindowController.renameTab(_:)), keyEquivalent: "")
        let fileItem = NSMenuItem()
        fileItem.submenu = file
        menu.addItem(fileItem)

        let navigation = NSMenu(title: "Navigate")
        navigation.addItem(withTitle: "Go to Folder…", action: #selector(CommanderWindowController.goToFolder(_:)), keyEquivalent: "l")
        navigation.addItem(withTitle: "Left Pane Locations…", action: #selector(CommanderWindowController.leftLocations(_:)), keyEquivalent: "1")
        navigation.addItem(withTitle: "Right Pane Locations…", action: #selector(CommanderWindowController.rightLocations(_:)), keyEquivalent: "2")
        let matchDirectory = navigation.addItem(withTitle: "Open Current Directory in Other Pane",
            action: #selector(CommanderWindowController.matchDirectory(_:)), keyEquivalent: "d")
        matchDirectory.keyEquivalentModifierMask = [.command]
        navigation.addItem(withTitle: "Go Home", action: #selector(CommanderWindowController.goHome(_:)), keyEquivalent: "~")
        navigation.addItem(withTitle: "Refresh", action: #selector(CommanderWindowController.refresh(_:)), keyEquivalent: "r")
        navigation.addItem(withTitle: "Show Hidden Files", action: #selector(CommanderWindowController.toggleHidden(_:)), keyEquivalent: ".")
        let navigationItem = NSMenuItem()
        navigationItem.submenu = navigation
        menu.addItem(navigationItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        menu.addItem(editItem)

        let view = NSMenu(title: "View")
        let appearance = NSMenu(title: "Appearance")
        for mode in CommanderAppearanceMode.allCases {
            let item = appearance.addItem(
                withTitle: mode.menuTitle,
                action: #selector(selectAppearance(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            appearanceMenuItems[mode] = item
        }
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearance
        view.addItem(appearanceItem)
        let placement = NSMenu(title: "Tab Placement")
        for position in TabPlacement.allCases {
            let item = placement.addItem(withTitle: position.menuTitle,
                action: #selector(CommanderWindowController.selectTabPlacement(_:)), keyEquivalent: "")
            item.representedObject = position.rawValue
        }
        let placementItem = NSMenuItem(title: "Tab Placement", action: nil, keyEquivalent: "")
        placementItem.submenu = placement
        view.addItem(placementItem)
        view.addItem(.separator())
        let nextTab = view.addItem(withTitle: "Next Tab", action: #selector(CommanderWindowController.nextTab(_:)), keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        let previousTab = view.addItem(withTitle: "Previous Tab", action: #selector(CommanderWindowController.previousTab(_:)), keyEquivalent: "[")
        previousTab.keyEquivalentModifierMask = [.command, .shift]
        let viewItem = NSMenuItem()
        viewItem.submenu = view
        menu.addItem(viewItem)

        NSApp.mainMenu = menu
        updateAppearanceMenu()
    }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = CommanderAppearanceMode(rawValue: raw) else { return }
        CommanderAppearancePreference.mode = mode
        CommanderAppearancePreference.applyToApplication()
        updateAppearanceMenu()
        mainWindow?.refreshAppearance()
    }

    private func updateAppearanceMenu() {
        let selected = CommanderAppearancePreference.mode
        for (mode, item) in appearanceMenuItems {
            item.state = mode == selected ? .on : .off
        }
    }
}

/// Observes modifiers before dispatch, including while a dialog owns keyboard focus.
@MainActor
final class CommanderWindow: NSWindow {
    var onModifiersChanged: ((NSEvent.ModifierFlags) -> Void)?
    override func sendEvent(_ event: NSEvent) {
        onModifiersChanged?(event.modifierFlags)
        super.sendEvent(event)
    }
}


@MainActor
final class AppearanceObservingView: NSView {
    var onAppearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }
}
