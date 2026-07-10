import Foundation
import SwiftUI

/// Edit-mode drag-to-reorder state model for the ranked-list surface
/// (`FullListScreen`) — C4 iOS management-UI Task 3. `@MainActor final class …
/// ObservableObject`, NOT `@Observable`: the package floor is iOS 16
/// (Package.swift), so this follows the `WatchlistModel` / `JournalListModel` /
/// `FeedFeedModel` precedent.
///
/// ALL IO is injected as closures (same style as `WatchlistModel`) so the
/// edit-mode toggle, the in-tier move math, the no-op suppression, the
/// full-membership reorder write, the single `ranking_move` emission, and the
/// optimistic-apply/revert-on-throw are XCTest-covered with ZERO network
/// (`RankManageModelTests`). The screen (`FullListScreen`) binds the closures to
/// `RankingRepository.reorderTier` / `RankMoveEmitter.emit` / `ToastCenter`.
///
/// ── Contract pins (each has a test) ────────────────────────────────────────
///
///  1. EDIT-MODE TOGGLE. `toggleEditing()` flips `isEditing`; the view shows
///     drag handles and the `.onMove` affordance while it is on.
///
///  2. IN-TIER MOVE, FULL MEMBERSHIP. `moveRow(tier:from:to:)` takes the
///     SwiftUI `.onMove` arguments (source `IndexSet`, destination `Int`
///     computed BEFORE the removal), resolves them to a `TierOrder`
///     `from`/`to`, and computes the tier's ENTIRE new membership via
///     `TierOrder.tierOrderAfterReorder`. The persisted write always carries
///     that FULL membership (partial arrays orphan rows — see the RPC contract
///     in `docs/contracts/shared-payloads.md` § `user_rankings ordering`).
///     Cross-tier drag is OUT of scope (the long-press context menu owns
///     moves) — drag is confined to one tier's rows.
///
///  3. NO-OP SUPPRESSION (audit B1). A drop that leaves the order unchanged
///     (same position) does NOTHING: no reorder RPC, no `ranking_move` event.
///     `TierOrder.tierOrderAfterReorder` returns an equal array in that case,
///     and this model compares before/after to decide.
///
///  4. OPTIMISTIC APPLY → REVERT + TOAST. On a real change the new order is
///     applied to the in-memory tier FIRST (the list reorders immediately),
///     then persisted. A throw REVERTS that tier to the exact prior order and
///     toasts. Only a CONFIRMED change emits ONE `ranking_move` (metadata
///     `{notes?, year?}` from the moved item — NEVER watched-with, per the
///     `activity_events` contract; `RankedItem` carries no notes, so notes is
///     always nil here).
///
/// Movies only: the ranked-list surface reads `user_rankings` exclusively
/// (`RankingRepository.getAllRankedItems`), so every row is a movie and the
/// reorder write hardcodes `media: "movie"`.
///
/// Header last reviewed: 2026-07-09
@MainActor
public final class RankManageModel: ObservableObject {

    /// The `ranking_move` emission input for one confirmed in-tier reorder. The
    /// media columns come from the MOVED item; metadata is `{notes?, year?}`
    /// (watched-with STRIPPED — the move sites never carry it). `RankedItem`
    /// has no notes field, so `notes` is always nil for a drag reorder; `year`
    /// is the moved item's year as a string when present.
    public struct MoveEvent: Equatable, Sendable {
        public let tmdbId: String
        public let title: String
        public let tier: String
        public let posterUrl: String?
        public let year: String?
        public let notes: String?

        public init(tmdbId: String, title: String, tier: String,
                    posterUrl: String?, year: String?, notes: String?) {
            self.tmdbId = tmdbId
            self.title = title
            self.tier = tier
            self.posterUrl = posterUrl
            self.year = year
            self.notes = notes
        }
    }

    // MARK: Injected IO

    /// `RankingRepository.reorderTier(media:tier:ids:)` — persists the tier's
    /// FULL new membership. Args: `(media, tier, ids)`. Throws so the optimistic
    /// reorder can revert.
    public typealias ReorderIO = (String, String, [String]) async throws -> Void
    /// Emit ONE `ranking_move` activity event for a confirmed reorder. Fire-and-
    /// forget (a feed-insert hiccup never fails the reorder) — bound to
    /// `RankMoveEmitter.emit` in prod.
    public typealias EmitIO = (MoveEvent) async -> Void
    /// A user-visible message (bound to `ToastCenter.shared.show` in prod).
    public typealias Toast = (String, ToastLevel) -> Void

    // MARK: Published state

    /// Whether the list is in edit mode (drag handles visible, `.onMove` live).
    @Published public private(set) var isEditing: Bool = false
    /// The in-memory per-tier membership, best-first. The single source of truth
    /// the view renders while editing; `setItems` seeds it from the loaded shelf.
    @Published public private(set) var tiers: [Tier: [RankedItem]] = [:]

