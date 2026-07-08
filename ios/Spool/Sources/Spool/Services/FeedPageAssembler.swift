import Foundation

/// The C1 feed refill loop, pure-orchestrated: the Swift mirror of web's
/// `getFeedCards` in `services/feedService.ts` (post-#32), minus the
/// offset→cursor session bridge iOS doesn't need (SwiftUI callers are
/// cursor-native). ALL IO is injected as closures, so the whole contract is
/// XCTest-covered in FeedPageAssemblerTests with zero network.
///
/// The binding Part-B caller contract (docs/plans/2026-07-07-ios-parity-
/// ledger.md, C1-iOS notes; plan Global Constraints):
///  - stage order = type filter → mutes → throttle; the milestone throttle
///    runs LAST over the surviving rows (web L310-325);
///  - the throttle counts dict lives for ONE `assemblePage` call — created
///    inside, carried across that call's refill pages, never across calls
///    (web resets per getFeedCards call, L275-280);
///  - the cursor advances over EVERY consumed raw row, kept or dropped, and
///    the result carries the last RAW row's cursor — never rewound to the
///    last kept card (web L308);
///  - `hasMore` = last raw page row count == pageSize (web L293-294);
///  - ≤ `maxRPCPages` raw fetches per call (web MAX_FEED_RPC_PAGES, L212);
///  - reads fail soft AT THIS LAYER for page assembly: a first-page
///    `fetchPage` throw yields empty/hasMore-false; a later refill throw
///    returns what's kept so far with hasMore true (an error is not
///    end-of-stream — web L287-290 breaks without exhausting); mutes/
///    profiles/scores throws degrade (web's in-service soft-fails:
///    getMutes L619-622 returns []).
///
/// Out of scope here (ships with the filter UI fast-follow, see the C1
/// ledger's deferred list): tier/time-range/bracket row filters and the
/// `boosted_ts`-below-cutoff early stop — `assemblePage` takes no time
/// range, so no cutoff can be active.
///
/// Contract source: docs/plans/2026-07-08-c1-ios-feed-ui-plan.md (Task 2).

// MARK: - Result + config

/// One assembled, hydrated feed page.
public struct FeedAssemblyResult: Sendable {
    /// Hydrated cards, stream order, at most `config.pageSize` of them.
    public let cards: [FeedCard]
    /// Cursor of the last RAW row consumed (kept or dropped); pass back as
    /// `after:` to continue. Echoes the input cursor when nothing was
    /// consumed (empty first page / first-page fetch failure).
    public let cursor: FeedCursor?
    /// Last raw page row count == pageSize. False once a short raw page
    /// marks the stream exhausted; stays true on refill errors and on the
    /// page cap (retry/continue can make progress).
    public let hasMore: Bool

