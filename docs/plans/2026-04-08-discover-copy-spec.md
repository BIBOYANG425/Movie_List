# Discover Surface — Copy & Voice Spec

**Date:** 2026-04-08
**Branch (proposed):** `feature/discover-surface`
**Parent doc:** `~/.gstack/projects/BIBOYANG425-Movie_List/mac-feature-smart-suggestions-launch-design-20260408-005801.md`
**Siblings:** `2026-04-08-discover-technical-spec.md`, `2026-04-08-discover-ui-spec.md`, `2026-04-08-discover-rollout.md`

---

## 1. Why copy gets its own spec

Every recommendation feed in existence has the same algorithmic guts. The thing that makes one feel human and another feel generic is the words around the items. Voice is the only cheap differentiator. Get the copy wrong and this looks like every other "for you" page.

Almost every failure mode on a recommendation surface is a copy failure:

- "Because you watched X" → generic, uninteresting, ignored
- "Trending now" → meaningless at this scale
- "Recommended for you" → the most-copied useless phrase in the industry

The rule for this spec: **every string on this surface should sound like it was written by a friend who knows the user's taste, not by a product team.**

## 2. Voice rules (binding)

These rules are non-negotiable for anything on the Discover surface.

### Word bans (hard)
Banned from every string on Discover:

- delve, crucial, robust, comprehensive, nuanced, multifaceted, furthermore, moreover, pivotal, landscape, tapestry, underscore, foster, showcase, intricate, vibrant, fundamental, significant, interplay
- "here's the kicker," "here's the thing," "plot twist," "let me break this down," "the bottom line"
- "Recommended for you"
- "You may also like"
- "Hot picks"
- "Trending now"
- "Don't miss"
- "Must watch"
- "Handpicked"
- "Curated for you"
- "Personalized"

### Punctuation
- **No em dashes.** Use commas, periods, or "...".
- Short sentences. Short paragraphs. Fragments are fine.
- No exclamation marks. Discover is calm.
- No ending periods on single-line reasons (feels terser, more confident).

### Tone
- Specific beats generic. "Because you loved Past Lives" beats "Based on your recent activity."
- Dry beats enthusiastic. "Slow, aching, quiet." beats "A haunting masterpiece!"
- Honest beats hype. "You've ranked 2 horror movies. Try a 3rd." beats "Expand your horizons with horror!"
- Write like a friend texting. "You'd probably love this." beats "This is a great match for your taste."

### Length
- Pool header: 3-5 words
- Pool subtitle: 4-8 words
- Card reason line: ≤60 characters (truncates at ~50 on mobile)
- Empty-state copy: ≤2 sentences total

### Testing a string
Before shipping any new string, ask: **would a friend actually text this to me?** If no, rewrite. If you can't imagine anyone you know saying it out loud, it's cut.

## 3. Page-level strings

### Page header
**en:** `Discover`
**zh:** `发现`

Single word. The minimal possible page title.

### Page subline (below title)
**en:** `Fresh picks for today, built from your taste.`
**zh:** `今日精选，基于你的品味。`

This is the only sentence explaining what the page is. No "AI-powered" or "smart" language. "Built from your taste" is the only framing.

### Media filter chips

| Key | en | zh |
|---|---|---|
| `discover.filter.all` | `All` | `全部` |
| `discover.filter.movies` | `Movies` | `电影` |
| `discover.filter.tv` | `TV` | `剧集` |
| `discover.filter.books` | `Books` | `书籍` |

## 4. Pool headers and subtitles

Each pool has a header (fixed string) and a subtitle (dynamic string generated from data).

### Friend pool

**Header (en):** `Your people loved this`
**Header (zh):** `你的朋友喜欢`

**Subtitle formats:**
- 1 friend: `${username} ranked these high`
  - en: "Alex ranked these high"
  - zh: `${username} 给这些高分`
- 2 friends: `${a} and ${b} ranked these high`
- 3 friends: `${a}, ${b}, and ${c}`
- 4+ friends: `${a}, ${b}, and ${n-2} others`

**Fallback if usernames are unavailable:** `Picks from your circle` / `来自你的圈子`

### Similar pool

**Header (en):** `Because you loved ${anchorTitle}`
**Header (zh):** `因为你喜欢《${anchorTitle}》`

Header is dynamic because the anchor title IS the hook. "Because you loved Past Lives" is more specific than "More like stuff you loved."

**Subtitle:** none. The header carries all the context.

