# Discover Surface — UI / UX Spec

**Date:** 2026-04-08
**Branch (proposed):** `feature/discover-surface`
**Parent doc:** `~/.gstack/projects/BIBOYANG425-Movie_List/mac-feature-smart-suggestions-launch-design-20260408-005801.md`
**Siblings:** `2026-04-08-discover-technical-spec.md`, `2026-04-08-discover-copy-spec.md`, `2026-04-08-discover-rollout.md`

---

## 1. Goals for the UI

- **Browsable, not exhaustive.** The user should be able to scroll, get a sense of the full surface in 10 seconds, and stop where something catches their eye. No infinite scroll, no "load more," no pagination ceremony.
- **Specific, not generic.** Every card tells the user WHY it's being recommended in one line. Generic cards with no "because" line are the fastest way to make this feel like every other recommendation app.
- **Quiet before loud.** No banner art. No hero treatments. No "Featured" slot. Just pools with good voice.
- **Works at 320px.** The builder uses this on their phone. Everything fits.
- **Feels like Spool.** Same fonts, same spacing, same tier language, same gold accent. This is not a different app.

## 2. Information architecture

One page. One vertical scroll. Sections are pools.

Pool order (from top):
1. **Friend** — "Your people loved this" — small header, pool cards
2. **Similar** — "Because you loved X" — medium header, pool cards
3. **Taste** — "Fits your taste" — medium header, pool cards
4. **Trending** — "Hot on Spool" — medium header, pool cards
5. **Variety** — "Outside your usual" — medium header, pool cards

Why this order: Friend is the strongest emotional signal ("my people loved this") so it earns the top slot. Variety goes last because it's the most speculative — the user scrolls down to "stretch."

Between the header and the pools is a **media filter** (single-select): All · Movies · TV · Books. Default: All.

If `All` is selected, each pool section can contain a mix of movies, TV, and books. If a specific media is selected, the pools show only that media type, and pools with zero items are hidden.

## 3. Page-level layout (desktop + mobile)

```
┌─────────────────────────────────────────────────┐
│  Discover                                        │  <- page header (h1)
│  Fresh picks for today, built from your taste.   │  <- subline (muted)
├─────────────────────────────────────────────────┤
│  [ All ] [ Movies ] [ TV ] [ Books ]             │  <- media filter chips
├─────────────────────────────────────────────────┤
│                                                 │
│  👥 Your people loved this          3 picks    │  <- pool header
│  ┌──┐ ┌──┐ ┌──┐                                 │
│  │  │ │  │ │  │                                 │  <- pool card row (grid on mobile)
│  └──┘ └──┘ └──┘                                 │
│                                                 │
│  ✧ Because you loved Past Lives      4 picks   │
│  ┌──┐ ┌──┐ ┌──┐ ┌──┐                            │
│  │  │ │  │ │  │ │  │                            │
│  └──┘ └──┘ └──┘ └──┘                            │
│                                                 │
│  ◎ Fits your taste                   6 picks   │
│  ┌──┐ ┌──┐ ┌──┐ ┌──┐ ┌──┐ ┌──┐                  │
│  └──┘ └──┘ └──┘ └──┘ └──┘ └──┘                  │
│                                                 │
│  🔥 Hot on Spool                     4 picks   │
│  ...                                            │
│                                                 │
│  ⟲ Outside your usual                4 picks   │
│  ...                                            │
│                                                 │
└─────────────────────────────────────────────────┘
```

Icons used in pool headers come from lucide-react (existing dependency):
- Friend → `Users` (not the lock-emoji above)
- Similar → `Sparkles`
- Taste → `Compass`
- Trending → `Flame`
- Variety → `Shuffle`

(The emoji in the mock is just for layout legibility.)

## 4. Pool section anatomy

### Header row
- Left: icon + bold title + optional subtitle (e.g., "Because you loved Past Lives")
- Right: count pill in muted style (e.g., "4 picks")
- Full-width horizontal divider below (existing `border-border/30`)
- Vertical spacing: 24px above, 12px below (Tailwind: `pt-6 pb-3`)

