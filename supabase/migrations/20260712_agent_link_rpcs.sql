-- Agent-linking RPCs (iMessage companion P1 — spool-agent handshake).
--
-- The agent owns hana.link_codes / hana.agent_links (created by its plugin;
-- shapes are the contract in spool-agent packages/plugins/spool/src/schema.ts).
-- The hana schema is NOT exposed to PostgREST, so the app mints codes through
-- these SECURITY DEFINER primitives in public. No client ever writes hana
-- directly; anon EXECUTE revoked everywhere.
--
-- mint_agent_link_code(): 6-char single-use code (unambiguous alphabet, no
--   0/O/1/I), 15-min TTL, for auth.uid(). Rate-limited to 5 live codes/user.
--   Cryptographic randomness via pgcrypto gen_random_bytes (extensions schema).
-- unlink_agent(): removes the caller's phone bindings + live codes.
-- get_agent_link_status(): the caller's current bindings (for the Settings UI).

create or replace function public.mint_agent_link_code()
returns table (code text, expires_at timestamptz)
language plpgsql
security definer
set search_path = public, hana, extensions
as $$
declare
  v_code text;
  v_expires timestamptz := now() + interval '15 minutes';
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; -- 32 chars, unambiguous
  live_count int;
  bytes bytea;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  select count(*) into live_count
  from hana.link_codes lc
  where lc.user_id = auth.uid()
    and lc.used_at is null
    and lc.expires_at > now();
  if live_count >= 5 then
    raise exception 'too many active link codes — use an existing one or wait for expiry';
  end if;

  loop
    bytes := extensions.gen_random_bytes(6);
    v_code := '';
    for i in 1..6 loop
      v_code := v_code || substr(alphabet, 1 + (get_byte(bytes, i - 1) % 32), 1);
    end loop;
    begin
      insert into hana.link_codes (code, user_id, expires_at)
      values (v_code, auth.uid(), v_expires);
      exit;
    exception when unique_violation then
      -- 1-in-a-billion collision: regenerate
    end;
  end loop;

  return query select v_code, v_expires;
end
$$;

revoke execute on function public.mint_agent_link_code() from public, anon;
grant execute on function public.mint_agent_link_code() to authenticated;

create or replace function public.unlink_agent()
returns void
language plpgsql
security definer
set search_path = public, hana
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  delete from hana.agent_links where user_id = auth.uid();
  delete from hana.link_codes where user_id = auth.uid() and used_at is null;
end
$$;

revoke execute on function public.unlink_agent() from public, anon;
grant execute on function public.unlink_agent() to authenticated;

create or replace function public.get_agent_link_status()
returns table (phone text, linked_at timestamptz)
language sql
security definer
set search_path = hana
as $$
  select phone, linked_at from hana.agent_links where user_id = auth.uid();
$$;

revoke execute on function public.get_agent_link_status() from public, anon;
grant execute on function public.get_agent_link_status() to authenticated;

-- ROLLBACK (verbatim):
--   drop function if exists public.mint_agent_link_code();
--   drop function if exists public.unlink_agent();
--   drop function if exists public.get_agent_link_status();
