# iOS Design Check Audit — "functions overlaying each other"

- **Branch:** `fix/ios-design-check`
- **Scope:** SwiftUI SPM library `ios/Spool/Sources/Spool` — Screens/, Components/, App/, Theme/, L10n/
- **Mode:** READ-ONLY. No code was edited. This doc characterizes root causes and proposes minimal fixes.
- **Date:** 2026-07-11

All line numbers are against the files as they exist on `fix/ios-design-check`.

---

## Summary table

| # | Defect | File:line | Root cause | Severity | Fix size |
|---|--------|-----------|------------|----------|----------|
| 1 | Preview banner overlaps Recent Stubs / last-watched card | `App/SpoolAppRoot.swift:210-219`, `281-307`; content reserve `Screens/StubsScreen.swift:134`, `Screens/ProfileScreen.swift:39` | Bottom `.overlay` stack (banner + nav) grows ~33pt taller when `previewMode`, but every scroll screen hard-codes a fixed `.padding(.bottom, 110)` reserve that never accounts for the banner | **Blocking** | Structural (introduce shared bottom reserve) OR quick (`.safeAreaInset(edge:.bottom)`) |
| 2 | Floating "+" FAB overlaps banner / nav | `Components/BottomNav.swift:35-46`, `87-103`; stack `App/SpoolAppRoot.swift:210-219` | The + is `.offset(y:-22)` OUT of the nav's own bounds, and the banner is stacked directly ABOVE the nav in the same VStack, so the 22pt of circle that pokes up lands on top of / touching the banner. No `zIndex`, no spacer for the FAB overhang | **Blocking** | Quick (add top spacer to overhang + raise zIndex) |
| 3 | "◉ 4 friends" pill clipped / truncated | `Screens/ProfileScreen.swift:335-343`; pill `Components/SpoolPill.swift:21-37` | `footerPills` is a plain `HStack` with two pills and no `Spacer`, no `.fixedSize()`, no wrap. The long taste-twin pill competes for width; `SpoolPill`'s `Text` has no `lineLimit`, so under pressure the friends pill's label truncates while its capsule keeps full width | **Blocking** | Quick (`.fixedSize()` on pills or wrap) |
| 4 | Settings "ghost circle" (blank avatar ring) | `Components/Avatar.swift:3-18` (`StripedAvatar`); used at `Screens/ProfileScreen.swift:72`, `Screens/FriendProfileScreen.swift:115` | `StripedAvatar` paints `StripePattern(a: cream3, b: cream2)` — in paper mode those two creams differ by <15/channel and sit on a `cream` page, so the stripes are near-invisible and the avatar reads as an empty ink ring. It is a permanent placeholder that never shows a photo (avatar upload is deferred) | **Polish** (Blocking if read as broken) | Quick (raise stripe contrast or swap to initials avatar) |
| 5 | Queue vs Watchlist naming mismatch (EN) | nav `L10n/EN.swift:19`; screen title `L10n/EN.swift:432`; screen `Screens/WatchlistScreen.swift:44` | Bottom-nav tab label is `nav.queue` = "queue" but the screen it opens is titled `watchlist.title` = "watchlist"; internal copy/comments also call it "the queue". ZH is consistent ("想看" for both) | **Polish** | Quick (one string) |
| 6 | StubShareScreen ships hardcoded demo values | `Screens/StubShareScreen.swift:30-37`, `62-66`, `107`, `123` | The share card renders literal fake data (`"cried on the 6 train."`, moods `["tender","devastating"]`, `"APR · 18 · 2026"`, `"#0127"`, director `"celine song"`, `year: 2023`, handle `"@yurui"`) instead of the tapped `stub`'s real data | **Blocking** | Structural-ish (thread real stub fields through) |
| 7 | zh typography — CJK on display fonts + long-string clipping | `Theme/SpoolFonts.swift:24-49`; banner `App/SpoolAppRoot.swift:290-294`; pills throughout | Gloock/Kalam/Caveat carry NO CJK glyphs, so every zh string in `serif`/`hand`/`script` falls back per-glyph to the system CJK face (aesthetic + baseline/line-height shift). Long zh strings in fixed single-line capsules (`.lineLimit(1).minimumScaleFactor(0.85)`) shrink or clip | **Polish** | Structural (register a CJK display face) + quick per-pill relief |

