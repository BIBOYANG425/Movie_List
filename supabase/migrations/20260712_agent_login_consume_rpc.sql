-- Agent-initiated web login: consume-token RPC (P4 / Slice B2).
--
-- Companion to 20260712_agent_link_rpcs.sql. That migration mints the 6-char
-- code for the APP-initiated handshake (user already signed in on iOS). THIS one
-- serves the AGENT-initiated direction: Chris texts an UNLINKED user a rich link
-- carrying a single-use login token; the user signs in on the web, and the
-- agent-link edge function calls this RPC under their fresh JWT to redeem it.
--
-- The token lives in hana.login_links, a table the AGENT owns and creates in its
-- plugin onInit (spool-agent) — the hana schema is agent-managed, so we do NOT
-- create it here:
--   login_links:
--     token       text        primary key
--     phone       text        not null      (E.164 sender the token was minted for)
--     created_at  timestamptz default now()
--     expires_at  timestamptz not null      (created_at + ~15 min, agent-side)
--     consumed_at timestamptz               (null until this RPC redeems it)
--
-- Same shape/discipline as the code RPCs: SECURITY DEFINER into hana, hana NOT
-- exposed to PostgREST, anon EXECUTE revoked, runs as auth.uid() via the caller's
-- forwarded JWT. The bind matches the agent's verifyAndConsumeCode transaction
-- verbatim: UPSERT agent_links on the phone PK (re-bind to the new user on
-- conflict), then mark the token consumed — atomic within the function body.
--
-- The edge function tolerates hana.login_links not existing yet (the agent's
-- deploy creates it): a relation-not-found (undefined_table) inside this function
-- is caught and mapped to the same opaque 'expired' status as an unknown/stale
-- token, so the web surface never leaks which reason applied.
--
-- Returns a single status text row:
--   'expired'        → unknown token, past expires_at, already consumed, or the
--                      table not existing yet (one shape for all — no leak).
--   'linked'         → freshly bound phone -> auth.uid(); token marked consumed.
--   'already_linked' → that phone was already linked to THIS user; token still
--                      marked consumed (idempotent re-tap).

create or replace function public.consume_agent_login_token(p_token text)
returns table (status text)
language plpgsql
security definer
set search_path = public, hana
as $$
declare
  v_uid uuid := auth.uid();
  v_phone text;
  v_expires timestamptz;
  v_consumed timestamptz;
  v_existing_user uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  -- Lock the token row against a concurrent double-tap (mirrors the agent's
  -- FOR UPDATE consume transaction). Unknown token -> 'expired'.
  select ll.phone, ll.expires_at, ll.consumed_at
    into v_phone, v_expires, v_consumed
  from hana.login_links ll
  where ll.token = p_token
  for update;

  if not found then
    status := 'expired';
    return next;
    return;
  end if;

  -- Consumed or past TTL -> 'expired' (same opaque shape, no leak of which).
  if v_consumed is not null or v_expires < now() then
    status := 'expired';
    return next;
    return;
  end if;

  -- Is this phone already bound? If to THIS user, it's an idempotent re-tap; if
  -- to a DIFFERENT user, re-bind to the caller (the texter's phone is the source
  -- of truth) — EXACTLY the agent's ON CONFLICT (phone) DO UPDATE semantics.
  select al.user_id into v_existing_user
  from hana.agent_links al
  where al.phone = v_phone;

  insert into hana.agent_links (phone, user_id, linked_at)
  values (v_phone, v_uid, now())
  on conflict (phone) do update
    set user_id = excluded.user_id, linked_at = now();

  update hana.login_links
    set consumed_at = now()
  where token = p_token;

  if v_existing_user is not null and v_existing_user = v_uid then
    status := 'already_linked';
  else
    status := 'linked';
  end if;
  return next;
  return;

exception
  -- The agent deploy creates hana.login_links; before that, the relation is
  -- undefined. Treat that (and a missing hana schema) as an ordinary stale link.
  when undefined_table or invalid_schema_name then
    status := 'expired';
    return next;
    return;
end
$$;

revoke execute on function public.consume_agent_login_token(text) from public, anon;
grant execute on function public.consume_agent_login_token(text) to authenticated;

-- ROLLBACK (verbatim):
--   drop function if exists public.consume_agent_login_token(text);
