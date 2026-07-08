import Foundation
import SwiftUI

/// The journal COMPOSER state model — the correctness keystone of the C2 cycle
/// (plan Task 4). Drives `JournalComposer` (Task 6). Mirrors web
/// `JournalConversation.tsx` + `journalService.upsertJournalEntry`.
///
/// `ObservableObject`, NOT `@Observable`: the package floor is iOS 16 / macOS 13
/// (Package.swift); the Observation macro needs iOS 17. Same
/// `@MainActor final class … ObservableObject` + `@Published` shape as
/// `TicketEngagementModel` / `ToastCenter`.
///
/// ALL IO is injected as closures (repo/photo/profile/emitters) so every
/// load-bearing invariant is XCTest-covered with ZERO network
/// (`JournalDraftModelTests`). The screen wiring (Task 6) binds these to
/// `JournalRepository.getOwnEntry/ratingTier/upsert`, `PhotoStore.upload`,
/// `ProfileRepository.currentVisibility`, and the real
/// `activity_events` / `notifications` inserts.
///
/// ── The four load-bearing correctness points (each has a test) ─────────────
///
///  1. PROBE-BEFORE-EDIT. `openForEntry` starts `.loading`, awaits the FULL
///     owner row (`probeOwnEntry` = `getOwnEntry`, `select('*')`), runs it
///     through `JournalEntryContract.pickEntryForEdit(probed, seed)` — the
///     freshly-probed owner row ALWAYS wins over a takeaway-less seed/passed row
///     from a list/search read — populates the draft, and ONLY THEN becomes
///     `.ready`. A save is impossible before `.ready` (`guard phase == .ready`),
///     so a not-fully-loaded draft can never wipe `personal_takeaway` (the exact
///     web wipe bug).
///
///  2. FULL-REPLACE SAVE. `save()` resolves `rating_tier` (`resolveRatingTier` =
///     `user_rankings.tier` lookup, NEVER the form), builds the full 20-field
///     `JournalEntryContract.upsertPayload`, upserts, and captures the returned
///     row's id. Never a partial payload.
///
///  3. PHOTO ORDERING (side-effect-free mint). Photos live at
///     `{userId}/{ENTRY-UUID}/{i}`; a NEW entry has no id until it exists. So
///     `addPhoto` mirrors web `handlePhotoAdd` EXACTLY: if no minted id yet,
///     `mintMinimalEntry()` upserts a MINIMAL `{title, posterUrl}` payload
///     (empty review → gate closed, no tagged friends → no fan-out) that runs
///     NO side effects, then `uploadPhoto(..., entryID: mintedID, index:
///     photoCount, ...)`, and holds the path in the IN-MEMORY draft. The new
///     `photo_paths` persists on the user's next EXPLICIT `save()` — so a
///     photo-add NEVER fires a review event or a journal_tag, even if the user
///     already typed a public review or tagged friends (the full draft's side
///     effects run once, on the explicit save). An existing entry already has
///     its id, so it uploads straight away (still no side effects).
///
///  4. SIDE EFFECTS on save, in web order (mirror `upsertJournalEntry` exactly):
///     a. `review` activity event ONLY when review non-empty AND resolved
///        visibility == public. Resolution uses the RAW override overload
///        (`resolveVisibility(rawOverride:profileVisibility:)`); the author's
///        `profile_visibility` is fetched ONLY when the override is nil, and a
///        failed fetch resolves to 'friends' → gate closed (fail-closed).
///     b. one `journal_tag` notification per `watchedWithUserIds` friend
///        (body = first 100 chars of review) — fires REGARDLESS of visibility
///        and re-fires on every save (audit D2 known flaw; mirrored as-is).
///
/// `guard !saving` re-entrancy: overlapping saves are dropped (a double-tapped
/// Save button must not double-write).
///
/// Header last reviewed: 2026-07-07
@MainActor
public final class JournalDraftModel: ObservableObject {

    /// Composer lifecycle. The model is born `.loading`; `openForEntry` flips it
    /// `.ready` only after the probe resolves and the draft is populated. A save
    /// is refused unless `.ready`.
    public enum Phase: Equatable, Sendable {
        case loading
        case ready
    }

