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
///  3. PHOTO ORDERING. Photos live at `{userId}/{ENTRY-UUID}/{i}`; a NEW entry
///     has no id until first save. So `addPhoto` mirrors web `handlePhotoAdd`:
///     if no minted id yet, `save()` first (the returned row mints the id), then
///     `uploadPhoto(..., entryID: mintedID, index: photoCount, ...)`, append the
///     returned path, and `save()` again to persist `photo_paths`. An existing
///     entry already has its id, so it uploads straight away.
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
        let tier = (try? await resolveRatingTier(draft.tmdbId)) ?? nil
        let payload = JournalEntryContract.upsertPayload(userID: userID, ratingTier: tier, from: draft)
        return try await upsertIO(payload)
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

    /// Add a photo. Mirrors web `handlePhotoAdd`: photos key off the ENTRY UUID,
    /// which a brand-new entry doesn't have until it's saved. So if no id has
    /// been minted, save FIRST (the returned row mints it), upload under that id
    /// at the next index, append the returned path, then save AGAIN to persist
    /// `photo_paths`. An existing entry already has its id, so it uploads
    /// straight away and one save persists the new path.
    public func addPhoto(data: Data, ext: String) async {
        guard phase == .ready, !saving else { return }
        guard draft.photoPaths.count < JournalConstants.journalMaxPhotos else { return }

        // Ensure the entry has a minted id (web: upsert to get loadedEntryId).
        let entryID: UUID
        if let existing = loadedEntryID {
            entryID = existing
        } else {
            guard let row = await save() else { return }   // mint the id
            entryID = row.id
        }

        let index = draft.photoPaths.count
        do {
            let path = try await uploadPhotoIO(data, entryID, index, ext)
            draft.photoPaths.append(path)
        } catch {
            inlineError = Self.photoFailure
            return
        }
        // Persist the new photo_paths on the row.
        _ = await save()
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
