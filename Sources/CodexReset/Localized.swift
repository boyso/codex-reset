import Foundation

/// Always display built-in messages in English, regardless of macOS language.
/// Retain the legacy two-argument helper for existing UI and log call sites.
func L(_ legacyChinese: String, _ english: String) -> String {
    english
}

/// Migrate only the old Chinese default; preserve user-customized commands.
func englishContinueCommand(_ saved: String?) -> String {
    guard let saved else { return "Continue" }
    return saved == "继续" ? "Continue" : saved
}