### Card grid
- Mobile (≤640px): 2 columns, 3:4 aspect posters, 12px gutters
- Small tablet (641-1024px): 3 columns
- Desktop (≥1025px): 4 columns
- Each card is a `DiscoverCard` component — consistent across pools

### Pool subtitle behavior
- **Friend pool:** subtitle is "Alex · Jordan · Sam" (first 3 friend usernames) or "Alex and 4 others"
- **Similar pool:** subtitle is "Because you loved Past Lives" (the anchor title chosen for `/similar`)
- **Taste pool:** subtitle is "Slow, character-driven, 2020s" (the top weighted genres + preferred decade, in 3-5 words)
- **Trending pool:** subtitle is "14 people ranked these this week" (aggregate stat)
- **Variety pool:** subtitle is "You've ranked 2 horror movies. Try a third." (honest about the underexposed genre)

The exact copy is the copy spec's job; this spec just defines the SLOTS.

## 5. DiscoverCard anatomy

```
┌──────────────────┐
│                  │
│   [poster]       │  <- aspect 2:3, rounded, tier badge top-left if from Friend pool
│                  │
│                  │
│ [♡]       [+]    │  <- hover/tap row: heart = save to watchlist, + = rank now
└──────────────────┘
 Past Lives
 2023 · Drama · A24
 Because you loved Moonlight      <- pool reason line, muted, 1 line truncated
```

### Card states
- **Default:** poster + title + meta + reason line
- **Hover (desktop):** slight lift (`hover:scale-[1.02]`), reveal action buttons overlaid on poster
- **Tap (mobile):** tapping the poster opens the detail modal (reuses existing `MediaDetailModal`)
- **Saved:** heart filled; card stays in feed until page refresh, then excluded
- **Ranked from Discover:** card flips to "Ranked" state briefly, then removed on next daily refresh

### Tier badge (Friend pool only)
When a card is in the Friend pool, overlay a small tier badge in the top-left of the poster (same treatment as `StubCard` full variant). Shows "Alex · S" — whose taste and what tier. Max 1 friend shown on the badge; if multiple friends ranked it, tooltip shows the rest.

Other pools do NOT show a tier badge. They're not anchored to a specific person's ranking.

### Meta line format
Depending on media type:
- Movie: `{year} · {genre1} · {genre2}` (e.g., "2023 · Drama · Romance")
- TV: `{year} · {genre1} · {episodeCount} eps` (e.g., "2023 · Thriller · 10 eps")
- Book: `{year} · {author}` (e.g., "2018 · Madeline Miller")

Books get author instead of genre because author is more identifying for books. Genre is noise for most book recommendations.

### Reason line (the most important line on the card)
One line. Muted color. Truncated with ellipsis if overflow. Never two lines.

Pool-specific reason lines:
- **Friend:** "Alex ranked this S"
- **Similar:** "Same writer-director as Past Lives" OR "Same author as Circe" (author for books)
- **Taste:** "Slow, emotional, 2020s — 87% match"
- **Trending:** "12 people S-tiered this this week"
- **Variety:** "You've ranked 2 horror movies. Here's a 3rd."

Copy spec owns the exact wording.

## 6. Media filter chips

```
┌─────┐ ┌────────┐ ┌────┐ ┌───────┐
│ All │ │ Movies │ │ TV │ │ Books │
└─────┘ └────────┘ └────┘ └───────┘
```

- Single-select chip group at the top of the page, sticky below the page header on scroll (or not — see a11y note below)
- Selected state: `bg-gold/20 text-gold`
- Unselected: `text-muted-foreground hover:text-foreground`
- Transition: opacity cross-fade on pool contents, not a hard re-render
- Default: `All`
- Selection persists across the session (localStorage: `spool.discover.mediaFilter`). Resets to `All` after 7 days idle.