    // MARK: Injected IO

    /// `JournalRepository.getOwnEntry(tmdbId:)` — the FULL owner probe.
    public typealias ProbeOwnEntry = (String) async throws -> JournalRow?
    /// `JournalRepository.ratingTier(tmdbId:)` — `user_rankings.tier` lookup.
    public typealias ResolveRatingTier = (String) async throws -> String?
    /// `JournalRepository.upsert(_:)` — full-replace, returns the written row.
    public typealias Upsert = (JournalUpsertPayload) async throws -> JournalRow
    /// `PhotoStore.upload(data:userID:entryID:index:ext:)` bound to `(data,
    /// entryID, index, ext)` — the model owns the minted `entryID`.
    public typealias UploadPhoto = (Data, UUID, Int, String) async throws -> String
    /// `ProfileRepository.currentVisibility()` — the author's
    /// `profile_visibility` (nil on absence/failure → fail-closed to friends).
    public typealias FetchProfileVisibility = () async -> String?
    /// Emit a `review` activity event (`activity_events` insert). Injected so
    /// the gate is testable; the screen binds it to the real insert.
    public typealias EmitReviewEvent = (ReviewEventInput) async -> Void
    /// Emit one `journal_tag` notification for a tagged friend (`notifications`
    /// insert). Injected so the fan-out is testable.
    public typealias EmitJournalTag = (JournalTagInput) async -> Void
    /// The signed-in user id (`SpoolClient.currentUserID`).
    public typealias CurrentUserID = () async -> UUID?

    /// The `review` activity-event body — mirrors web `logReviewActivityEvent`'s
    /// `review` object (`activity_events`, `event_type: 'review'`).
    public struct ReviewEventInput: Equatable, Sendable {
        public let tmdbId: String
        public let title: String
        public let posterUrl: String?
        public let tier: String?
        public let body: String
        public let containsSpoilers: Bool
    }

    /// One `journal_tag` notification row — mirrors web's `notifications` insert
    /// (`type: 'journal_tag'`, body = first 100 chars of the review).
    public struct JournalTagInput: Equatable, Sendable {
        public let friendID: UUID
        public let actorID: UUID
        public let title: String
        public let body: String?
        public let referenceID: UUID
    }

    // MARK: Published state

    /// The editable draft — two-way bound by the composer. Mutated directly by
    /// the view (`model.draft.reviewText = …`).
    @Published public var draft: JournalDraft
    /// Lifecycle. `.loading` until the probe resolves; a save requires `.ready`.
    @Published public private(set) var phase: Phase = .loading
    /// A save (or photo mint) is in flight — disables the Save button and gates
    /// re-entrancy.
    @Published public private(set) var saving: Bool = false
    /// Inline save-failure copy (lowercase voice); nil when clear.
    @Published public private(set) var inlineError: String?

    // MARK: Stored

    /// The minted journal-entry id — nil for a brand-new entry until the first
    /// save returns a row. Photo paths and side-effect references key off it.
    public private(set) var loadedEntryID: UUID?

    /// The probed owner row's `rating_tier` at open time — the fallback when a
    /// tier lookup THROWS at save time (a transient failure must NOT null out an
    /// already-set tier on the full replace). nil when there was no probed row
    /// (a brand-new entry has no existing tier to preserve).
    private var probedRatingTier: String?

    private let probeOwnEntry: ProbeOwnEntry
    private let seedRow: JournalRow?
    private let resolveRatingTier: ResolveRatingTier
    private let upsertIO: Upsert
    private let uploadPhotoIO: UploadPhoto
    private let fetchProfileVisibility: FetchProfileVisibility
    private let emitReviewEvent: EmitReviewEvent
    private let emitJournalTag: EmitJournalTag
    private let currentUserID: CurrentUserID