    public init(cards: [FeedCard], cursor: FeedCursor?, hasMore: Bool) {
        self.cards = cards
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

public struct FeedAssemblerConfig: Sendable {
    /// Kept-cards target per assemblePage call AND the raw page_size sent
    /// to every get_feed_page fetch (web passes `limit` for both).
    public var pageSize: Int
    /// Hard bound on raw fetches per assemblePage call — web
    /// MAX_FEED_RPC_PAGES (feedService.ts L212).
    public var maxRPCPages: Int

    public init(pageSize: Int = 20, maxRPCPages: Int = 10) {
        self.pageSize = pageSize
        self.maxRPCPages = maxRPCPages
    }
}

// MARK: - Assembler

public actor FeedPageAssembler {

    public typealias FetchPage = (FeedMode, FeedCursor?, Int) async throws -> [FeedEventRow]
    public typealias FetchMutes = () async throws -> (users: Set<UUID>, media: Set<String>)
    public typealias FetchProfiles = ([UUID]) async throws -> [UUID: ProfileRow]
    public typealias FetchScores = ([(userID: UUID, tmdbID: String)]) async throws -> [String: Double]

    private let fetchPage: FetchPage
    private let fetchMutes: FetchMutes
    private let fetchProfiles: FetchProfiles
    private let fetchScores: FetchScores
    private let config: FeedAssemblerConfig

    /// Production wiring binds these to `FeedRepository.fetchPage`,
    /// `FeedRepository.mutes`, `ProfileRepository.getProfilesByIds`,
    /// `FeedRepository.rankingScores` (Task 5); tests inject scripts.
    public init(fetchPage: @escaping FetchPage,
                fetchMutes: @escaping FetchMutes,
                fetchProfiles: @escaping FetchProfiles,
                fetchScores: @escaping FetchScores,
                config: FeedAssemblerConfig = .init()) {
        self.fetchPage = fetchPage
        self.fetchMutes = fetchMutes
        self.fetchProfiles = fetchProfiles
        self.fetchScores = fetchScores
        self.config = config
    }

    /// Assemble one hydrated feed page after `cursor`. Never throws: every
    /// failure degrades per the caller contract (see type docs).
    public func assemblePage(mode: FeedMode,
                             after cursor: FeedCursor?,
                             allowedTypes: Set<String>) async -> FeedAssemblyResult {
        // Mutes: once per call, applied client-side in BOTH modes. A failed
        // read degrades to "no mutes" — web getMutes fails soft to []
        // (feedService.ts L619-622); a mute miss beats a blank feed.
        let mutes: (users: Set<UUID>, media: Set<String>)
        do { mutes = try await fetchMutes() } catch { mutes = ([], []) }

        // Throttle counts live for THIS call only: created here, shared by
        // every refill page below, gone when we return. Carrying the dict
        // across calls would over-throttle vs web (ledger, C1-iOS (c)).
        var throttleCounts: [String: Int] = [:]

        var cursor = cursor
        var kept: [FeedEventRow] = []
        var exhausted = false
        var rpcPages = 0
        var firstFetchFailed = false

        // Refill: filters shorten raw pages, so keep fetching until the
        // kept page is full, the stream ends, or the page cap trips.
        while !exhausted && kept.count < config.pageSize && rpcPages < config.maxRPCPages {
            rpcPages += 1

            let raw: [FeedEventRow]
            do {
                raw = try await fetchPage(mode, cursor, config.pageSize)
            } catch {
                // First page: nothing to show — empty result, hasMore false.
                // Later refill: keep what we have; the error is NOT
                // end-of-stream, so exhausted stays false (web L287-290).
                if rpcPages == 1 { firstFetchFailed = true }
                break
            }

            // Short raw page = end of stream — judged on the RAW count,
            // before any filtering (web L293-294).
            if raw.count < config.pageSize { exhausted = true }

            for row in raw {
                // Page full: the unconsumed tail is NOT cursor-advanced —
                // the next call re-fetches it (web L297).
                if kept.count >= config.pageSize { break }

                // Row consumed — advance the keyset whether it survives the
                // stages or not. This is what makes refilling never skip
                // and never duplicate (web L308; audit B4c bug family).
                cursor = FeedPipeline.cursor(fromLastConsumed: row)

                // Stage 1: event-type filter.
                guard !FeedPipeline.applyTypeFilter([row], allowed: allowedTypes).isEmpty
                else { continue }
                // Stage 2: mutes.
                guard !FeedPipeline.applyMutes([row], mutedUsers: mutes.users,
                                               mutedMedia: mutes.media).isEmpty
                else { continue }
                // Stage 3 — LAST: milestone throttle. Only rows that survived
                // the earlier stages may spend throttle budget.
                guard !FeedPipeline.throttleMilestones([row], counts: &throttleCounts).isEmpty
                else { continue }

                kept.append(row)
            }
        }

        if firstFetchFailed {
            return FeedAssemblyResult(cards: [], cursor: cursor, hasMore: false)
        }

        let hasMore = !exhausted
        if kept.isEmpty {
            return FeedAssemblyResult(cards: [], cursor: cursor, hasMore: hasMore)
        }

        let cards = await hydrate(kept.map(FeedCards.card(from:)))
        return FeedAssemblyResult(cards: cards, cursor: cursor, hasMore: hasMore)
    }

    // MARK: hydration

    /// Fill `actorUsername`/`actorAvatarURL`/`score` on the kept cards.
    /// Both lookups degrade independently — a failed batch never fails the
    /// page (matching web's in-service soft-fails; ledger: "rankingScores
    /// callers catch to empty map — a missing score means hide the badge").
    private func hydrate(_ cards: [FeedCard]) async -> [FeedCard] {
        // One batched profile fetch: unique actor ids, first-seen order.
        var actorIDs: [UUID] = []
        var seen = Set<UUID>()
        for card in cards where seen.insert(card.actorID).inserted {
            actorIDs.append(card.actorID)
        }
        let profiles: [UUID: ProfileRow]
        do { profiles = try await fetchProfiles(actorIDs) } catch { profiles = [:] }

        // Scores: collection rule = ranking/review cards with a tmdb id
        // (FeedCards.scorePairs); skip the RPC entirely when nothing
        // qualifies.
        let pairs = FeedCards.scorePairs(for: cards)
        var scores: [String: Double] = [:]
        if !pairs.isEmpty {
            do { scores = try await fetchScores(pairs) } catch { scores = [:] }
        }

        var hydrated = cards
        for i in hydrated.indices {
            // DOCUMENTED CHOICE — hydration failure leaves BOTH fields nil.
            // `FeedCards.avatarURL` would happily emit a dicebear URL from a
            // nil username, but that chain is a per-profile fallback for a
            // FETCHED profile lacking avatar fields, not a mask for a failed
            // or missing read: a dicebear-for-unknown would render a stable-
            // looking identicon for an account we know nothing about, and
            // the UI could no longer tell "profile has no avatar" from
            // "profile never loaded". Views render their own placeholder for
            // nil. (Web paints 'unknown' + undefined avatar here.)
            if let profile = profiles[hydrated[i].actorID] {
                hydrated[i].actorUsername = profile.username
                hydrated[i].actorAvatarURL = FeedCards.avatarURL(
                    avatarUrl: profile.avatar_url,
                    avatarPath: profile.avatar_path,
                    username: profile.username
                )
            }

            // Score lookup mirrors the collection rule; the map key is
            // `"<lowercase uuid>:<tmdbId>"` (FeedPipeline.scoreKey — web's
            // `${userId}:${tmdbId}`). A missing key = no badge, never an
            // error.
            if hydrated[i].kind == .ranking || hydrated[i].kind == .review,
               let tmdbID = hydrated[i].mediaTmdbID {
                hydrated[i].score = scores[FeedPipeline.scoreKey(userID: hydrated[i].actorID,
                                                                 tmdbID: tmdbID)]
            }
        }
        return hydrated
    }
}
