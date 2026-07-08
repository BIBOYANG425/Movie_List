import Foundation
import SwiftUI

/// The journal LIST state model (plan Task 5) — drives `JournalListView` inside
/// the owner's Stubs tab. `@MainActor final class … ObservableObject`, NOT
/// `@Observable`: the package floor is iOS 16 (Package.swift), so this follows
/// the `FeedFeedModel` / `TicketEngagementModel` / `ToastCenter` precedent.
///
/// ALL IO is injected as closures (same style as `FeedFeedModel`) so `load`,
/// `search`, and the optimistic `toggleLike` are XCTest-covered with ZERO
/// network (`JournalListModelTests`). The screen (`JournalListView`) binds the
/// closures to `JournalRepository.listOwnEntries` / `likedEntryIDs` / `search`
/// / `toggleLike`.
///
/// ── Contract pins (each has a test) ────────────────────────────────────────
///
///  1. BATCH liked-state. `load()` fetches the owner's entries THEN makes ONE
///     `likedEntryIDs(ids)` call over ALL loaded ids — never a per-card probe.
///     Cards read their liked-state from `likedIDs`; a fresh card must never
///     default to "not liked" and drift the count.
///
///  2. OPTIMISTIC toggle. `toggleLike` applies the pure `applyLikeToggle`
///     (count ±1 clamped ≥ 0, liked flips) to the in-memory row + `likedIDs`
///     BEFORE the write, passing the PRE-toggle liked state to the closure; a
///     throw reverts both.
///
///  3. SEARCH vs LIST. A non-empty (trimmed) query → `.search` mode with
///     `searchResults` from the RPC; an empty/whitespace query → `.list` mode
///     (the loaded `entries` are untouched). Reads catch to empty (feed
///     convention) — a failed search yields an empty result set in `.search`
///     mode, a failed list flips `loadFailed`.
///
/// Header last reviewed: 2026-07-07
@MainActor
public final class JournalListModel: ObservableObject {

    /// Which surface the list is showing: the owner's reverse-chron entries, or
    /// live search results.
    public enum Mode: Equatable, Sendable {
        case list
        case search
    }

    // MARK: Injected IO

    /// `JournalRepository.listOwnEntries()` — the owner's rows, newest first.
    public typealias ListOwnEntries = () async throws -> [JournalRow]
    /// `JournalRepository.likedEntryIDs(_:)` — batched liked-state for the page.
    public typealias LikedEntryIDs = ([UUID]) async throws -> Set<UUID>
    /// `JournalRepository.search(_:targetUserID:)` bound to the owner — takes the
    /// raw query, returns the 23-column shared rows.
    public typealias Search = (String) async throws -> [JournalSearchRow]
    /// `JournalRepository.toggleLike(entryID:currentlyLiked:)` — the write; takes
    /// the PRE-toggle liked state.
    public typealias ToggleLike = (UUID, Bool) async throws -> Void

    // MARK: Published state

    /// The owner's reverse-chron entries (list mode). Mutated locally by the
    /// optimistic like toggle so a card's count updates without a reload.
    @Published public private(set) var entries: [JournalRow] = []
    /// Search-mode results (the 23-column shared shape — no `personal_takeaway`).
    @Published public private(set) var searchResults: [JournalSearchRow] = []
    /// The ids this viewer has liked — the single source of a card's like state.
    @Published public private(set) var likedIDs: Set<UUID> = []
    /// list vs search.
    @Published public private(set) var mode: Mode = .list
    /// The initial list load failed; the view shows an empty/quiet state rather
    /// than a crash (feed convention).
    @Published public private(set) var loadFailed: Bool = false
    /// A first load has completed at least once (used by the view to avoid a
    /// one-frame empty-state flash before the first fetch resolves).
    @Published public private(set) var didLoad: Bool = false

    // MARK: Stored

    private let listOwnEntriesIO: ListOwnEntries
    private let likedEntryIDsIO: LikedEntryIDs
    private let searchIO: Search
    private let toggleLikeIO: ToggleLike

