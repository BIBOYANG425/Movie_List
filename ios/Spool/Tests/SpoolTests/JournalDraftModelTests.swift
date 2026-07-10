import XCTest
@testable import Spool

/// The composer state model — the correctness keystone of the C2 journal cycle
/// (plan Task 4). All IO is injected as closures (same idiom as
/// `TicketEngagementModelTests` / `FeedPageAssembler`), so every load-bearing
/// invariant is XCTest-covered with zero network.
///
/// Contract pins (docs/contracts/shared-payloads.md ## journal_entries):
///  - PROBE-BEFORE-EDIT: `openForEntry` awaits the FULL owner row
///    (`getOwnEntry`), runs it through `pickEntryForEdit(probed, seed)`, and the
///    freshly-probed owner row ALWAYS wins over a takeaway-less seed — the exact
///    web wipe-bug guard. The model starts `.loading`; a save is impossible
///    until `.ready`.
///  - FULL-REPLACE SAVE: `save()` resolves rating_tier, builds the full 20-field
///    `upsertPayload`, upserts, returns the row. Never a partial payload.
///  - PHOTO ORDERING: for a NEW entry the id doesn't exist until first save;
///    `addPhoto` saves first to mint the id, uploads under `{userId}/{ENTRY-UUID}
///    /{i}`, appends the path, saves again to persist `photo_paths`.
///  - SIDE EFFECTS on save (mirror web exactly): (1) `review` activity event
///    ONLY when review non-empty AND resolved visibility == public (raw override
///    overload; profile_visibility fetched only when override nil; failed fetch
///    → friends → gate closed). (2) one `journal_tag` per tagged friend (body =
///    first 100 chars of review) regardless of visibility, re-fires each save.
///  - `guard !saving` re-entrancy.
@MainActor
final class JournalDraftModelTests: XCTestCase {

    private let me = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let friendA = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!
    private let friendB = UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!
    private let entryID = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!

    private struct FakeError: Error {}

    // MARK: fixtures

    /// A full owner row (keeps `personal_takeaway`) — the shape `getOwnEntry`
    /// returns from the probe.
    private func ownerRow(
        id: UUID? = nil,
        tmdbId: String = "603",
        title: String = "The Matrix",
        review: String? = "loved it",
        takeaway: String? = "trust the questions",
        overrideVis: String? = nil,
        photoPaths: [String]? = [],
        moods: [String]? = ["nostalgic"]
    ) -> JournalRow {
        JournalRow(
            id: id ?? entryID, user_id: me, tmdb_id: tmdbId, title: title,
            poster_url: "/p.jpg", rating_tier: "loved", review_text: review,
            contains_spoilers: false, mood_tags: moods, vibe_tags: [],
            favorite_moments: [], standout_performances: [],
            watched_date: "2026-07-01", watched_location: nil, watched_with_user_ids: [],
            watched_platform: nil, is_rewatch: false, rewatch_note: nil,
            personal_takeaway: takeaway, photo_paths: photoPaths, visibility_override: overrideVis,
            like_count: 0, created_at: "2026-07-01T00:00:00+00:00"
        )
    }

    /// A takeaway-LESS "seed"/passed row (as a list/search read would omit it) —
    /// the wipe-bug trap. `personal_takeaway == nil` here.
    private func seedRow(review: String? = "seed review", moods: [String]? = ["cozy"]) -> JournalRow {
        JournalRow(
            id: entryID, user_id: me, tmdb_id: "603", title: "The Matrix",
            poster_url: "/p.jpg", rating_tier: "loved", review_text: review,
            contains_spoilers: false, mood_tags: moods, vibe_tags: [],
            favorite_moments: [], standout_performances: [],
            watched_date: "2026-07-01", watched_location: nil, watched_with_user_ids: [],
            watched_platform: nil, is_rewatch: false, rewatch_note: nil,
            personal_takeaway: nil, photo_paths: [], visibility_override: nil,
            like_count: 0, created_at: "2026-07-01T00:00:00+00:00"
        )
    }

