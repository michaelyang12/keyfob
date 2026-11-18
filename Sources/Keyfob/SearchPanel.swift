import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SearchPanelController: NSObject, NSWindowDelegate {
    private let panel: KeyPanel
    private let model: SearchModel
    private var monitor: Any?
    private var lastHidden = Date.distantPast
    var suppressAutoHide = false

    init(model: SearchModel) {
        self.model = model
        panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: SearchView.windowWidth, height: 240),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self

        let hosting = NSHostingView(rootView: SearchView(model: model))
        hosting.sizingOptions = []
        panel.contentView = hosting

        model.onHeightChange = { [weak self] height in
            Task { @MainActor in self?.resize(to: height) }
        }
    }

    var isVisible: Bool { panel.isVisible }
    var canReopen: Bool { Date().timeIntervalSince(lastHidden) > 0.3 }

    func show(anchor: NSRect?) {
        model.prepareForPresent()
        panel.setFrame(frame(anchor: anchor, height: SearchView.height(for: model.results.count)), display: false)
        panel.makeKeyAndOrderFront(nil)
        installMonitor()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        lastHidden = Date()
        removeMonitor()
    }

    func refocus() {
        if panel.isVisible { panel.makeKey() }
    }

    func windowDidResignKey(_ notification: Notification) {
        if !suppressAutoHide { hide() }
    }

    private func resize(to height: CGFloat) {
        var frame = panel.frame
        guard frame.height != height else { return }
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    private func frame(anchor: NSRect?, height: CGFloat) -> NSRect {
        let screen = anchor.flatMap { a in NSScreen.screens.first { $0.frame.contains(a.origin) } }
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = SearchView.windowWidth
        let top = anchor.map { $0.minY + 2 } ?? visible.maxY - visible.height * 0.18
        let midX = anchor?.midX ?? visible.midX
        let x = min(max(midX - width / 2, visible.minX), visible.maxX - width)
        return NSRect(x: x, y: max(top - height, visible.minY), width: width, height: height)
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.panel else { return false }
                return self.handle(event)
            }
            return handled ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case kVK_DownArrow:
            model.move(1)
            return true
        case kVK_UpArrow:
            model.move(-1)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            model.submit(mods.contains(.shift) ? .export : mods.contains(.option) ? .dotenv : .value)
            return true
        case kVK_Escape:
            if model.query.isEmpty { hide() } else { model.query = "" }
            return true
        default:
            break
        }

        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == .control {
            switch key {
            case "n": model.move(1); return true
            case "p": model.move(-1); return true
            default: return false
            }
        }
        guard mods == .command else { return false }
        switch key {
        case "n": model.onNew(model.query)
        case "e": model.editSelected()
        case "o": model.onManage()
        case ",": model.onSettings()
        case "l": model.lock.lock()
        default: return false
        }
        return true
    }
}

struct SearchView: View {
    @Bindable var model: SearchModel
    @FocusState private var focused: Bool

    static let margin: CGFloat = 18
    static let barHeight: CGFloat = 50
    static let gap: CGFloat = 10
    static let rowHeight: CGFloat = 42
    static let headerHeight: CGFloat = 30
    static let listInset: CGFloat = 6
    static let emptyHeight: CGFloat = 76
    static let maxVisibleRows = 6
    static let contentWidth: CGFloat = 540
    static var windowWidth: CGFloat { contentWidth + margin * 2 }

    static func height(for count: Int) -> CGFloat {
        let results = count == 0
            ? emptyHeight
            : headerHeight + CGFloat(min(count, maxVisibleRows)) * rowHeight + listInset
        return margin * 2 + barHeight + gap + results
    }

    var body: some View {
        let results = model.results
        GlassEffectContainer(spacing: Self.gap) {
            VStack(spacing: Self.gap) {
                HStack(spacing: Self.gap) {
                    searchBar
                    addButton
                }
                resultsPanel(results)
            }
        }
        .padding(Self.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { focused = true }
        .onChange(of: model.presentCount) { focused = true }
        .onChange(of: results.count) { _, count in model.onHeightChange(Self.height(for: count)) }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search Tokens", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused($focused)
            if model.lock.isEnabled {
                Button {
                    if model.lock.isUnlocked { model.lock.lock() }
                } label: {
                    Image(systemName: model.lock.isUnlocked ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.lock.isUnlocked ? "Unlocked — click to lock" : "Locked — Touch ID is required to copy")
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .frame(height: Self.barHeight)
        .glassEffect(.regular, in: .capsule)
    }

    private var addButton: some View {
        Button {
            model.onNew(model.query.trimmingCharacters(in: .whitespaces))
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .medium))
                .frame(width: Self.barHeight, height: Self.barHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help("New Token")
    }

    private func resultsPanel(_ results: [Token]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty {
                emptyState
            } else {
                sectionHeader
                list(results)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
    }

    private var sectionHeader: some View {
        HStack {
            if let message = model.message {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            } else {
                Text(sectionTitle).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
        .frame(height: Self.headerHeight, alignment: .bottom)
    }

    private var sectionTitle: String {
        if !model.query.isEmpty { return "Tokens" }
        return model.store.usage.isEmpty ? "All Tokens" : "Recently Used"
    }

    private func list(_ results: [Token]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, token in
                        TokenRow(token: token, selected: index == model.selection)
                            .id(token.id)
                            .onTapGesture {
                                model.selection = index
                                model.submit(.value)
                            }
                    }
                }
                .padding(.horizontal, Self.listInset)
                .padding(.bottom, Self.listInset)
            }
            .scrollIndicators(results.count > Self.maxVisibleRows ? .automatic : .never)
            .onChange(of: model.selection) { _, index in
                if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 3) {
            if let error = model.store.loadError {
                Text("Couldn't Read Keychain").font(.system(size: 13, weight: .semibold))
                Text(error).foregroundStyle(.secondary).lineLimit(1)
            } else if model.store.tokens.isEmpty {
                Text("No Tokens").font(.system(size: 13, weight: .semibold))
                Text("Press Return or click + to add your first token.").foregroundStyle(.secondary)
            } else {
                Text("No Results for “\(model.query)”").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("Press Return to add it as a new token.").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TokenRow: View {
    let token: Token
    let selected: Bool

    var body: some View {
        let expiry = token.expiry()
        HStack(spacing: 11) {
            Monogram(name: token.name, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(token.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(token.variableName).font(.system(size: 11, design: .monospaced))
                    if !token.tags.isEmpty {
                        Text("·")
                        Text(token.tags.joined(separator: ", "))
                    }
                    if let label = expiry.label {
                        Text("·")
                        Text(label).foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(expiry.tint))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if selected {
                HStack(spacing: 4) {
                    Text("Copy")
                    Image(systemName: "return")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            }
        }
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .frame(height: SearchView.rowHeight)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }
}

@MainActor @Observable
final class HUDModel {
    var title = ""
    var subtitle = ""
}

@MainActor
final class CopyHUD {
    private let panel: NSPanel
    private let model = HUDModel()
    private var hideTask: Task<Void, Never>?
    private let size = NSSize(width: 360, height: 96)

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let hosting = NSHostingView(rootView: HUDView(model: model))
        hosting.sizingOptions = []
        panel.contentView = hosting
    }

    func show(title: String, subtitle: String) {
        model.title = title
        model.subtitle = subtitle
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - visible.height * 0.18 - size.height))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled, let self else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                self.panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            self.panel.orderOut(nil)
        }
    }
}

struct HUDView: View {
    let model: HUDModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white, .green)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title).font(.system(size: 13, weight: .semibold))
                Text(model.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 22)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
