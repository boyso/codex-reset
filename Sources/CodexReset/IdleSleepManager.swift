import Foundation

/// Pure decision logic, kept separate from macOS power management for testing.
enum IdleSleepPolicy {
    static func shouldPreventIdleSleep(
        enabled: Bool,
        autoContinueEnabled: Bool,
        hasSelectedQuotaFailure: Bool,
        hasSelectedRunningTurn: Bool,
        isSendingContinue: Bool
    ) -> Bool {
        enabled && autoContinueEnabled &&
            (hasSelectedQuotaFailure || hasSelectedRunningTurn || isSendingContinue)
    }
}

/// Holds a macOS process activity only while an opted-in, selected conversation
/// needs to wait for quota or finish its resumed turn.
/// This blocks *idle system sleep*, not display sleep, lid-close or explicit sleep.
@MainActor
final class IdleSleepManager {
    private var activity: NSObjectProtocol?

    var isActive: Bool { activity != nil }

    /// Returns true only when the held assertion changes.
    @discardableResult
    func setActive(_ shouldBeActive: Bool) -> Bool {
        if shouldBeActive {
            guard activity == nil else { return false }
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "CodexReset: waiting for a selected Codex task to resume or finish"
            )
            return true
        }

        guard let activity else { return false }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
        return true
    }

    func stop() {
        setActive(false)
    }
}
