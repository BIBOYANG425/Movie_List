# C3-iOS verification probes — movie watchlist follower SELECT (Part A, Task 1)

Run by the controller against prod (project `emulyralduiitxuigboj`) in the SQL
editor (superuser/`postgres` session, which may `SET LOCAL ROLE authenticated`),
AFTER applying:

1. `supabase/migrations/20260709_c3_movie_watchlist_follower_select.sql` (drops
   the movie owner-only combined SELECT policy and recreates the tv/book
   two-policy shape: owner SELECT + follower SELECT — Q2 adjudication).

Owner adjudication (Q2, 2026-07-09): the movie watchlist becomes
FOLLOWER-VISIBLE, aligning `watchlist_items` with `tv_watchlist_items` /
`book_watchlist_items`. This unblocks the iOS Twin exclusion (TasteRepository
reads a friend's movie watchlist) and closes the three-table RLS asymmetry.

Every probe below is a READ (or a write that must be RLS-denied), and each is
wrapped in `begin; … rollback;` — nothing persists. Each probe sets
`local role authenticated` + a `request.jwt.claims` sub so RLS runs under the
caller's identity, exactly as the app calls it. The write probes (4) additionally
seed a followee row inside the transaction so the denial is observable on a real
target row; all of it rolls back.

---

## 0. Fixture discovery (run as-is, no role switch — RLS bypassed)

Pick real UUIDs and substitute them into the probes below. We need a real
**follower pair** (FOLLOWER follows FOLLOWEE) where FOLLOWEE has at least one
`watchlist_items` row, plus a NON-follower for the negative probe.

```sql
-- FOLLOWER pair with a non-empty followee movie watchlist.
-- Returns (follower_id, following_id) where following_id owns >= 1 watchlist row.
select f.follower_id, f.following_id, count(w.id) as followee_watchlist_rows
from friend_follows f
join watchlist_items w on w.user_id = f.following_id
group by f.follower_id, f.following_id
order by followee_watchlist_rows desc
limit 5;
-- Pick a row: FOLLOWER := follower_id, FOLLOWEE := following_id.

-- NON-FOLLOWER: a real user who does NOT follow FOLLOWEE (and is not FOLLOWEE).
select p.id as non_follower
from profiles p
where p.id <> '<FOLLOWEE>'
  and not exists (
    select 1 from friend_follows f
    where f.follower_id = p.id and f.following_id = '<FOLLOWEE>'
  )
limit 1;

-- Sanity: how many rows FOLLOWEE actually has (the expected count for probes 1 & 2).
select count(*) as followee_row_count
from watchlist_items
where user_id = '<FOLLOWEE>';
```

Substitute `<FOLLOWER>`, `<FOLLOWEE>`, `<NON_FOLLOWER>`, and
`<FOLLOWEE_ROW_COUNT>` (the count above) into the probes below.

---

## Probe 1 — owner reads own rows (unchanged behavior)

The owner SELECT policy is recreated verbatim, so FOLLOWEE still sees their own
watchlist in full.

```sql
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<FOLLOWEE>"}';

  select count(*) as own_rows
  from watchlist_items
  where user_id = '<FOLLOWEE>';
  -- EXPECT: <FOLLOWEE_ROW_COUNT>  (owner sees all of their own rows — unchanged)
rollback;
```

## Probe 2 — follower reads followee's movie watchlist rows (the Q2 unlock)

Under the new follower SELECT policy, FOLLOWER (who follows FOLLOWEE) can now
read FOLLOWEE's movie watchlist. This is the row previously returned 0 — the
Twin-exclusion blocker.

```sql
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<FOLLOWER>"}';

  select count(*) as followee_rows_visible
  from watchlist_items
  where user_id = '<FOLLOWEE>';
  -- EXPECT: <FOLLOWEE_ROW_COUNT>  (> 0 — follower now sees followee rows).
  -- BEFORE this migration this returned 0. Non-zero == Q2 unlock confirmed.
rollback;
```

## Probe 3 — non-follower gets 0 rows (no over-broadening)

A user who does NOT follow FOLLOWEE must still see none of FOLLOWEE's rows. The
policy only opens the read to actual followers.

```sql
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<NON_FOLLOWER>"}';

  select count(*) as leaked_rows
  from watchlist_items
  where user_id = '<FOLLOWEE>';
  -- EXPECT: 0  (non-follower sees nothing; follower-gate holds).
rollback;
```

## Probe 4 — follower cannot INSERT / UPDATE / DELETE followee rows (read-only)

The migration touches only SELECT. FOLLOWER can READ but must NOT write
FOLLOWEE's watchlist: INSERT is WITH-CHECK-denied, UPDATE/DELETE match 0 rows
under the owner-only write policies.

```sql
-- 4a. INSERT another user's row -> RLS WITH CHECK violation.
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<FOLLOWER>"}';

  insert into watchlist_items (user_id, tmdb_id, title, type)
  values ('<FOLLOWEE>', 'c3_probe_insert', 'Probe Insert', 'movie');
  -- EXPECT: ERROR — new row violates row-level security policy for table
  --         "watchlist_items" (SQLSTATE 42501). Owner INSERT policy requires
  --         auth.uid() = user_id, and FOLLOWER != FOLLOWEE.
rollback;

-- 4b. UPDATE a followee row -> 0 rows affected (owner-only UPDATE policy).
-- Seed a real followee row inside the txn so there IS a target to (not) update.
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<FOLLOWEE>"}';   -- FOLLOWEE seeds it
  insert into watchlist_items (user_id, tmdb_id, title, type)
  values ('<FOLLOWEE>', 'c3_probe_upd', 'Probe Upd', 'movie');
  reset role;                                                -- back to superuser

  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<FOLLOWER>"}';   -- FOLLOWER attempts write
  with upd as (
    update watchlist_items
       set title = 'HIJACKED'
     where user_id = '<FOLLOWEE>' and tmdb_id = 'c3_probe_upd'
    returning 1
  )
  select count(*) as rows_updated from upd;
  -- EXPECT: 0  (owner UPDATE policy: USING auth.uid() = user_id filters the row
  --             out; follower's UPDATE matches nothing — no error, no change).
rollback;

-- 4c. DELETE a followee row -> 0 rows affected (owner-only DELETE policy).
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<FOLLOWEE>"}';   -- FOLLOWEE seeds it
  insert into watchlist_items (user_id, tmdb_id, title, type)
  values ('<FOLLOWEE>', 'c3_probe_del', 'Probe Del', 'movie');
  reset role;

  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<FOLLOWER>"}';   -- FOLLOWER attempts delete
  with del as (
    delete from watchlist_items
     where user_id = '<FOLLOWEE>' and tmdb_id = 'c3_probe_del'
    returning 1
  )
  select count(*) as rows_deleted from del;
  -- EXPECT: 0  (owner DELETE policy filters the row out; follower deletes nothing).
rollback;
```

## Probe 5 — post-apply policy inventory (names + count)

Confirm the final policy set on `watchlist_items`: exactly two SELECT policies
(own + followed), plus the untouched owner INSERT / UPDATE / DELETE.

```sql
select policyname, cmd, qual, with_check
from pg_policies
where schemaname = 'public' and tablename = 'watchlist_items'
order by cmd, policyname;
-- EXPECT exactly these five policies (cmd / policyname):
--   SELECT | "Users can view followed users watchlist"   (qual: EXISTS friend_follows join)
--   SELECT | "Users can view own watchlist"              (qual: auth.uid() = user_id)
--   INSERT | "Users can insert own watchlist"            (with_check: auth.uid() = user_id)
--   UPDATE | "Users can update own watchlist"            (qual + with_check: auth.uid() = user_id)
--   DELETE | "Users can delete own watchlist"            (qual: auth.uid() = user_id)
-- No "Users can view own watchlist" for any cmd other than SELECT; INSERT/UPDATE/
-- DELETE names/clauses must be byte-for-byte what they were pre-migration.

-- Count assertion for the ledger:
select count(*) as policy_count
from pg_policies
where schemaname = 'public' and tablename = 'watchlist_items';
-- EXPECT: 5  (was 4 pre-migration; +1 from the new follower SELECT).
```

---

## Pass criteria

| Probe | Expect |
|---|---|
| 1 owner reads own rows | `own_rows` == `<FOLLOWEE_ROW_COUNT>` (unchanged) |
| 2 follower reads followee rows | `followee_rows_visible` == `<FOLLOWEE_ROW_COUNT>` (> 0; was 0 before) |
| 3 non-follower | `leaked_rows` == `0` |
| 4a follower INSERT | ERROR SQLSTATE `42501` (RLS WITH CHECK) |
| 4b follower UPDATE | `rows_updated` == `0` (owner-only UPDATE) |
| 4c follower DELETE | `rows_deleted` == `0` (owner-only DELETE) |
| 5 policy inventory | 5 policies; two SELECT (own + followed), owner INSERT/UPDATE/DELETE intact |
