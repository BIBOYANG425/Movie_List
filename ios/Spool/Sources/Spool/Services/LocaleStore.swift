import Foundation
import SwiftUI

/// App language. Two cases mirror the web `Locale` union (`'en' | 'zh'`,
/// contexts/LanguageContext.tsx) so the iOS and web copy tables stay in
/// lock-step. `RawRepresentable: String` so it rides the same raw-string
/// `@AppStorage` contract the theme preference uses (`ThemePreference`,
/// SpoolTokens.swift) — no bespoke `ObservableObject` needed.
public enum SpoolLocale: String, CaseIterable, Sendable {
    case en
    case zh

    /// Map a BCP-47 / device preferred-language identifier to a locale.
    /// Anything starting `zh` (zh-Hans, zh-Hant, zh-CN, …) is Chinese; every
    /// other language falls back to English. Case-insensitive.
    public static func from(languageCode identifier: String) -> SpoolLocale {
        identifier.lowercased().hasPrefix("zh") ? .zh : .en
    }

    /// The locale to seed a fresh install with, derived from the device's
    /// ordered preferred languages. FIRST entry only: if the first language
    /// starts with `zh*` the result is `.zh`, otherwise `.en`. Matches
    /// `TMDBService` / `SuggestionsClient` first-entry semantics exactly so
    /// an en-primary / zh-secondary device is consistently treated as `.en`,
    /// not silently flipped to `.zh` on first read (which would persist via
    /// `LocaleStore.current`'s write-back).
    /// Pure over its input so it is unit-tested with ZERO `UserDefaults` /
    /// `Locale.preferredLanguages` reads.
    public static func deviceDefault(preferredLanguages: [String]) -> SpoolLocale {
        from(languageCode: preferredLanguages.first ?? "")
    }
}

/// Persisted language selection. Single source of truth for `L10n.t`.
///
/// Storage shape: a raw `String` under `spool_locale` in `UserDefaults`,
/// the SAME contract SwiftUI reads via `@AppStorage("spool_locale")` (Task 2's
/// Settings toggle binds a `SpoolLocale`-typed picker to that raw string, exactly
/// as `SpoolAppRoot` does for `spool.theme_preference`). This type is the
/// non-View reader/writer for code paths that can't use `@AppStorage`
/// (`L10n.t`, TMDB/suggestions in Task 2).
///
/// DEFAULT = device preferred language, PERSISTED on first read so the choice
/// is stable forever after (a later OS-language change never silently flips an
/// existing install). `resolve` is the pure decision the persisting `current`
/// getter and its tests share.
///
/// ## Contract for Task 2 (TMDBService / SuggestionsClient)
/// Read `LocaleStore.current` BEFORE any `@AppStorage("spool_locale") = "en"`
/// default assignment on a fresh install. An `@AppStorage` default writes the
/// value into UserDefaults the moment the property wrapper is initialised, which
/// would overwrite the device-default `.zh` (derived and persisted on first read
/// here) with `"en"` — masking the device preference permanently. Always let
/// `LocaleStore.current` pin the default first; only then attach `@AppStorage`
/// consumers.
///
/// ## Contract for Task 3 (view re-render)
/// Any view that calls `L10n.t` MUST also observe the locale so it re-renders on
/// language change. The one canonical pattern: declare a root-level
/// `@AppStorage("spool_locale") var rawLocale: String` (same key as
/// `LocaleStore.storageKey`) and apply `.id(rawLocale)` on the root content
/// view, or read `@AppStorage("spool_locale")` in each affected view. Do NOT
/// read `LocaleStore.current` inside a View body without an `@AppStorage`
/// observation — that bypasses SwiftUI's dependency tracking and the view will
/// NOT re-render on locale switch.
public enum LocaleStore {
    /// UserDefaults key. Bare (no `spool.` dot prefix) to match the web
    /// `STORAGE_KEY` (`'spool_locale'`, LanguageContext.tsx) so a shared
    /// account reads the same slot conceptually on both clients.
    public static let storageKey = "spool_locale"

    /// The active locale. Reads the persisted value; on a fresh install
    /// (no stored value) it computes the device default, WRITES it back, and
    /// returns it — so every subsequent read is stable regardless of later
    /// OS-language changes.
    public static var current: SpoolLocale {
        get {
            let defaults = UserDefaults.standard
            let stored = defaults.string(forKey: storageKey)
            let (locale, shouldPersist) = resolve(
                stored: stored,
                preferredLanguages: Locale.preferredLanguages
            )
            if shouldPersist {
                defaults.set(locale.rawValue, forKey: storageKey)
            }
            return locale
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
        }
    }

    /// Testable overload of `current`'s read-side logic. Accepts an injected
    /// `UserDefaults` suite (e.g. `UserDefaults(suiteName: UUID().uuidString)`)
    /// and preferred-language list so tests exercise the persist write-back path
    /// without touching `UserDefaults.standard` or `Locale.preferredLanguages`.
    @discardableResult
    static func readCurrent(
        defaults: UserDefaults,
        preferredLanguages: [String]
    ) -> SpoolLocale {
        let stored = defaults.string(forKey: storageKey)
        let (locale, shouldPersist) = resolve(stored: stored, preferredLanguages: preferredLanguages)
        if shouldPersist {
            defaults.set(locale.rawValue, forKey: storageKey)
        }
        return locale
    }

    /// Pure resolution for `current`. Returns the locale to use and whether the
    /// caller should persist it (only true on first read of a fresh install, so
    /// the default gets pinned exactly once).
    ///
    /// - A recognised stored value (`"en"`/`"zh"`) wins and is NOT re-persisted.
    /// - An absent or unrecognised stored value falls back to the device
    ///   default and SIGNALS persistence so it becomes stable.
    static func resolve(
        stored: String?,
        preferredLanguages: [String]
    ) -> (locale: SpoolLocale, shouldPersist: Bool) {
        if let stored, let known = SpoolLocale(rawValue: stored) {
            return (known, false)
        }
        return (SpoolLocale.deviceDefault(preferredLanguages: preferredLanguages), true)
    }
}