A11y note on stickiness: sticky elements on mobile are fine but only if they don't eat vertical space. If the chip row is sticky, it must be ≤44px tall. Otherwise, let it scroll away and re-appear at the top on each page re-render.

## 7. Empty / error / cold-start states

### Empty (no data)
Shown when the taste profile exists but all pools returned zero items, OR when the user has ranked zero items across all media.

```
         ┌──────────────┐
         │   ⊙          │   <- Compass icon, muted, 40px
         └──────────────┘
         Nothing to show yet
         Rank a few things you love, and Discover
         fills up with stuff you might also love.

         [ Start ranking ]   <- primary button, links to RankingAppPage
```

### Partial (cold start)
Shown when `total_ranked < 5` across all media. The Taste and Similar pools won't have enough signal to work well. Hide them. Show only Trending and Friend pools, with a small banner at the top:

```
  ☆  Rank a few more and unlock more Discover pools.
     You're at 3/5.                       [ Start ranking → ]
```

This banner is dismissible (`×` on the right). Dismissal persists in localStorage.

### Error
If `getDiscoverFeed` throws entirely (e.g., the Supabase query for the exclude set failed), show a retry state:

```
         ⚠ Couldn't load Discover.
         [ Try again ]
```

Single button. No stack trace, no error code. This is a side project, the user isn't debugging.

### Per-pool error
Pools that fail individually are just hidden. No error UI per pool. Silent degradation.

## 8. Loading states

Initial page load: show a header + media filter immediately, then render skeleton pool sections while data loads.

```
▓▓▓▓▓▓▓▓▓▓▓▓              <- skeleton pool title
┌──┐ ┌──┐ ┌──┐ ┌──┐
│░░│ │░░│ │░░│ │░░│        <- skeleton cards (existing SkeletonCard w/ variant="discover")
└──┘ └──┘ └──┘ └──┘
```

Use the existing `SkeletonList` with `variant="discover"` (already shipped). Show 3 skeleton sections while loading.

Total load budget: if `getDiscoverFeed` takes >3 seconds, keep showing skeletons. Don't degrade to partial results. The user will wait.

Subsequent navigation to Discover within the same session: if we have a cached feed for today, render instantly. Don't re-fetch unless the user explicitly hits refresh.

## 9. Refresh affordance (deferred, mention only)

The first release does NOT have a visible refresh button. The daily seeded shuffle handles freshness. If the builder asks for "show me something else" within a day, a future release can add a quiet `⟲` button in the page header that re-seeds with a random salt. Defer.

## 10. Interactions

### Tapping a card
→ opens the existing `MediaDetailModal` (movies), or the TV season detail modal, or a book detail modal (needs to be verified or built — see open question). The modal has existing Add/Rank/Save affordances; Discover does not reinvent them.

### Tapping the `♡` (save) button on a card
→ adds to watchlist immediately (no confirm), shows a toast ("Added to watchlist"), card animates heart filled. Excluded from Discover on next refresh.

### Tapping the `+` (rank now) button
→ opens the ranking flow modal (existing `RankingFlowModal`) pre-populated with this item. On successful rank, the card animates to "Ranked" state and is excluded from Discover.

### Swipe gestures (mobile)
No swipe gestures in v1. Keep interactions explicit. (Swipe-to-save is tempting but makes the surface feel like Tinder, which is the wrong emotional register.)

## 11. Navigation

### Where Discover lives in the app chrome
Current state: `DiscoverView` is rendered as one of the tabs in `RankingAppPage` — a mode toggle alongside Watch List, Ranking, Journal, etc.

Discover should be its own top-level destination, same level as Feed, Journal, Profile. That means:

1. **AppLayout nav** gets a new "Discover" item with the `Compass` icon.
2. **Current routing** keeps the embedded `DiscoverView` as a fallback until the new route is wired.
3. **Transitional state:** during the first week of the branch, Discover can live in both places (the new nav item AND the old embedded location) to avoid breaking existing muscle memory. Once the new location is validated, remove the old one.

