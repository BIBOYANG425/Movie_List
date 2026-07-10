import Foundation
import SwiftUI

/// State model for the ranked-list surface (`FullListScreen`) — C4 iOS
/// management-UI Tasks 3 (edit-mode drag) + 4 (long-press context menu).
/// `@MainActor final class … ObservableObject`, NOT `@Observable`: the package
/// floor is iOS 16 (Package.swift), so this follows the `WatchlistModel` /
/// `JournalListModel` / `FeedFeedModel` precedent.
///
/// ALL IO is injected as closures (same style as `WatchlistModel`) so the
/// edit-mode toggle, the in-tier move math, the no-op suppression, the
/// full-membership reorder write, the cross-tier move / notes edit / re-rank /
/// delete menu actions, the single `ranking_move`/`ranking_remove` emissions,
/// and the optimistic-apply/revert-on-throw are all XCTest-covered with ZERO
/// network (`RankManageModelTests`). The screen (`FullListScreen`) binds the
/// closures to `RankingRepository.reorderTier`/`moveRanking`/`getNotes`/
/// `updateNotes`/`deleteRanking`, `RankMoveEmitter.emit`/`RankRemoveEmitter.emit`,
/// the re-rank hand-off (via `bindRerank`), and `ToastCenter`.
///
/// ── Long-press menu actions (Task 4; each has a test) ───────────────────────
///
///  A. MOVE TO TIER (`moveTo`). Optimistic cross-tier regroup: the item leaves
///     its old tier and APPENDS to the target tail, both tiers renumber, then
///     `moveRanking` persists (append ⇒ atIndex nil). ONE `ranking_move` with
///     the TARGET tier on success; revert both tiers + toast on throw.
///  B. EDIT NOTES (`fetchNotes` + `saveNotes`). `fetchNotes` PROBES the live
///     row's notes so the sheet never blanks an existing note (the shelf's
///     `RankedItem` has no notes column). Returns `.success(notes?)` on a clean
///     probe or `.probeFailed` on a throw — the sheet shows a warning and blocks
///     blank saves on the failed-probe path so a whitespace commit can never wipe
///     a real note. A toast also fires on probe failure. `saveNotes` trims /
///     nil-normalizes and calls `updateNotes` — emits NOTHING (web has no
///     standalone notes event).
///  C. RE-RANK (`requestRerank`). Fires the injected hand-off with the RAW item,
///     NO watchlist origin — the ceremony owns the event + compaction.
///  D. DELETE (`delete`). View-confirmed (destructive dialog). Optimistic
///     removal + renumber, `deleteRanking` (row dies + compaction; watchlist NOT
///     restored — orphan semantics), ONE `ranking_remove` on success; revert +
///     toast on throw.
///
/// ── Edit-mode drag pins (Task 3; each has a test) ───────────────────────────
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
///  5. IN-FLIGHT GUARD. `isReordering` blocks a second concurrent drop while an
///     RPC is already in flight (same pattern as `JournalDraftModel`'s `saving`
///     guard). The second drop is silently ignored — the optimistic order from
///     the first is already live.
///
///  6. RANK RENUMBER ON CONFIRMED DRAG. After a successful persist, each tier's
///     `RankedItem.rank` is updated to its 0-based position in that tier so
///     the `#n` badge in the editable list stays current mid-edit and the
///     read-only render (which sorts by `rank`) shows the right order when
///     edit mode exits.
///
/// Per-vertical (C5 Task 2): the model carries a `media` key (`"movie" | "tv" |
/// "book"`, default `"movie"`) that the shelf sets on each media-segment switch.
/// Every management IO — reorder / cross-tier move / notes probe+save / delete —
/// threads that key so a tv/book shelf reorders/moves/deletes on its own table
/// (`RankingRepository`'s ops already take a `media:` param since C4-UI). As of
/// C5-iOS Task 6 re-rank is offered for ALL media (`showsRerank(forMedia:)`
/// accepts any known vertical); the media-generic ceremony (T5) now exists, so
/// tv/book cards offer move/notes/delete/re-rank, and the completion routes per
/// media. Each mutating op CAPTURES `media` at op start and skips its post-await
/// tier writes / emission if the shelf switched verticals mid-flight, so a stale
/// response can never corrupt the newly-selected media's in-memory list.
///
/// Header last reviewed: 2026-07-10
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

    /// The `ranking_remove` emission input for one confirmed delete (Task 4).
    /// Same shape as `MoveEvent`: media columns from the deleted item, metadata
    /// `{notes?, year?}` (watched-with STRIPPED — web's `ranking_remove` writer
    /// passes only `{notes, year}`). `tier` is the tier the row was removed
    /// FROM. `RankedItem` carries no notes, so `notes` is nil on the menu path.
    public struct RemoveEvent: Equatable, Sendable {
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
    /// `RankingRepository.moveRanking(tmdbId:fromTier:toTier:atIndex:media:)` —
    /// cross-tier move. Args: `(media, tmdbId, fromTier, toTier, atIndex)`. The
    /// menu always APPENDS to the target tail, so `atIndex` is always nil here.
    /// Throws so the optimistic regroup can revert.
    public typealias MoveIO = (String, String, String, String, Int?) async throws -> Void
    /// `RankingRepository.getNotes(tmdbId:media:)` — fetch-before-edit probe for
    /// the notes sheet. Args: `(media, tmdbId)`. Throws; the model surfaces a
    /// throw as `.probeFailed` rather than degrading silently to nil.
    public typealias NotesProbeIO = (String, String) async throws -> String?
    /// `RankingRepository.updateNotes(tmdbId:notes:media:)` — single-column notes
    /// write. Args: `(media, tmdbId, notes)`; nil clears the column. Throws so a
    /// save failure can toast. Emits NOTHING (web has no standalone notes-edit
    /// event).
    public typealias SaveNotesIO = (String, String, String?) async throws -> Void
    /// `RankingRepository.deleteRanking(tmdbId:tier:media:)` — DESTRUCTIVE row
    /// delete + tier compaction. Args: `(media, tmdbId, tier)`. Throws so the
    /// optimistic removal can revert. The confirmation DIALOG is view-level; the
    /// model API takes the already-confirmed action.
    public typealias DeleteIO = (String, String, String) async throws -> Void
    /// Request the re-rank ceremony for the RAW item, preseeded, NO watchlist
    /// origin (bound in `SpoolAppRoot` to dismiss the shelf sheet + enter the
    /// Task-2-corrected `.tier` flow). Synchronous hand-off — the ceremony owns
    /// the rest (events/compaction).
    public typealias RerankIO = (RankedItem) -> Void
    /// Emit ONE `ranking_move` activity event for a confirmed reorder/move. Fire-
    /// and-forget (a feed-insert hiccup never fails the write) — bound to
    /// `RankMoveEmitter.emit` in prod.
    public typealias EmitIO = (MoveEvent) async -> Void
    /// Emit ONE `ranking_remove` activity event for a confirmed delete. Fire-and-
    /// forget — bound to `RankRemoveEmitter.emit` in prod.
    public typealias EmitRemoveIO = (RemoveEvent) async -> Void
    /// A user-visible message (bound to `ToastCenter.shared.show` in prod).
    public typealias Toast = (String, ToastLevel) -> Void

    // MARK: Published state

    /// Whether the list is in edit mode (drag handles visible, `.onMove` live).
    @Published public private(set) var isEditing: Bool = false
    /// The vertical this model manages (`"movie" | "tv" | "book"`). Threaded into
    /// EVERY management IO (reorder / move / notes probe+save / delete) so a
    /// tv/book shelf reorders/moves/deletes on its own table. Defaults to `"movie"`
    /// so the C4 movie shelf is unchanged until the screen sets a media. The shelf
    /// (`FullListScreen`) calls `setMedia` on each media-segment switch.
    @Published public private(set) var media: String = "movie"
    /// The in-memory per-tier membership, best-first. The single source of truth
    /// the view renders while editing; `setItems` seeds it from the loaded shelf.
    @Published public private(set) var tiers: [Tier: [RankedItem]] = [:]
    /// True while a reorder RPC is in flight. A second `.onMove` drop received
    /// while this is set is ignored (same guard as `JournalDraftModel.saving`).
    @Published public private(set) var isReordering: Bool = false

    // MARK: Stored

    private let reorderIO: ReorderIO
    private let moveIO: MoveIO
    private let notesProbeIO: NotesProbeIO
    private let saveNotesIO: SaveNotesIO
    private let deleteIO: DeleteIO
    private let rerankIO: RerankIO
    private let emitIO: EmitIO
    private let emitRemoveIO: EmitRemoveIO
    private let toastIO: Toast

    /// Full designated init — every menu action's IO injected (Task 4). The
    /// three-arg init (Task 3, drag-only) delegates here with no-op stubs for the
    /// menu closures so the existing edit-mode tests are untouched.
    public init(
        reorder: @escaping ReorderIO,
        move: @escaping MoveIO,
        notesProbe: @escaping NotesProbeIO,
        saveNotes: @escaping SaveNotesIO,
        delete: @escaping DeleteIO,
        rerank: @escaping RerankIO,
        emit: @escaping EmitIO,
        emitRemove: @escaping EmitRemoveIO,
        toast: @escaping Toast
    ) {
        self.reorderIO = reorder
        self.moveIO = move
        self.notesProbeIO = notesProbe
        self.saveNotesIO = saveNotes
        self.deleteIO = delete
        self.rerankIO = rerank
        self.emitIO = emit
        self.emitRemoveIO = emitRemove
        self.toastIO = toast
    }

    /// Task-3 drag-only init (kept for `RankManageModelTests`' edit-mode cases).
    /// The menu closures default to no-ops — a model built this way exercises
    /// only the in-tier reorder path.
    public convenience init(
        reorder: @escaping ReorderIO,
        emit: @escaping EmitIO,
        toast: @escaping Toast
    ) {
        self.init(
            reorder: reorder,
            move: { _, _, _, _, _ in },
            notesProbe: { _, _ in nil },
            saveNotes: { _, _, _ in },
            delete: { _, _, _ in },
            rerank: { _ in },
            emit: emit,
            emitRemove: { _ in },
            toast: toast
        )
    }

    /// Production init — bind every closure to the real `RankingRepository`, the
    /// `RankMoveEmitter` / `RankRemoveEmitter`, and the shared toast center. The
    /// re-rank hand-off is injected separately by the screen (it needs the
    /// screen's sheet-dismiss + flow-entry choreography), so it defaults to a
    /// no-op here and `FullListScreen` overrides it via `bindRerank`.
    public convenience init() {
        self.init(
            reorder: { media, tier, ids in
                _ = try await RankingRepository.shared.reorderTier(media: media, tier: tier, ids: ids)
            },
            move: { media, tmdbId, fromTier, toTier, atIndex in
                try await RankingRepository.shared.moveRanking(
                    tmdbId: tmdbId, fromTier: fromTier, toTier: toTier, atIndex: atIndex,
                    media: media
                )
            },
            notesProbe: { media, tmdbId in
                try await RankingRepository.shared.getNotes(tmdbId: tmdbId, media: media)
            },
            saveNotes: { media, tmdbId, notes in
                try await RankingRepository.shared.updateNotes(tmdbId: tmdbId, notes: notes, media: media)
            },
            delete: { media, tmdbId, tier in
                try await RankingRepository.shared.deleteRanking(tmdbId: tmdbId, tier: tier, media: media)
            },
            rerank: { _ in },
            emit: { event in
                await RankMoveEmitter.emit(event)
            },
            emitRemove: { event in
                await RankRemoveEmitter.emit(event)
            },
            toast: { text, level in
                ToastCenter.shared.show(text, level: level)
            }
        )
    }

    /// Override the re-rank hand-off closure after construction. The production
    /// `init()` can't wire it (it needs `FullListScreen`'s sheet-dismiss + flow-
    /// entry choreography), so the screen calls this once with a closure that
    /// closes the shelf sheet and enters the Task-2-corrected `.tier` ceremony
    /// preseeded with the RAW item, NO watchlist origin.
    public func bindRerank(_ rerank: @escaping RerankIO) {
        self.rerankOverride = rerank
    }

    /// Set by `bindRerank`; takes precedence over the injected `rerankIO`.
    private var rerankOverride: RerankIO?

    // MARK: - Media

    /// Set the vertical this model manages. The shelf calls this on each media-
    /// segment switch (before re-seeding via `setItems`) so every subsequent
    /// reorder / move / notes / delete routes to the right table. Ending edit
    /// mode on a switch is the SCREEN's job (it also re-seeds), so this only
    /// updates the routing key.
    public func setMedia(_ media: String) {
        self.media = media
    }

    /// Whether the long-press "re-rank" menu action is offered for `media`.
    /// ALL media as of C5-iOS Task 6: the media-generic ceremony now exists
    /// (T5), so tv/book cards get re-rank too. The completion routes per media —
    /// a tv re-rank enters the ceremony with the SEASON item already chosen (its
    /// `seasonNumber` is real, so NO season grid), a book/movie re-rank enters
    /// the ceremony direct. `requestRerank` still no-ops on an unknown media so
    /// a malformed shelf can never seed a garbage ceremony.
    public static func showsRerank(forMedia media: String) -> Bool {
        RankMedia(rawValue: media) != nil
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

    /// All items from every tier, flattened in natural tier order (S→D), each
    /// tier sorted by `rank` ascending. Used by `FullListScreen` to sync its
    /// read-only `items` array when edit mode exits so the shelf render and the
    /// `#rank` badges reflect any drags without a network round-trip.
    public var flatItems: [RankedItem] {
        Tier.allCases.flatMap { tiers[$0] ?? [] }
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
    ///
    /// A second drop received while an RPC is already in flight is ignored
    /// (`isReordering` guard — same pattern as `JournalDraftModel.saving`).
    ///
    /// On a confirmed persist the tier's `rank` fields are renumbered 0-based so
    /// the `#n` badge stays current mid-edit and the read-only render (which
    /// sorts by `rank`) shows the correct order when edit mode exits.
    public func moveRow(tier: Tier, from source: IndexSet, to destination: Int) async {
        guard !isReordering else { return }
        guard let current = tiers[tier], !current.isEmpty else { return }
        guard let fromIndex = source.first else { return }

        // Capture the media at op start (C5-iOS Task 6 cross-media race guard):
        // the RPC awaits, and the shelf may switch verticals + re-seed `tiers`
        // meanwhile. A post-await mutation keyed off the OLD tier would then
        // corrupt the NEW media's in-memory list. If the media changed we skip
        // the optimistic + post-await tier writes below (the switch already
        // cleared/re-seeded), so a stale response never mutates the wrong list.
        let opMedia = media

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

        isReordering = true
        defer { isReordering = false }

        do {
            try await reorderIO(opMedia, tier.rawValue, after)
            // The shelf switched media mid-flight and re-seeded — do NOT write
            // this (old-media) result onto the new media's tiers. The emission
            // is also skipped: the reorder DID land on the old table, but the
            // UI has moved on; a fresh reload on return reflects reality.
            guard media == opMedia else { return }
            // Confirmed change → renumber ranks 0-based so #n badges and the
            // read-only render (sorted by rank) stay consistent mid-edit and
            // after edit mode exits.
            tiers[tier] = Self.renumbered(reordered)
            // ONE ranking_move for the moved item.
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
            // Revert THIS tier to its exact prior order and toast — but only if
            // the shelf hasn't switched media meanwhile (the switch already
            // re-seeded; reverting onto the new list would corrupt it).
            guard media == opMedia else { return }
            tiers[tier] = current
            toastIO(L10n.t("toast.reorderFailed", ["title": movedItem.title]), .error)
        }
    }

    // MARK: - Long-press menu actions (Task 4)

    /// MOVE a ranking to a DIFFERENT tier (context-menu "move to tier" submenu).
    /// Optimistic: the item leaves its old tier group and APPENDS to the target
    /// tier's tail, both tiers renumber 0-based immediately, then the cross-tier
    /// move persists (`moveRanking`, `atIndex` nil = append). A confirmed move
    /// emits ONE `ranking_move` carrying the TARGET tier (`{notes?, year?}`,
    /// never watched-with — the move sites strip it). A throw REVERTS both tiers
    /// to their exact prior membership and toasts; no emission on failure.
    ///
    /// A move to the tier the item already lives in is a no-op (the submenu hides
    /// the current tier, but we guard defensively). Routes to `self.media`'s table.
    public func moveTo(tier target: Tier, item: RankedItem) async {
        let source = item.tier
        guard target != source else { return }

        // Capture the media at op start (cross-media race guard, C5-iOS Task 6):
        // if the shelf switches verticals during the await, skip the post-await
        // emission + revert so a stale response never mutates the new list.
        let opMedia = media

        // Snapshot both tiers for an exact revert.
        let priorSource = tiers[source] ?? []
        let priorTarget = tiers[target] ?? []

        // Optimistic regroup: drop from source, append to target tail.
        let newSource = Self.renumbered(priorSource.filter { $0.id != item.id })
        var moved = item
        moved.tier = target
        let newTarget = Self.renumbered(priorTarget + [moved])
        tiers[source] = newSource
        tiers[target] = newTarget

        do {
            try await moveIO(opMedia, item.id, source.rawValue, target.rawValue, nil)
            // Media switched mid-flight — the move DID land on the old table, but
            // the UI has moved on; skip the emission and let a reload reconcile.
            guard media == opMedia else { return }
            // ONE ranking_move for the moved item, carrying the TARGET tier.
            await emitIO(MoveEvent(
                tmdbId: item.id,
                title: item.title,
                tier: target.rawValue,
                posterUrl: item.posterUrl,
                year: item.year.map(String.init),
                notes: nil
            ))
        } catch {
            guard media == opMedia else { return }
            tiers[source] = priorSource
            tiers[target] = priorTarget
            toastIO(L10n.t("toast.moveFailed", ["title": item.title]), .error)
        }
    }

    /// The outcome of a `fetchNotes` probe. The sheet uses this to distinguish
    /// a confirmed-nil note (no warning, save enabled) from a probe failure
    /// (warning shown, save blocked until the user types something non-empty —
    /// so a blank save can never fire on the failed-probe path and wipe a real note).
    public enum NotesFetchResult: Equatable, Sendable {
        /// Probe succeeded. `value` is the live note (nil = column empty).
        case success(String?)
        /// Probe threw. The existing note is unknown; the sheet must warn the
        /// user and block blank saves so it can't overwrite an unseen note.
        case probeFailed
    }

    /// FETCH the row's current notes so the "edit notes" sheet seeds from the
    /// live value (the shelf's `RankedItem` has no notes column — probe-before-
    /// edit, the journal lesson, so a save never blanks an existing note).
    ///
    /// On success returns `.success(notes)` where `notes` is the live column
    /// value (nil = empty). On a probe throw returns `.probeFailed` instead of
    /// degrading silently to nil: the sheet must warn the user that the existing
    /// note is unknown and block blank saves so a whitespace commit can never
    /// wipe a real note. A toast is also fired so the failure is surfaced even
    /// if the sheet is already open.
    public func fetchNotes(item: RankedItem) async -> NotesFetchResult {
        do {
            let notes = try await notesProbeIO(media, item.id)
            return .success(notes)
        } catch {
            NSLog("[RankManageModel] notes probe failed for \(item.id): \(error)")
            toastIO(L10n.t("toast.noteLoadFailed"), .error)
            return .probeFailed
        }
    }

    /// SAVE edited notes (context-menu "edit notes" sheet commit). Trims, and
    /// normalizes whitespace-only to nil so an emptied editor CLEARS the column
    /// (parity with web `notes.trim() || undefined`). Persists via `updateNotes`.
    /// Emits NOTHING — web has no standalone notes-edit activity event (notes
    /// only ride the ceremony's `ranking_add`/`ranking_move`). A throw toasts; no
    /// optimistic list change to revert (notes aren't projected onto the shelf).
    public func saveNotes(item: RankedItem, notes: String) async {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String? = trimmed.isEmpty ? nil : trimmed
        do {
            try await saveNotesIO(media, item.id, normalized)
        } catch {
            toastIO(L10n.t("toast.noteSaveFailed"), .error)
        }
    }

    /// REQUEST the re-rank ceremony for the RAW item (context-menu "re-rank").
    /// Fires the hand-off closure synchronously — the screen closes the shelf
    /// sheet and enters the Task-2-corrected `.tier` flow preseeded, NO watchlist
    /// origin (the ceremony's completion owns the single `ranking_move` +
    /// both-tier compaction). This model does NOT touch its in-memory tiers or
    /// persist anything: the ceremony is the single source of truth for a
    /// re-rank, and the shelf refetches when it reopens.
    ///
    /// Media guard (C5-iOS Task 6): if `self.media` is not a known vertical the
    /// re-rank is a no-op — a malformed shelf can never seed a garbage ceremony.
    /// The screen already gates the menu via `showsRerank`, so this is
    /// defense-in-depth mirroring the completion's per-media routing.
    public func requestRerank(item: RankedItem) {
        guard Self.showsRerank(forMedia: media) else {
            NSLog("[RankManageModel] requestRerank ignored for unknown media '\(media)'")
            return
        }
        (rerankOverride ?? rerankIO)(item)
    }

    /// DELETE a ranking (context-menu "delete", already confirmed by the view's
    /// destructive dialog naming the movie). Optimistic: the row leaves its tier
    /// group and the tier renumbers 0-based immediately, then the destructive
    /// delete persists (`deleteRanking` → row dies + tier compaction; ORPHAN
    /// semantics — watchlist is never restored). A confirmed delete emits ONE
    /// `ranking_remove` (`{notes?, year?}`, the tier it was removed FROM). A
    /// throw REVERTS the tier to its exact prior order + ranks and toasts; no
    /// emission on failure. Routes to `self.media`'s table.
    public func delete(item: RankedItem) async {
        let tier = item.tier
        let prior = tiers[tier] ?? []

        // Capture the media at op start (cross-media race guard, C5-iOS Task 6).
        let opMedia = media

        // Optimistic removal + renumber.
        tiers[tier] = Self.renumbered(prior.filter { $0.id != item.id })

        do {
            try await deleteIO(opMedia, item.id, tier.rawValue)
            // Media switched mid-flight — skip the emission; the delete landed on
            // the old table and a reload on return reflects it.
            guard media == opMedia else { return }
            await emitRemoveIO(RemoveEvent(
                tmdbId: item.id,
                title: item.title,
                tier: tier.rawValue,
                posterUrl: item.posterUrl,
                year: item.year.map(String.init),
                notes: nil
            ))
        } catch {
            guard media == opMedia else { return }
            tiers[tier] = prior
            toastIO(L10n.t("toast.deleteFailed", ["title": item.title]), .error)
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

    /// Assign contiguous 0-based `rank` values to `items` in their current order.
    /// Called after a confirmed persist so the `#n` badge (which reads `item.rank`)
    /// matches the visual position mid-edit, and the read-only render (sorted by
    /// `rank`) shows the correct order when edit mode exits.
    private static func renumbered(_ items: [RankedItem]) -> [RankedItem] {
        items.enumerated().map { idx, item in
            var copy = item
            copy.rank = idx
            return copy
        }
    }
}
