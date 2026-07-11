# iOS Design-Check Fix Plan (overlay/clipping/demo-data defects)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Fix the owner-reported "functions overlaying each other" defects on the iOS app plus the polish items surfaced in the audit, without regressing the 854-test suite.

**Architecture:** SwiftUI SPM library `ios/Spool/Sources/Spool`. The keystone is a `safeAreaInset(edge:.bottom)` refactor of the banner/nav stack that removes the fixed `.padding(.bottom, 110)` reserve across 10 scroll screens and kills both overlap defects at once. Remaining tasks are isolated per-component fixes.

**Tech Stack:** Swift + XCTest. Baseline suite: iOS 854, 0 failures. No backend/migrations.

## Global Constraints

- Binding audit: `docs/plans/audits/2026-07-11-ios-design-check-audit.md` (defect list, file:line, root causes, proposed fixes).
- L10n: any changed/new user-facing copy goes through `L10n.t` with en + zh values; the L10n parity test must stay green. NO em dashes / no `不是…而是` / no negation-contrast in copy (owner voice rules).
- Conventional commits + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; bump any edited `Header last reviewed:` header to 2026-07-10.
- Do NOT edit `ios/SpoolSimulator` project files. Layout changes must not alter existing test expectations without updating the test in the same task.
- Purely visual changes that no test covers: add a snapshot-free unit test only where a pure seam exists (e.g. a formatting/derivation function); otherwise trace the manual-verification note in the task report. Do not invent no-op tests.

---

### Task 1: Bottom-bar safe-area refactor (Defects 1, 2, A3)

**Files:** `App/SpoolAppRoot.swift` (banner+nav overlay ~209-219, banner ~281-307), and the bottom reserve in all 10 scroll screens listed in the audit (`StubsScreen.swift:134`, `ProfileScreen.swift:39`, `FeedScreen.swift:75`, `WatchlistScreen.swift:117`, `FriendProfileScreen.swift:65`, `JournalListView.swift:44`, `DiscoverScreen.swift:169`, `FriendsScreen.swift:35`, `StubDetailScreen.swift:80`, `TwinScreen.swift:81`); `Components/BottomNav.swift` only if the FAB overhang needs a spacing tweak.
- Replace the `.overlay(alignment:.bottom){ VStack{ banner; nav } }` on the active screen with `.safeAreaInset(edge:.bottom, spacing:0){ VStack(spacing:…){ banner (preview only); nav } }` so the bar both draws AND shrinks every screen's scroll safe area. Choose the VStack spacing so the FAB's `-22` overhang (BottomNav) never touches the preview banner (audit Defect 2: ~14pt clears it).
- Reduce each screen's `.padding(.bottom, 110)` to a small breathing pad (audit suggests ~12) now that the inset reserves the bar height. Verify NO screen relies on the 110 for anything but nav clearance (grep for other uses).
- Verify: signed-in (no banner) and preview (banner present) both clear the last scroll item; the FAB renders cleanly with no banner collision. Add/adjust any layout test that asserted the old padding.
- Commit `fix(ios): bottom bar via safeAreaInset — banner/nav no longer overlap scroll content (design-check 1,2)`.

### Task 2: Pill clipping (Defect 3)

**Files:** `Components/SpoolPill.swift` (add `.fixedSize()` / `.lineLimit(1)` so a pill never compresses below intrinsic width), `Screens/ProfileScreen.swift:335-343` (`footerPills` — trailing `Spacer(minLength:0)`), `Screens/FriendProfileScreen.swift:364-371` (same-shape footer). Reuse the existing `Spacer(minLength:0)` idiom used by the media/mode/tab switchers.
- Verify the "◉ 4 friends" pill and the long taste-twin pill coexist left-aligned without truncation at both narrow and normal widths.
- Commit `fix(ios): footer pills size to content, no clip (design-check 3)`.

### Task 3: StubShareScreen real data (Defect 6) — BLOCKING demo-data leak

**Files:** `Screens/StubShareScreen.swift` (delete the six hardcoded constants: review line, moods, date, stub number, director/year, `@yurui` handle), the `stubDetail`/`stubShare` seam in `App/SpoolAppRoot.swift` (~90-91, 319-329) to pass the full real `StubRow` (or a richer `WatchedDay` carrying line/moods/date/number), and the handle source (`ProfileRepository`/`SpoolClient` — mirror `ProfileScreen.displayedHandle`). Reuse `StubsScreen.admitDate(...)` + `stubNumber(...)` for formatting parity.
- If threading the full row is too broad for one task, the acceptable fallback is to gate the screen so it never renders placeholder identity to a signed-in user — but prefer the real-data thread.
- Tests: a pure formatting/derivation seam (date/number) gets a unit test; the wiring gets a trace-in-report.
- Commit `fix(ios): StubShareScreen renders the real stub, not demo values (design-check 6)`.

### Task 4: Copy fixes (Defect 5 + A2)

**Files:** `L10n/EN.swift:19` (`nav.queue` value "queue" → "watchlist" to match the screen title + all "watchlist" copy; keep the key name to preserve parity keys), `L10n/EN.swift:561` (recast the preview-banner EN copy to drop the em dash, matching the zh no-dash rule). ZH unchanged. Confirm the L10n parity test stays green.
- Commit `fix(ios): align queue→watchlist label; drop em dash in banner copy (design-check 5)`.

### Task 5: Avatar ghost circle (Defect 4)

**Files:** `Components/Avatar.swift` (`StripedAvatar`). Replace the near-invisible `cream3/cream2` stripe placeholder with a legible "no photo" treatment — prefer an initials monogram (filled disc + letter from handle/display name) matching the paper aesthetic; accept the audit's contrast-raise as the quick alternative. Keep the call sites (`ProfileScreen.swift:72`, `FriendProfileScreen.swift:115`) working; if adding an initials param, default it so existing callers compile.
- Tests: if an initials-derivation function is added (first-letter/uppercase/fallback for empty), unit-test it.
- Commit `fix(ios): profile avatar shows a legible placeholder, not a ghost ring (design-check 4)`.

### Task 6: zh typography fallback (Defect 7 + A1)

**Files:** `Theme/SpoolFonts.swift:24-49` — when `LocaleStore.current == .zh`, return a system CJK-capable font at the same size/weight instead of the Latin-only Gloock/Kalam/Caveat/DM Mono (which carry no CJK glyphs), so zh keeps a consistent face with no per-glyph baseline mismatch; EN path unchanged. `App/SpoolAppRoot.swift:220/880-897` — inset the `paletteToggle` so it doesn't overlap the FeedScreen trailing cluster (bell/compass) [A1].
- Tests: `SpoolFonts` locale branch is a pure seam — unit-test that `.zh` returns a different descriptor than `.en` for `serif`/`hand`/`script`/`mono`. Flag for owner device-smoke (visual).
- Commit `fix(ios): zh uses a CJK-capable face; palette toggle clears the header (design-check 7,A1)`.

## Self-Review Notes
- Task 1 is the keystone and touches the most files — run the FULL suite after it and eyeball that no screen's existing layout test asserted the literal 110. The other tasks are isolated.
- Defect 7's CJK face swap is visual-only and needs an owner device-smoke; the unit test only pins that the branch diverges, not that it looks right.
- Order per audit: 1 → 2 → 3 → 4 → 5 → 6. Sequential (shared files: ProfileScreen in 1/2/5, SpoolAppRoot in 1/3/6) so no intra-branch conflicts.
