import AppKit
import Carbon.HIToolbox
import Observation

struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt
    var key: String

    static let standard = HotKeyCombo(
        keyCode: UInt32(kVK_ANSI_K),
        modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue,
        key: "K"
    )

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + key
    }

    static func keyName(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Delete: "⌫"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        default: fKeys[Int(event.keyCode)] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }

    private static let fKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

@MainActor @Observable
final class Preferences {
    private enum Keys {
        static let hotKey = "hotKey"
        static let requireUnlock = "requireUnlock"
        static let lockAfter = "lockAfterMinutes"
        static let clearAfter = "clearClipboardAfter"
    }

    private let defaults = UserDefaults.standard
    @ObservationIgnored var onHotKeyChange: ((HotKeyCombo?) -> Void)?

    var hotKey: HotKeyCombo {
        didSet {
            if let data = try? JSONEncoder().encode(hotKey) { defaults.set(data, forKey: Keys.hotKey) }
            onHotKeyChange?(hotKey)
        }
    }

    var isRecordingHotKey = false {
        didSet { onHotKeyChange?(isRecordingHotKey ? nil : hotKey) }
    }

    var requireUnlock: Bool {
        didSet { defaults.set(requireUnlock, forKey: Keys.requireUnlock) }
    }

    var lockAfterMinutes: Int {
        didSet { defaults.set(lockAfterMinutes, forKey: Keys.lockAfter) }
    }

    var clearClipboardAfter: Int {
        didSet { defaults.set(clearClipboardAfter, forKey: Keys.clearAfter) }
    }

    init() {
        defaults.register(defaults: [
            Keys.requireUnlock: true,
            Keys.lockAfter: 15,
            Keys.clearAfter: 30,
        ])
        hotKey = defaults.data(forKey: Keys.hotKey)
            .flatMap { try? JSONDecoder().decode(HotKeyCombo.self, from: $0) } ?? .standard
        requireUnlock = defaults.bool(forKey: Keys.requireUnlock)
        lockAfterMinutes = defaults.integer(forKey: Keys.lockAfter)
        clearClipboardAfter = defaults.integer(forKey: Keys.clearAfter)
    }
}
