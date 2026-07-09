# journal-search CJK/fuzzy verification probes (Task 1)

Run by the controller against prod (project `emulyralduiitxuigboj`) in the SQL editor
(superuser/`postgres` session, which may `SET LOCAL ROLE authenticated`), AFTER applying:

- `supabase/migrations/20260709_journal_search_cjk_fuzzy.sql`
  (pg_trgm extension + two trigram GIN indexes + `CREATE OR REPLACE search_journal_entries`).

Every fixture write is wrapped in `begin; … rollback;` — nothing persists. The
matching probes (2)/(3)/(4) insert an in-transaction fixture row, search it via the
RPC, assert the row count, then roll back. The RLS probe (6) uses the
`set local role authenticated` + `request.jwt.claims` pattern from C2/C3, unchanged.

The RPC is SECURITY INVOKER: under a superuser session RLS is bypassed, so the
`user_id = target_user_id` filter alone selects the fixture rows for probes (1)-(5).
Probe (6) explicitly switches to `authenticated` to exercise the RLS row filter.

---

## 0. Fixture discovery (run as-is, no role switch — RLS bypassed)

Pick a real owner UUID and substitute it into `<OWNER>` in the probes below.
Any authenticated user with at least one journal entry works; the probes insert
their own fixture rows under that user, so an empty journal is also fine.

```sql
select je.user_id as owner_id, count(*) as entries
from journal_entries je
group by je.user_id
order by entries desc
limit 5;
```

For probe (6) you also need a SECOND user who is a STRANGER to `<OWNER>` (not a
follower, not the owner) and one of `<OWNER>`'s PRIVATE / non-public entries.

```sql
-- A stranger candidate: any other user id.
select id as stranger_id from profiles where id <> '<OWNER>' limit 5;

-- A non-public entry owned by <OWNER> (private, or NULL-override resolving
-- private via the owner's profile). Confirm it is not visible to a stranger.
select id as private_entry_id, title, visibility_override
from journal_entries
where user_id = '<OWNER>'
  and visibility_override = 'private'
limit 1;
```

---

## (1) EN word still matches via tsvector — expect ≥ 1

Confirms the primary English full-text path is untouched. Insert a fixture whose
`review_text` contains a normal English word, search that word, expect the row.

```sql
begin;
  insert into journal_entries (user_id, tmdb_id, title, rating_tier, review_text)
  values ('<OWNER>', 'tmdb_verify_en', 'Verify EN', 'S',
          'An absolutely stunning cinematography masterpiece.');

  select count(*) as hits
  from search_journal_entries('cinematography', '<OWNER>')
  where tmdb_id = 'tmdb_verify_en';
  -- EXPECT: hits >= 1  (tsvector stems 'cinematography' -> matches)
rollback;
```

## (2) CJK substring in review_text matches — expect ≥ 1

The core CJK gap. Insert a fixture with an unspaced Han run in `review_text`, then
search a single-character substring inside it. The tsvector branch yields an empty
tsquery for pure CJK (matches nothing); the trigram-ILIKE branch carries the row.

```sql
begin;
  insert into journal_entries (user_id, tmdb_id, title, rating_tier, review_text)
  values ('<OWNER>', 'tmdb_verify_cjk', '验证测试', 'A',
          '这部电影让我非常难过但也很感动');

  -- Substring search on a character embedded mid-string (not at a token boundary).
  select count(*) as hits
  from search_journal_entries('难过', '<OWNER>')
  where tmdb_id = 'tmdb_verify_cjk';
  -- EXPECT: hits >= 1  (pre-migration this was 0 — English tsvector cannot
  --         segment CJK; the ILIKE '%难过%' branch now matches)
rollback;
```

## (3) Partial-word 'matri' matches 'The Matrix' title — expect ≥ 1

Fuzzy/partial-word English via the title trigram-ILIKE branch. tsvector matches
whole lexemes only, so 'matri' would miss; ILIKE '%matri%' hits the title.

```sql
begin;
  insert into journal_entries (user_id, tmdb_id, title, rating_tier, review_text)
  values ('<OWNER>', 'tmdb_verify_matrix', 'The Matrix', 'S',
          'Red pill or blue pill.');

  select count(*) as hits
  from search_journal_entries('matri', '<OWNER>')
  where tmdb_id = 'tmdb_verify_matrix';
  -- EXPECT: hits >= 1  (partial-word 'matri' matches the title via ILIKE)
rollback;
```

## (4) Takeaway-only text does NOT match — expect 0 (TAKEAWAY-EXCLUSION INVARIANT)

