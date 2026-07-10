import XCTest
@testable import Spool

/// Pure contract tests for the C2 journal marshalling seam. Mirrors the web
/// `services/__tests__/journalService.test.ts` truth tables (visibility,
/// event gate, full-replace column list, edit seam) against the binding
/// `journal_entries` contract in docs/contracts/shared-payloads.md.
final class JournalContractTests: XCTestCase {

    private let uid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let friendA = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    private let friendB = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!

    // MARK: helpers

    private func jsonObject<T: Encodable>(_ payload: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(payload)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func jsonKeys<T: Encodable>(_ payload: T) throws -> Set<String> {
        Set(try jsonObject(payload).keys)
    }

    // The exact 20 client-written columns from the contract's "Write shape".
    private let expectedUpsertKeys: Set<String> = [
        "user_id", "tmdb_id", "title", "poster_url", "rating_tier",
        "review_text", "contains_spoilers", "mood_tags", "vibe_tags",
        "favorite_moments", "standout_performances", "watched_date",
        "watched_location", "watched_with_user_ids", "watched_platform",
        "is_rewatch", "rewatch_note", "personal_takeaway", "photo_paths",
        "visibility_override",
    ]

    private func fullDraft() -> JournalDraft {
        JournalDraft(
            tmdbId: "603",
            title: "The Matrix",
            posterUrl: "https://image.tmdb.org/t/p/w500/matrix.jpg",
            reviewText: "A machine dream.",
            containsSpoilers: true,
            moodTags: ["thrilled", "amazed"],
            vibeTags: ["late_night"],
            favoriteMoments: ["the lobby", "red pill"],
            standoutPerformances: [
                StandoutPerformance(personId: 6384, name: "Keanu Reeves", character: "Neo"),
            ],
            watchedDate: "2026-07-06",
            watchedLocation: "home",
            watchedWithUserIds: [friendA, friendB],
            watchedPlatform: "netflix",
            isRewatch: true,
            rewatchNote: "still holds up",
            personalTakeaway: "choose your reality",
            photoPaths: ["u/603/0.jpg"],
            visibilityOverride: .pub
        )
    }

    // MARK: visibility truth table — COALESCE(override, profileVisibility)

    func testResolveVisibilityExplicitOverrideWinsRegardlessOfProfile() {
        for profile in ["public", "friends", "private", "garbage", nil] as [String?] {
            XCTAssertEqual(JournalEntryContract.resolveVisibility(override: .pub, profileVisibility: profile), .pub, "profile=\(String(describing: profile))")
            XCTAssertEqual(JournalEntryContract.resolveVisibility(override: .friends, profileVisibility: profile), .friends, "profile=\(String(describing: profile))")
            XCTAssertEqual(JournalEntryContract.resolveVisibility(override: .priv, profileVisibility: profile), .priv, "profile=\(String(describing: profile))")
        }
    }

    func testResolveVisibilityNilOverrideInheritsProfile() {
        XCTAssertEqual(JournalEntryContract.resolveVisibility(override: nil, profileVisibility: "public"), .pub)
        XCTAssertEqual(JournalEntryContract.resolveVisibility(override: nil, profileVisibility: "friends"), .friends)
        XCTAssertEqual(JournalEntryContract.resolveVisibility(override: nil, profileVisibility: "private"), .priv)
    }

    func testResolveVisibilityUnknownProfileFallsToFriendsNeverPublic() {
        // nil override + unknown/nil profile → friends (fail toward the safe
        // social default, never public).
        XCTAssertEqual(JournalEntryContract.resolveVisibility(override: nil, profileVisibility: "garbage"), .friends)
        XCTAssertEqual(JournalEntryContract.resolveVisibility(override: nil, profileVisibility: nil), .friends)
        XCTAssertEqual(JournalEntryContract.resolveVisibility(override: nil, profileVisibility: ""), .friends)
    }

    // MARK: raw-string overload — web parity (journalService.ts:39). A stored
    // ROW's visibility_override is an arbitrary string; a non-empty-but-INVALID
    // value fails closed to private (one step MORE restrictive than friends),
    // mirroring the SQL policy where a value matching no branch grants nothing.

    func testResolveVisibilityRawValidOverrideMapsToEnum() {
        for profile in ["public", "friends", "private", "garbage", nil] as [String?] {
            XCTAssertEqual(JournalEntryContract.resolveVisibility(rawOverride: "public", profileVisibility: profile), .pub, "profile=\(String(describing: profile))")
            XCTAssertEqual(JournalEntryContract.resolveVisibility(rawOverride: "friends", profileVisibility: profile), .friends, "profile=\(String(describing: profile))")
            XCTAssertEqual(JournalEntryContract.resolveVisibility(rawOverride: "private", profileVisibility: profile), .priv, "profile=\(String(describing: profile))")
        }
    }

    func testResolveVisibilityRawGarbageOverrideFailsClosedToPrivate() {
        // The exact web-parity case: a non-empty invalid stored override →
        // private, regardless of profile (never friends, never public).
        XCTAssertEqual(JournalEntryContract.resolveVisibility(rawOverride: "garbage", profileVisibility: "public"), .priv)
        XCTAssertEqual(JournalEntryContract.resolveVisibility(rawOverride: "garbage", profileVisibility: "garbage"), .priv)
        XCTAssertEqual(JournalEntryContract.resolveVisibility(rawOverride: "garbage", profileVisibility: nil), .priv)
        XCTAssertEqual(JournalEntryContract.resolveVisibility(rawOverride: "PUBLIC", profileVisibility: "public"), .priv, "case-sensitive: only exact lowercase is valid")
    }

    func testResolveVisibilityRawNilOrEmptyOverrideInheritsProfile() {
        // nil or empty override = "Default" → inherit profile (unknown/nil → friends).
        XCTAssertEqual(JournalEntryContract.resolveVisibility(rawOverride: nil, profileVisibility: "public"), .pub)
        XCTAssertEqual(JournalEntryContract.resolveVisibility(rawOverride: nil, profileVisibility: "private"), .priv)
        XCTAssertEqual(JournalEntryContract.resolveVisibility(rawOverride: nil, profileVisibility: "garbage"), .friends)
        XCTAssertEqual(JournalEntryContract.resolveVisibility(rawOverride: nil, profileVisibility: nil), .friends)
        XCTAssertEqual(JournalEntryContract.resolveVisibility(rawOverride: "", profileVisibility: "public"), .pub)
        XCTAssertEqual(JournalEntryContract.resolveVisibility(rawOverride: "", profileVisibility: nil), .friends)
    }

    func testTypedOverloadAgreesWithRawForAllValidInputs() {
        // One source of truth: the typed overload delegates to the raw one, so
        // for every valid (override, profile) pair the two must agree.
        let overrides: [JournalVisibility?] = [nil, .pub, .friends, .priv]
        let profiles: [String?] = ["public", "friends", "private", "garbage", "", nil]
        for override in overrides {
            for profile in profiles {
                let typed = JournalEntryContract.resolveVisibility(override: override, profileVisibility: profile)
                let raw = JournalEntryContract.resolveVisibility(rawOverride: override?.rawValue, profileVisibility: profile)
                XCTAssertEqual(typed, raw, "override=\(String(describing: override)) profile=\(String(describing: profile))")
            }
        }
    }

    // MARK: upsert payload — the exact 20-key set, full-replace

    func testUpsertPayloadEncodesExactly20ClientColumns() throws {
        let p = JournalEntryContract.upsertPayload(userID: uid, ratingTier: "S", from: fullDraft())
        XCTAssertEqual(try jsonKeys(p), expectedUpsertKeys,
                       "full-replace upsert must carry EVERY client column and nothing server-owned")
        XCTAssertEqual(expectedUpsertKeys.count, 20)
    }

    func testUpsertPayloadNeverIncludesServerOwnedColumns() throws {
        let keys = try jsonKeys(JournalEntryContract.upsertPayload(userID: uid, ratingTier: nil, from: fullDraft()))
        for server in ["id", "created_at", "updated_at", "like_count", "search_vector"] {
            XCTAssertFalse(keys.contains(server), "\(server) is server-owned and must never be written")
        }
    }

    func testUpsertPayloadValuesRoundTrip() throws {
        let obj = try jsonObject(JournalEntryContract.upsertPayload(userID: uid, ratingTier: "A", from: fullDraft()))
        XCTAssertEqual(obj["user_id"] as? String, uid.uuidString.lowercased())
        XCTAssertEqual(obj["tmdb_id"] as? String, "603")
        XCTAssertEqual(obj["title"] as? String, "The Matrix")
        XCTAssertEqual(obj["rating_tier"] as? String, "A")
        XCTAssertEqual(obj["review_text"] as? String, "A machine dream.")
        XCTAssertEqual(obj["contains_spoilers"] as? Bool, true)
        XCTAssertEqual(obj["mood_tags"] as? [String], ["thrilled", "amazed"])
        XCTAssertEqual(obj["vibe_tags"] as? [String], ["late_night"])
        XCTAssertEqual(obj["favorite_moments"] as? [String], ["the lobby", "red pill"])
        XCTAssertEqual(obj["watched_date"] as? String, "2026-07-06")
        XCTAssertEqual(obj["watched_location"] as? String, "home")
        XCTAssertEqual(obj["watched_platform"] as? String, "netflix")
        XCTAssertEqual(obj["is_rewatch"] as? Bool, true)
        XCTAssertEqual(obj["rewatch_note"] as? String, "still holds up")
        XCTAssertEqual(obj["personal_takeaway"] as? String, "choose your reality")
        XCTAssertEqual(obj["photo_paths"] as? [String], ["u/603/0.jpg"])
        XCTAssertEqual(obj["visibility_override"] as? String, "public")

        let withIds = (obj["watched_with_user_ids"] as? [String])?.map { $0.lowercased() }
        XCTAssertEqual(withIds, [friendA.uuidString.lowercased(), friendB.uuidString.lowercased()])

        let performances = obj["standout_performances"] as? [[String: Any]]
        XCTAssertEqual(performances?.count, 1)
        XCTAssertEqual(performances?.first?["personId"] as? Int, 6384)
        XCTAssertEqual(performances?.first?["name"] as? String, "Keanu Reeves")
        XCTAssertEqual(performances?.first?["character"] as? String, "Neo")
    }

    // MARK: explicit-null encoding for nil optionals (full-replace can't omit)

    func testUpsertPayloadEncodesNilOptionalsAsExplicitJSONNull() throws {
        var draft = fullDraft()
        draft.posterUrl = nil
        draft.watchedPlatform = nil
        draft.visibilityOverride = nil
        let obj = try jsonObject(JournalEntryContract.upsertPayload(userID: uid, ratingTier: nil, from: draft))
        for key in ["poster_url", "rating_tier", "watched_platform", "visibility_override"] {
            XCTAssertTrue(obj.keys.contains(key), "\(key) key must exist even when nil")
            XCTAssertTrue(obj[key] is NSNull, "\(key) must encode as explicit JSON null so a full replace clears it")
        }
    }

    // MARK: empty text → null (contract: "empty string coerced to null")

    func testUpsertPayloadEmptyTextCoercesToNull() throws {
        var draft = fullDraft()
        draft.reviewText = ""
        draft.watchedLocation = ""
        draft.rewatchNote = ""
        draft.personalTakeaway = ""
        let obj = try jsonObject(JournalEntryContract.upsertPayload(userID: uid, ratingTier: nil, from: draft))
        for key in ["review_text", "watched_location", "rewatch_note", "personal_takeaway"] {
            XCTAssertTrue(obj[key] is NSNull, "empty \(key) must coerce to JSON null")
        }
    }

    // MARK: array/bool defaults survive as [] / false (never dropped)

    func testUpsertPayloadEmptyArraysAndBoolsEncodeExplicitly() throws {
        var draft = fullDraft()
        draft.moodTags = []
        draft.vibeTags = []
        draft.favoriteMoments = []
        draft.standoutPerformances = []
        draft.watchedWithUserIds = []
        draft.photoPaths = []
        draft.containsSpoilers = false
        draft.isRewatch = false
        let obj = try jsonObject(JournalEntryContract.upsertPayload(userID: uid, ratingTier: nil, from: draft))
        for key in ["mood_tags", "vibe_tags", "favorite_moments", "standout_performances", "watched_with_user_ids", "photo_paths"] {
            XCTAssertEqual((obj[key] as? [Any])?.count, 0, "\(key) defaults to an empty array, never null/omitted")
        }
        XCTAssertEqual(obj["contains_spoilers"] as? Bool, false)
        XCTAssertEqual(obj["is_rewatch"] as? Bool, false)
    }

    // MARK: draft(from:) round-trips a full owner row (edit seam)

    func testDraftFromRowRoundTripsEveryField() {
        let row = JournalRow(
            id: UUID(),
            user_id: uid,
            tmdb_id: "603",
            title: "The Matrix",
            poster_url: "p.jpg",
            rating_tier: "S",
            review_text: "A machine dream.",
            contains_spoilers: true,
            mood_tags: ["thrilled"],
            vibe_tags: ["late_night"],
            favorite_moments: ["the lobby"],
            standout_performances: [StandoutPerformance(personId: 6384, name: "Keanu Reeves", character: "Neo")],
            watched_date: "2026-07-06",
            watched_location: "home",
            watched_with_user_ids: [friendA],
            watched_platform: "netflix",
            is_rewatch: true,
            rewatch_note: "holds up",
            personal_takeaway: "choose",
            photo_paths: ["u/603/0.jpg"],
            visibility_override: "public",
            like_count: 7,
            created_at: "2026-07-06T00:00:00Z"
        )
        let draft = JournalEntryContract.draft(from: row)
        XCTAssertEqual(draft.tmdbId, "603")
        XCTAssertEqual(draft.title, "The Matrix")
        XCTAssertEqual(draft.posterUrl, "p.jpg")
        XCTAssertEqual(draft.reviewText, "A machine dream.")
        XCTAssertEqual(draft.containsSpoilers, true)
        XCTAssertEqual(draft.moodTags, ["thrilled"])
        XCTAssertEqual(draft.vibeTags, ["late_night"])
        XCTAssertEqual(draft.favoriteMoments, ["the lobby"])
        XCTAssertEqual(draft.standoutPerformances, [StandoutPerformance(personId: 6384, name: "Keanu Reeves", character: "Neo")])
        XCTAssertEqual(draft.watchedDate, "2026-07-06")
        XCTAssertEqual(draft.watchedLocation, "home")
        XCTAssertEqual(draft.watchedWithUserIds, [friendA])
        XCTAssertEqual(draft.watchedPlatform, "netflix")
        XCTAssertEqual(draft.isRewatch, true)
        XCTAssertEqual(draft.rewatchNote, "holds up")
        XCTAssertEqual(draft.personalTakeaway, "choose")
        XCTAssertEqual(draft.photoPaths, ["u/603/0.jpg"])
        XCTAssertEqual(draft.visibilityOverride, .pub)
    }

    func testDraftFromRowCoercesNilsToEmptyEditableDefaults() {
        // A row with all-null optionals (empty entry) becomes editable empties,
        // not crashing nils — the composer binds to non-optional String/[T].
        let row = JournalRow(
            id: UUID(), user_id: uid, tmdb_id: "1", title: "T",
            poster_url: nil, rating_tier: nil, review_text: nil,
            contains_spoilers: false, mood_tags: nil, vibe_tags: nil,
            favorite_moments: nil, standout_performances: nil,
            watched_date: nil, watched_location: nil, watched_with_user_ids: nil,
            watched_platform: nil, is_rewatch: false, rewatch_note: nil,
            personal_takeaway: nil, photo_paths: nil, visibility_override: nil,
            like_count: 0, created_at: "2026-07-06T00:00:00Z"
        )
        let d = JournalEntryContract.draft(from: row)
        XCTAssertEqual(d.reviewText, "")
        XCTAssertEqual(d.watchedLocation, "")
        XCTAssertEqual(d.rewatchNote, "")
        XCTAssertEqual(d.personalTakeaway, "")
        XCTAssertEqual(d.moodTags, [])
        XCTAssertEqual(d.vibeTags, [])
        XCTAssertEqual(d.favoriteMoments, [])
        XCTAssertEqual(d.standoutPerformances, [])
        XCTAssertEqual(d.watchedWithUserIds, [])
        XCTAssertEqual(d.photoPaths, [])
        XCTAssertNil(d.posterUrl)
        XCTAssertNil(d.watchedPlatform)
        XCTAssertNil(d.visibilityOverride)
    }

    func testDraftFromRowInvalidVisibilityOverrideBecomesNil() {
        // A garbage stored override can't map to a JournalVisibility case; the
        // editable draft treats it as "no override" (Default) rather than
        // fabricating a value. (resolveVisibility handles the fail-closed read.)
        let row = JournalRow(
            id: UUID(), user_id: uid, tmdb_id: "1", title: "T",
            poster_url: nil, rating_tier: nil, review_text: nil,
            contains_spoilers: false, mood_tags: nil, vibe_tags: nil,
            favorite_moments: nil, standout_performances: nil,
            watched_date: nil, watched_location: nil, watched_with_user_ids: nil,
            watched_platform: nil, is_rewatch: false, rewatch_note: nil,
            personal_takeaway: nil, photo_paths: nil, visibility_override: "garbage",
            like_count: 0, created_at: "2026-07-06T00:00:00Z"
        )
        XCTAssertNil(JournalEntryContract.draft(from: row).visibilityOverride)
    }

    // MARK: probe-before-edit seam — probed always wins the wipe-bug guard

    func testPickEntryForEditProbedWins() {
        let probed = JournalRow(
            id: UUID(), user_id: uid, tmdb_id: "1", title: "probed",
            poster_url: nil, rating_tier: nil, review_text: nil,
            contains_spoilers: false, mood_tags: nil, vibe_tags: nil,
            favorite_moments: nil, standout_performances: nil,
            watched_date: nil, watched_location: nil, watched_with_user_ids: nil,
            watched_platform: nil, is_rewatch: false, rewatch_note: nil,
            personal_takeaway: "owner takeaway", photo_paths: nil, visibility_override: nil,
            like_count: 0, created_at: "2026-07-06T00:00:00Z"
        )
        let passed = JournalRow(
            id: UUID(), user_id: uid, tmdb_id: "1", title: "passed",
            poster_url: nil, rating_tier: nil, review_text: nil,
            contains_spoilers: false, mood_tags: nil, vibe_tags: nil,
            favorite_moments: nil, standout_performances: nil,
            watched_date: nil, watched_location: nil, watched_with_user_ids: nil,
            watched_platform: nil, is_rewatch: false, rewatch_note: nil,
            personal_takeaway: nil, photo_paths: nil, visibility_override: nil,
            like_count: 0, created_at: "2026-07-06T00:00:00Z"
        )
        // Even when a takeaway-less list/search row is passed, the freshly
        // probed owner row wins so personal_takeaway is never wiped.
        XCTAssertEqual(JournalEntryContract.pickEntryForEdit(probed: probed, passed: passed)?.title, "probed")
        XCTAssertEqual(JournalEntryContract.pickEntryForEdit(probed: probed, passed: passed)?.personal_takeaway, "owner takeaway")
    }

    func testPickEntryForEditPassedBacktopsNilProbe() {
        let passed = JournalRow(
            id: UUID(), user_id: uid, tmdb_id: "1", title: "passed",
            poster_url: nil, rating_tier: nil, review_text: nil,
            contains_spoilers: false, mood_tags: nil, vibe_tags: nil,
            favorite_moments: nil, standout_performances: nil,
            watched_date: nil, watched_location: nil, watched_with_user_ids: nil,
            watched_platform: nil, is_rewatch: false, rewatch_note: nil,
            personal_takeaway: nil, photo_paths: nil, visibility_override: nil,
            like_count: 0, created_at: "2026-07-06T00:00:00Z"
        )
        XCTAssertEqual(JournalEntryContract.pickEntryForEdit(probed: nil, passed: passed)?.title, "passed")
    }

    func testPickEntryForEditBothNilIsNewEntry() {
        XCTAssertNil(JournalEntryContract.pickEntryForEdit(probed: nil, passed: nil))
    }

    // MARK: review-event emission gate — non-empty review AND resolved==public

    func testShouldEmitReviewEventOnlyWhenNonEmptyAndPublic() {
        XCTAssertTrue(JournalEntryContract.shouldEmitReviewEvent(reviewText: "great", resolved: .pub))
        XCTAssertFalse(JournalEntryContract.shouldEmitReviewEvent(reviewText: "", resolved: .pub), "empty review never emits")
        XCTAssertFalse(JournalEntryContract.shouldEmitReviewEvent(reviewText: "great", resolved: .friends), "friends-only must not leak into explore")
        XCTAssertFalse(JournalEntryContract.shouldEmitReviewEvent(reviewText: "great", resolved: .priv))
        XCTAssertFalse(JournalEntryContract.shouldEmitReviewEvent(reviewText: "", resolved: .friends))
    }

    // MARK: tag constants mirror web constants.ts verbatim (IDs must match)

    func testMoodTagIDsMirrorWebVerbatim() {
        XCTAssertEqual(JournalConstants.moodTagIDs, [
            "inspired", "joyful", "thrilled", "moved", "amazed", "comforted", "hopeful",
            "thoughtful", "nostalgic", "melancholy", "haunted", "contemplative",
            "tense", "disturbed", "heartbroken", "angry", "overwhelmed", "exhausted",
            "amused", "charmed", "entertained", "relaxed", "satisfied",
        ])
        XCTAssertEqual(JournalConstants.moodTagIDs.count, 23)
    }

    func testVibeTagIDsMirrorWebVerbatim() {
        XCTAssertEqual(JournalConstants.vibeTagIDs, [
            "solo_watch", "date_night", "movie_night", "family_time", "theater",
            "cozy_night", "binge", "rewatch", "blind_watch", "late_night", "travel",
        ])
        XCTAssertEqual(JournalConstants.vibeTagIDs.count, 11)
    }

    func testPlatformIDsMirrorWebVerbatim() {
        XCTAssertEqual(JournalConstants.platformIDs, [
            "theater", "netflix", "apple_tv", "max", "hulu", "prime", "disney",
            "peacock", "paramount", "mubi", "criterion", "physical", "other",
        ])
        XCTAssertEqual(JournalConstants.platformIDs.count, 13)
    }

    func testJournalNumericConstantsMatchWeb() {
        XCTAssertEqual(JournalConstants.journalMaxMoments, 5)
        XCTAssertEqual(JournalConstants.journalMaxPhotos, 6)
        XCTAssertEqual(JournalConstants.journalPhotoSignedURLTTL, 2_592_000)
    }

    // MARK: - Re-rank merge seam (C3 Part B Task 0)

    /// A RICH existing owner row — the exact shape a probe returns for a movie the
    /// user has fleshed out (review, moments, performances, photos, takeaway,
    /// visibility override, watch context). The re-rank merge must preserve ALL of
    /// these verbatim while folding in only the ceremony's new moods + one-liner.
    private func richRow() -> JournalRow {
        JournalRow(
            id: UUID(uuidString: "22222222-0000-0000-0000-000000000002")!,
            user_id: uid, tmdb_id: "603", title: "The Matrix",
            poster_url: "/p.jpg", rating_tier: "loved",
            review_text: "a machine dreamt of us.", contains_spoilers: true,
            mood_tags: ["nostalgic"], vibe_tags: ["late_night"],
            favorite_moments: ["the lobby", "red pill"],
            standout_performances: [
                StandoutPerformance(personId: 6384, name: "Keanu Reeves", character: "Neo"),
            ],
            watched_date: "2026-06-01", watched_location: "home",
            watched_with_user_ids: [friendA], watched_platform: "netflix",
            is_rewatch: true, rewatch_note: "still holds up",
            personal_takeaway: "choose your reality", photo_paths: ["u/603/0.jpg"],
            visibility_override: "public", like_count: 3,
            created_at: "2026-06-01T00:00:00+00:00"
        )
    }

    /// MERGE preserves every rich field verbatim and folds in ONLY the new moods
    /// + one-liner. review_text takes the new line; mood_tags take the new moods.
    func testMergePreservesRichFieldsAndFoldsNewMoodsAndLine() {
        let merged = JournalEntryContract.merge(
            newMoods: ["thrilled", "amazed"], newLine: "second time hits harder.",
            onto: richRow())

        // Folded in from the ceremony:
        XCTAssertEqual(merged.reviewText, "second time hits harder.")
        XCTAssertEqual(merged.moodTags, ["thrilled", "amazed"])

        // Preserved verbatim from the existing rich row:
        XCTAssertEqual(merged.favoriteMoments, ["the lobby", "red pill"])
        XCTAssertEqual(merged.standoutPerformances.first?.name, "Keanu Reeves")
        XCTAssertEqual(merged.personalTakeaway, "choose your reality")
        XCTAssertEqual(merged.photoPaths, ["u/603/0.jpg"])
        XCTAssertEqual(merged.visibilityOverride, .pub)
        XCTAssertEqual(merged.vibeTags, ["late_night"])
        XCTAssertEqual(merged.watchedLocation, "home")
        XCTAssertEqual(merged.watchedWithUserIds, [friendA])
        XCTAssertEqual(merged.watchedPlatform, "netflix")
        XCTAssertTrue(merged.isRewatch)
        XCTAssertEqual(merged.rewatchNote, "still holds up")
        XCTAssertTrue(merged.containsSpoilers)
    }

    /// ADJUDICATION: a re-rank keeps the EXISTING row's watched_date — it is a
    /// re-rank, not a new watch, so the original watch day must survive the merge
    /// (never bumped to today).
    func testMergeKeepsExistingWatchedDate() {
        let merged = JournalEntryContract.merge(
            newMoods: ["thrilled"], newLine: "again.", onto: richRow())
        XCTAssertEqual(merged.watchedDate, "2026-06-01")
        XCTAssertNotEqual(merged.watchedDate, StubWriteContract.localDateString())
    }

    /// An EMPTY new one-liner must NOT wipe the existing review — only moods
    /// change on a moods-only re-rank.
    func testMergeEmptyLinePreservesExistingReview() {
        let merged = JournalEntryContract.merge(
            newMoods: ["thrilled"], newLine: "", onto: richRow())
        XCTAssertEqual(merged.reviewText, "a machine dreamt of us.")
        XCTAssertEqual(merged.moodTags, ["thrilled"])
    }

    /// The merged draft round-trips through the full-replace payload with ALL 20
    /// columns still present (the merge makes full-replace safe — it never
    /// degrades into a partial-column update).
    func testMergedDraftUpsertPayloadCarriesAllColumnsAndRichData() throws {
        let merged = JournalEntryContract.merge(
            newMoods: ["thrilled"], newLine: "again.", onto: richRow())
        let payload = JournalEntryContract.upsertPayload(
            userID: uid, ratingTier: "loved", from: merged)
        XCTAssertEqual(try jsonKeys(payload), expectedUpsertKeys)
        XCTAssertEqual(payload.personal_takeaway, "choose your reality")
        XCTAssertEqual(payload.photo_paths, ["u/603/0.jpg"])
        XCTAssertEqual(payload.watched_date, "2026-06-01")
        XCTAssertEqual(payload.visibility_override, "public")
    }
}
