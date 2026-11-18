import AppKit
import Carbon.HIToolbox
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

    private let size = NSSize(width: 640, height: 420)

    init(model: SearchModel) {
        self.model = model
        panel = KeyPanel(
            contentRect: NSRect(origin: .zero, size: size),
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
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor

        let hosting = NSHostingView(rootView: SearchView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
    }

    var isVisible: Bool { panel.isVisible }
    var canReopen: Bool { Date().timeIntervalSince(lastHidden) > 0.3 }

    func show(anchor: NSRect?) {
        panel.setFrame(frame(anchor: anchor), display: false)
        model.prepareForPresent()
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

    private func frame(anchor: NSRect?) -> NSRect {
        let screen = anchor.flatMap { a in NSScreen.screens.first { $0.frame.contains(a.origin) } }
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var origin: NSPoint
        if let anchor {
            origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6)
        } else {
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - visible.height * 0.2 - size.height)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = max(origin.y, visible.minY + 8)
        return NSRect(origin: origin, size: size)
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
        case "n":
            model.onNew(model.query)
        case "e":
            model.editSelected()
        case "o":
            model.onManage()
        case ",":
            model.onSettings()
        case "l":
            model.lock.lock()
        default:
            return false
        }
        return true
    }
}

struct SearchView: View {
    @Bindable var model: SearchModel
    @FocusState private var focused: Bool

    var body: some View {
        let results = model.results
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            Group {
                if results.isEmpty { emptyState } else { list(results) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.6)
            footer(count: results.count)
        }
        .onAppear { focused = true }
        .onChange(of: model.presentCount) { focused = true }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search tokens", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 21))
                .focused($focused)
            if model.lock.isEnabled {
                Button {
                    if model.lock.isUnlocked { model.lock.lock() }
                } label: {
                    Image(systemName: model.lock.isUnlocked ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(model.lock.isUnlocked ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(model.lock.isUnlocked ? "Unlocked. Click or press ⌘L to lock." : "Locked. Touch ID is required to copy.")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private func list(_ results: [Token]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, token in
                        TokenRow(token: token, usage: model.store.usage[token.id], selected: index == model.selection)
                            .id(token.id)
                            .onTapGesture {
                                model.selection = index
                                model.submit(.value)
                            }
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selection) { _, index in
                if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            if let error = model.store.loadError {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 26)).foregroundStyle(.orange)
                Text("Couldn't read the keychain").font(.headline)
                Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else if model.store.tokens.isEmpty {
                Image(systemName: "key.horizontal").font(.system(size: 26)).foregroundStyle(.tertiary)
                Text("No tokens yet").font(.headline)
                Text("Press ↩ to add your first one").foregroundStyle(.secondary)
            } else {
                Image(systemName: "magnifyingglass").font(.system(size: 26)).foregroundStyle(.tertiary)
                Text("No match for “\(model.query)”").font(.headline)
                Text("Press ↩ to add it as a new token").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(24)
    }

    private func footer(count: Int) -> some View {
        HStack(spacing: 12) {
            if let message = model.message {
                Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            } else {
                KeyHint("↩", "Copy")
                KeyHint("⇧↩", "export")
                KeyHint("⌥↩", ".env")
                KeyHint("⌘E", "Edit")
                KeyHint("⌘N", "New")
            }
            Spacer()
            Text("\(count) of \(model.store.tokens.count)")
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .frame(height: 32)
    }
}

struct TokenRow: View {
    let token: Token
    let usage: Usage?
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Monogram(name: token.name, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(token.name)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    ExpiryBadge(expiry: token.expiry())
                }
                Text(token.variableName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            ForEach(token.tags.prefix(3), id: \.self) { TagChip(tag: $0) }
            if let usage {
                Text(usage.lastUsed, format: .relative(presentation: .named))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 70, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(0.22))
            }
        }
        .contentShape(Rectangle())
    }
}
