import AppKit
import LocalAuthentication
import Observation

@MainActor @Observable
final class SessionLock {
    private(set) var isUnlocked = false {
        didSet { if isUnlocked != oldValue { onChange?(isUnlocked) } }
    }

    @ObservationIgnored var onChange: ((Bool) -> Void)?
    @ObservationIgnored private var relockTask: Task<Void, Never>?
    @ObservationIgnored private var pending: Task<Bool, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    private let prefs: Preferences

    init(prefs: Preferences) {
        self.prefs = prefs
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            })
        }
    }

    var isEnabled: Bool { prefs.requireUnlock }

    func authorize(reason: String) async -> Bool {
        guard isEnabled else { return true }
        if isUnlocked {
            scheduleRelock()
            return true
        }
        if let pending { return await pending.value }

        let task = Task { await Self.evaluate(reason: reason) }
        pending = task
        let ok = await task.value
        pending = nil
        if ok {
            isUnlocked = true
            scheduleRelock()
        }
        return ok
    }

    func lock() {
        relockTask?.cancel()
        relockTask = nil
        isUnlocked = false
    }

    private func scheduleRelock() {
        relockTask?.cancel()
        let minutes = prefs.lockAfterMinutes
        guard minutes > 0 else { return }
        relockTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            self?.lock()
        }
    }

    nonisolated private static func evaluate(reason: String) async -> Bool {
        let context = LAContext()
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
                continuation.resume(returning: ok)
            }
        }
    }
}
