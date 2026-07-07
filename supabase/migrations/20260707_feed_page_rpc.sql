-- 20260707_feed_page_rpc.sql
--
-- get_feed_page: keyset-paginated feed reads for the social feed.
-- Fixes audit finding B4 (docs/plans/audits/2026-07-07-c1-feed-web-audit.md):
-- the client paged with offset + a growing over-fetch window
-- (fetchLimit = limit + offset + 20) and re-sorted client-side, causing
-- duplicated cards, skipped cards, premature feed end, and O(n²) refetch.
-- This RPC pages with a stable keyset cursor over the boost-aware ordering
-- key, so each page is one bounded query and pages never overlap or gap.
--
-- Adjudicated decision Q3 (controller, 2026-07-07, do not relitigate): the
-- 2-hour review boost is KEPT, implemented as an expression keyset here.
--
-- ── Ordering key: boosted_ts (WINDOWLESS) ───────────────────────────────────
--
--   boosted_ts = created_at + interval '2 hours' * (event_type = 'review')::int
--
-- i.e. every review row sorts as created_at + 2h, permanently — reviews float
-- above up-to-2h-newer cards at any age. This matches the legacy client's
-- applyReviewBoost EXACTLY (plan-owner decision, 2026-07-07 review): the old
-- code boosted reviews unconditionally, with no window and no fetch-time
-- anchor, so visible ordering is preserved bit-for-bit. An earlier revision
-- of this migration used a 2h WINDOW anchored to a per-session timestamp
-- (session_ts parameter); the window came from a plan-authoring error in the
-- Task 3 test pins and was removed. (The plan's cited "audit §2b" sketch does
-- not exist in the audit file; the authoritative sketch is audit B4's
-- additive form, used verbatim above.)
--
-- Because boosted_ts is a pure function of the row (no now(), no session
-- anchor), the ordering is deterministic forever: no per-session freeze
-- parameter is needed, cursors never expire, and an expression index can
-- serve the ORDER BY (see index note below).
--
-- ── Cursor contract ─────────────────────────────────────────────────────────
--
-- First page: cursor_rank and cursor_id both NULL.
-- Next pages: cursor_rank/cursor_id = boosted_ts/id of the last card the
-- client consumed; the keyset predicate (boosted_ts, id) < (cursor_rank,
-- cursor_id) resumes strictly after it. Passing exactly one of the pair is a
-- malformed cursor and raises.
--
-- The function returns boosted_ts AS A COLUMN alongside the event row, so
-- the client builds the next cursor from the server-computed value verbatim
-- (byte-exact, Postgres µs precision preserved) and NEVER recomputes the
-- ordering key — eliminating the ms/µs precision mismatch class entirely.
-- The TS side (services/feedService.ts cursorFromFeedRow) just copies
-- (boosted_ts, id) off the last consumed row.
--
-- ── Modes ───────────────────────────────────────────────────────────────────
--
-- 'friends': adds the follower EXISTS clause (same shape as the follower
--   branch of the Task 2 policy in 20260707_explore_visibility_rls.sql).
--   The viewer's own rows are excluded because nobody follows themselves —
--   adjudicated Q1: the friends tab excludes self.
-- 'explore': no extra clause. The function is SECURITY INVOKER, so the
--   activity_events SELECT policy rewritten by Task 2 (own OR followed OR
--   public-profile actors, public branch limited to
--   ranking_add/review/list_create/milestone) scopes the rows transitively.
-- Anything else raises (loud rejection, no silent empty page).
--
-- Event-type / tier / time-range filters, mutes, and the milestone throttle
-- intentionally stay CLIENT-side (audit B4 fix design): the client must see
-- every raw row to advance the cursor deterministically, and it refills
-- short pages by fetching the next raw page with the advanced cursor.
--
-- ── Index / IMMUTABLE note ──────────────────────────────────────────────────
--
-- The ORDER BY is index-serveable, but NOT by indexing the raw expression:
-- `timestamptz + interval` (timestamptz_pl_interval) is marked STABLE in the
-- catalog — its result can depend on the TimeZone GUC when the interval has
-- day/month components — so
--   create index on activity_events
--     ((created_at + interval '2 hours' * (event_type = 'review')::int) desc, id desc)
-- fails with "functions in index expression must be marked IMMUTABLE".
-- Wrapping the same arithmetic in a CASE does not help (the STABLE operator
-- is still inside either branch). The fix is the feed_boosted_ts wrapper
-- below, declared IMMUTABLE — a sound assertion for THIS expression because
-- a pure hours-only interval is an exact 7200-second instant shift,
-- independent of timezone/DST (only day/month interval components are
-- timezone-sensitive). The RPC's predicate and ORDER BY call the same
-- wrapper so the planner can match the index.
--
-- Rollback:
--   drop function public.get_feed_page(text, timestamptz, uuid, int);
--   drop index public.idx_activity_events_boosted_ts_id;
--   drop function public.feed_boosted_ts(text, timestamptz);

