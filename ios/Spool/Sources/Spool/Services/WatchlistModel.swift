import Foundation
import SwiftUI

/// The watchlist TAB state model (C3-iOS Part A, Task 3) — drives
/// `WatchlistScreen`. `@MainActor final class … ObservableObject`, NOT
/// `@Observable`: the package floor is iOS 16 (Package.swift), so this follows
/// the `JournalListModel` / `FeedFeedModel` / `ToastCenter` precedent.
///
/// ALL IO is injected as closures (same style as `JournalListModel`) so `load`,
/// the media switch, and the optimistic `remove` are XCTest-covered with ZERO
/// network (`WatchlistModelTests`). The screen (`WatchlistScreen`) binds the
/// closures to `WatchlistRepository.list` / `remove`, and the toast to
/// `ToastCenter.shared`.
///
/// ── Contract pins (each has a test) ────────────────────────────────────────
///
///  1. PER-MEDIA state machine. Each media type has its own `LoadState`
///     (`.loading` → `.loaded([…])` | `.empty` | `.failed`). `list(media:)`
///     THROWS on a broken read (Task 2's feed convention), so the tab can
///     distinguish `.empty` (a successful read of zero rows) from `.failed`
///     (the read blew up) and show the right state per media type.
///
///  2. MEDIA SWITCH reloads. Flipping `select(media:)` to a not-yet-loaded
///     type kicks a fresh `load()` for it; a type already loaded keeps its
///     cached state (no reload flicker), but `reload()` always refetches.
///
///  3. OPTIMISTIC remove. `remove(item:)` drops the row from the in-memory
///     list FIRST (so the card disappears immediately), then persists; a throw
///     REVERTS the row back into place at its original index and toasts. A
///     successful remove that empties the list transitions to `.empty`.
///
///  4. RANK IT seam (Task 4). `rankIt(item:)` just forwards the tapped movie
///     item to the injected `onRankIt` closure — the model owns NO ranking
///     logic. Movies only; the screen never offers Rank It on tv/book cards.
///
/// Header last reviewed: 2026-07-09
@MainActor
public final class WatchlistModel: ObservableObject {

    /// The load state of ONE media type's list. `.loading` is the pre-first-load
    /// state; `.empty` is a successful read of zero rows; `.failed` is a thrown
    /// read (feed convention lets the tab tell these apart).
    public enum LoadState: Equatable, Sendable {
        case loading
        case loaded([WatchlistItem])
        case empty
        case failed
    }

    // MARK: Injected IO

    /// `WatchlistRepository.list(media:)` — the owner's rows for a media type,
    /// newest first. Throws on failure (→ `.failed`).
    public typealias ListMedia = (WatchlistMediaType) async throws -> [WatchlistItem]
    /// `WatchlistRepository.remove(tmdbId:media:)` — the delete. Throws on
    /// failure so the optimistic remove can revert.
    public typealias RemoveItem = (String, WatchlistMediaType) async throws -> Void
    /// A user-visible message (bound to `ToastCenter.shared.show` in prod).
    public typealias Toast = (String, ToastLevel) -> Void
    /// The Rank It entry point — Task 4 wires this into the rank ceremony. The
    /// model only forwards the tapped MOVIE item.
    public typealias OnRankIt = (WatchlistItem) -> Void

    // MARK: Published state

    /// Which media segment is showing. `.movie` is the primary/default tab.
    @Published public private(set) var selectedMedia: WatchlistMediaType = .movie
    /// Per-media load state. A type absent from the map has never been loaded
    /// (renders `.loading` until its first `load`).
    @Published public private(set) var states: [WatchlistMediaType: LoadState] = [:]

    // MARK: Stored

    private let listIO: ListMedia
    private let removeIO: RemoveItem
    private let toastIO: Toast
    private let onRankIt: OnRankIt

    public init(
        list: @escaping ListMedia,
        remove: @escaping RemoveItem,
        toast: @escaping Toast,
        onRankIt: @escaping OnRankIt
    ) {
        self.listIO = list
        self.removeIO = remove
        self.toastIO = toast
        self.onRankIt = onRankIt
    }