**Additional defects found (not owner-reported):**

| # | Defect | File:line | Root cause | Severity |
|---|--------|-----------|------------|----------|
| A1 | `paletteToggle` overlaps the header title row | `App/SpoolAppRoot.swift:220`, `880-897` | Top-trailing overlay circle sits at `.top+6 / .trailing+14`, directly over the same y-band as `SpoolHeader`/feed wordmark trailing cluster (bell, compass). It can overlap the notification bell on FeedScreen | Polish |
| A2 | EN preview-banner copy contains an em dash | `L10n/EN.swift:561` | `"preview mode — sign in to save your rankings"` violates the owner's no-em-dash voice rule (enforced for zh via parity test, but the EN value is unchecked) | Polish |
| A3 | Fixed `.padding(.bottom, 110)` ignores the home-indicator safe area | all 10 scroll screens (see list under Defect 1) | 110 is a magic constant covering the nav in the common case but not the safe-area bottom inset on notched devices; combined with Defect 1 it under-reserves | Polish |

**Counts: 5 Blocking, 5 Polish** (Blocking = 1, 2, 3, 6, and the EN-only naming/typography items are Polish; Defect 4 rated Polish, Defect 7 Polish; additional A1–A3 Polish).

> Blocking total for the headline report = **4** hard overlap/clip/demo-data defects (1, 2, 3, 6). Defect 5 (naming) and 7 (zh type) and 4 (ghost circle) and A1–A3 are Polish → **6 Polish**.

---

## Defect 1 — Preview banner overlaps "Recent Stubs" (Blocking)

### Where it lives
The banner + nav are a single bottom overlay on the active screen:

`App/SpoolAppRoot.swift:209-219`
```swift
screen
    .overlay(alignment: .bottom) {
        VStack(spacing: 0) {
            if previewMode && !navHidden {
                previewBanner
            }
            if !navHidden {
                BottomNav(active: tab, onTab: onTab)
            }
        }
    }
```

The banner itself (`App/SpoolAppRoot.swift:281-307`) is a yellow capsule with `.padding(.vertical, 6)` + `.padding(.bottom, 6)` → it adds roughly **30–34pt of height above the nav** when `previewMode == true`.

Every scrolling screen reserves a FIXED bottom pad for the nav and nothing else:

`Screens/StubsScreen.swift:133-134`
```swift
.padding(.horizontal, 16)
.padding(.bottom, 110)
```
Same constant at `ProfileScreen.swift:39`, `FeedScreen.swift:75`, `WatchlistScreen.swift:117`, `FriendProfileScreen.swift:65`, `JournalListView.swift:44`, `DiscoverScreen.swift:169`, `FriendsScreen.swift:35`, `StubDetailScreen.swift:80`, `TwinScreen.swift:81`.

### Root cause
This is an **overlay z-order + insufficient content reserve** problem, not a ZStack-alignment bug. `.overlay` always draws ABOVE its subject, so the banner and nav correctly float on top. The failure is that the scrollable content's bottom reserve (`110`) is a constant sized for *nav only*. When the preview banner is present it consumes another ~33pt, so the last ~33pt of scroll content (the "last watched" `AdmitStub` card at `StubsScreen.swift:119-127`, the "RECENT STUBS" row on Profile) sits *under* the opaque banner. To the user the banner and the Recent Stubs content "render on top of each other."

There is **no `.safeAreaInset`** anywhere in the codebase (verified), so nothing dynamically pushes content up when the banner appears.

