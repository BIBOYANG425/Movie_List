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
-- ── Ordering key: boosted_ts ────────────────────────────────────────────────
--
--   boosted_ts = case
--     when event_type = 'review'
--      and created_at > session_ts - interval '2 hours'
--     then created_at + interval '2 hours'
--     else created_at
--   end
--
-- i.e. reviews younger than 2 hours (relative to the pagination session's
-- frozen reference time) float above up-to-2h-newer cards; everything else
-- sorts by plain recency.
--
-- Provenance note: the plan defers to "audit §2b" for this expression, but
-- the audit file contains no §2b. The expression above is reconstructed from
-- the two sketches that DO exist, per the plan's intent:
--   * audit B4 fix design: additive form
--     `sort_ts = created_at + interval '2 hours' * (event_type='review')::int`
--   * plan Task 3 sketch region: the 2-hour window condition
--     `... and created_at > now() - interval '2 hours' ...`
-- The additive-inside-a-window form is chosen over the plan sketch's
-- `greatest(created_at, ... then now() end)` form because greatest() would
-- collapse every in-window review onto the same key (session_ts), reducing
-- their relative order to uuid order; the additive form preserves recency
-- order among boosted reviews, matching the client's old applyReviewBoost
-- within the window.
--
-- Known, intended divergence from the old client sort: applyReviewBoost
-- boosted reviews of ANY age by +2h; here a review older than 2h loses the
-- boost and sorts by plain created_at. This is required for keyset stability
-- and is pinned by services/__tests__/feedPagination.test.ts (a review at
-- 2h01m must NOT outrank a ranking_add at 30m).
--
-- ── session_ts: the boost freeze ────────────────────────────────────────────
--
-- boosted_ts must be IMMUTABLE for the duration of a pagination session: if
-- the window were evaluated against a live now(), a review crossing the 2h
-- boundary between page N and page N+1 would drop ~2h down the ordering —
-- rows behind the cursor reappear (duplicates) and rows ahead of it fall
-- behind (skips), the exact bug class B4 describes. The caller therefore
-- passes the FIRST page's timestamp as session_ts and reuses it verbatim for
-- every subsequent page of that session. A fresh session (page 1) starts a
-- fresh session_ts. session_ts is required (no default): the client must
-- know the exact value to recompute boosted_ts for the last row of each page
-- when building the cursor (the function returns plain activity_events rows,
-- which do not carry boosted_ts). The TS mirror of this expression lives in
-- services/feedService.ts (computeBoostedTs), pinned by
-- services/__tests__/feedPagination.test.ts.
--
-- ── Cursor contract ─────────────────────────────────────────────────────────
--
-- First page: cursor_rank and cursor_id both NULL.
-- Next pages: cursor_rank/cursor_id = boosted_ts/id of the last card the
-- client consumed; the keyset predicate (boosted_ts, id) < (cursor_rank,
-- cursor_id) resumes strictly after it. Passing exactly one of the pair is a
-- malformed cursor and raises.
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
-- Performance note: boosted_ts is a per-call expression (it depends on
-- session_ts), so no index can serve the ORDER BY — each page sorts the
-- RLS-visible row set. Fine at MVP scale; if activity_events grows large,
-- revisit with a "recent boosted reviews UNION rest by created_at" split
-- that can use an index on (created_at desc, id desc).
--
-- Rollback: drop function public.get_feed_page(text, timestamptz, uuid, int, timestamptz);

create or replace function public.get_feed_page(
  mode text,
  cursor_rank timestamptz,
  cursor_id uuid,
  page_size int,
  session_ts timestamptz
)
returns setof public.activity_events
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

  if session_ts is null then
    raise exception 'get_feed_page: session_ts is required — pass the first page''s timestamp and reuse it for every page of the session'
      using errcode = '22004';
  end if;

  if (cursor_rank is null) <> (cursor_id is null) then
    raise exception 'get_feed_page: cursor_rank and cursor_id must be passed together (both NULL = first page)'
      using errcode = '22023';
  end if;

  if page_size is null or page_size < 1 or page_size > 100 then
    raise exception 'get_feed_page: page_size must be between 1 and 100, got %', coalesce(page_size::text, 'NULL')
      using errcode = '22023';
  end if;

  return query
  select e.*
  from public.activity_events e
  cross join lateral (
    select case
             when e.event_type = 'review'
              and e.created_at > session_ts - interval '2 hours'
             then e.created_at + interval '2 hours'
             else e.created_at
           end as boosted_ts
  ) b
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
    and (cursor_rank is null or (b.boosted_ts, e.id) < (cursor_rank, cursor_id))
  order by b.boosted_ts desc, e.id desc
  limit page_size;
end;
$$;

grant execute on function public.get_feed_page(text, timestamptz, uuid, int, timestamptz) to authenticated;