    /// Production init — bind the closures to the real `WatchlistRepository`,
    /// the shared toast center, and the caller's Rank It routing.
    public convenience init(onRankIt: @escaping OnRankIt = { _ in }) {
        self.init(
            list: { media in
                try await WatchlistRepository.shared.list(media: media)
            },
            remove: { tmdbId, media in
                try await WatchlistRepository.shared.remove(tmdbId: tmdbId, media: media)
            },
            toast: { text, level in
                ToastCenter.shared.show(text, level: level)
            },
            onRankIt: onRankIt
        )
    }

    // MARK: - Derived

    /// The current media segment's load state (defaults to `.loading` before a
    /// first load lands).
    public var currentState: LoadState {
        states[selectedMedia] ?? .loading
    }

    /// The current media segment's items, or `[]` for any non-`.loaded` state.
    /// Convenience for the view's grid.
    public var currentItems: [WatchlistItem] {
        if case .loaded(let items) = currentState { return items }
        return []
    }

    // MARK: - Load

    /// Load `media`'s list into its state. Sets `.loading` first, then
    /// `.loaded` (non-empty), `.empty` (zero rows), or `.failed` (a thrown
    /// read — the feed convention lets us distinguish broken from empty).
    public func load(media: WatchlistMediaType) async {
        states[media] = .loading
        do {
            let items = try await listIO(media)
            states[media] = items.isEmpty ? .empty : .loaded(items)
        } catch {
            states[media] = .failed
        }
    }

    /// Load the currently selected media's list (first appearance / `.task`).
    public func loadCurrent() async {
        await load(media: selectedMedia)
    }

    /// Force a refetch of the current media (pull-to-refresh / retry button).
    public func reload() async {
        await load(media: selectedMedia)
    }

    // MARK: - Media switch

    /// Flip to `media`. If it has never been loaded, kick a fresh load; a type
    /// already loaded keeps its cached state (no reload flicker on a back-and-
    /// forth flip). Selecting the already-current media is a no-op.
    public func select(media: WatchlistMediaType) async {
        guard media != selectedMedia else { return }
        selectedMedia = media
        if states[media] == nil {
            await load(media: media)
        }
    }

    // MARK: - Optimistic remove

    /// Optimistically remove `item` from its media's list: drop it from the
    /// in-memory `.loaded` array FIRST (the card vanishes immediately), then
    /// persist. A throw REVERTS the row to its original index and toasts. A
    /// successful remove that empties the list transitions to `.empty`.
    ///
    /// A remove requested while the item's media is NOT in a `.loaded` state
    /// (e.g. mid-load) is ignored — there is no list to mutate.
    public func remove(item: WatchlistItem) async {
        let media = item.mediaType
        guard case .loaded(var items) = states[media],
              let idx = items.firstIndex(where: { $0.id == item.id }) else {
            return
        }

        // Optimistic drop.
        let removed = items.remove(at: idx)
        states[media] = items.isEmpty ? .empty : .loaded(items)

        do {
            try await removeIO(item.id, media)
        } catch {
            // Revert: splice the row back at its original index (clamped in case
            // the list shifted underneath us — it can't in this single-actor
            // path, but stay defensive).
            var reverted = currentItems(for: media)
            let insertAt = min(idx, reverted.count)
            reverted.insert(removed, at: insertAt)
            states[media] = .loaded(reverted)
            toastIO("couldn't remove \(removed.title) — try again", .error)
        }
    }

    /// The items backing `media` right now (empty for any non-`.loaded` state).
    /// Used by the revert path so an empty→`.empty` transition still restores.
    private func currentItems(for media: WatchlistMediaType) -> [WatchlistItem] {
        if case .loaded(let items) = states[media] { return items }
        return []
    }

    // MARK: - Rank It (Task 4 seam)

    /// Forward a tapped MOVIE item to the injected Rank It entry point. The
    /// model owns no ranking logic — Task 4 fills `onRankIt`. The screen only
    /// exposes this affordance on movie cards, so callers should pass a
    /// `.movie` item; a non-movie item still forwards (the guard lives in the
    /// view, where the affordance is), but production never calls it that way.
    public func rankIt(item: WatchlistItem) {
        onRankIt(item)
    }
}
