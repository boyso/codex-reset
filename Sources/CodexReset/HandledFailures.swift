import Foundation

/// Remember successful resume submissions by failed turn, not by conversation.
final class HandledFailures {
    private static let storageKey = "handledUsageLimitFailuresV1"
    private let defaults: UserDefaults
    private let maxEntries: Int
    private var recentKeys: [String]
    private var knownKeys: Set<String>

    init(defaults: UserDefaults = .standard, maxEntries: Int = 500) {
        self.defaults = defaults
        self.maxEntries = max(1, maxEntries)
        let saved = defaults.stringArray(forKey: Self.storageKey) ?? []
        recentKeys = Array(saved.suffix(self.maxEntries))
        knownKeys = Set(recentKeys)
    }

    private func key(threadId: String, failedTurnId: String?) -> String? {
        guard let failedTurnId, !failedTurnId.isEmpty else { return nil }
        return "\(threadId):\(failedTurnId)"
    }

    func contains(threadId: String, failedTurnId: String?) -> Bool {
        guard let key = key(threadId: threadId, failedTurnId: failedTurnId) else { return false }
        return knownKeys.contains(key)
    }

    func record(threadId: String, failedTurnId: String?) {
        guard let key = key(threadId: threadId, failedTurnId: failedTurnId),
              knownKeys.insert(key).inserted else { return }
        recentKeys.append(key)
        if recentKeys.count > maxEntries {
            recentKeys.removeFirst(recentKeys.count - maxEntries)
            knownKeys = Set(recentKeys)
        }
        defaults.set(recentKeys, forKey: Self.storageKey)
    }
}