    public init(
        listOwnEntries: @escaping ListOwnEntries,
        likedEntryIDs: @escaping LikedEntryIDs,
        search: @escaping Search,
        toggleLike: @escaping ToggleLike
    ) {
        self.listOwnEntriesIO = listOwnEntries
        self.likedEntryIDsIO = likedEntryIDs
        self.searchIO = search
        self.toggleLikeIO = toggleLike
    }

    /// Production init — bind the closures to the real `JournalRepository`.
    /// `targetUserID` for search is the current user (owner-only this cycle);
    /// resolved lazily inside the closure so a signed-out preview stays inert.
    public convenience init() {
        self.init(
            listOwnEntries: {
                try await JournalRepository.shared.listOwnEntries()
            },
            likedEntryIDs: { ids in
                try await JournalRepository.shared.likedEntryIDs(ids)
            },
            search: { query in
                guard let userID = await SpoolClient.currentUserID() else { return [] }
                return try await JournalRepository.shared.search(query, targetUserID: userID)
            },
            toggleLike: { entryID, currentlyLiked in
                try await JournalRepository.shared.toggleLike(entryID: entryID, currentlyLiked: currentlyLiked)
            }
        )
    }

    // MARK: - Load

    /// Load the owner's entries, then batch the liked-state over every loaded id
    /// in ONE call. A list-read failure flips `loadFailed` and leaves the list
    /// empty; a liked-state failure just leaves `likedIDs` empty (no card starts
    /// pre-liked) — both are the feed's fail-soft-to-empty convention.
    public func load() async {
        mode = .list
        do {
            let rows = try await listOwnEntriesIO()
            entries = rows
            loadFailed = false
            // Batch liked-state over the loaded ids — ONE read, never per-card.
            await refreshLikedState(for: rows.map(\.id))
        } catch {
            entries = []
            likedIDs = []
            loadFailed = true
        }
        didLoad = true
    }

    /// The single batched liked-state read. Empty id set short-circuits (no
    /// network); a throw leaves `likedIDs` empty rather than surfacing.
    private func refreshLikedState(for ids: [UUID]) async {
        guard !ids.isEmpty else { likedIDs = []; return }
        do {
            likedIDs = try await likedEntryIDsIO(ids)
        } catch {
            likedIDs = []
        }
    }

    // MARK: - Search

    /// A non-empty (trimmed) query runs the search RPC and enters `.search`
    /// mode; an empty/whitespace query returns to `.list` mode (the loaded
    /// `entries` are left intact). A search failure yields empty results in
    /// `.search` mode (feed convention). The liked-state batch is refreshed over
    /// the result ids so search cards render their like state too.
    public func search(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            mode = .list
            searchResults = []
            await refreshLikedState(for: entries.map(\.id))
            return
        }

