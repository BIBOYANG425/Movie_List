# Shared Payload Contracts

Shapes BOTH clients write to shared tables. Any PR that changes a shape on
one platform updates this file and the other platform in the same cycle.
Program rule source: docs/plans/2026-07-07-ios-parity-program-design.md.

## movie_stubs (since PR #30 / C0)

One stub per `(user_id, media_type, tmdb_id)` — unique index; rewatches are
not representable. `media_type` ∈ {"movie", "tv_season"}; books never get
stubs (CHECK constraint). `poster_path` holds a FULL image URL (w500), not
a bare TMDB path.

**INSERT** (first rank of an item) — exactly these columns:
`user_id, media_type, tmdb_id, title, poster_path, tier, template_id,
watched_date, updated_at`.
- `watched_date`: the user's LOCAL calendar day, `yyyy-MM-dd`. Never UTC.
- `template_id`: `"s_tier_gold"` when tier = S, else `"default"`.
- `palette`, `mood_tags`, `stub_line`: NEVER sent — DB defaults own them
  (`palette text[] NOT NULL DEFAULT '{}'`). Reserved until C2 decides
  whether moods/one-liner move onto stubs.

**On unique violation (SQLSTATE 23505)** — UPDATE exactly
`title, poster_path, tier, template_id, updated_at`, keyed on
`(user_id, media_type, tmdb_id)`. `watched_date`, `palette`, `mood_tags`,
`stub_line` are preserved: a re-rank must not rewrite stub history.

**Palette refresh** (async, after either path): fetch poster, extract up to
3 lowercase `#rrggbb` colors, UPDATE `palette` only. Extraction failure
leaves the existing value. Renderers require length ≥ 2 and fall back to
tier colors otherwise. Cross-platform color equality is NOT required.

`poster_path` is encoded as an EXPLICIT JSON null when absent on both
platforms (web `?? null`, iOS custom `encode(to:)`) — PostgREST treats a
missing key as "don't touch", so omission would silently preserve a stale
poster on conflict-update.

**Failure semantics:** stub writes are fire-and-forget on both platforms —
a stub failure never fails or delays a rank save.

Implementations: web `services/stubService.ts`
(`buildStubInsertPayload` / `buildStubConflictUpdatePayload` /
`insertStubOrUpdateOnConflict`); iOS
`ios/Spool/Sources/Spool/Services/StubWriteContract.swift` + `StubWriter.swift`.
Tests: `services/__tests__/stubService.test.ts`,
`ios/Spool/Tests/SpoolTests/StubWriteContractTests.swift`.
