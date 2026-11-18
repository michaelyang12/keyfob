import AppKit
import SwiftUI

@main
enum KeyfobMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = AppController()
        controller.start()
        self.controller = controller
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { controller?.handle($0) }
    }
}

@MainActor
final class AppController {
    let prefs = Preferences()
    let store = TokenStore()
    let clipboard = Clipboard()
    let hud = CopyHUD()
    let lock: SessionLock
    let search: SearchModel
    let manager: ManagerModel
    let settings: SettingsModel
    let panel: SearchPanelController
    let windows: WindowController
    private var statusBar: StatusBarController?
    private var hotKey: GlobalHotKey?

    init() {
        lock = SessionLock(prefs: prefs)
        search = SearchModel(store: store, lock: lock)
        manager = ManagerModel(store: store, lock: lock)
        settings = SettingsModel(prefs: prefs, lock: lock)
        panel = SearchPanelController(model: search)
        windows = WindowController(manager: manager, settings: settings)
    }

    func start() {
        NSApp.mainMenu = buildMainMenu()
        store.reload()

        let statusBar = StatusBarController(menu: buildStatusMenu())
        statusBar.onClick = { [weak self] in self?.togglePanel(anchored: true) }
        self.statusBar = statusBar
        lock.onChange = { [weak self] unlocked in self?.statusBar?.setUnlocked(unlocked) }

        let hotKey = GlobalHotKey { [weak self] in self?.togglePanel(anchored: false) }
        hotKey.register(prefs.hotKey)
        self.hotKey = hotKey
        prefs.onHotKeyChange = { [weak self] combo in
            guard let self else { return }
            if let combo {
                self.hotKey?.register(combo)
                self.statusBar?.menu = self.buildStatusMenu()
            } else {
                self.hotKey?.unregister()
            }
        }

        search.onCopy = { [weak self] token, format in self?.copy(token, as: format) }
        search.onNew = { [weak self] name in self?.openManager(newTokenNamed: name) }
        search.onEdit = { [weak self] token in self?.openManager(selecting: token.id, edit: true) }
        search.onManage = { [weak self] in self?.openManager() }
        search.onSettings = { [weak self] in self?.openSettings() }
        manager.onCopy = { [weak self] token, format in self?.copy(token, as: format) }

        if store.tokens.isEmpty && store.loadError == nil {
            openManager(newTokenNamed: "")
        }
    }

