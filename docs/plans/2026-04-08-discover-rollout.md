# Discover Surface — Rollout Plan

**Date:** 2026-04-08
**Branch (proposed):** `feature/discover-surface`
**Parent doc:** `~/.gstack/projects/BIBOYANG425-Movie_List/mac-feature-smart-suggestions-launch-design-20260408-005801.md`
**Siblings:** `2026-04-08-discover-technical-spec.md`, `2026-04-08-discover-ui-spec.md`, `2026-04-08-discover-copy-spec.md`

---

## 1. Rollout philosophy

This is a side project used by the builder and 2-10 friends. Rollout is not "staging → canary → prod." It's **"land it on main, use it, see if it sticks."** The risk is not breaking the service for thousands of users — the risk is shipping something that feels generic, nobody uses, and quietly dies like shared watchlists did.

The rollout therefore optimizes for:
1. Shipping the smallest useful unit first
2. Giving the builder a real chance to use it alone before layering on TV/books
3. Forcing honest check-ins at points where "should we keep going" is the real question
4. Defining kill signals upfront so the project doesn't limp along on hope

## 2. Phase-by-phase plan

### Phase 0 — Kickoff (½ session, before any code)

**Outputs:**
- Read the four companion docs end-to-end (master + technical + UI + copy)
- Confirm the scope — if anything in the docs no longer feels right, amend BEFORE implementation starts
- Branch off `main`: `git checkout -b feature/discover-surface`
- Open a draft PR immediately, even empty. Gives a place to track progress and note scope changes.
- Create the task list for Phase 1 (see below)

**Exit criteria:**
- Branch exists
- Draft PR exists
- Docs are in `docs/plans/`
- No code changes yet

### Phase 1 — Movies-only Discover surface (smallest useful unit)

**The goal of Phase 1: close Disconnect #1 from the master doc.** Rewire `DiscoverView.tsx` to use the existing 5-pool engine for movies only. Do not touch TV, books, credits caches, or the RPC. This phase proves the surface works with the engine we already have.

**Work:**
1. Add types: `DiscoverItem`, `PoolResult`, `UnifiedTasteProfile` (movie fields only) to `types.ts`
2. Create `services/discoverService.ts` with:
   - `getDiscoverFeed(userId)` — movies only
   - `loadTasteProfile(userId)` — reads from existing `user_taste_profiles`
   - `buildMoviePools(profile, excludeIds)` — wraps the existing `getSmartSuggestions` output into `PoolResult[]`
   - Seeded daily shuffle helper
3. Rewrite `components/social/DiscoverView.tsx`:
   - Delete old `getFriendRecommendations` / `getTrendingAmongFriends` calls
   - Render pools as sections per the UI spec (no media filter yet — All = Movies in this phase)
   - Use `SkeletonList variant="discover"` for loading
   - Wire empty state, error state, cold-start banner