## 12. Accessibility

- `<main>` wraps the page. `<section>` per pool with `aria-labelledby` pointing at the pool header's `<h2>`.
- Pool headers are `<h2>`. Cards are `<article>`.
- Media filter chips: `role="tablist"`, each chip is `role="tab"`, selected chip has `aria-selected="true"`.
- Cards are tab-focusable. Enter/Space opens the detail modal.
- Save/Rank buttons on cards have `aria-label` (e.g., "Save Past Lives to watchlist").
- Focus outlines visible everywhere (existing project-wide outline rules per FINDING-* from the prior branch).
- All animations honor `prefers-reduced-motion`: replace scale/transform with opacity-only transitions.
- Color contrast: reason line text meets WCAG AA (≥4.5:1 against card background). If `text-muted-foreground` on `bg-card` fails this, nudge the muted color.

## 13. Responsive breakpoints

| Breakpoint | Cards per row | Pool spacing | Page padding |
|---|---|---|---|
| <640px (mobile) | 2 | `pt-6 pb-3` | `px-4` |
| 641-1024px (tablet) | 3 | `pt-8 pb-4` | `px-6` |
| ≥1025px (desktop) | 4 | `pt-10 pb-5` | `px-8` |

Maximum content width: `max-w-7xl` centered. Don't let the grid sprawl on ultrawide monitors.

## 14. Animation

- Card hover: 150ms ease-out, `scale(1.02)` + `translateY(-2px)`. Respects reduced-motion.
- Pool header fade-in on mount: 200ms ease. Staggered 50ms per pool.
- Save button press: 100ms spring, heart fills.
- Filter chip transition: 150ms cross-fade of pool contents, not a re-mount. Uses a `key` on the grid so React can diff efficiently.

No parallax. No complicated entry animations. Quiet.

## 15. States matrix (every pool × every data state)

| Data state | Friend | Similar | Taste | Trending | Variety |
|---|---|---|---|---|---|
| 0 items returned | Hidden | Hidden | Hidden | Hidden | Hidden |
| <3 items, threshold met | Shown | Shown | Shown | Shown | Shown |
| <3 items, cold start | Hidden (partial state banner instead) | Hidden | Hidden | Shown | Hidden |
| Pool errored | Hidden (logged) | Hidden (logged) | Hidden (logged) | Hidden (logged) | Hidden (logged) |
| Pool has items but filter excludes them | Hidden | Hidden | Hidden | Hidden | Hidden |

## 16. Things that are NOT in this spec

- Custom animations or motion design beyond simple transitions
- A "for you" onboarding modal that explains each pool
- Swipe gestures
- Per-pool bookmarking / favoriting
- Sharing a Discover card externally (use the existing share card flow from `ShareCardModal` instead)
- A refresh button (deferred)
- Per-user pool ordering (the order is fixed)
- Dark/light mode switch (Spool is dark-only per the existing theme)
- Desktop-specific hero treatment (same UI on all sizes, just different grid counts)
- Group-mode Discover ("what should we all watch")

## 17. Open questions for implementation

1. **Does the book detail modal exist?** If not, the card's tap → detail modal flow is blocked for books. Either (a) build a minimal book detail modal reusing `MediaDetailModal` structure, or (b) make book cards tap to an inline expanded state. Recommendation: build a minimal book modal; it'll be reused.
2. **Should the media filter be sticky on scroll?** Only if it fits ≤44px. Otherwise let it scroll off.
3. **The "Ranked" card state animation** — should it be a quick tier-color flash and then removal, or a slow fade? Prefer quick flash + removal; slow fades feel draggy.
4. **What happens when the user clicks the heart on a card that's already in their watchlist?** Unlikely (excluded from Discover), but if it happens, show a subtle toast "Already in your watchlist" and no-op.

---

*End of UI spec. See copy spec for exact wording of every string.*
