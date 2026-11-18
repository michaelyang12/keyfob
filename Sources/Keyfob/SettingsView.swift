import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var prefs: Preferences
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Open search panel") {
                    HotKeyRecorder(prefs: prefs)
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Security") {
                Toggle("Require Touch ID to copy", isOn: $prefs.requireUnlock)
                Picker("Stay unlocked", selection: $prefs.lockAfterMinutes) {
                    Text("1 minute").tag(1)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("1 hour").tag(60)
                    Text("Until screen locks").tag(0)
                }
                .disabled(!prefs.requireUnlock)
            }

            Section {
                Picker("Clear clipboard after", selection: $prefs.clearClipboardAfter) {
                    Text("10 seconds").tag(10)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("Never").tag(0)
                }
            } footer: {
                Text("Copied tokens are marked concealed so clipboard managers skip them. The clipboard is only cleared if it still holds the token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
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
    }
}

struct HotKeyRecorder: View {
    @Bindable var prefs: Preferences
    @State private var monitor: Any?

    var body: some View {
        Button {
            prefs.isRecordingHotKey ? stop() : start()
        } label: {
            Text(prefs.isRecordingHotKey ? "Type shortcut…" : prefs.hotKey.display)
                .font(.system(.body, design: .rounded).weight(.medium))
                .frame(minWidth: 110)
        }
        .onDisappear { stop() }
    }

    private func start() {
        prefs.isRecordingHotKey = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { capture(event) }
            return nil
        }
    }

    private func capture(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            stop()
            return
        }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !mods.intersection([.command, .option, .control]).isEmpty else {
            NSSound.beep()
            return
        }
        prefs.hotKey = HotKeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods.rawValue, key: HotKeyCombo.keyName(for: event))
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if prefs.isRecordingHotKey { prefs.isRecordingHotKey = false }
    }
}