### Fix (prefer the idiomatic one)
The codebase already floats the nav as an overlay; the clean fix is to convert the reserve from a magic number into a real safe-area inset so content always clears whatever the overlay actually is:

- Replace the `.overlay(alignment:.bottom){ banner+nav }` with `.safeAreaInset(edge: .bottom, spacing: 0) { VStack{ banner; nav } }` on `mainApp`. `safeAreaInset` both draws the bar AND shrinks the safe area every screen's `ScrollView` respects, so the per-screen `.padding(.bottom, 110)` can drop to a small breathing pad (e.g. `12`) and the banner can never overlap content in either preview or signed-in mode.

Minimal alternative (no structural change): make the reserve conditional. Expose the current bottom-bar height (nav height, plus banner height when `previewMode`) through the environment and have each screen pad by that value instead of `110`. More plumbing than the `safeAreaInset` route for the same result; prefer `safeAreaInset`.

---

## Defect 2 — Floating "+" overlaps banner / nav (Blocking)

### Where it lives
`Components/BottomNav.swift:35-46`
```swift
ZStack(alignment: .top) {
    capsule(t: t)
    plusOverlay(t: t)
}
.padding(.horizontal, 14)
.padding(.bottom, 18)
.padding(.top, 22)   // room for the + overhang
```
`Components/BottomNav.swift:87-103`
```swift
Button { onTab(.rank) } label: { Text("+") ... .frame(width: 54, height: 54) ... }
.offset(y: -22)      // 22pt pokes above the capsule top edge
```

And the banner is stacked directly above the nav in the same VStack (`SpoolAppRoot.swift:210-219`).

### Root cause
Two compounding issues:
1. **FAB overhang vs banner.** The + is offset `-22` so 22pt of the 54pt circle extends above the capsule. `BottomNav` adds `.padding(.top, 22)` to reserve that space *within its own bounds* — but the preview banner is a **sibling stacked immediately above** the nav (VStack `spacing: 0`). The banner's bottom edge and the FAB's top edge land in the same 22pt band, so the + touches / overlaps the yellow banner capsule. When `navHidden` is false and preview mode is on, the two visually collide.
2. **No z-order guarantee.** Neither the FAB nor the banner sets `zIndex`, so the paint order is source order. The banner (declared first) paints under the nav's ZStack, and the FAB (last in the ZStack) paints on top — the FAB wins over the banner but the *overlap itself* is the defect, not who's on top.

### Fix
- In the `VStack` at `SpoolAppRoot.swift:211`, give the banner bottom clearance so the FAB overhang never reaches it: add `.padding(.bottom, 10)` to the banner call OR increase the VStack `spacing` to ~14 (the FAB overhang is 22, the capsule top padding is 22, so ~14 of banner-to-nav gap fully clears it).
- Reuse the existing idiom: `BottomNav` already documents (lines 79-101) that the FAB is a deliberate half-in overlap of the *capsule*. Keep that, but treat the banner as a peer that must sit above the FAB's reach. Alternatively set `.zIndex(1)` on the `plusOverlay` and `.zIndex(0)` on the banner so any residual overlap renders the + cleanly on top rather than half-behind the banner stroke.
- Quick one-liner that removes the collision entirely: raise the VStack spacing — `VStack(spacing: 14)` at `SpoolAppRoot.swift:211`.

---

## Defect 3 — "◉ 4 friends" pill clipped (Blocking)

### Where it lives
`Screens/ProfileScreen.swift:335-343`
```swift
private var footerPills: some View {
    HStack(spacing: 6) {
        SpoolPill(L10n.t("profile.friendsCount", ["n": "\(friendsCount)"]), size: .sm)   // "◉ 4 friends"
        if let twin = topTwin {
            SpoolPill(L10n.t("profile.tasteTwin",
                ["handle": twin.handle, "score": "\(twin.score)"]), size: .sm)          // "taste twin @handle · 87%"
        }
    }
}
```
`Components/SpoolPill.swift:22-34` — the pill is a `Text(title)` with padding + capsule; **no `.lineLimit`, no `.fixedSize`, no `.minimumScaleFactor`.**