    // MARK: recorder — captures what the injected closures received

    private final class Recorder: @unchecked Sendable {
        var upsertPayloads: [JournalUpsertPayload] = []
        var uploadCalls: [(entryID: UUID, index: Int, ext: String)] = []
        var reviewEvents: [JournalDraftModel.ReviewEventInput] = []
        var journalTags: [JournalDraftModel.JournalTagInput] = []
        var profileFetchCount = 0
        /// C7-iOS Task 2: how many times the post-write achievement hook fired.
        var grantCount = 0
    }

    /// Build a model with sensible no-op defaults; each test overrides the
    /// closures it cares about. `upsert` echoes the payload back as a row so the
    /// returned-id path works by default.
    private func makeModel(
        rec: Recorder = Recorder(),
        probe: @escaping (String) async throws -> JournalRow? = { _ in nil },
        seed: JournalRow? = nil,
        ratingTier: @escaping (String) async throws -> String? = { _ in "loved" },
        upsert: ((JournalUpsertPayload) async throws -> JournalRow)? = nil,
        uploadPhoto: ((Data, UUID, Int, String) async throws -> String)? = nil,
        profileVisibility: @escaping () async -> String? = { nil },
        userID: @escaping () async -> UUID? = { UUID(uuidString: "00000000-0000-0000-0000-00000000000A") }
    ) -> JournalDraftModel {
        let capturedEntry = entryID
        let defaultUpsert: (JournalUpsertPayload) async throws -> JournalRow = { payload in
            rec.upsertPayloads.append(payload)
            return JournalRow(
                id: capturedEntry, user_id: payload.user_id, tmdb_id: payload.tmdb_id,
                title: payload.title, poster_url: payload.poster_url,
                rating_tier: payload.rating_tier, review_text: payload.review_text,
                contains_spoilers: payload.contains_spoilers, mood_tags: payload.mood_tags,
                vibe_tags: payload.vibe_tags, favorite_moments: payload.favorite_moments,
                standout_performances: payload.standout_performances,
                watched_date: payload.watched_date, watched_location: payload.watched_location,
                watched_with_user_ids: payload.watched_with_user_ids,
                watched_platform: payload.watched_platform, is_rewatch: payload.is_rewatch,
                rewatch_note: payload.rewatch_note, personal_takeaway: payload.personal_takeaway,
                photo_paths: payload.photo_paths, visibility_override: payload.visibility_override,
                like_count: 0, created_at: "2026-07-01T00:00:00+00:00"
            )
        }
        return JournalDraftModel(
            probeOwnEntry: probe,
            seed: seed,
            resolveRatingTier: ratingTier,
            upsert: { payload in
                if let upsert { return try await upsert(payload) }
                return try await defaultUpsert(payload)
            },
            uploadPhoto: { data, eid, index, ext in
                rec.uploadCalls.append((eid, index, ext))
                if let uploadPhoto { return try await uploadPhoto(data, eid, index, ext) }
                return "\(eid.uuidString.lowercased())/\(index).jpg"
            },
            fetchProfileVisibility: { rec.profileFetchCount += 1; return await profileVisibility() },
            emitReviewEvent: { rec.reviewEvents.append($0) },
            emitJournalTag: { rec.journalTags.append($0) },
            grantAchievements: { rec.grantCount += 1 },
            currentUserID: userID
        )
    }

    // MARK: - Probe-before-edit