    func handle(_ url: URL) {
        guard url.scheme == "keyfob" else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "q" }?.value
        switch url.host {
        case "manage": openManager()
        case "settings": openSettings()
        case "new": openManager(newTokenNamed: query ?? "")
        case "token":
            store.reload()
            if let match = Ranker.rank(store.tokens, query: query ?? "", usage: store.usage).first {
                openManager(selecting: match.id)
            }
        default:
            store.reload()
            if !panel.isVisible { panel.show(anchor: nil) }
            if let query { search.query = query }
        }
    }

    func togglePanel(anchored: Bool) {
        if panel.isVisible {
            panel.hide()
            return
        }
        guard panel.canReopen else { return }
        store.reload()
        panel.show(anchor: anchored ? statusBar?.buttonFrame : nil)
    }

    func copy(_ token: Token, as format: CopyFormat) {
        Task {
            panel.suppressAutoHide = true
            defer {
                panel.suppressAutoHide = false
                panel.refocus()
            }
            guard await lock.authorize(reason: "copy “\(token.name)”") else {
                search.message = "Unlock was cancelled"
                return
            }
            do {
                let secret = try store.secret(for: token.id)
                clipboard.copy(format.render(token, secret: secret), clearAfter: prefs.clearClipboardAfter)
                store.recordUse(token.id)
                panel.hide()
                statusBar?.flash()
                hud.show(title: copyTitle(token, format), subtitle: clearSubtitle)
            } catch {
                search.message = error.localizedDescription
                manager.error = error.localizedDescription
            }
        }
    }

    private func copyTitle(_ token: Token, _ format: CopyFormat) -> String {
        switch format {
        case .value: "Copied \(token.name)"
        case .export: "Copied export \(token.variableName)"
        case .dotenv: "Copied \(token.variableName)=…"
        }
    }

    private var clearSubtitle: String {
        switch prefs.clearClipboardAfter {
        case 0: "Stays on the clipboard"
        case let s where s < 60: "Clears from the clipboard in \(s) seconds"
        case 60: "Clears from the clipboard in 1 minute"
        case let s: "Clears from the clipboard in \(s / 60) minutes"
        }
    }

    func openManager(selecting id: String? = nil, edit: Bool = false, newTokenNamed name: String? = nil) {
        panel.hide()
        store.reload()
        windows.showManager()
        if let id {
            manager.select(id)
            if edit { manager.beginEditing() }
        } else if let name {
            manager.newToken(name: name)
        }
    }

    func openSettings() {
        panel.hide()
        windows.showSettings()
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let combo = prefs.hotKey
        menu.addItem(ActionMenuItem(
            "Search Tokens",
            symbol: "magnifyingglass",
            key: combo.key.count == 1 ? combo.key.lowercased() : "",
            modifiers: combo.flags.intersection([.command, .option, .control, .shift])
        ) { [weak self] in self?.togglePanel(anchored: true) })
        menu.addItem(ActionMenuItem("New Token…", symbol: "plus") { [weak self] in self?.openManager(newTokenNamed: "") })
        menu.addItem(ActionMenuItem("Manage Tokens…", symbol: "key.horizontal") { [weak self] in self?.openManager() })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Lock Now", symbol: "lock") { [weak self] in self?.lock.lock() })
        menu.addItem(ActionMenuItem("Settings…", symbol: "gearshape", key: ",") { [weak self] in self?.openSettings() })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Quit keyfob", symbol: "power", key: "q") { NSApp.terminate(nil) })
        return menu
    }

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(ActionMenuItem("Settings…", symbol: "gearshape", key: ",") { [weak self] in self?.openSettings() })
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide keyfob", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit keyfob", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(submenu(appMenu, title: "keyfob"))

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(ActionMenuItem("New Token", symbol: "plus", key: "n") { [weak self] in self?.openManager(newTokenNamed: "") })
        fileMenu.addItem(ActionMenuItem("Import from .env File…", symbol: "square.and.arrow.down", key: "i", modifiers: [.command, .shift]) { [weak self] in
            self?.openManager()
            self?.manager.beginImport()
        })
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        main.addItem(submenu(fileMenu, title: "File"))

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        main.addItem(submenu(editMenu, title: "Edit"))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        main.addItem(submenu(windowMenu, title: "Window"))
        NSApp.windowsMenu = windowMenu

        return main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

@MainActor
final class StatusBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var menu: NSMenu
    private var unlocked = false
    private var flashTask: Task<Void, Never>?
    var onClick: () -> Void = {}

    init(menu: NSMenu) {
        self.menu = menu
        super.init()
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "keyfob"
        refreshIcon()
    }

    var buttonFrame: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func setUnlocked(_ unlocked: Bool) {
        self.unlocked = unlocked
        if flashTask == nil { refreshIcon() }
    }

    func flash() {
        flashTask?.cancel()
        item.button?.image = Self.icon("checkmark")
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.flashTask = nil
            self?.refreshIcon()
        }
    }

    private func refreshIcon() {
        item.button?.image = Self.icon(unlocked ? "key.horizontal.fill" : "key.horizontal")
    }

    private static func icon(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "keyfob")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        return image
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            onClick()
        }
    }
}

@MainActor
final class WindowController {
    private let manager: ManagerModel
    private let settings: SettingsModel
    private var managerWindow: NSWindow?
    private var settingsWindow: NSWindow?

    init(manager: ManagerModel, settings: SettingsModel) {
        self.manager = manager
        self.settings = settings
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.managerWindow?.level = .normal
                self?.settingsWindow?.level = .normal
            }
        }
    }

    func showManager() {
        let window = managerWindow ?? makeManagerWindow()
        managerWindow = window
        present(window)
    }

    func showSettings() {
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        present(window)
    }

    private func makeManagerWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: ManagerView(model: manager))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: hosting)
        window.title = "keyfob"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 960, height: 600))
        window.center()
        window.setFrameAutosaveName("keyfob.manager.v2")
        return window
    }

    private func makeSettingsWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(settingsTab("General", symbol: "gearshape", GeneralSettingsView(settings: settings)))
        tabs.addTabViewItem(settingsTab("Security", symbol: "lock", SecuritySettingsView(settings: settings)))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func settingsTab<Content: View>(_ label: String, symbol: String, _ content: Content) -> NSTabViewItem {
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = [.preferredContentSize]
        hosting.title = label
        let item = NSTabViewItem(viewController: hosting)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }

    private func present(_ window: NSWindow) {
        NSApp.activate()
        if !NSApp.isActive { window.level = .floating }
        window.orderFrontRegardless()
        window.makeKey()
    }
}