### Root cause
`padding`/`frame`/no-`fixedSize`. The `footerPills` HStack has two pills, no trailing `Spacer(minLength:)`, and no scroll. The taste-twin pill is long ("taste twin @somelonghandle · 87%"). Because `SpoolPill` doesn't set `.fixedSize()`, SwiftUI is free to compress either pill to fit the row inside the outer `.padding(.horizontal, 18)`. The short "◉ 4 friends" pill gets squeezed, and since its inner `Text` has no `lineLimit(1)` guard the label truncates (or wraps oddly) while the capsule background/stroke keeps drawing — reading as a clipped pill. The `friendProfile.footerPills` (`FriendProfileScreen.swift:364-371`) has the same shape (mutual + stubs pills) and the same risk.

### Fix
Prefer the existing idiom — other pill rows that must not compress use a trailing `Spacer(minLength: 0)` (see `WatchlistScreen.mediaSwitcher:72`, `FeedScreen.modeSwitcher:155`, `StubsScreen.tabSwitcher:90`). Apply the same here:
- Add `Spacer(minLength: 0)` at the end of the `footerPills` HStack so the pills size to content and left-align instead of stretching to fill.
- Belt-and-suspenders: add `.fixedSize()` to `SpoolPill`'s `Text` (or the whole pill) so a pill never compresses below its intrinsic width. This is the most targeted fix and protects every pill site at once.
- If the twin pill is genuinely too wide for the row, wrap `footerPills` in a horizontal `ScrollView` (matches how the app scrolls other over-wide chip rows), or drop the pills to a two-line layout.

---

## Defect 4 — Settings "ghost circle" (Polish; reads Blocking)

### Where it lives
There is **no avatar in `SettingsScreen.swift`** (account rows are text only, lines 145-171; Edit Profile explicitly defers avatar upload, `EditProfileScreen.swift:8-9`). The "ghost circle" the owner saw on the settings *flow* is the **profile-header avatar** the gear button sits next to:

`Components/Avatar.swift:3-18`
```swift
public struct StripedAvatar: View {
    public var body: some View {
        SpoolThemeReader { t, _ in
            ZStack {
                StripePattern(a: t.cream3, b: t.cream2, spacing: 4)   // <-- low-contrast stripes
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                Circle().stroke(t.ink, lineWidth: 1.5)                 // <-- the visible ring
            }
        }
    }
}
```
Used at `ProfileScreen.swift:72` and `FriendProfileScreen.swift:115` (`StripedAvatar(size: 72)`).

### Root cause
Low-contrast placeholder that never resolves to a photo. Paper palette (`Theme/SpoolTokens.swift:57-59`):
```
cream  = #F2ECDC   (page)
cream2 = #E8E0C9   (stripe b)
cream3 = #DDD3B8   (stripe a)
```
`cream2` and `cream3` differ by only ~11/channel, on a `cream` page — the diagonal stripes are effectively invisible at avatar scale, so the avatar renders as a bare ink ring = a "ghost circle." `avatar_url`/`avatar_path` exist on `ProfileRow` but are never read by any avatar view (verified — the only `AsyncImage` avatar is `FeedTicket.avatar`, which has a *filled* gray placeholder, not a ring). So the profile/settings avatar is a permanent empty ring.

### Fix (reuse an existing idiom)
- **Best:** replace `StripedAvatar` at the profile headers with an **initials avatar** derived from the handle/display name (filled disc + monogram) — this is the standard "no photo" pattern and matches the paper aesthetic. There is no existing initials avatar component, so this is a small new view or an extension of `StripedAvatar` that takes a fallback letter.
- **Quickest:** raise stripe contrast so the pattern is actually visible — e.g. use `StripePattern(a: t.ink.opacity(0.12), b: t.cream2, ...)` or `(a: t.cream3, b: t.ink.opacity(0.08))`. Removes the "empty ring" read without new plumbing.
- **Correct long-term:** wire `avatar_url` through an `AsyncImage` (mirror `FeedTicket.avatar:296-319`) with the initials/striped disc as the placeholder, so real photos land when upload ships.