    func testOpen_startsLoading_thenReady() async {
        let model = makeModel(probe: { _ in self.ownerRow() })
        // Before open resolves, the model is not yet editable.
        XCTAssertEqual(model.phase, .loading)
        await model.openForEntry(tmdbId: "603", title: "The Matrix", posterUrl: "/p.jpg", seed: nil)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.draft.title, "The Matrix")
    }

    /// THE WIPE-BUG GUARD: the freshly-probed owner row (WITH takeaway) must win
    /// over a takeaway-less seed. Opening from the seed and saving would null the
    /// takeaway — this is the exact web bug the probe prevents.
    func testOpen_probeWinsOverSeed_takeawaySurvives() async {
        let probed = ownerRow(takeaway: "trust the questions")
        let seed = seedRow()   // personal_takeaway == nil
        let model = makeModel(probe: { _ in probed }, seed: seed)

        await model.openForEntry(tmdbId: "603", title: "The Matrix", posterUrl: "/p.jpg", seed: seed)

        XCTAssertEqual(model.draft.personalTakeaway, "trust the questions",
                       "probed takeaway must survive a takeaway-less seed")
        // The probed review wins too, not the seed's.
        XCTAssertEqual(model.draft.reviewText, "loved it")
    }

    /// A nil probe with a seed starts from the ceremony seed.
    func testOpen_nilProbe_fallsBackToSeed() async {
        let seed = seedRow(review: "seed review", moods: ["cozy"])
        let model = makeModel(probe: { _ in nil }, seed: seed)

        await model.openForEntry(tmdbId: "603", title: "The Matrix", posterUrl: "/p.jpg", seed: seed)

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.draft.reviewText, "seed review")
        XCTAssertEqual(model.draft.moodTags, ["cozy"])
    }

    /// Both nil = brand-new fresh draft seeded from the passed movie identity.
    func testOpen_bothNil_freshDraft() async {
        let model = makeModel(probe: { _ in nil }, seed: nil)
        await model.openForEntry(tmdbId: "603", title: "The Matrix", posterUrl: "/p.jpg", seed: nil)

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.draft.tmdbId, "603")
        XCTAssertEqual(model.draft.title, "The Matrix")
        XCTAssertEqual(model.draft.reviewText, "")
        XCTAssertEqual(model.draft.personalTakeaway, "")
        XCTAssertTrue(model.draft.moodTags.isEmpty)
    }

    /// A ceremony seed (moods + line-as-review) with no existing entry seeds the
    /// composer from that convenience row.
    func testOpen_ceremonySeed_seedsMoodsAndLine() async {
        let ceremony = JournalDraftModel.ceremonySeed(
            tmdbId: "603", title: "The Matrix", posterUrl: "/p.jpg",
            line: "still hits", moods: ["nostalgic", "hopeful"]
        )
        let model = makeModel(probe: { _ in nil }, seed: ceremony)
        await model.openForEntry(tmdbId: "603", title: "The Matrix", posterUrl: "/p.jpg", seed: ceremony)

        XCTAssertEqual(model.draft.reviewText, "still hits")
        XCTAssertEqual(model.draft.moodTags, ["nostalgic", "hopeful"])
    }

    /// A save is impossible before the probe resolves: while `.loading` the
    /// model refuses to write.
    func testSave_refusedWhileLoading() async {
        let rec = Recorder()
        let model = makeModel(rec: rec)   // never opened → phase .loading
        await model.save()
        XCTAssertTrue(rec.upsertPayloads.isEmpty, "no write may happen before .ready")
    }

    // MARK: - Full-replace save

    func testSave_buildsFull20FieldPayload() async throws {
        let rec = Recorder()
        let model = makeModel(rec: rec, probe: { _ in nil }, ratingTier: { _ in "loved" })
        await model.openForEntry(tmdbId: "603", title: "The Matrix", posterUrl: "/p.jpg", seed: nil)
        model.draft.reviewText = "great"
        model.draft.personalTakeaway = "keep this"

        await model.save()

        XCTAssertEqual(rec.upsertPayloads.count, 1)
        let payload = try XCTUnwrap(rec.upsertPayloads.first)
        // rating_tier came from the lookup, NEVER the form.
        XCTAssertEqual(payload.rating_tier, "loved")
        XCTAssertEqual(payload.review_text, "great")
        XCTAssertEqual(payload.personal_takeaway, "keep this")

        // Full-replace proof: encode → exactly the 20 client keys, every optional
        // present (explicit null), no field dropped.
        let data = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expected: Set<String> = [
            "user_id", "tmdb_id", "title", "poster_url", "rating_tier", "review_text",
            "contains_spoilers", "mood_tags", "vibe_tags", "favorite_moments",
            "standout_performances", "watched_date", "watched_location",
            "watched_with_user_ids", "watched_platform", "is_rewatch", "rewatch_note",
            "personal_takeaway", "photo_paths", "visibility_override",
        ]
        XCTAssertEqual(Set(json.keys), expected)
    }

    /// Empty review text coerces to null in the payload (contract: cleared field
    /// wipes on the full replace).
    func testSave_emptyReviewCoercesToNull() async throws {
        let rec = Recorder()
        let model = makeModel(rec: rec, probe: { _ in nil })
        await model.openForEntry(tmdbId: "603", title: "T", posterUrl: nil, seed: nil)
        model.draft.reviewText = ""
        await model.save()
        let payload = try XCTUnwrap(rec.upsertPayloads.first)
        XCTAssertNil(payload.review_text)
    }

    /// A genuine unranked item (tier lookup returns nil, no throw) writes null —
    /// correct, even when a probed row is present.
    func testSave_tierGenuinelyNil_writesNull() async throws {
        let rec = Recorder()
        let probed = ownerRow()   // probed row has rating_tier "loved"
        let model = makeModel(rec: rec, probe: { _ in probed }, ratingTier: { _ in nil })
        await model.openForEntry(tmdbId: "603", title: "The Matrix", posterUrl: "/p.jpg", seed: nil)

        await model.save()
        let payload = try XCTUnwrap(rec.upsertPayloads.first)
        XCTAssertNil(payload.rating_tier, "a true unranked (nil, no throw) writes null")
    }

    /// A TRANSIENT tier-lookup THROW must NOT null out an already-set tier: fall
    /// back to the probed owner row's tier captured at open time.
    func testSave_tierLookupThrows_preservesProbedTier() async throws {
        let rec = Recorder()
        let probed = ownerRow()   // rating_tier "loved"
        let model = makeModel(rec: rec, probe: { _ in probed }, ratingTier: { _ in throw FakeError() })
        await model.openForEntry(tmdbId: "603", title: "The Matrix", posterUrl: "/p.jpg", seed: nil)

        await model.save()
        let payload = try XCTUnwrap(rec.upsertPayloads.first)
        XCTAssertEqual(payload.rating_tier, "loved",
                       "a transient lookup failure must preserve the existing tier, not clobber it")
    }

    // MARK: - Re-entrancy

    func testSave_reentrancyGuard() async {
        let rec = Recorder()
        // A slow upsert so the second save() call overlaps the first.
        let model = makeModel(rec: rec, probe: { _ in nil }, upsert: { payload in
            rec.upsertPayloads.append(payload)
            try? await Task.sleep(nanoseconds: 40_000_000)
            return self.ownerRow()
        })
        await model.openForEntry(tmdbId: "603", title: "T", posterUrl: nil, seed: nil)

        async let first = model.save()
        async let second = model.save()
        _ = await (first, second)

        XCTAssertEqual(rec.upsertPayloads.count, 1, "overlapping save must be dropped")
    }

    // MARK: - Photo ordering (side-effect-free mint, id must exist first)

    /// A NEW entry has no id until it exists. `addPhoto` mints one with a MINIMAL,
    /// side-effect-free payload (exactly ONE upsert), uploads under that ENTRY
    /// UUID, and holds the path in the IN-MEMORY draft — NOT auto-persisted (that
    /// happens on the user's next explicit save). Mirrors web `handlePhotoAdd`.
    func testAddPhoto_newEntry_mintsMinimalThenUploadsUnderMintedID() async throws {
        let rec = Recorder()
        let model = makeModel(rec: rec, probe: { _ in nil })
        await model.openForEntry(tmdbId: "603", title: "T", posterUrl: "/p.jpg", seed: nil)
        // The user typed a review before adding a photo — must NOT be persisted by
        // the mint (web mints a bare {title, posterUrl}).
        model.draft.reviewText = "typed before photo"

        await model.addPhoto(data: Data([0x1]), ext: "jpg")

        // Exactly ONE upsert: the minimal mint (no persist-again).
        XCTAssertEqual(rec.upsertPayloads.count, 1)
        let mint = try XCTUnwrap(rec.upsertPayloads.first)
        // Minimal payload: identity only, empty review (gate closed), no photos.
        XCTAssertEqual(mint.tmdb_id, "603")
        XCTAssertEqual(mint.title, "T")
        XCTAssertNil(mint.review_text, "mint carries an EMPTY review, not the draft's")
        XCTAssertTrue(mint.photo_paths.isEmpty, "mint has no photos yet")
        XCTAssertTrue(mint.watched_with_user_ids.isEmpty)
        // Uploaded under the minted entry id (not the tmdb id).
        XCTAssertEqual(rec.uploadCalls.count, 1)
        XCTAssertEqual(rec.uploadCalls.first?.entryID, entryID)
        XCTAssertEqual(rec.uploadCalls.first?.index, 0)
        // Path landed in the in-memory draft; the typed review is still there,
        // unpersisted, waiting for the explicit save.
        XCTAssertEqual(model.draft.photoPaths.count, 1)
        XCTAssertEqual(model.draft.reviewText, "typed before photo")
    }

    /// An EXISTING entry (already has an id from the probe) uploads immediately —
    /// no mint upsert at all; the index is the current photo count, and the path
    /// is held in-memory until the next explicit save.
    func testAddPhoto_existingEntry_uploadsAtNextIndexNoUpsert() async throws {
        let rec = Recorder()
        let probed = ownerRow(photoPaths: ["a/0.jpg"])
        let model = makeModel(rec: rec, probe: { _ in probed })
        await model.openForEntry(tmdbId: "603", title: "The Matrix", posterUrl: "/p.jpg", seed: nil)

        await model.addPhoto(data: Data([0x2]), ext: "png")

        XCTAssertTrue(rec.upsertPayloads.isEmpty, "existing id → no mint upsert")
        XCTAssertEqual(rec.uploadCalls.first?.entryID, entryID)
        XCTAssertEqual(rec.uploadCalls.first?.index, 1, "next index = existing photo count")
        XCTAssertEqual(model.draft.photoPaths.count, 2)
    }

    /// THE FIX: a new entry with a public review + a tagged friend fires ZERO
    /// review-events and ZERO journal_tags during photo-add. Web mints
    /// side-effect-free; the side effects fire only on the subsequent EXPLICIT
    /// save, exactly once.
    func testAddPhoto_newEntry_firesZeroSideEffects() async throws {
        let rec = Recorder()
        let model = makeModel(rec: rec, probe: { _ in nil })
        await model.openForEntry(tmdbId: "603", title: "The Matrix", posterUrl: "/p.jpg", seed: nil)
        model.draft.reviewText = "public review"
        model.draft.visibilityOverride = .pub
        model.draft.watchedWithUserIds = [friendA]

        await model.addPhoto(data: Data([0x1]), ext: "jpg")

        // Photo-add: no side effects, ever.
        XCTAssertTrue(rec.reviewEvents.isEmpty, "photo-add must not emit a review event")
        XCTAssertTrue(rec.journalTags.isEmpty, "photo-add must not emit journal_tags")

        // The user's explicit save fires them once.
        await model.save()
        XCTAssertEqual(rec.reviewEvents.count, 1)
        XCTAssertEqual(rec.journalTags.count, 1)
    }

    func testRemovePhoto_dropsPath() async {
        let rec = Recorder()
        let probed = ownerRow(photoPaths: ["a/0.jpg", "a/1.jpg"])
        let model = makeModel(rec: rec, probe: { _ in probed })
        await model.openForEntry(tmdbId: "603", title: "The Matrix", posterUrl: "/p.jpg", seed: nil)

        model.removePhoto(path: "a/0.jpg")
        XCTAssertEqual(model.draft.photoPaths, ["a/1.jpg"])
    }

    // MARK: - Side effect: review activity event gate

    /// Non-empty review + resolved PUBLIC (explicit override) → event emitted.
    func testReviewEvent_publicOverride_emits() async {
        let rec = Recorder()
        let model = makeModel(rec: rec, probe: { _ in nil })
        await model.openForEntry(tmdbId: "603", title: "The Matrix", posterUrl: "/p.jpg", seed: nil)
        model.draft.reviewText = "public review"
        model.draft.visibilityOverride = .pub

        await model.save()

        XCTAssertEqual(rec.reviewEvents.count, 1)
        XCTAssertEqual(rec.reviewEvents.first?.body, "public review")
        // Override was explicit → no profile fetch needed.
        XCTAssertEqual(rec.profileFetchCount, 0)
    }

    /// Non-empty review + resolved FRIENDS (explicit override) → NO event.
    func testReviewEvent_friendsOverride_gateClosed() async {
        let rec = Recorder()
        let model = makeModel(rec: rec, probe: { _ in nil })
        await model.openForEntry(tmdbId: "603", title: "T", posterUrl: nil, seed: nil)
        model.draft.reviewText = "friends only"
        model.draft.visibilityOverride = .friends

        await model.save()
        XCTAssertTrue(rec.reviewEvents.isEmpty)
    }

    /// Empty review → NO event even when public.
    func testReviewEvent_emptyReview_noEmit() async {
        let rec = Recorder()
        let model = makeModel(rec: rec, probe: { _ in nil })
        await model.openForEntry(tmdbId: "603", title: "T", posterUrl: nil, seed: nil)
        model.draft.reviewText = ""
        model.draft.visibilityOverride = .pub

        await model.save()
        XCTAssertTrue(rec.reviewEvents.isEmpty)
    }

    /// Nil override + profile 'public' → fetch happens, resolves public → emit.
    func testReviewEvent_nilOverride_fetchesProfilePublic_emits() async {
        let rec = Recorder()
        let model = makeModel(rec: rec, probe: { _ in nil }, profileVisibility: { "public" })
        await model.openForEntry(tmdbId: "603", title: "T", posterUrl: nil, seed: nil)
        model.draft.reviewText = "inherits public"
        model.draft.visibilityOverride = nil

        await model.save()
        XCTAssertEqual(rec.profileFetchCount, 1, "override nil → profile fetched")
        XCTAssertEqual(rec.reviewEvents.count, 1)
    }

    /// Nil override + profile fetch FAILS (nil) → fail-closed to 'friends' → gate
    /// closed, no event.
    func testReviewEvent_nilOverride_failedFetch_failsClosed() async {
        let rec = Recorder()
        let model = makeModel(rec: rec, probe: { _ in nil }, profileVisibility: { nil })
        await model.openForEntry(tmdbId: "603", title: "T", posterUrl: nil, seed: nil)
        model.draft.reviewText = "should not leak"
        model.draft.visibilityOverride = nil

        await model.save()
        XCTAssertEqual(rec.profileFetchCount, 1)
        XCTAssertTrue(rec.reviewEvents.isEmpty, "failed fetch → friends → gate closed")
    }

    // MARK: - Side effect: journal_tag notifications

    /// One journal_tag per tagged friend, regardless of visibility.
    func testJournalTag_onePerFriend_regardlessOfVisibility() async {
        let rec = Recorder()
        let model = makeModel(rec: rec, probe: { _ in nil })
        await model.openForEntry(tmdbId: "603", title: "The Matrix", posterUrl: nil, seed: nil)
        model.draft.reviewText = "watched together"
        model.draft.visibilityOverride = .priv          // private — tags still fire
        model.draft.watchedWithUserIds = [friendA, friendB]

        await model.save()

        XCTAssertEqual(rec.journalTags.count, 2)
        XCTAssertEqual(Set(rec.journalTags.map { $0.friendID }), [friendA, friendB])
        // No review event (private), but tags still fired.
        XCTAssertTrue(rec.reviewEvents.isEmpty)
    }

    /// journal_tag body is the first 100 chars of the review.
    func testJournalTag_bodyTruncatedTo100() async {
        let rec = Recorder()
        let long = String(repeating: "x", count: 150)
        let model = makeModel(rec: rec, probe: { _ in nil })
        await model.openForEntry(tmdbId: "603", title: "T", posterUrl: nil, seed: nil)
        model.draft.reviewText = long
        model.draft.watchedWithUserIds = [friendA]

        await model.save()
        XCTAssertEqual(rec.journalTags.first?.body?.count, 100)
    }

    /// No tagged friends → no journal_tag.
    func testJournalTag_noFriends_noEmit() async {
        let rec = Recorder()
        let model = makeModel(rec: rec, probe: { _ in nil })
        await model.openForEntry(tmdbId: "603", title: "T", posterUrl: nil, seed: nil)
        model.draft.reviewText = "solo"
        model.draft.watchedWithUserIds = []
        await model.save()
        XCTAssertTrue(rec.journalTags.isEmpty)
    }

    // MARK: - Save failure surfaces inline error

    func testSave_failure_setsInlineError() async {
        let model = makeModel(probe: { _ in nil }, upsert: { _ in throw FakeError() })
        await model.openForEntry(tmdbId: "603", title: "T", posterUrl: nil, seed: nil)
        await model.save()
        XCTAssertNotNil(model.inlineError)
        XCTAssertFalse(model.saving)
    }

    // MARK: - Post-write achievement hook (C7-iOS Task 2)

    /// The grant hook fires EXACTLY ONCE on a confirmed save — after the upsert
    /// and side effects, never before (a partial/failed write must not grant).
    func testGrantHook_firesOnceOnConfirmedSave() async {
        let rec = Recorder()
        let model = makeModel(rec: rec, probe: { _ in nil })
        await model.openForEntry(tmdbId: "603", title: "The Matrix", posterUrl: "/p.jpg", seed: nil)
        model.draft.reviewText = "great"

        await model.save()

        XCTAssertEqual(rec.upsertPayloads.count, 1, "the primary write must have landed")
        XCTAssertEqual(rec.grantCount, 1, "grant fires once, only after a confirmed save")
    }

    /// A FAILED save (upsert throws) must NOT fire the grant hook — the primary
    /// write never confirmed, so no badge may be granted.
    func testGrantHook_noFireOnFailedSave() async {
        let rec = Recorder()
        let model = makeModel(rec: rec, probe: { _ in nil }, upsert: { _ in throw FakeError() })
        await model.openForEntry(tmdbId: "603", title: "T", posterUrl: nil, seed: nil)

        await model.save()

        XCTAssertNotNil(model.inlineError, "the save failed")
        XCTAssertEqual(rec.grantCount, 0, "a failed save must not grant achievements")
    }

    /// A save REFUSED because the model is still `.loading` (never opened) must
    /// not grant — no write happened, so the hook is unreachable.
    func testGrantHook_noFireWhenRefusedLoading() async {
        let rec = Recorder()
        let model = makeModel(rec: rec)   // never opened → phase .loading
        await model.save()
        XCTAssertTrue(rec.upsertPayloads.isEmpty)
        XCTAssertEqual(rec.grantCount, 0, "a refused save must not grant achievements")
    }

    /// The SIDE-EFFECT-FREE photo mint (`addPhoto` on a new entry) upserts a
    /// minimal row but must NOT fire the grant hook — grants belong only to the
    /// user's explicit save, exactly like the review-event / journal_tag gate.
    func testGrantHook_noFireOnPhotoMint() async {
        let rec = Recorder()
        let model = makeModel(rec: rec, probe: { _ in nil })
        await model.openForEntry(tmdbId: "603", title: "The Matrix", posterUrl: "/p.jpg", seed: nil)

        await model.addPhoto(data: Data([0x1]), ext: "jpg")
        XCTAssertEqual(rec.grantCount, 0, "the photo mint must not grant achievements")

        // The user's explicit save grants exactly once.
        await model.save()
        XCTAssertEqual(rec.grantCount, 1)
    }
}