    // MARK: Stored

    private let reorderIO: ReorderIO
    private let emitIO: EmitIO
    private let toastIO: Toast

    public init(
        reorder: @escaping ReorderIO,
        emit: @escaping EmitIO,
        toast: @escaping Toast
    ) {
        self.reorderIO = reorder
        self.emitIO = emit
        self.toastIO = toast
    }

    /// Production init — bind the closures to the real `RankingRepository`, the
    /// `RankMoveEmitter`, and the shared toast center.
    public convenience init() {
        self.init(
            reorder: { media, tier, ids in
                _ = try await RankingRepository.shared.reorderTier(media: media, tier: tier, ids: ids)
            },
            emit: { event in
                await RankMoveEmitter.emit(event)
            },
            toast: { text, level in
                ToastCenter.shared.show(text, level: level)
            }
        )
    }

    // MARK: - Seeding

    /// Seed the per-tier membership from the loaded shelf. Groups by tier and
    /// sorts each section by `rank` ascending (best first), mirroring
    /// `FullListScreen.itemsByTier`.
    public func setItems(_ items: [RankedItem]) {
        var out: [Tier: [RankedItem]] = [:]
        for item in items { out[item.tier, default: []].append(item) }
        for tier in out.keys {
            out[tier]?.sort { $0.rank < $1.rank }
        }
        tiers = out
    }

    /// The current membership of `tier`, best-first (empty when the tier has no
    /// rows). Convenience for the view's per-tier `ForEach`.
    public func items(in tier: Tier) -> [RankedItem] {
        tiers[tier] ?? []
    }

    // MARK: - Edit mode

    /// Flip edit mode on/off (drag handles + `.onMove`).
    public func toggleEditing() {
        isEditing.toggle()
    }

    /// Force edit mode off (used when the shelf reloads or the sheet closes so a
    /// stale edit state never survives fresh data).
    public func endEditing() {
        isEditing = false
    }

    // MARK: - In-tier reorder

    /// Handle a SwiftUI `.onMove` within `tier`. `source`/`destination` are the
    /// stock `.onMove` arguments: `destination` is the index the row would sit
    /// at BEFORE the removal, so a drop-in-place yields `destination == from` or
    /// `destination == from + 1` (both no-ops). We resolve those to a
    /// `TierOrder` `to` and compute the tier's FULL new membership.
    ///
    /// A move that leaves the order unchanged does NOTHING (no RPC, no event —
    /// audit B1). A real change applies OPTIMISTICALLY, persists the full
    /// membership, then either emits ONE `ranking_move` (success) or reverts the
    /// tier to its exact prior order and toasts (throw).
    public func moveRow(tier: Tier, from source: IndexSet, to destination: Int) async {
        guard let current = tiers[tier], !current.isEmpty else { return }
        guard let fromIndex = source.first else { return }

        // Translate SwiftUI's before-removal destination into TierOrder's
        // after-removal `to` (SwiftUI adds 1 when moving downward).
        let toIndex = destination > fromIndex ? destination - 1 : destination

        let before = current.map(\.id)
        let after = TierOrder.tierOrderAfterReorder(before, from: fromIndex, to: toIndex)

        // No-op suppression: an unchanged order = no RPC, no event.
        guard after != before else { return }

        // The item that actually moved drives the emission.
        let movedItem = current[fromIndex]

        // Optimistic apply: reorder the in-memory tier to `after`.
        let reordered = Self.reorder(current, to: after)
        tiers[tier] = reordered

        do {
            try await reorderIO("movie", tier.rawValue, after)
            // Confirmed change → ONE ranking_move for the moved item.
            let event = MoveEvent(
                tmdbId: movedItem.id,
                title: movedItem.title,
                tier: tier.rawValue,
                posterUrl: movedItem.posterUrl,
                year: movedItem.year.map(String.init),
                notes: nil
            )
            await emitIO(event)
        } catch {
            // Revert THIS tier to its exact prior order and toast. Other tiers
            // are untouched (drag is single-tier).
            tiers[tier] = current
            toastIO("couldn't reorder \(movedItem.title) — try again", .error)
        }
    }

    /// Reorder `items` to match the id order in `orderedIds`. Pure helper: keeps
    /// the `RankedItem` payloads, only permutes their positions. Any id in
    /// `orderedIds` absent from `items` is skipped; any item missing from
    /// `orderedIds` is appended in its original relative order (defensive — the
    /// two are always in sync on the reorder path).
    private static func reorder(_ items: [RankedItem], to orderedIds: [String]) -> [RankedItem] {
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [RankedItem] = orderedIds.compactMap { byId[$0] }
        let placed = Set(orderedIds)
        for item in items where !placed.contains(item.id) { out.append(item) }
        return out
    }
}