---

## Defect 5 — Queue vs Watchlist naming (Polish)

### Every user-facing variant and where it shows
| String | Value (EN) | Value (ZH) | Surface |
|--------|-----------|-----------|---------|
| `nav.queue` | **"queue"** | "想看" | Bottom-nav tab label (`BottomNav.swift:62` → `L10n.t("nav.queue")`) |
| `watchlist.title` | **"watchlist"** | "想看" | Screen header title (`WatchlistScreen.swift:44`) |
| `watchlist.loadFailed` | "couldn't load your **watchlist**" | "想看列表没加载出来" | Error state |
| `watchlist.removeA11y` | "Remove {title} from **watchlist**" | "把{title}从想看里删除" | VoiceOver |
| `shelf.deleteMessage` | "…won't return to your **watchlist**." | (see ZH) | Shelf delete confirm (`EN.swift:383`) |
| code comments | "…drops out of the **queue**" | — | `WatchlistScreen.swift:24,55`, `SpoolAppRoot.swift:80` |

### Root cause / assessment
Real, EN-only. The **tab says "queue" but the screen it opens is titled "watchlist"** and all supporting copy says "watchlist". ZH is internally consistent (both "想看"), so this is an English-copy mismatch, not a data issue. "Want to watch" does **not** appear anywhere — that variant is not in the tables.

### Fix
Pick one term and align. Least-churn: change `nav.queue` value "queue" → "watchlist" (`EN.swift:19`) so the tab matches its screen and all the "watchlist" copy. (Keep the key name `nav.queue` to avoid a parity-key rename, or rename the key too if desired.) ZH needs no change.

---

## Defect 6 — StubShareScreen ships demo values (Blocking)

### Where it lives
`Screens/StubShareScreen.swift:30-37`
```swift
private var stubMovie: Movie {
    Movie(id: stub.title, title: stub.title, year: 2023, director: "celine song", seed: 0)
}
private let stubLine = "cried on the 6 train."
private let stubMoods = ["tender", "devastating"]
private let stubDate = "APR · 18 · 2026"
private let stubNo = "#0127"
```
These are then rendered into the visible share card and the exported image:
`StubShareScreen.swift:62-66` (`AdmitStub(... line: stubLine, moods: stubMoods, date: stubDate, stubNo: stubNo)`) and `StubShareScreen.swift:107` / `123` (`StubImageRenderer.render(... handle: "@yurui" ...)`).

### Root cause
Hardcoded placeholder data. Only `stub.tier` and `stub.title` come from the tapped `WatchedDay`; everything else — the review line, moods, date, stub number, director, year, and the `@yurui` handle — is a literal constant. So a real user sharing *their* stub gets someone else's fake review ("cried on the 6 train."), a wrong date ("APR · 18 · 2026"), a fake sequence number ("#0127"), and the handle "@yurui" burned into the exported image and the Instagram/TikTok/save payloads. This ships to real users.

### Fix
Thread the real values in. `WatchedDay` already carries `day`/`month`/`year`/`tier`/`title` (`StubsScreen.rowToDay:331-341`), and the detail/share flow originates from a real `StubRow` in `StubsScreen` (which has `stub_line`, `mood_tags`, `watched_date`, and a global stub number via `stubNumber(totalStubsCount)`). The minimal correct fix:
- Extend the `stubDetail`/`stubShare` seam in `SpoolAppRoot` (lines 90-91, 319-329) to pass the full `StubRow` (or a richer `WatchedDay` carrying line/moods/date/number) into `StubShareScreen`, and delete the six hardcoded constants in favor of those fields.
- Pull the handle from `ProfileRepository.getMyProfile()`/`SpoolClient` instead of the literal `"@yurui"` (the profile handle is already loaded elsewhere, e.g. `ProfileScreen.displayedHandle`).
- Reuse `StubsScreen.admitDate(...)` (lines 368-377) and `stubNumber(...)` (385-387) so the share card's date/number formatting matches the rest of the app.

