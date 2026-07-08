# C2-iOS Journal Design (owner-approved 2026-07-08)

Bring the full **manual** journal to Spool iOS (the AI agent is deferred). iOS has zero journal code today; the web half (security fixes) is merged (PR #33) and the backend is live in prod.

## Owner decisions (visual/brainstorm session 2026-07-08)

1. **Scope:** full journal minus the AI agent — ceremony quick-entry + journal tab + composer (all 15 fields) + photos + search + likes. The Kimi `journal-agent` chat client is deferred to a follow-up.
2. **Placement:** journal lives **inside the Stubs tab**, which becomes "your movie memories." A segmented header (`stubs` / `journal`) switches between the existing ticket grid and a reverse-chronological entry list. Stubs and journal entries for the same film cross-link.
3. **Ceremony → composer:** after the rank ceremony's moods + one-liner, an inline "write more" jumps into the SAME full composer, pre-filled — one composer, one edit door (captures rich entries at peak motivation).

## Reference & contract (binding)

- Audit: `docs/plans/audits/2026-07-08-c2-journal-web-audit.md` (entry contract, field marshalling, visibility resolution, RLS). Contract doc: `docs/contracts/shared-payloads.md` (`## journal_entries`).
- **Full-replace upsert:** `journal_entries` upsert replaces the whole row (web semantics). The composer MUST load the complete owner row (`select('*')`, owner path retains `personal_takeaway`) before editing, or it wipes fields — the exact bug PR #33 fixed on web. iOS avoids it by construction: the composer never opens from a partial row, always from a fresh owner-scoped fetch keyed on the entry's `(user_id, tmdb_id)`.
- **Resolved visibility:** `COALESCE(visibility_override, profiles.profile_visibility)`; owner always reads; iOS mirrors `resolveVisibility(override, profileVisibility)` as a pure function.
- **Likes:** the `journal_entry_likes` table (unique per user) + trigger-maintained `like_count` (PR #33). Toggle = insert/delete own row; the old increment/decrement RPCs are dropped — do not call them.
- **Photos:** private `journal-photos` bucket; store the storage PATH (`{userId}/{entryId}/{index}.{ext}`), render via 30-day signed URLs re-signed on view (never persist a signed URL). Owner-only storage RLS.
- **Personal takeaway** is owner-only; never sent in any cross-user read path (already enforced server-side; iOS only ever reads its own entries in the composer).

## Architecture

Pure/tested layer under thin SwiftUI, mirroring the feed cycle:

- **`JournalEntryContract` (pure):** `resolveVisibility(override:profileVisibility:)`; `upsertPayload(from: JournalDraft) -> JournalUpsertPayload` (the full 15-field marshalling — every field mapped, none silently dropped, pinned by a truth-table test); `draft(from: JournalRow) -> JournalDraft` (round-trip). `JournalDraft` = the editable model (moods, vibes, review text, one-liner, favorite moments, standout performances, watch location/platform/with-whom, rewatch flag+note, personal takeaway, photo paths, visibility_override).
- **`JournalRepository` (actor):** `upsert(payload)` (full-replace), `getOwnEntry(tmdbId)` (owner `select('*')`), `listEntries(userId:limit:)` (reverse-chron), `search(query:targetUserId:)` (the invoker `search_journal_entries` RPC — excludes `personal_takeaway`), `toggleLike(entryId:currentlyLiked:)`, `likedEntryIds(...)`, `deleteEntry(...)`. Guards + `[JournalRepository]` logging like the other repos.
- **`PhotoStore`:** PHPicker selection → `uploadJournalPhoto(entryId:index:data:) -> path`; `signedURL(forPath:) -> URL` (30-day). Pure `journalPhotoPath(userId:entryId:index:ext:)` builder tested.
- **Views:** `StubsScreen` gains the `stubs`/`journal` segmented header; `JournalListView` (entry cards) + `JournalEntryCard` (torn-page: title/year, mood stamps, review excerpt, photo strip, visibility glyph, like count); `JournalComposer` (single scrolling paper sheet, collapsible sections: the moment / the feeling / the details / private / photos / visibility); ceremony "write more" routes into `JournalComposer` pre-filled.

## Components & boundaries

| Unit | Responsibility | Depends on |
|---|---|---|
| `JournalEntryContract` | pure marshalling + visibility (no I/O) | models only |
| `JournalRepository` | journal_entries + likes + search I/O | SpoolClient, contract |
| `PhotoStore` | photo pick/upload/sign | SpoolClient storage, PhotosUI |
| `JournalDraftModel` (@MainActor ObservableObject) | composer state, load-full-row-first, save, validation | repo, contract, PhotoStore |
| `JournalListModel` | list/search/like state | repo |
| views | render + wire | the models |

## Data flow

Ceremony finish (moods+line) → if "write more": open `JournalComposer` seeded from a `JournalDraft` (moods+one-liner pre-filled) → on first open for an existing film, `JournalDraftModel` fetches the full owner row and merges (never partial) → save → `upsertPayload` → `JournalRepository.upsert` (full replace) → list refreshes. Quick-entry without "write more" still writes a minimal `journal_entry` (moods + one-liner) via the same payload path (stage a). Likes/search from `JournalListView` hit the repo directly. Photos: pick → upload path → stored in the draft → rendered via signed URLs.

## Testing

All pure logic RED-first: visibility resolution truth table; `upsertPayload` field-marshalling (assert every one of the 15 fields present with correct key/shape — the no-silent-drop guard); `draft(from:)` round-trip; search-result mapping excludes takeaway; photo-path builder; like-toggle state. Network paths are live in prod (PR #33 applied) → device smoke is real. SwiftUI previews for the composer (empty + full + pre-filled), entry card (with/without photos, each visibility), and the stubs/journal segmented header.

## Deferred (ledgered, not in this cycle)

- **AI agent chat** — the Kimi `journal-agent` edge-function client (session/consent/correction flow). Own follow-up.
- **journal_tag notifications** deep-linking on iOS (the C1 deferred item).
- The web `JournalEntrySheet` is dead code; do not port it.

## Definition of done

Journal tab renders own entries with real prod data; composer creates/edits with all 15 fields round-tripping (no field wiped); photos upload + display via signed URLs; likes toggle; search works; ceremony "write more" seeds the composer; visibility respected; suite green; owner device smoke.
