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

    private let width: CGFloat = 480

    init(model: SearchModel) {
        self.model = model
        panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
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
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor

        let hosting = NSHostingView(rootView: SearchView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.sizingOptions = []
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
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

    private func resize(to height: CGFloat) {
        var frame = panel.frame
        guard frame.height != height else { return }
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        if !suppressAutoHide { hide() }
    }

    private func frame(anchor: NSRect?, height: CGFloat) -> NSRect {
        let screen = anchor.flatMap { a in NSScreen.screens.first { $0.frame.contains(a.origin) } }
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let top = anchor.map { $0.minY - 6 } ?? visible.maxY - visible.height * 0.2
        let midX = anchor?.midX ?? visible.midX
        let x = min(max(midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        return NSRect(x: x, y: max(top - height, visible.minY + 8), width: width, height: height)
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

    static let headerHeight: CGFloat = 44
    static let footerHeight: CGFloat = 26
    static let rowHeight: CGFloat = 38
    static let maxVisibleRows = 6
    static let emptyHeight: CGFloat = 92

    static func height(for count: Int) -> CGFloat {
        let body = count == 0
            ? emptyHeight
            : CGFloat(min(count, maxVisibleRows)) * (rowHeight + 2) + 8
        return headerHeight + body + footerHeight + 2
    }

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
        .onChange(of: results.count) { _, count in model.onHeightChange(Self.height(for: count)) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search tokens", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($focused)
            if model.lock.isEnabled {
                Button {
                    if model.lock.isUnlocked { model.lock.lock() }
                } label: {
                    Image(systemName: model.lock.isUnlocked ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(model.lock.isUnlocked ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.lock.isUnlocked ? "Unlocked. Click or press ⌘L to lock." : "Locked. Touch ID is required to copy.")
            }
            Button {
                model.onNew(model.query.trimmingCharacters(in: .whitespaces))
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New token (⌘N)")
        }
        .padding(.horizontal, 14)
        .frame(height: Self.headerHeight)
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
                .padding(4)
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
                Text("Couldn't read the keychain").font(.system(size: 13, weight: .semibold))
                Text(error).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
            } else if model.store.tokens.isEmpty {
                Text("No tokens yet").font(.system(size: 13, weight: .semibold))
                Text("Click + or press ↩ to add one").foregroundStyle(.secondary)
            } else {
                Text("No match for “\(model.query)”").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("Press ↩ or + to add it").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 20)
    }

    private func footer(count: Int) -> some View {
        HStack(spacing: 10) {
            if let message = model.message {
                Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            } else {
                KeyHint("↩", "Copy")
                KeyHint("⇧↩", "export")
                KeyHint("⌘E", "Edit")
            }
            Spacer()
            Text("\(count) of \(model.store.tokens.count)")
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 12)
        .frame(height: Self.footerHeight)
    }
}

struct TokenRow: View {
    let token: Token
    let usage: Usage?
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Monogram(name: token.name, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(token.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    ExpiryBadge(expiry: token.expiry())
                }
                Text(token.variableName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            ForEach(token.tags.prefix(2), id: \.self) { TagChip(tag: $0) }
            if let usage {
                Text(usage.lastUsed, format: .relative(presentation: .named))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: SearchView.rowHeight)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.22))
            }
        }
        .contentShape(Rectangle())
    }
}
