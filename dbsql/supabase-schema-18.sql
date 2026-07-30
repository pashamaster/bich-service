-- ═══════════════════════════════════════════════════════════════════
-- bich.service — schema part 18
--
--   1. the display name gets a way to be set
--   2. the attendance correction card gets what it needs
--
-- Run after 17. Idempotent.
-- ═══════════════════════════════════════════════════════════════════


-- ── 1. display name ───────────────────────────────────────────────
-- The column was added in schema 13 and nothing has ever written to it.
-- It is optional and never replaces the handle: two random words remain
-- the identity, this is only what somebody would rather be called.
--
-- Requires the device secret, like every other write that changes an
-- account — users has an open select policy, so a uuid on its own proves
-- nothing about who is asking.

drop function if exists public.set_display_name(uuid, text, text);
create or replace function public.set_display_name(
  p_user uuid, p_secret text, p_name text
)
returns text
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_hash text;
  v_clean text;
begin
  if p_user is null or p_secret is null then
    raise exception 'not yours' using errcode = '42501';
  end if;

  select device_secret_hash into v_hash from public.users where id = p_user;
  if not found or v_hash is null or v_hash <> public.bich_hash(p_secret) then
    raise exception 'not yours' using errcode = '42501';
  end if;

  v_clean := nullif(btrim(coalesce(p_name, '')), '');

  -- Clearing it is allowed and returns to handle-only.
  if v_clean is null then
    update public.users set display_name = null where id = p_user;
    return null;
  end if;

  if length(v_clean) < 2 or length(v_clean) > 24 then
    raise exception 'a name is 2 to 24 characters' using errcode = '22023';
  end if;

  /* No newlines or control characters. This string is rendered in other
     people's feeds, so it must not be able to carry layout with it. */
  if v_clean ~ '[\n\r\t]' then
    raise exception 'one line only' using errcode = '22023';
  end if;

  update public.users set display_name = v_clean where id = p_user;
  return v_clean;
end $$;

grant execute on function public.set_display_name(uuid, text, text) to anon;


drop function if exists public.my_profile(uuid, text);
create or replace function public.my_profile(p_user uuid, p_secret text)
returns table (handle text, display_name text, magic_enabled boolean)
language plpgsql stable security definer set search_path = public, extensions
as $$
declare v_hash text;
begin
  if p_user is null or p_secret is null then return; end if;
  select device_secret_hash into v_hash from public.users where id = p_user;
  if not found or v_hash is null or v_hash <> public.bich_hash(p_secret) then return; end if;

  return query
    select u.handle, u.display_name, u.magic_enabled
    from public.users u where u.id = p_user;
end $$;

grant execute on function public.my_profile(uuid, text) to anon;


-- ── 2. the correction card ────────────────────────────────────────
-- promote_attendance() flips 'going' to 'attended' a few hours after an
-- event ends. It has to guess: somebody who said they were coming and
-- then did not show is counted as having been there, and that quietly
-- pollutes the crossed-paths graph with people who never met.
--
-- So the app asks, once, and only about what it guessed. The existing
-- recent_auto_attended() and unattend() were written for this in schema
-- 12 and have never been called. This version returns what the card
-- actually needs to render.

/* Schema 12 defined this with four output columns; this version returns
   five. Postgres will not let CREATE OR REPLACE change the shape of a
   function's result — the OUT parameters are part of its identity — so
   the old one has to go first. That is what failed the previous run of
   this file, and it rolled the whole script back with it. */
drop function if exists public.recent_auto_attended(uuid, interval);

create or replace function public.recent_auto_attended(
  p_user uuid, p_since interval default interval '7 days'
)
returns table (
  event_id   uuid,
  short_id   text,
  title      text,
  starts_at  timestamptz,
  venue_name text
)
language sql stable security definer set search_path = public
as $$
  select e.id, e.short_id, e.title, e.starts_at, e.venue_name
  from public.attendances a
  join public.events e on e.id = a.event_id
  where a.user_id = p_user
    and a.status = 'attended'
    and a.confirmed_at is not null
    and a.confirmed_at > now() - p_since
  order by e.starts_at desc
  limit 10;
$$;

grant execute on function public.recent_auto_attended(uuid, interval) to anon;


-- "I was not there." Demotes to 'cancelled' so the pair never counts as
-- having crossed paths. Only ever the caller's own row, and only ever
-- downwards — nothing here can claim an attendance.
-- Superseded by unattend_as below, which verifies the device secret.
-- Leaving both would mean one path that checks who is asking and one
-- that does not.
drop function if exists public.unattend(uuid, uuid);

drop function if exists public.unattend_as(uuid, text, uuid);
create or replace function public.unattend_as(
  p_user uuid, p_secret text, p_event uuid
)
returns boolean
language plpgsql security definer set search_path = public, extensions
as $$
declare v_hash text;
begin
  select device_secret_hash into v_hash from public.users where id = p_user;
  if not found or v_hash is null or v_hash <> public.bich_hash(p_secret) then
    raise exception 'not yours' using errcode = '42501';
  end if;

  update public.attendances
     set status = 'cancelled', confirmed_at = null
   where user_id = p_user and event_id = p_event and status = 'attended';
  return found;
end $$;

grant execute on function public.unattend_as(uuid, text, uuid) to anon;


-- ── 3. a duplicate left over from schema 5 ────────────────────────
-- Schema 5 defined my_going(viewer uuid, event_ids uuid[]) and nothing
-- ever called it. Schema 14 defined my_going(p_viewer uuid,
-- p_event_ids text[]) and the app calls that one.
--
-- They coexist rather than conflict, because the argument types differ
-- — which is precisely the problem: two functions with one name, doing
-- nearly the same job, where only the parameter NAMES keep PostgREST
-- pointed at the right one. Rename a parameter one day and the call
-- silently resolves to the wrong function.

drop function if exists public.my_going(uuid, uuid[]);


-- ── afterwards ────────────────────────────────────────────────────
--   select handle, display_name from public.users where display_name is not null;
--   select * from public.recent_auto_attended('<your uuid>');
--
-- To see what the promotion job has been guessing:
--   select e.title, a.status, a.confirmed_at
--     from public.attendances a join public.events e on e.id = a.event_id
--    where a.confirmed_at is not null order by a.confirmed_at desc limit 20;
