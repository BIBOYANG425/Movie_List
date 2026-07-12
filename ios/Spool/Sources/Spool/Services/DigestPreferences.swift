import Foundation

/// How often Chris sends his "daily reel". Mirrors the DB CHECK on
/// `agent_preferences.trade_digest_cadence` exactly (`daily` / `weekly` / `off`);
/// the raw values ARE the stored strings so the picker and the payload never drift.
public enum DigestCadence: String, CaseIterable, Sendable, Equatable {
    case daily
    case weekly
    case off

    /// L10n key for the picker segment label. The sheet resolves it; the enum
    /// never owns UI strings.
    public var labelKey: String {
        switch self {
        case .daily:  return "digest.cadenceDaily"
        case .weekly: return "digest.cadenceWeekly"
        case .off:    return "digest.cadenceOff"
        }
    }
}

/// The user's Chris-reel settings — pure value type mirroring one
/// `agent_preferences` row. Holds the contract DEFAULTS (daily @ 9) so a user with
/// no row still renders a sensible control. `timezone` is read back for
/// completeness but is always re-stamped from the device on save, so the UI never
/// edits it directly.
///
/// Header last reviewed: 2026-07-12
public struct DigestPreferences: Sendable, Equatable {
    public var cadence: DigestCadence
    public var hour: Int
    public var timezone: String

    /// Contract defaults from the migration: daily, 9am, LA. Used when the user
    /// has no row yet.
    public static let defaults = DigestPreferences(
        cadence: .daily, hour: 9, timezone: "America/Los_Angeles"
    )

    public init(cadence: DigestCadence, hour: Int, timezone: String) {
        self.cadence = cadence
        self.hour = Self.clampHour(hour)
        self.timezone = timezone
    }

    /// Build from a decoded DB row, tolerating an unknown cadence string (a future
    /// server value never crashes an old client — it falls back to the default
    /// cadence) and clamping the hour into 0...23.
    init(row: DigestPreferencesRow) {
        self.cadence = DigestCadence(rawValue: row.trade_digest_cadence) ?? DigestPreferences.defaults.cadence
        self.hour = Self.clampHour(row.digest_hour)
        self.timezone = row.timezone
    }

    /// Clamp an hour into the DB's 0...23 CHECK range. Defensive — the picker only
    /// ever offers valid hours, but a bad server value must not escape the range.
    public static func clampHour(_ hour: Int) -> Int {
        min(23, max(0, hour))
    }
}

// MARK: - Hour label (pure formatting)

/// Pure formatting for the delivery-hour control ("arrives around 9am"). Kept
/// separate + pure so the 12-hour / am-pm / midnight-noon edge cases are unit
/// tested with no view. English uses `9am` / `12pm`; the sheet wraps it with the
/// localized "arrives around {hour}" frame so zh reads naturally.
public enum DigestHour {
    /// The full 0...23 range the wheel offers.
    public static let all: [Int] = Array(0...23)

    /// A short 12-hour clock label for `hour` (0...23): `12am`, `9am`, `12pm`,
    /// `5pm`. Out-of-range input is clamped first (never crashes on a bad value).
    public static func clockLabel(_ hour: Int) -> String {
        let h = DigestPreferences.clampHour(hour)
        let suffix = h < 12 ? "am" : "pm"
        let twelve = h % 12 == 0 ? 12 : h % 12
        return "\(twelve)\(suffix)"
    }
}