**Fallback if anchor title is unknown (shouldn't happen, but):** `More like your favorites` / `更多你喜欢的`

### Taste pool

**Header (en):** `Fits your taste`
**Header (zh):** `合你的品味`

**Subtitle format:** 3-5 words describing the signal
- `${genre1}, ${genre2}, ${decade}` (e.g., "Slow dramas, 2020s")
- en example: "Slow dramas, character-driven, 2020s"
- zh example: "慢节奏, 角色驱动, 2020年代"

**Fallback subtitle:** `Based on what you love` / `基于你的喜好`

### Trending pool

**Header (en):** `Hot on Spool`
**Header (zh):** `Spool 热门`

**Subtitle format:** an honest stat
- en: `${n} people ranked these this week`
- zh: `本周 ${n} 人给这些打分`

**Threshold:** only show this pool if `n >= 5`. Below that, hide the whole pool (no "hot" with 2 rankings).

### Variety pool

**Header (en):** `Outside your usual`
**Header (zh):** `跳出你的舒适圈`

**Subtitle format:** specific and honest about what's being suggested and why
- en: `You've ranked ${n} ${genre} ${mediaPlural}. Here's a ${nth}.`
  - "You've ranked 2 horror movies. Here's a 3rd."
  - "You've never ranked a documentary. Try this."
- zh: `你看过 ${n} 部${genre}。试试这个。`

**Fallback:** `Try something different` / `尝试一些不同的`

## 5. Card strings

### Meta line format

Already defined in the UI spec. Restated here for the copy rules:

**Movie:**
- en: `${year} · ${genre1} · ${genre2}`
- zh: `${year} · ${genre1} · ${genre2}`

**TV:**
- en: `${year} · ${genre1} · ${episodeCount} eps`
- zh: `${year} · ${genre1} · ${episodeCount} 集`

**Book:**
- en: `${year} · ${author}`
- zh: `${year} · ${author}`

### Card reason line (the most important line on the page)

This is the line that makes Discover feel specific.

#### Friend pool card reason
- 1 friend: `${username} ranked this ${tier}`
  - en: "Alex ranked this S"
  - zh: `${username} 给这个打了 ${tier}`
- 2+ friends with same tier: `${username1} and ${n-1} others ranked this ${tier}`
- Multiple friends, different tiers: `${username1} loved this. ${n-1} more ranked it.`
- **Fallback:** `Ranked high by your circle` / `朋友们的高分`

#### Similar pool card reason

Pick the first available anchor from the list:
1. **Same director/creator/author:** `Same ${role} as ${anchorTitle}`
   - en: "Same director as Past Lives"
   - en: "Same author as Circe"
   - zh: `和《${anchorTitle}》同${role}`
2. **Same lead actor (movies/TV only):** `${actor} is in this too`
3. **Generic fallback:** `More like ${anchorTitle}`
   - en: "More like Past Lives"
   - zh: `类似《${anchorTitle}》`

#### Taste pool card reason

Construct a 3-5 word description of the matching signals:
- en: `${genreBlend}, ${decade}` — e.g., "Slow, emotional, 2020s"
- en: `Your ${director} phase continues` (if a director match) — e.g., "Your Celine Song phase continues"
- en: `Matches 4 of your S-tiers`
- zh: `${genreBlend}, ${decade}` or `${director} 风格`

Pick the most specific available signal. Don't default to "Matches your taste" — that's the banned generic voice.

**Fallback:** `Feels like your S-tier picks` / `和你的 S 级品味相似`

#### Trending pool card reason

- en: `${n} people ranked this ${bestTier} this week`
  - "12 people ranked this S this week"
- en: `${n} fresh ${tier} rankings this week` (alternate)
- zh: `本周 ${n} 人打了 ${bestTier}`

**Threshold:** only show if `n >= 3`. Below that, hide the card.

#### Variety pool card reason

- en: `You haven't ranked a ${genre} yet`
- en: `Your first ${genre}?`
- en: `You've ranked 1 ${genre}. Here's another.`
- zh: `你还没看过${genre}`
- zh: `你的第一部${genre}?`

Vary between these three phrasings across the pool so it doesn't read as a template.

## 6. Empty-state copy

### Full empty state (user has ranked zero items)

**Title (en):** `Nothing to show yet`
**Title (zh):** `暂无内容`

**Body (en):**
```
Rank a few things you love, and Discover
fills up with stuff you might also love.
```

**Body (zh):**
```
先给几部你喜欢的打分, Discover
就会给你推荐更多可能喜欢的。
```

**CTA button (en):** `Start ranking`
**CTA button (zh):** `开始打分`

### Cold-start partial (3/5 threshold)

**Banner (en):** `Rank a few more and unlock more Discover pools. You're at ${n}/5.`
**Banner (zh):** `再打几分, 解锁更多推荐。你已打了 ${n}/5。`

**CTA (en):** `Start ranking →`
**CTA (zh):** `开始打分 →`

### Error state

**Text (en):** `Couldn't load Discover.`
**Text (zh):** `无法加载。`

**Retry button (en):** `Try again`
**Retry button (zh):** `重试`

No explanations, no technical details, no error codes. The user either retries or navigates away.

### Pool-level hidden (no copy)

Empty pools are silently hidden. No "no picks in this pool" messages. Absence is the communication.

## 7. Toast copy

### Save to watchlist
**Success (en):** `Added to watchlist`
**Success (zh):** `已加入想看`

**Already in watchlist (en):** `Already in your watchlist`
**Already in watchlist (zh):** `已在想看列表中`

### Rank from Discover
**Success (en):** `Ranked. Nice pick.`
**Success (zh):** `已打分。好选择。`

(The "Nice pick." is deliberately warm. It's the one exclamation-adjacent moment on the surface because completing a rank IS a small celebration.)

### Error saving
**en:** `Couldn't save. Try again?`
**zh:** `保存失败。再试一次?`

## 8. A11y strings (aria-labels)

| Context | en | zh |
|---|---|---|
| Save button | `Save ${title} to watchlist` | `将《${title}》加入想看` |
| Rank button | `Rank ${title} now` | `为《${title}》打分` |
| Media filter chip | `Filter Discover by ${mediaType}` | `按${mediaType}筛选` |
| Pool section | `${poolHeader}, ${n} picks` | `${poolHeader}, ${n} 个推荐` |
| Dismiss banner | `Dismiss banner` | `关闭横幅` |

## 9. i18n key table (ready to add to `i18n/en.ts` and `i18n/zh.ts`)

Add under a new `discover` namespace (alongside the existing `discover.*` keys used by the legacy DiscoverView — some will be reused, many will be new).

```typescript
// i18n/en.ts additions
'discover.title': 'Discover',
'discover.subtitle': 'Fresh picks for today, built from your taste.',

'discover.filter.all': 'All',
'discover.filter.movies': 'Movies',
'discover.filter.tv': 'TV',
'discover.filter.books': 'Books',

// Pool headers
'discover.pool.friend.header': 'Your people loved this',
'discover.pool.similar.header': 'Because you loved {title}',
'discover.pool.taste.header': 'Fits your taste',
'discover.pool.trending.header': 'Hot on Spool',
'discover.pool.variety.header': 'Outside your usual',

// Pool subtitles
'discover.pool.friend.subtitle.one': '{username} ranked these high',
'discover.pool.friend.subtitle.two': '{a} and {b} ranked these high',
'discover.pool.friend.subtitle.many': '{a}, {b}, and {n} others',
'discover.pool.friend.subtitle.fallback': 'Picks from your circle',
'discover.pool.taste.subtitle.fallback': 'Based on what you love',
'discover.pool.trending.subtitle': '{n} people ranked these this week',
'discover.pool.variety.subtitle.fallback': 'Try something different',

// Card reason lines
'discover.card.reason.friend.one': '{username} ranked this {tier}',
'discover.card.reason.friend.many': '{username} and {n} others ranked this {tier}',
'discover.card.reason.friend.mixed': '{username} loved this. {n} more ranked it.',
'discover.card.reason.friend.fallback': 'Ranked high by your circle',
'discover.card.reason.similar.sameRole': 'Same {role} as {title}',
'discover.card.reason.similar.sameActor': '{actor} is in this too',
'discover.card.reason.similar.fallback': 'More like {title}',
'discover.card.reason.taste.genreDecade': '{genres}, {decade}',
'discover.card.reason.taste.directorPhase': 'Your {director} phase continues',
'discover.card.reason.taste.matchCount': 'Matches {n} of your S-tiers',
'discover.card.reason.taste.fallback': 'Feels like your S-tier picks',
'discover.card.reason.trending': '{n} people ranked this {tier} this week',
'discover.card.reason.trending.alt': '{n} fresh {tier} rankings this week',
'discover.card.reason.variety.firstOf': "You haven't ranked a {genre} yet",
'discover.card.reason.variety.firstQuestion': 'Your first {genre}?',
'discover.card.reason.variety.countPlus': "You've ranked {n} {genre}. Here's another.",

// Meta lines
'discover.card.meta.movie': '{year} · {g1} · {g2}',
'discover.card.meta.tv': '{year} · {genre} · {count} eps',
'discover.card.meta.book': '{year} · {author}',

// Empty states
'discover.empty.title': 'Nothing to show yet',
'discover.empty.body': 'Rank a few things you love, and Discover fills up with stuff you might also love.',
'discover.empty.cta': 'Start ranking',
'discover.coldstart.banner': "Rank a few more and unlock more Discover pools. You're at {n}/5.",
'discover.coldstart.cta': 'Start ranking →',
'discover.error.title': "Couldn't load Discover.",
'discover.error.retry': 'Try again',

// Toasts
'discover.toast.savedToWatchlist': 'Added to watchlist',
'discover.toast.alreadyInWatchlist': 'Already in your watchlist',
'discover.toast.ranked': 'Ranked. Nice pick.',
'discover.toast.saveError': "Couldn't save. Try again?",

// A11y
'discover.a11y.save': 'Save {title} to watchlist',
'discover.a11y.rank': 'Rank {title} now',
'discover.a11y.filter': 'Filter Discover by {mediaType}',
'discover.a11y.pool': '{header}, {n} picks',
'discover.a11y.dismissBanner': 'Dismiss banner',
```

```typescript
// i18n/zh.ts additions (abbreviated — matching keys, translated values)
'discover.title': '发现',
'discover.subtitle': '今日精选，基于你的品味。',
'discover.filter.all': '全部',
'discover.filter.movies': '电影',
'discover.filter.tv': '剧集',
'discover.filter.books': '书籍',
'discover.pool.friend.header': '你的朋友喜欢',
'discover.pool.similar.header': '因为你喜欢《{title}》',
'discover.pool.taste.header': '合你的品味',
'discover.pool.trending.header': 'Spool 热门',
'discover.pool.variety.header': '跳出你的舒适圈',
'discover.pool.friend.subtitle.one': '{username} 给这些高分',
'discover.pool.friend.subtitle.many': '{a}、{b} 和其他 {n} 人',
'discover.pool.trending.subtitle': '本周 {n} 人给这些打分',
'discover.card.reason.friend.one': '{username} 给这个打了 {tier}',
'discover.card.reason.similar.sameRole': '和《{title}》同{role}',
'discover.card.reason.trending': '本周 {n} 人打了 {tier}',
'discover.card.reason.variety.firstOf': '你还没看过{genre}',
'discover.card.reason.variety.firstQuestion': '你的第一部{genre}?',
'discover.empty.title': '暂无内容',
'discover.empty.body': '先给几部你喜欢的打分, Discover 就会给你推荐更多可能喜欢的。',
'discover.empty.cta': '开始打分',
'discover.coldstart.banner': '再打几分, 解锁更多推荐。你已打了 {n}/5。',
'discover.error.title': '无法加载。',
'discover.error.retry': '重试',
'discover.toast.savedToWatchlist': '已加入想看',
'discover.toast.alreadyInWatchlist': '已在想看列表中',
'discover.toast.ranked': '已打分。好选择。',
'discover.toast.saveError': '保存失败。再试一次?',
// ... remaining keys filled in during implementation
```

## 10. Strings the legacy DiscoverView used that should be deleted

These keys exist in `i18n/*.ts` today from the old DiscoverView and should be removed once the new surface ships:

- `discover.forYou` (old tab label)
- `discover.fromCircle`, `discover.circleHint`
- `discover.followMore`
- `discover.trending`, `discover.trendingTitle`, `discover.trendingHint`, `discover.trendingEmpty`
- `discover.rankers`
- `discover.saveToWatchlist` (replaced by `discover.toast.savedToWatchlist`)

Check for other callers before deleting. If any surface outside DiscoverView uses these keys, leave them.

## 11. Voice check examples (before vs after)

Generic voice vs Spool voice, on the same data:

| Generic | Spool |
|---|---|
| "Based on your viewing history" | "Because you loved Past Lives" |
| "You might also enjoy" | "Your Celine Song phase continues" |
| "Trending in your area" | "12 people ranked this S this week" |
| "Recommended for you" | "Alex ranked this S" |
| "Explore new genres" | "You've ranked 2 horror movies. Here's a 3rd." |
| "Personalized picks" | "Fits your taste" |

The left column is banned. The right column is the goal.

## 12. Open questions for implementation

1. **Does `{title}` interpolation need book brackets?** Chinese convention uses 《》 around titles. English does not. The string templates above assume English omits brackets and Chinese includes them. Verify the i18n library supports conditional markup per locale; if not, hardcode brackets into the zh values.
2. **Pluralization for counts.** "1 person" vs "2 people." English has two forms; Chinese has one. Use the existing i18n plural mechanism (if one exists), otherwise hand-roll a `pluralize()` helper in `utils/`.
3. **The "ranked this S" format on the Friend pool.** Should it be "S-tier" or just "S"? Current project usage varies. Recommendation: **just the letter** (e.g., "ranked this S"). Terser. The letter alone is recognizable enough within Spool.
4. **Variety pool wording sensitivity.** "You haven't ranked a documentary yet" can read as a nudge. Make sure it doesn't feel like shaming the user's taste. The "try this" / "here's a 3rd" variants are meant to feel curious, not judgmental.

---

*End of copy spec. See rollout plan for the shipping sequence.*