4. Add the new i18n keys for movies-only strings (pool headers, subtitles, card reasons, empty states) to `i18n/en.ts` and `i18n/zh.ts`. Defer the media filter + TV/book strings.
5. Keep DiscoverView in its current navigation slot for now (no new top-level nav — that's Phase 4)

**Exit criteria:**
- `npm run build` + `npm run typecheck` clean
- DiscoverView loads real data from the 5-pool engine
- All five movie pools render if threshold is met, or cold-start state if not
- Pool cards use the new voice (no banned generic strings)
- Builder has personally clicked through Discover at least 10 times on local dev

**Dogfood checkpoint (end of Phase 1):**
- Builder uses Phase 1 on their own account for **one full week** before starting Phase 2
- At the week mark, answer honestly: **did I open Discover organically at least 3 times this week?** Not because I was testing, but because I wanted something to watch?
- If YES: continue to Phase 2
- If NO: go to §5 Kill signal protocol

### Phase 2 — TV support

**The goal of Phase 2: extend the engine to TV** so the pools blend movies + TV.

**Work:**
1. Migration: create `tv_credits_cache` table with RLS (see technical spec §4a)
2. Migration: `ALTER user_taste_profiles` to add TV columns (§4c)
3. Migration: rewrite `recompute_taste_profile` RPC to include TV signal (§4d)
4. Migration: add trigger on `tv_rankings` calling `trigger_recompute_taste` (§4e)
5. Migration: one-shot backfill to recompute existing profiles (§4f)
6. Run migrations against a local/staging Supabase instance first
7. Code: extend `discoverService.ts` with `buildTvPools(profile, excludeIds)` using the existing `/discover/tv`, `/trending/tv/week`, `/tv/{id}/similar` endpoints (new TMDB calls, need to add them to tmdbService first)
8. Code: update `getDiscoverFeed` to call both movie and TV pool builders in parallel
9. Code: update DiscoverView to render blended pools (media type shows as a small label on the card — "TV" badge next to the title)
10. Populate `tv_credits_cache` lazily: on first rank of a TV season, fetch credits and cache show-level data keyed by `show_tmdb_id`
11. Add TV-specific i18n strings (`{count} eps` meta line, etc.)

**Exit criteria:**
- Migrations applied
- Build + typecheck clean
- DiscoverView shows mixed movies + TV in every pool
- Taste profile correctly reflects TV rankings (check by ranking a TV season and watching `user_taste_profiles.total_tv_ranked` update)
- All five pools have TV coverage (even if sparse)

**Dogfood checkpoint (end of Phase 2):**
- Builder uses Discover for **one week** with TV support
- Answer: am I discovering TV through Discover, or still only movies?
- If TV pools are hollow (0-1 items consistently), that's a data problem — either few TV shows are ranked across the app, or the pool builder logic has an off-by-one. Diagnose before Phase 3.

### Phase 3 — Book support

**The goal of Phase 3: extend to books.** This is the thinnest phase, both in engine capability and in expected user delight, but it completes the multi-media vision.

**Work:**
1. No new DB: books piggyback on `user_taste_profiles` columns already added in Phase 2. Books don't have a credits cache.
2. Extend `recompute_taste_profile` RPC again to include book signal (genres, authors, book work keys)
3. Add trigger on `book_rankings`
4. Run the backfill DO block again to update profiles with book signal
5. Code: extend `discoverService.ts` with `buildBookPools(profile, excludeIds)` using `openLibraryService.searchBooks` and subject filters
6. Handle empty/thin book pools: hide any book pool with <3 items unless the user explicitly filters to Books-only (where threshold drops to 1)
7. Add book-specific i18n strings (`year · author` meta line, etc.)
8. Accept that book Trending is empty for MVP — no source for it. Hide the book Trending pool entirely.

**Exit criteria:**
- Migrations applied
- Book pools render when the user has ranked at least 3 books
- Book cards use the correct meta format
- Hidden book Trending pool doesn't leave a gap in the UI

**Dogfood checkpoint (end of Phase 3):**
- Use Discover in Books-only mode for a few days
- Is the book experience usable, or is it so thin that it feels worse than the empty state?
- If books are worse than nothing: hide books from the default filter and keep them behind an explicit "Books" filter selection. Do not force the user to see empty book pools.

### Phase 4 — Top-level navigation + media filter

**The goal of Phase 4:** move Discover to a top-level destination and add the media filter. This is UX polish; not blocking.

**Work:**
1. Add "Discover" to `AppLayout` nav with the `Compass` icon (per UI spec §11)
2. Add a new route / page component at `pages/DiscoverPage.tsx` that wraps `DiscoverView`
3. Add the media filter chip UI from UI spec §6
4. Wire the filter to `getDiscoverFeed(userId, { mediaFilter })`
5. Persist the selected filter in localStorage (`spool.discover.mediaFilter`)
6. During transition week, keep DiscoverView embedded in the old location too. After the transition week, remove the embedded location.

**Exit criteria:**
- Discover is a top-level nav item
- Media filter works and persists
- Old embedded DiscoverView location is either removed or clearly deprecated

**Dogfood checkpoint (end of Phase 4):**
- Has the new top-level nav position increased organic opens? Compare usage before/after.
- Does the filter get used, or is it ignored? If ignored for 2 weeks, consider hiding it behind a settings toggle — the filter complicates the UI and if nobody touches it, it's noise.

### Phase 5 — Voice pass + polish (the craft phase)

**The goal of Phase 5:** make the copy actually good. Don't skip this.

**Work:**
1. Review every string on the surface side-by-side with the copy spec §11 (voice examples)
2. Read every pool reason line out loud. If you wouldn't text it to a friend, rewrite.
3. Specifically audit:
   - Variety pool copy for any hint of shaming or lecturing
   - Trending pool copy for vague stats
   - Taste pool for generic "matches your taste" language
4. Run through the surface in Chinese (if you don't read Chinese fluently, ask a friend who does)
5. Tweak any visual polish that feels off now that the strings have changed length
6. Check every empty state, every error, every loading skeleton
7. Final accessibility pass: tab through the whole page with keyboard, check screen reader output on one section

**Exit criteria:**
- Every string passes the "would a friend text this" test
- Visual rhythm is consistent
- Accessibility is verified

### Phase 6 — Legacy cleanup (optional, deferred)

Only do this after Phase 5 has been stable for 2+ weeks.

**Work:**
1. Grep for remaining callers of `getFriendRecommendations` and `getTrendingAmongFriends`
2. If no callers outside Discover: delete the functions
3. Remove legacy `discover.*` i18n keys from copy spec §10
4. Commit the cleanup as a separate PR

**Exit criteria:**
- Dead code removed
- No regressions

## 3. Commit and PR strategy

### One branch, multiple commits, one PR

The whole work lives on `feature/discover-surface`. Each phase is one or more commits. The PR is opened as draft from Phase 0 and marked ready-for-merge after Phase 5.

### Commit cadence

Commit at least once per phase, ideally at "green build" checkpoints within phases. Follow the project's commit style:
- `feat(discover): rewire DiscoverView to 5-pool engine (movies)`
- `feat(discover): add TV credits cache + tv pool builder`
- `feat(discover): add book pool builder with OL subject search`
- `feat(discover): add top-level nav + media filter`
- `style(discover): voice pass and copy polish`

**Important:** do NOT squash-merge. Each phase commit should survive in history so future debugging can bisect to "which phase broke what."

### Not a trunk-based incremental ship

This is NOT a feature-flag-gated incremental rollout to users. It's a branch-lives-until-done model. Rationale: no users to feature-flag, and the phases are too tightly coupled in the UI to ship independently without visible breakage.

## 4. Dogfood plan (the real test)

After Phase 1 ships, the builder commits to using Discover as their primary "what should I watch" surface for **at least 2 weeks** before drawing any conclusions. During that window:

1. **No adding features.** If Discover feels off, note it but don't build anything new. Usage data matters more than reactions in the first week.
2. **No showing it to friends yet.** Solo dogfood first. The builder's own honest usage pattern is the signal; a friend's polite "it's cool" is not.
3. **Journal the usage (lightly).** At the end of each day, note in a text file: did I open Discover today? If yes, what did I do there? If I ranked something, did I discover it via Discover or some other way?
4. **Look at the pattern at day 7 and day 14.** Not before.

### What "using it" looks like (positive signal)
- Opens Discover on a quiet day because you're bored
- Adds something from a Variety or Trending pool to your watchlist without needing to force it
- Rank something you discovered on Discover and the ranking signal flows back into the next day's Taste pool
- Mentions something to a friend that came from Discover ("hey, did you see this show?")
- Feel a small pull to open Discover after a rough day at work (this is the emotional hook)

### What "not using it" looks like (warning)
- You remember to check it once a day because you know you're supposed to, not because you want to
- Every pool feels the same
- You can't remember what you added to your watchlist from Discover vs from search
- The only pool you reach for is Friend (which means the engine isn't the value, the friend layer is — different product)
- You find yourself using Letterboxd/Goodreads instead for actual recommendations

## 5. Kill signal protocol

Defined upfront so the project doesn't keep adding features on top of a dead surface.

### Kill trigger
**Two full weeks post-Phase-5 merge, Discover is opened <1x/week by the builder.**

(Note: this is the builder's OWN usage. Friend usage is secondary because the friend base is too small to produce reliable signal.)

### What happens when the kill signal fires

1. **Do NOT add more features.** Not threads, not shared watchlists, not notifications.
2. **Open a kill-signal retrospective document.** Answer in writing:
   - When did you last open Discover voluntarily?
   - Which pool, if any, felt genuinely useful?
   - Which pool was dead weight?
   - What were you actually using to decide what to watch? (Be honest: Letterboxd? Friends texting? Scrolling TMDB?)
   - Is the underlying premise wrong (Spool doesn't need a forward-looking surface), or is the execution wrong (the pools feel generic)?
3. **Pick one response based on the retrospective:**
   - **Wrong premise:** revert the Discover surface, delete the new DB columns, and accept that Spool's value is backward-looking. Don't try again.
   - **Wrong execution:** pick the ONE thing that would have made it work (usually copy, sometimes data) and do a 3-day focused fix. Dogfood again for 1 week. If it still doesn't stick, revert.
   - **Mixed:** keep the parts that work (usually the Friend pool) and delete the rest. Fold Friend pool back into the feed.

### Explicitly NOT a kill signal

- Friends not engaging (sample size too small, not the primary test)
- Some pools being empty (data problem, fix with more rankings)
- Initial week feeling weird (learning curve is real)
- Technical bugs (fix the bug, don't kill the feature)

## 6. Success signals (what "working" looks like)

### After 1 week (Phase 1 dogfood)
- Builder opened Discover ≥3x organically
- At least 1 item added to watchlist from Discover
- No pool felt entirely useless

### After 2 weeks (Phase 1 dogfood extended)
- Builder opens Discover as part of their routine
- At least 1 item that was ranked came from Discover originally
- The Friend pool feels specific (names feel meaningful, not generic)

### After 4 weeks (post Phase 5)
- Builder has used Discover for 2+ weeks continuously
- At least 1 friend has independently ranked something they discovered via Discover
- The forward-looking loop is closing: Discover → Watchlist → Rank → Taste profile update → better next-day Discover

### Long-term (not in scope for this branch, but watch for)
- Discover becomes the default entry point, overtaking the feed
- Friends start expecting "did you see what Discover gave me today?" as conversation
- The app feels incomplete without it (the true retention test)

## 7. Risks specific to rollout

| # | Risk | Mitigation |
|---|---|---|
| RO-1 | Builder rushes Phase 2 before Phase 1 dogfood is honest | Dogfood is a hard gate, not a checkbox. One week minimum. |
| RO-2 | Builder shows Discover to friends too early, gets polite feedback, mistakes it for adoption | Don't show friends until Phase 4. Solo dogfood first. |
| RO-3 | A migration fails mid-rollout and the taste profile is in an inconsistent state | Run migrations in a single transaction where possible. Have a rollback SQL ready for each migration. Test against a staging DB first. |
| RO-4 | The kill signal fires and the builder ignores it | The retrospective doc is mandatory when the signal fires. Writing forces honesty. |
| RO-5 | Phase 4 navigation change breaks muscle memory for existing friends without warning | During transition week, keep both locations. Tell the ~few active friends when you move it. |
| RO-6 | The backfill DO block (Phase 2) runs slow on a user with 500+ rankings | Accept a short delay. The backfill is one-time. |
| RO-7 | Pre-commit hooks or CI fail on a phase commit | Fix the issue and make a new commit. Do not `--no-verify`. |
| RO-8 | The voice pass (Phase 5) discovers that pool reasons sound templated after real data fills them in | This is the expected outcome of Phase 5. Allocate real time for rewrites, not 10 minutes. |

## 8. Definition of done for the whole branch

- All five phases complete and merged to `main`
- All four companion docs (this one + tech + UI + copy) committed to `docs/plans/`
- The master doc has been updated if scope shifted during implementation
- `npm run build` + `npm run typecheck` clean
- DiscoverView is the primary entry point for the "what should I watch" use case
- The builder has used it for 2+ consecutive weeks without forcing
- No legacy dead code from the old DiscoverView remains (unless deliberately kept)
- i18n keys for en + zh are complete and the voice passes the §11 check in the copy spec
- The kill signal has been defined and dated (e.g., "if <1x/week by 2026-05-15, trigger retrospective")

## 9. What comes AFTER this branch (not in scope, but worth naming)

Only relevant if Discover sticks.

1. **Threads on Discover cards.** Solves the "talk about it" half of the office-hours stated want. Light async comment threads on each Discover card.
2. **Shared watchlist from Discover.** Re-attempt, but this time items arrive via "I'm adding this from Discover, anyone want to watch with me?" — Discover provides the hook shared watchlists never had.
3. **Server-side recommendation caching.** Move from client-side pool fetches to a nightly server-side batch. Removes TMDB rate pressure and makes the daily shuffle a real shuffle.
4. **Friend-group-scoped trending.** "Hot in your circle this week" as a distinct pool separate from app-wide Trending.
5. **Discover-driven notifications.** "Your Celine Song pool has 3 new picks today." Opt-in, low frequency.

None of these ship in this branch. They are follow-up work contingent on the Discover surface itself becoming habitual first.

---

*End of rollout plan. This is the last of the four companion docs. Implementation begins at Phase 0.*