    public init(
        probeOwnEntry: @escaping ProbeOwnEntry,
        seed: JournalRow?,
        resolveRatingTier: @escaping ResolveRatingTier,
        upsert: @escaping Upsert,
        uploadPhoto: @escaping UploadPhoto,
        fetchProfileVisibility: @escaping FetchProfileVisibility,
        emitReviewEvent: @escaping EmitReviewEvent,
        emitJournalTag: @escaping EmitJournalTag,
        currentUserID: @escaping CurrentUserID
    ) {
        self.probeOwnEntry = probeOwnEntry
        self.seedRow = seed
        self.resolveRatingTier = resolveRatingTier
        self.upsertIO = upsert
        self.uploadPhotoIO = uploadPhoto
        self.fetchProfileVisibility = fetchProfileVisibility
        self.emitReviewEvent = emitReviewEvent
        self.emitJournalTag = emitJournalTag
        self.currentUserID = currentUserID
        // A placeholder empty draft until `openForEntry` populates it — the
        // composer stays `.loading` so this is never rendered/editable.
        self.draft = Self.blankDraft(tmdbId: "", title: "", posterUrl: nil)
    }

    // MARK: - Probe-before-edit open

    /// Probe the FULL owner row, pick probed-over-seed, populate the draft, then
    /// go `.ready`. The composer renders `.loading` until this returns, so the
    /// user can never edit (or save) a partially-hydrated draft — the wipe-bug
    /// guard by construction.
    ///
    /// - `seed` (also passed at init) is the ceremony/list/search row. The probed
    ///   owner row wins whenever it exists; a nil probe falls back to the seed;
    ///   both nil = a fresh draft seeded from the passed movie identity.
    public func openForEntry(tmdbId: String, title: String, posterUrl: String?, seed: JournalRow?) async {
        phase = .loading

        // The FULL owner row (keeps personal_takeaway). A probe failure is
        // treated as "no existing entry" — we still let the user compose (fresh
        // or from the seed) rather than blocking the composer on a read hiccup.
        let probed = try? await probeOwnEntry(tmdbId)

        let chosen = JournalEntryContract.pickEntryForEdit(probed: probed, passed: seed ?? seedRow)
        if let row = chosen {
            draft = JournalEntryContract.draft(from: row)
            loadedEntryID = row.id
        } else {
            draft = Self.blankDraft(tmdbId: tmdbId, title: title, posterUrl: posterUrl)
            loadedEntryID = nil
        }
        // Preserve ONLY the probed owner row's tier as the throw-fallback — a
        // seed/list row (which omits or staleness-carries tier) must not backstop
        // a lookup failure; only the fresh owner probe is authoritative.
        probedRatingTier = probed?.rating_tier
        inlineError = nil
        phase = .ready
    }

    // MARK: - Save (full replace + side effects)

    /// Full-replace save + side effects, mirroring web `upsertJournalEntry`.
    /// Returns the written row (also used internally by `addPhoto` to mint the
    /// id). Refused unless `.ready` and no save is already in flight.
    @discardableResult
    public func save() async -> JournalRow? {
        guard phase == .ready else { return nil }
        guard !saving else { return nil }
        saving = true
        defer { saving = false }

        do {
            let row = try await performUpsert()
            loadedEntryID = row.id
            await runSideEffects(for: row)
            inlineError = nil
            return row
        } catch {
            inlineError = Self.saveFailure
            return nil
        }
    }

    /// Resolve tier (never the form), build the full-20-field payload, upsert.
    private func performUpsert() async throws -> JournalRow {
        guard let userID = await currentUserID() else { throw DraftError.notAuthenticated }
        let tier = await resolvedTierForSave()
        let payload = JournalEntryContract.upsertPayload(userID: userID, ratingTier: tier, from: draft)
        return try await upsertIO(payload)
    }

    /// The `rating_tier` to write on a full replace. A genuine nil (the item is
    /// unranked) writes null — correct. But a tier-lookup THROW (a transient
    /// read failure) must NOT clobber an already-set tier: fall back to the
    /// probed owner row's tier captured at open time, so a hiccup preserves the
    /// existing value. A brand-new entry has no probed tier, so the fallback is
    /// itself nil (unranked → null, as it should be).
    private func resolvedTierForSave() async -> String? {
        do {
            return try await resolveRatingTier(draft.tmdbId)
        } catch {
            return probedRatingTier
        }
    }