        mode = .search
        do {
            let rows = try await searchIO(trimmed)
            searchResults = rows
            await refreshLikedState(for: rows.map(\.id))
        } catch {
            searchResults = []
        }
    }

    // MARK: - Likes (optimistic)

    /// Optimistically toggle the like on `entryID`: apply `applyLikeToggle` to
    /// the in-memory row's count + `likedIDs` FIRST (passing the PRE-toggle liked
    /// state to the write), then persist; a throw reverts both. Works whether the
    /// row lives in `entries` (list) or `searchResults` (search).
    public func toggleLike(entryID: UUID) async {
        // Snapshot the LITERAL pre-toggle state up front. The revert restores
        // this snapshot verbatim — never recomputes it. Recomputing via a second
        // `applyLikeToggle` is off-by-one whenever the optimistic apply CLAMPED
        // (stale count=0 + wasLiked=true → newCount=0, and recompute would bump
        // it back to 1, leaving a phantom like on screen).
        let wasLiked = likedIDs.contains(entryID)
        let preCount = likeCount(for: entryID)
        let (newCount, newLiked) = Self.applyLikeToggle(count: preCount, liked: wasLiked)

        // Optimistic apply.
        setLikeState(entryID: entryID, count: newCount, liked: newLiked)

        do {
            try await toggleLikeIO(entryID, wasLiked)
        } catch {
            // Restore the pre-toggle snapshot LITERALLY.
            setLikeState(entryID: entryID, count: preCount, liked: wasLiked)
        }
    }

    /// The current like count for a row, wherever it lives (list or search). 0
    /// when the id isn't on either list.
    public func likeCount(for entryID: UUID) -> Int {
        if let row = entries.first(where: { $0.id == entryID }) { return row.like_count }
        if let row = searchResults.first(where: { $0.id == entryID }) { return row.like_count }
        return 0
    }

    /// Whether a row is liked by the current viewer (drives the card heart).
    public func isLiked(_ entryID: UUID) -> Bool {
        likedIDs.contains(entryID)
    }

    /// Apply a count + liked-set change to whichever collection holds the row.
    /// `JournalRow` / `JournalSearchRow` are immutable value types, so we rebuild
    /// the one row with the new count.
    private func setLikeState(entryID: UUID, count: Int, liked: Bool) {
        if liked { likedIDs.insert(entryID) } else { likedIDs.remove(entryID) }

        if let idx = entries.firstIndex(where: { $0.id == entryID }) {
            entries[idx] = entries[idx].withLikeCount(count)
        }
        if let idx = searchResults.firstIndex(where: { $0.id == entryID }) {
            searchResults[idx] = searchResults[idx].withLikeCount(count)
        }
    }

    // MARK: - Pure like math (tested)

    /// The pure optimistic-like TOGGLE: `liked` is the CURRENT state, and the
    /// result is the state AFTER flipping it. Currently unliked (`false`) → like:
    /// +1, liked=true. Currently liked (`true`) → unlike: -1 clamped at zero,
    /// liked=false. Mirrors `TicketEngagementModel.applyToggle`'s count
    /// discipline (never negative). Applying it to its own output flips back for a
    /// non-clamped case (used by the revert path).
    public static func applyLikeToggle(count: Int, liked: Bool) -> (Int, Bool) {
        if liked {
            // Currently liked → unlike: -1 floored at zero.
            return (max(0, count - 1), false)
        } else {
            // Currently unliked → like: +1.
            return (count + 1, true)
        }
    }
}

// MARK: - Immutable like-count rebuild helpers

private extension JournalRow {
    /// A copy with a replaced `like_count` (all other fields carried over). Used
    /// for the optimistic like update — the DTO is an immutable value type.
    func withLikeCount(_ newCount: Int) -> JournalRow {
        JournalRow(
            id: id, user_id: user_id, tmdb_id: tmdb_id, title: title,
            poster_url: poster_url, rating_tier: rating_tier, review_text: review_text,
            contains_spoilers: contains_spoilers, mood_tags: mood_tags, vibe_tags: vibe_tags,
            favorite_moments: favorite_moments, standout_performances: standout_performances,
            watched_date: watched_date, watched_location: watched_location,
            watched_with_user_ids: watched_with_user_ids, watched_platform: watched_platform,
            is_rewatch: is_rewatch, rewatch_note: rewatch_note, personal_takeaway: personal_takeaway,
            photo_paths: photo_paths, visibility_override: visibility_override,
            like_count: newCount, created_at: created_at
        )
    }
}

private extension JournalSearchRow {
    func withLikeCount(_ newCount: Int) -> JournalSearchRow {
        JournalSearchRow(
            id: id, user_id: user_id, tmdb_id: tmdb_id, title: title,
            poster_url: poster_url, rating_tier: rating_tier, review_text: review_text,
            contains_spoilers: contains_spoilers, mood_tags: mood_tags, vibe_tags: vibe_tags,
            favorite_moments: favorite_moments, standout_performances: standout_performances,
            watched_date: watched_date, watched_location: watched_location,
            watched_with_user_ids: watched_with_user_ids, watched_platform: watched_platform,
            is_rewatch: is_rewatch, rewatch_note: rewatch_note,
            photo_paths: photo_paths, visibility_override: visibility_override,
            like_count: newCount, created_at: created_at, updated_at: updated_at
        )
    }
}