Until wired, at minimum gate this screen behind real data so it never renders "@yurui / cried on the 6 train." to a signed-in user.

---

## Defect 7 — zh typography (Polish)

### Where it lives
`Theme/SpoolFonts.swift:24-49` — `serif` (Gloock), `hand` (Kalam), `script` (Caveat) all resolve to Latin-only display faces bundled at `ios/SpoolApp/SpoolApp/Fonts/*.ttf` and registered via `Info.plist` `UIAppFonts`. None contain CJK glyphs.

### Root cause / assessment (real)
1. **CJK falls off the display face.** Every zh string rendered in `serif`/`hand`/`script` (headers, bios, pills, the preview banner) has no glyph in Gloock/Kalam/Caveat, so iOS silently substitutes the system CJK face per-glyph. Result: the handwritten/serif *character* is lost for Chinese, and mixed EN+zh strings show two different faces on one line with a baseline/weight mismatch. `mono` (DM Mono) has the same gap.
2. **Long zh in fixed single-line capsules.** The preview banner (`SpoolAppRoot.swift:290-294`) is `hand(12)` + `.lineLimit(1).minimumScaleFactor(0.85)`; the zh value `"预览模式，登录后才能保存你的排名"` (`ZH.swift:512`, 15 chars) is longer than the EN and will hit `minimumScaleFactor` and shrink. Pills (`SpoolPill`, Defect 3) have no line-limit guard, so long zh labels like `"品味双子 @handle · 87%"` (`ZH.swift:193`) can clip in a fixed row.

### Fix
- Register a CJK-capable display face (or an explicit fallback) so zh text keeps a consistent look. Practical minimal path: in `SpoolFonts`, when `LocaleStore.current == .zh`, return a system CJK font at the same size/weight rather than the Latin custom face — the Latin faces add nothing for zh and cause the baseline mismatch. This is a `SpoolFonts` change, no call-site churn.
- Give fixed-width single-line zh containers relief: the banner and pills should allow a second line or a larger `minimumScaleFactor` floor for zh (or `.fixedSize()` per Defect 3).
- (Voice) A2: recast the EN banner to drop the em dash to match the zh no-dash rule.

---

## Additional (not owner-reported)

- **A1 — palette toggle over header cluster.** `SpoolAppRoot.swift:220` overlays `paletteToggle` at top-trailing (`.top+6/.trailing+14`, `SpoolAppRoot.swift:894-895`). On FeedScreen the header trailing cluster (compass + bell, `FeedScreen.swift:117-123`) lives in the same corner band; the toggle can sit over the bell. Fix: move the toggle into the header trailing cluster per-screen, or inset it below the header band.
- **A2 — em dash in EN banner copy** (`EN.swift:561`). See Defect 7 fix.
- **A3 — fixed 110pt reserve vs safe area.** The `.padding(.bottom, 110)` constant across all 10 scroll screens does not track the device home-indicator inset; fold this into the Defect 1 `safeAreaInset` fix so the reserve is computed, not guessed.

---

## Recommended fix order
1. Defect 1 + 2 + A3 together via one `safeAreaInset(edge:.bottom)` refactor of the banner/nav stack (kills both overlaps and the magic constant).
2. Defect 3 — add `.fixedSize()` to `SpoolPill` (+ trailing `Spacer` in the two footer rows).
3. Defect 6 — thread real stub data into StubShareScreen (or gate it).
4. Defect 5 — one-string rename.
5. Defect 4 + 7 — avatar contrast/initials and zh font fallback (both isolated to one component/file each).
