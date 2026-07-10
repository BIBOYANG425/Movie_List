import Foundation

/// Chinese string table. Key set MUST match `EN.table` exactly
/// (`L10nParityTests`), and every `{token}` in an English value MUST appear in
/// its zh counterpart. Owner-voice rule: NO em dashes (— U+2014 / – U+2013 /
/// ― U+2015) — the parity test fails the build if one slips in.
///
/// Nav values reuse the web zh copy (i18n/zh.ts) where the surface matches
/// (feed→动态, queue/watchlist→想看, me/profile→我的) so the two clients read
/// identically for a shared account.
public enum ZH {
    public static let table: [String: String] = [
        // Bottom nav tab labels — reuse web zh nav values where they map.
        "nav.feed": "动态",       // web nav.feed
        "nav.stubs": "票根",
        "nav.queue": "想看",      // web nav.watchlist
        "nav.friends": "好友",
        "nav.me": "我的",         // web nav.profile

        // Rank-button accessibility label.
        "nav.rankNew": "给新电影排名",

        // Rank flow toasts — recast without em dashes.
        "toast.rankSaveFailed": "排名没保存成功，检查一下网络",
        "toast.reRankFailed": "这部剧重新排名失败了，再试一次",

        // Ranking-management confirm — carries the same {label} token as en.
        "ranking.resetConfirm": "重置你的{label}列表？此操作无法撤销。",

        // Generic failure toast — reuse web 'ranking.failedSave'.
        "toast.saveFailed": "保存失败，请重试",
    ]
}