-- Defensive: an earlier (never-applied) revision of this migration declared a
-- 5-parameter signature with session_ts; drop it if it ever landed so the
-- 4-parameter function below cannot end up as an ambiguous overload.
drop function if exists public.get_feed_page(text, timestamptz, uuid, int, timestamptz);

-- The boosted ordering key as an IMMUTABLE function, so an expression index
-- can serve the keyset ORDER BY (see header note on why the raw expression
-- cannot be indexed directly).
create or replace function public.feed_boosted_ts(event_type text, created_at timestamptz)
returns timestamptz
language sql
immutable
as $$
  select created_at + interval '2 hours' * (event_type = 'review')::int
$$;

grant execute on function public.feed_boosted_ts(text, timestamptz) to authenticated;

create index if not exists idx_activity_events_boosted_ts_id
  on public.activity_events (public.feed_boosted_ts(event_type, created_at) desc, id desc);

create or replace function public.get_feed_page(
  mode text,
  cursor_rank timestamptz,
  cursor_id uuid,
  page_size int
)
returns table (
  id uuid,
  actor_id uuid,
  event_type text,
  target_user_id uuid,
  media_tmdb_id text,
  media_title text,
  media_tier text,
  media_poster_url text,
  metadata jsonb,
  created_at timestamptz,
  boosted_ts timestamptz
)
language plpgsql
stable
security invoker
set search_path = public
as $$
begin
  if mode is null or mode not in ('friends', 'explore') then
    raise exception 'get_feed_page: unknown mode % (expected ''friends'' or ''explore'')', coalesce(quote_literal(mode), 'NULL')
      using errcode = '22023';
  end if;

  if (cursor_rank is null) <> (cursor_id is null) then
    raise exception 'get_feed_page: cursor_rank and cursor_id must be passed together (both NULL = first page)'
      using errcode = '22023';
  end if;

  if page_size is null or page_size < 1 or page_size > 100 then
    raise exception 'get_feed_page: page_size must be between 1 and 100, got %', coalesce(page_size::text, 'NULL')
      using errcode = '22023';
  end if;

  -- All row references below are table-qualified: the RETURNS TABLE column
  -- names (id, event_type, ...) are plpgsql OUT variables, and unqualified
  -- use inside the query would be ambiguous.
  return query
  select
    e.id,
    e.actor_id,
    e.event_type,
    e.target_user_id,
    e.media_tmdb_id,
    e.media_title,
    e.media_tier,
    e.media_poster_url,
    e.metadata,
    e.created_at,
    public.feed_boosted_ts(e.event_type, e.created_at) as boosted_ts
  from public.activity_events e
  where
    (
      mode = 'explore'
      -- explore: no extra predicate — the SECURITY INVOKER SELECT policy on
      -- activity_events (Task 2) already scopes rows to own / followed /
      -- public-profile actors.
      or exists (
        -- friends: follower branch, same shape as the Task 2 policy.
        select 1
        from public.friend_follows
        where public.friend_follows.follower_id = auth.uid()
          and public.friend_follows.following_id = e.actor_id
      )
    )
    and (cursor_rank is null
         or (public.feed_boosted_ts(e.event_type, e.created_at), e.id) < (cursor_rank, cursor_id))
  order by public.feed_boosted_ts(e.event_type, e.created_at) desc, e.id desc
  limit page_size;
end;
$$;

grant execute on function public.get_feed_page(text, timestamptz, uuid, int) to authenticated;
