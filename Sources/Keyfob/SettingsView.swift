import AppKit
import Carbon.HIToolbox
import Observation
import ServiceManagement
import SwiftUI

@MainActor @Observable
final class SettingsModel {
    let prefs: Preferences
    let lock: SessionLock
    var openAtLogin = SMAppService.mainApp.status == .enabled
    var loginError: String?
    @ObservationIgnored private var monitor: Any?

    init(prefs: Preferences, lock: SessionLock) {
        self.prefs = prefs
        self.lock = lock
    }

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func toggleRecording() {
        prefs.isRecordingHotKey ? stopRecording() : startRecording()
    }

    private func startRecording() {
        prefs.isRecordingHotKey = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.capture(event) }
            return nil
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if prefs.isRecordingHotKey { prefs.isRecordingHotKey = false }
    }

    private func capture(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            stopRecording()
            return
        }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !mods.intersection([.command, .option, .control]).isEmpty else {
            NSSound.beep()
            return
        }
        prefs.hotKey = HotKeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods.rawValue, key: HotKeyCombo.keyName(for: event))
        stopRecording()
    }
}

struct GeneralSettingsView: View {
    @Bindable var settings: SettingsModel

    var body: some View {
        @Bindable var prefs = settings.prefs
        Form {
            Section {
                LabeledContent("Search shortcut") {
                    Button {
                        settings.toggleRecording()
                    } label: {
                        Text(settings.prefs.isRecordingHotKey ? "Press Shortcut…" : settings.prefs.hotKey.display)
                            .monospacedDigit()
                            .frame(minWidth: 96)
                    }
                    .help("Click, then press a new key combination. Press Esc to cancel.")
                }
                Toggle("Open at Login", isOn: Binding(
                    get: { settings.openAtLogin },
                    set: { settings.setOpenAtLogin($0) }
                ))
            } footer: {
                if let error = settings.loginError {
                    Text(error).foregroundStyle(.red)
                }
            }

            Section {
                Picker("Clear Clipboard", selection: $prefs.clearClipboardAfter) {
                    Text("After 10 Seconds").tag(10)
                    Text("After 30 Seconds").tag(30)
                    Text("After 1 Minute").tag(60)
                    Text("After 2 Minutes").tag(120)
                    Text("Never").tag(0)
                }
            } footer: {
                Text("Copied tokens are hidden from clipboard managers, and the clipboard is only cleared if it still holds the token.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { settings.stopRecording() }
    }
}

struct SecuritySettingsView: View {
    @Bindable var settings: SettingsModel

    var body: some View {
        @Bindable var prefs = settings.prefs
        Form {
            Section {
                Toggle("Require Touch ID to Copy", isOn: $prefs.requireUnlock)
                Picker("Lock Again", selection: $prefs.lockAfterMinutes) {
                    Text("After 1 Minute").tag(1)
                    Text("After 5 Minutes").tag(5)
                    Text("After 15 Minutes").tag(15)
                    Text("After 1 Hour").tag(60)
                    Text("When Screen Locks").tag(0)
                }
                .disabled(!settings.prefs.requireUnlock)
            } footer: {
                Text("keyfob also locks when your Mac sleeps or the screen locks.")
            }

            Section {
                LabeledContent("Status") {
                    Label(
                        settings.lock.isUnlocked ? "Unlocked" : "Locked",
                        systemImage: settings.lock.isUnlocked ? "lock.open.fill" : "lock.fill"
                    )
                    .foregroundStyle(settings.lock.isUnlocked ? .orange : .secondary)
                }
                Button("Lock Now") { settings.lock.lock() }
                    .disabled(!settings.lock.isUnlocked)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