    /// Web order: (1) review activity event (gated), (2) journal_tag per friend.
    private func runSideEffects(for row: JournalRow) async {
        await emitReviewEventIfPublic(row: row)
        await emitJournalTags(row: row)
    }

    /// Gate 1: emit the `review` activity event ONLY when review non-empty AND
    /// resolved visibility == public. Uses the RAW override overload; fetches the
    /// author's `profile_visibility` ONLY when the override is nil; a failed
    /// fetch resolves to 'friends' → gate closed (fail-closed — never leak a
    /// friends-only body into explore).
    private func emitReviewEventIfPublic(row: JournalRow) async {
        let review = draft.reviewText
        guard !review.isEmpty else { return }

        let rawOverride = draft.visibilityOverride?.rawValue
        var profileVisibility: String? = nil
        if rawOverride == nil {
            // Fetch only when there's no explicit override (web parity). A nil
            // result (absence OR failure) fails closed via resolveVisibility's
            // unknown-profile → friends branch.
            profileVisibility = await fetchProfileVisibility()
        }
        let resolved = JournalEntryContract.resolveVisibility(
            rawOverride: rawOverride, profileVisibility: profileVisibility
        )
        guard JournalEntryContract.shouldEmitReviewEvent(reviewText: review, resolved: resolved) else { return }

        await emitReviewEvent(ReviewEventInput(
            tmdbId: row.tmdb_id,
            title: row.title,
            posterUrl: row.poster_url,
            tier: row.rating_tier,
            body: review,
            containsSpoilers: draft.containsSpoilers
        ))
    }

    /// Gate 2: one `journal_tag` per tagged friend, body = first 100 chars of the
    /// review (nil when the review is empty). Fires REGARDLESS of visibility and
    /// re-fires every save (audit D2; mirrored as-is).
    private func emitJournalTags(row: JournalRow) async {
        let friends = draft.watchedWithUserIds
        guard !friends.isEmpty else { return }
        guard let actorID = await currentUserID() else { return }

        let body = draft.reviewText.isEmpty ? nil : String(draft.reviewText.prefix(100))
        for friendID in friends {
            await emitJournalTag(JournalTagInput(
                friendID: friendID,
                actorID: actorID,
                title: "watched \(row.title) with you",
                body: body,
                referenceID: row.id
            ))
        }
    }

    // MARK: - Photos (id-after-mint ordering)

    /// Add a photo. Mirrors web `handlePhotoAdd` (JournalConversation.tsx
    /// L416-428) EXACTLY: photos key off the ENTRY UUID, which a brand-new entry
    /// doesn't have until it's saved. So if no id has been minted, mint one with
    /// a MINIMAL, SIDE-EFFECT-FREE upsert (`mintMinimalEntry` — title + posterUrl
    /// only, empty review so the gate is closed, NO tagged friends), upload under
    /// that id at the next index, and hold the new path in the IN-MEMORY draft.
    ///
    /// The new `photo_paths` is NOT auto-persisted here — it lands on the row on
    /// the user's next EXPLICIT `save()`, which runs the review-event / journal_tag
    /// side effects exactly once (web parity: photo-add fires ZERO side effects,
    /// even if the user already typed a public review or tagged friends). An
    /// existing entry already has its id, so it uploads straight away — still no
    /// side effects, still deferred to the explicit save.
    public func addPhoto(data: Data, ext: String) async {
        guard phase == .ready, !saving else { return }
        guard draft.photoPaths.count < JournalConstants.journalMaxPhotos else { return }

        // Ensure the entry has a minted id WITHOUT running side effects (web mints
        // with a bare {title, posterUrl}, holding the photo path in view state).
        let entryID: UUID
        if let existing = loadedEntryID {
            entryID = existing
        } else if let minted = await mintMinimalEntry() {
            entryID = minted
        } else {
            return   // mint failed — inlineError already set
        }

        let index = draft.photoPaths.count
        do {
            let path = try await uploadPhotoIO(data, entryID, index, ext)
            // In-memory only; persisted on the user's next explicit save().
            draft.photoPaths.append(path)
        } catch {
            inlineError = Self.photoFailure
        }
    }

