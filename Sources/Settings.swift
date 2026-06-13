import Foundation

/// User-configurable preferences, persisted in UserDefaults. Defaults preserve the original
/// hardcoded behavior (50% alert threshold, 15-minute refresh).
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let alertThreshold = "alertThreshold"
        static let refreshIntervalMinutes = "refreshIntervalMinutes"
    }

    /// Alert threshold as a percentage (0–100). Metrics above this trigger alerts.
    var alertThreshold: Double {
        get {
            let v = defaults.double(forKey: Key.alertThreshold)
            return v == 0 ? 50 : v  // 0 means "never set" → default 50
        }
        set { defaults.set(newValue, forKey: Key.alertThreshold) }
    }

    /// Auto-refresh interval in minutes.
    var refreshIntervalMinutes: Int {
        get {
            let v = defaults.integer(forKey: Key.refreshIntervalMinutes)
            return v == 0 ? 15 : v
        }
        set { defaults.set(newValue, forKey: Key.refreshIntervalMinutes) }
    }

    /// Refresh interval in seconds, for the timer.
    var refreshIntervalSeconds: TimeInterval { TimeInterval(refreshIntervalMinutes * 60) }

    /// Selectable options surfaced in the menu.
    static let thresholdOptions: [Double] = [50, 60, 70, 75, 80, 90]
    static let intervalOptions: [Int] = [1, 5, 15, 30, 60]
}
