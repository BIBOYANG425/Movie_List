import Foundation

/// Pure decision helpers for `FeedScreen` and `NotificationBellView` — the
/// view-layer logic that could drift or regress, lifted out of the SwiftUI
/// body so it is XCTest-covered (FeedScreenLogicTests) instead of eyeballed in
/// a preview.
///
/// Nothing here touches SwiftUI, the network, or a clock: every function is a
/// pure map over its inputs.
///
/// Contract: docs/plans/2026-07-08-c1-ios-feed-ui-plan.md (Task 5).

// MARK: - Feed pagination + type set

public enum FeedScreenLogic {

    /// The event-type allow-set the feed requests. The filter UI is deferred
    /// (ledger fast-follow), so today the feed always asks for the whole
    /// contract set — every card kind coerces to one of these upstream, and
    /// an empty allow-set would drop everything. Kept as a named constant so
    /// the "no filter yet" decision is explicit, not an inline literal.
    public static let allEventTypes: Set<String> = [
        "ranking_add", "ranking_move", "review", "milestone", "list_create",
    ]

    /// Infinite-scroll trigger: should the row that just appeared kick off the
    /// next page fetch? True only when it is the LAST card, the stream has
    /// more, and no load is already in flight (the concurrency guard — the
    /// caller also flips `isLoading` before awaiting, so two near-simultaneous
    /// `.onAppear`s can't both pass).
    ///
    /// `appearedIndex`/`lastIndex` are the card's position and the final
    /// index; a negative or mismatched index (empty list, stale row) returns
    /// false rather than firing a spurious load.
    public static func shouldLoadNextPage(appearedIndex: Int,
                                          lastIndex: Int,
                                          hasMore: Bool,
                                          isLoading: Bool) -> Bool {
        guard hasMore, !isLoading else { return false }
        guard lastIndex >= 0, appearedIndex == lastIndex else { return false }
        return true
    }
}

// MARK: - Notification row → destination

/// Where tapping a notification row should take the viewer. Only the follower
/// kind routes in v1; everything else is inert (journal_tag deep-links are
/// ledgered to C2-iOS, the rest have no iOS destination yet). Kept pure +
/// tested so the routing table can't silently regress.
public enum NotificationDestination: Equatable, Sendable {
    /// Open the actor's profile (follower rows). Carries the actor id the
    /// caller turns into a `Friend`/`FriendProfileScreen` route.
    case actorProfile(UUID)
    /// No navigation — the row is informational in v1.
    case none

    /// Map one rendered notification to its tap destination. A follower row
    /// with a known actor opens that profile; a follower row missing its
    /// actor id (shouldn't happen, but the field is optional) and every other
    /// kind is inert.
    public static func destination(for item: NotificationItem) -> NotificationDestination {
        switch item.kind {
        case .newFollower:
            guard let actor = item.actorID else { return .none }
            return .actorProfile(actor)
        case .reviewLike, .listLike, .badgeUnlock, .rankingComment, .journalTag:
            return .none
        }
    }
}
