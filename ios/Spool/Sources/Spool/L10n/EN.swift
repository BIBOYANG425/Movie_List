import Foundation

/// English string table — the CANONICAL key set. Every key here MUST exist in
/// `ZH.table` (enforced by `L10nParityTests`), the Swift analogue of web's
/// `zh satisfies Record<TranslationKey, string>` type check (i18n/zh.ts).
///
/// Seeded with ~10 REAL in-app strings lifted from `BottomNav` (tab labels +
/// the rank-button accessibility label) and live toast copy, so the mechanism
/// is proven against actual UI. Task 3 does the full copy sweep; add keys here
/// FIRST, then their zh in `ZH.table`.
public enum EN {
    public static let table: [String: String] = [
        // Bottom nav tab labels (BottomNav.swift `tabButton` labels).
        "nav.feed": "feed",
        "nav.stubs": "stubs",
        "nav.queue": "queue",
        "nav.friends": "friends",
        "nav.me": "me",

        // Bottom nav floating "+" accessibility label (BottomNav.swift).
        "nav.rankNew": "Rank a new movie",

        // Rank flow toasts (RankH2H / rank persistence sites).
        "toast.rankSaveFailed": "couldn't save your rank — check connection",
        "toast.reRankFailed": "couldn't re-rank this show — try again",

        // Ranking-management confirm (carries a {label} token — proves
        // interpolation + placeholder-set parity with zh; mirrors web
        // 'ranking.resetConfirm').
        "ranking.resetConfirm": "Reset your {label} list? This cannot be undone.",

        // A generic failure toast — verbatim web 'ranking.failedSave' en copy
        // (i18n/en.ts). Em-dash ban is zh-only; en value is faithful to web.
        "toast.saveFailed": "Failed to save — please try again",

        // Settings → language row (C6-iOS Task 2). Web has no settings.* keys yet,
        // so these are iOS-first; the two option labels reuse the web
        // `LanguageToggle` glyphs ('EN' / '中文', components/shared/LanguageToggle.tsx)
        // verbatim so both surfaces name the languages identically.
        "settings.language": "language",
        "settings.languageEnglish": "EN",
        "settings.languageChinese": "中文",
    ]
}