The one way this migration could regress C2's B5 leak. Insert a fixture where a
unique term appears ONLY in `personal_takeaway` (never in title/review_text), then
search it. The trigram branches touch only title/review_text; the tsvector excludes
takeaway; the return has no takeaway column — so the term is unmatchable.

```sql
begin;
  insert into journal_entries (user_id, tmdb_id, title, rating_tier, review_text,
                               personal_takeaway)
  values ('<OWNER>', 'tmdb_verify_takeaway', 'Neutral Title', 'B',
          'A neutral review body.',
          'zzqxsecretzz only-in-takeaway marker text');

  select count(*) as hits
  from search_journal_entries('zzqxsecretzz', '<OWNER>');
  -- EXPECT: hits = 0  (takeaway is NEVER matchable — trigram/ILIKE/tsvector all
  --         exclude personal_takeaway; anything else recreates the B5 leak)
rollback;
```

## (5) Return columns unchanged — expect 23, none named personal_takeaway/search_vector

The wire contract is frozen. Assert the function still returns exactly the 23-column
table with the same names/types and no `personal_takeaway` / `search_vector`.

```sql
select count(*) as col_count
from information_schema.columns c
join information_schema.routines r
  on r.specific_name = c.table_name  -- not used; see the pg_get_function_result path below
where false;
```

Preferred (robust) form — read the declared OUT columns straight from the RPC's
result signature:

```sql
-- Column count (EXPECT: 23) and the ordered name/type list.
select pg_get_function_result(
  'search_journal_entries(text, uuid)'::regprocedure
) as result_signature;
-- EXPECT: a TABLE(...) with exactly 23 columns, in order:
--   id uuid, user_id uuid, tmdb_id text, title text, poster_url text,
--   rating_tier text, review_text text, contains_spoilers boolean,
--   mood_tags text[], vibe_tags text[], favorite_moments text[],
--   standout_performances jsonb, watched_date date, watched_location text,
--   watched_with_user_ids uuid[], watched_platform text, is_rewatch boolean,
--   rewatch_note text, photo_paths text[], visibility_override text,
--   like_count integer, created_at timestamp with time zone,
--   updated_at timestamp with time zone
-- EXPECT: NO column named personal_takeaway, NO column named search_vector.
```

Cross-check the count numerically:

```sql
select (length(sig) - length(replace(sig, ',', ''))) + 1 as col_count
from (
  select pg_get_function_result(
    'search_journal_entries(text, uuid)'::regprocedure
  ) as sig
) s;
-- EXPECT: col_count = 23
```

## (6) Stranger-visibility RLS probe unchanged — expect 0 rows for a stranger

RLS still does the row filtering under SECURITY INVOKER. A stranger searching
`<OWNER>`'s PRIVATE entry must get zero rows even if the search term matches the
text — the function re-implements no visibility; the base-table RLS predicate is
appended by the planner. Substitute `<STRANGER>`, `<OWNER>`, and a term known to
appear in the private entry's title/review_text.

```sql
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<STRANGER>"}';

  -- Search <OWNER>'s journal as the stranger. A matching term in a PRIVATE
  -- (non-visible) entry must NOT surface.
  select count(*) as hits
  from search_journal_entries('<TERM_IN_PRIVATE_ENTRY>', '<OWNER>');
  -- EXPECT: hits = 0 for the private entry (RLS filters it out for a stranger);
  --         this is identical to the pre-migration behavior — matching improved,
  --         visibility did not change.
rollback;
```

Optional positive control — the same term as the OWNER returns the row (matching
works; only RLS differs between the two roles):

```sql
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<OWNER>"}';

  select count(*) as hits
  from search_journal_entries('<TERM_IN_PRIVATE_ENTRY>', '<OWNER>');
  -- EXPECT: hits >= 1  (owner sees own private entry; confirms probe (6)'s 0 is
  --         RLS filtering, not a broken query)
rollback;
```

---

## Pass criteria

| Probe | Expect |
|---|---|
| (1) EN word via tsvector | `hits >= 1` (English full-text path untouched) |
| (2) CJK substring in review_text | `hits >= 1` (pre-migration `0`; ILIKE trigram branch) |
| (3) partial-word 'matri' -> 'The Matrix' | `hits >= 1` (title ILIKE branch) |
| (4) takeaway-only term | `hits = 0` (TAKEAWAY-EXCLUSION invariant — no B5 leak) |
| (5) RPC result signature | 23 columns, order/types unchanged, no `personal_takeaway` / `search_vector` |
| (6) stranger searches OWNER's private entry | `hits = 0` (RLS filters; positive control returns the row for the owner) |
