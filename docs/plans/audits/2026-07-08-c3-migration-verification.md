# C3 migration verification probes (B3a + B4)

Run by the controller against prod (project `emulyralduiitxuigboj`) in the SQL editor
(superuser/`postgres` session, which may `SET ROLE authenticated`), AFTER applying:

1. `supabase/migrations/20260708_c3_watchlist_update_policy.sql` (B3a — watchlist UPDATE policy)
2. `supabase/migrations/20260708_c3_drop_taste_recompute.sql`   (B4 — drop dead taste-recompute trigger + functions; tables PARKED)

Runbook order between the two does not matter — they touch disjoint objects.

Every write probe is wrapped in `begin; … rollback;` — nothing persists, including
the UPDATE and upsert probes. Probes (c)/(d) capture the post-drop state; if you can
run them BEFORE applying migration 2, they double as the pre-fix baseline (trigger
count = 1, taste-profile count grows).

---

## 0. Fixture discovery (run as-is, no role switch — RLS bypassed)

Pick real UUIDs and substitute them into the probes below.

```sql
-- OWNER: a real user who has at least one watchlist_items row (for probe (b))
-- and at least one user_rankings row (for probe (d)).
select w.user_id as owner_id, count(distinct w.id) as watchlist_rows
from watchlist_items w
group by w.user_id
order by watchlist_rows desc
limit 5;

-- WATCHLIST_ROW: one owned watchlist_items row to UPDATE in probe (b).
-- Substitute <OWNER> from above.
select id as watchlist_row_id, tmdb_id, title, poster_url
from watchlist_items
where user_id = '<OWNER>'
limit 1;
```

---

## (a) watchlist_items now has exactly one UPDATE policy — expect `1`

```sql
select count(*)
from pg_policies
where schemaname = 'public'
  and tablename = 'watchlist_items'
  and cmd = 'UPDATE';
-- EXPECT: 1
```

Optional detail check — confirm it is the owner policy by name/clauses:

```sql
select policyname, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename = 'watchlist_items'
  and cmd = 'UPDATE';
-- EXPECT: policyname = 'Users can update own watchlist'
--         qual       = (auth.uid() = user_id)
--         with_check = (auth.uid() = user_id)
```

## (b) An authenticated owner UPDATE on their own watchlist row succeeds

Substitute `<OWNER>` and `<WATCHLIST_ROW_ID>` from the fixtures. The `begin/rollback`
discards the write; the point is that no RLS denial is raised.

```sql
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<OWNER>"}';

  update watchlist_items
     set poster_url = poster_url  -- no-op value change; only the UPDATE path matters
   where id = '<WATCHLIST_ROW_ID>'
     and user_id = '<OWNER>';

  -- EXPECT: UPDATE 1  (before the policy existed this raised
  --         "new row violates row-level security policy" / affected 0 rows)
rollback;
```

## (c) No taste-recompute trigger remains on user_rankings — expect `0`

```sql
select count(*)
from pg_trigger
where tgrelid = 'user_rankings'::regclass
  and tgname like '%taste%';
-- EXPECT: 0   (pre-fix baseline was 1 — trg_recompute_taste)
```

Optional — confirm the two functions are gone as well:

```sql
select count(*)
from pg_proc
where proname in ('trigger_recompute_taste', 'recompute_taste_profile');
-- EXPECT: 0
```

## (d) A user_rankings upsert no longer grows user_taste_profiles (count stable)

With the trigger dropped, writing a ranking must NOT recompute/insert a taste
profile. Substitute `<OWNER>`. The whole probe is rolled back.

```sql
begin;
  -- BEFORE count
  select count(*) as before_count from user_taste_profiles;

  -- Simulate a ranking write (runs as superuser; the trigger, if present,
  -- would have fired on this INSERT). Use an id unlikely to collide; the
  -- unique key is (user_id, tmdb_id).
  insert into user_rankings (user_id, tmdb_id, tier, rank_position, title, year)
  values ('<OWNER>', 'tmdb_999999999', 'S', 999, 'VERIFY PROBE', 2026)
  on conflict (user_id, tmdb_id) do update set tier = excluded.tier;

  -- AFTER count — must equal before_count (trigger gone → no profile written)
  select count(*) as after_count from user_taste_profiles;
  -- EXPECT: after_count = before_count
  --         (pre-fix: after_count = before_count + 1 for a new-profile user,
  --          or the existing row's updated_at would bump)
rollback;
```

> If `user_rankings` has additional NOT NULL columns beyond those listed, add them
> to the INSERT with any valid placeholder — the probe only needs the write to
> execute so the (now-absent) trigger would have fired.

## (e) Parked tables still EXIST (not dropped) — expect both present

```sql
select table_name
from information_schema.tables
where table_schema = 'public'
  and table_name in ('user_taste_profiles', 'movie_credits_cache')
order by table_name;
-- EXPECT: two rows — movie_credits_cache, user_taste_profiles
--         (Q1 owner decision: trigger+functions dropped, tables PARKED)
```

---

## Pass criteria

| Probe | Expect |
|---|---|
| (a) UPDATE policy count on `watchlist_items` | `1` (named `Users can update own watchlist`) |
| (b) owner UPDATE under authenticated JWT | succeeds (`UPDATE 1`, no RLS denial) |
| (c) `%taste%` triggers on `user_rankings` | `0` |
| (c-opt) `trigger_recompute_taste` + `recompute_taste_profile` in `pg_proc` | `0` |
| (d) `user_taste_profiles` count around a `user_rankings` upsert | stable (before = after) |
| (e) `user_taste_profiles` + `movie_credits_cache` tables | both still exist (parked) |
