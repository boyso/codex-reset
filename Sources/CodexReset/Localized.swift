import Foundation

/// 语言设置：跟随系统 / 强制中文 / 强制英文（面板「设置」里可切换，存 UserDefaults）
enum LanguageSetting: String {
    case system = "system"
    case zh = "zh"
    case en = "en"

    static var current: LanguageSetting {
        LanguageSetting(rawValue: UserDefaults.standard.string(forKey: "language") ?? "system") ?? .system
    }
}

/// 轻量本地化：返回中/英文文案
/// - 默认跟随系统：系统语言以 zh 开头 → 中文，否则英文
/// - 可在「设置」里强制 中文 或 English
func L(_ zh: String, _ en: String) -> String {
    switch LanguageSetting.current {
    case .zh: return zh
    case .en: return en
    case .system:
        let isZH = Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
        return isZH ? zh : en
    }
}
