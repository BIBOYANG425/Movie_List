import Foundation

/// String-table lookup seam. iOS port of the web `t()` (contexts/LanguageContext.tsx).
///
/// Fallback order is IDENTICAL to web: active locale → `en` → the key itself.
/// A missing zh string shows the English copy (never a blank); a key missing
/// from BOTH tables surfaces the raw key (loud, so it gets noticed and added).
///
/// Keys live in `EN.table` / `ZH.table` (EN.swift / ZH.swift). Task 3 does the
/// big copy sweep; `L10nParityTests` enforces both tables carry the same keys,
/// so `t` can trust `EN.table` as the canonical key set.
public enum L10n {
    /// Look up `key` for the current locale, falling back zh → en → key.
    public static func t(_ key: String) -> String {
        t(key, locale: LocaleStore.current)
    }

    /// Interpolating overload. Replaces every `{token}` in the resolved string
    /// with `replacements["token"]`. Mirrors the web `.replace('{token}', v)`
    /// chains (e.g. RankingPage `resetConfirm`) with one clean pass so callers
    /// don't hand-roll replacement per token.
    public static func t(_ key: String, _ replacements: [String: String]) -> String {
        interpolate(t(key, locale: LocaleStore.current), replacements)
    }

    /// Pure lookup used by both public overloads and the tests. `locale` is
    /// explicit so fallback semantics are asserted with no `UserDefaults` read.
    static func t(_ key: String, locale: SpoolLocale) -> String {
        t(key, locale: locale, zhTable: ZH.table, enTable: EN.table)
    }

    /// Injectable-table overload. Accepts caller-supplied zh/en dictionaries so
    /// tests can drive the fallback chain (zh-missing → en; both-missing → key;
    /// interpolation on the fixture path) without touching the real tables and
    /// without parity constraints forcing every key to exist in both tables.
    /// The public `t(_:locale:)` delegates here with the real tables.
    static func t(
        _ key: String,
        locale: SpoolLocale,
        zhTable: [String: String],
        enTable: [String: String]
    ) -> String {
        let primary: [String: String] = locale == .zh ? zhTable : enTable
        return primary[key] ?? enTable[key] ?? key
    }

    /// Pure `{token}` substitution. Unknown tokens in the string are left
    /// untouched; unused replacement entries are ignored.
    static func interpolate(_ template: String, _ replacements: [String: String]) -> String {
        var result = template
        for (token, value) in replacements {
            result = result.replacingOccurrences(of: "{\(token)}", with: value)
        }
        return result
    }

    private static func table(for locale: SpoolLocale) -> [String: String] {
        switch locale {
        case .en: return EN.table
        case .zh: return ZH.table
        }
    }
}