    /// Mint a brand-new entry with a MINIMAL, side-effect-free payload so
    /// `addPhoto` has an entry id to upload under. Mirrors web `handlePhotoAdd`'s
    /// `{ title, posterUrl }` upsert: review empty (review-event gate closed),
    /// NO tagged friends (no journal_tag fan-out), all other columns their
    /// full-replace defaults. Crucially this does NOT call `runSideEffects` — a
    /// photo-add must never emit a review event or a tag notification (those fire
    /// only on the user's explicit save). Returns the minted id, caching it in
    /// `loadedEntryID`; nil on failure (with `inlineError` set).
    private func mintMinimalEntry() async -> UUID? {
        guard let userID = await currentUserID() else {
            inlineError = Self.saveFailure
            return nil
        }
        // A minimal draft: only the movie identity carries over; everything else
        // is the blank default (empty review → gate closed, no friends → no tags,
        // no photos yet). tmdb_id/user_id/contains_spoilers/is_rewatch/arrays are
        // all supplied by the full-replace payload builder.
        let minimal = Self.blankDraft(
            tmdbId: draft.tmdbId, title: draft.title, posterUrl: draft.posterUrl
        )
        let tier = await resolvedTierForSave()
        let payload = JournalEntryContract.upsertPayload(userID: userID, ratingTier: tier, from: minimal)
        do {
            let row = try await upsertIO(payload)
            loadedEntryID = row.id
            return row.id
        } catch {
            inlineError = Self.saveFailure
            return nil
        }
    }

    /// Remove a photo path from the draft. The stored object is left in the
    /// bucket (web parity: `deleteJournalPhoto` on save-time cleanup is out of
    /// this cycle's scope); the next save writes the shortened `photo_paths`.
    public func removePhoto(path: String) {
        draft.photoPaths.removeAll { $0 == path }
    }

    // MARK: - Seed factory

    /// The ceremony convenience seed: fold the one-liner into `review_text` and
    /// carry the moods (plan note — there is NO separate one-liner column). Used
    /// by Task 6 when opening the composer from the rank ceremony. `id` is a
    /// throwaway placeholder — a ceremony seed with no existing owner row loses
    /// to a nil probe only insofar as `pickEntryForEdit` returns it (both nil →
    /// this seed), and its id is never used to write (save re-mints via upsert).
    public static func ceremonySeed(
        tmdbId: String, title: String, posterUrl: String?,
        line: String, moods: [String]
    ) -> JournalRow {
        JournalRow(
            id: UUID(), user_id: UUID(), tmdb_id: tmdbId, title: title,
            poster_url: posterUrl, rating_tier: nil, review_text: line,
            contains_spoilers: false, mood_tags: moods, vibe_tags: [],
            favorite_moments: [], standout_performances: [],
            watched_date: StubWriteContract.localDateString(),
            watched_location: nil, watched_with_user_ids: [],
            watched_platform: nil, is_rewatch: false, rewatch_note: nil,
            personal_takeaway: nil, photo_paths: [], visibility_override: nil,
            like_count: 0, created_at: ""
        )
    }

    /// A brand-new empty draft carrying only the movie identity + local
    /// `watched_date` default (the composer binds non-optional fields).
    static func blankDraft(tmdbId: String, title: String, posterUrl: String?) -> JournalDraft {
        JournalDraft(
            tmdbId: tmdbId, title: title, posterUrl: posterUrl,
            reviewText: "", containsSpoilers: false,
            moodTags: [], vibeTags: [], favoriteMoments: [],
            standoutPerformances: [], watchedDate: StubWriteContract.localDateString(),
            watchedLocation: "", watchedWithUserIds: [], watchedPlatform: nil,
            isRewatch: false, rewatchNote: "", personalTakeaway: "",
            photoPaths: [], visibilityOverride: nil
        )
    }

    // MARK: - Copy / errors

    static let saveFailure = "couldn't save — try again"
    static let photoFailure = "couldn't add photo — try again"

    enum DraftError: Error { case notAuthenticated }
}
