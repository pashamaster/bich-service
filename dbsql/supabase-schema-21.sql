-- ═══════════════════════════════════════════════════════════════════
-- bich.service — schema part 21
--
--   1. magic on by default for everyone
--   2. admin rights, for correcting and removing anyone's event
--
-- Run after 20. Idempotent.
-- ═══════════════════════════════════════════════════════════════════


-- ── 1. magic by default ───────────────────────────────────────────
-- The flag stays — this is a change of DEFAULT, not a removal of the
-- switch. Turning it off for one account later is still one update, and
-- the worker still checks before spending anything.
--
-- The daily cap in the worker remains the actual spend protection. With
-- magic open to everyone, DAILY_CAP is the only thing standing between
-- a curious afternoon and a bill, so it matters more now, not less.

alter table public.users alter column magic_enabled set default true;

update public.users
   set magic_enabled = true,
       magic_granted_at = coalesce(magic_granted_at, now()),
       magic_source = coalesce(magic_source, 'default')
 where magic_enabled = false;


-- ── 2. admin ──────────────────────────────────────────────────────
-- One flag, checked the same way everything else is: device secret plus
-- the flag itself. An admin uuid on its own would be no better than a
-- normal one, since users has an open select policy and every id is
-- listable.
--
-- Admin powers are deliberately narrow — correct an event, remove an
-- event, list every event including hidden and deleted ones. There is
-- no power here to read attendee lists, see who is going, or look at
-- anyone's history. Those stay impossible for everybody, which is the
-- promise the whole app rests on, and an admin flag is not a reason to
-- put a door in it.

alter table public.users
  add column if not exists is_admin boolean not null default false;

create or replace function public.is_admin(p_user uuid, p_secret text)
returns boolean
language plpgsql stable security definer set search_path = public, extensions
as $$
declare v_hash text; v_admin boolean;
begin
  if p_user is null or p_secret is null then return false; end if;
  select device_secret_hash, is_admin into v_hash, v_admin
    from public.users where id = p_user;
  if not found or v_hash is null then return false; end if;
  if v_hash <> public.bich_hash(p_secret) then return false; end if;
  return coalesce(v_admin, false);
end $$;

grant execute on function public.is_admin(uuid, text) to anon;


-- Every event, whatever its status, newest first. The normal feed only
-- ever shows status = 'live' and only the future, so there has been no
-- way to find a deleted or hidden event to look at or restore.
create or replace function public.admin_all_events(
  p_user uuid, p_secret text, p_limit integer default 200
)
returns table (
  short_id     text,
  title        text,
  status       text,
  starts_at    timestamptz,
  venue_name   text,
  city         text,
  community    text,
  host_handle  text,
  source       text,
  needs_review boolean,
  created_at   timestamptz
)
language plpgsql stable security definer set search_path = public, extensions
as $$
begin
  if not public.is_admin(p_user, p_secret) then
    raise exception 'not an admin' using errcode = '42501';
  end if;

  return query
    select e.short_id, e.title, e.status, e.starts_at, e.venue_name,
           e.city, e.community_slug, u.handle, e.source, e.needs_review, e.created_at
    from public.events e
    left join public.users u on u.id = e.host_id
    order by e.created_at desc
    limit greatest(1, least(coalesce(p_limit, 200), 1000));
end $$;

grant execute on function public.admin_all_events(uuid, text, integer) to anon;


-- Correct anyone's event. Same patch shape as update_event_as, so the
-- app can reuse the edit sheet exactly as it stands.
create or replace function public.admin_update_event(
  p_user uuid, p_secret text, p_short_id text, p_patch jsonb
)
returns public.events_public
language plpgsql security definer set search_path = public, extensions
as $$
declare
  target public.events;
  result public.events_public;
begin
  if not public.is_admin(p_user, p_secret) then
    raise exception 'not an admin' using errcode = '42501';
  end if;

  select * into target from public.events where short_id = p_short_id;
  if not found then raise exception 'no such event' using errcode = 'P0002'; end if;

  update public.events e set
    title          = coalesce(p_patch->>'title', e.title),
    description    = coalesce(p_patch->>'description', e.description),
    venue_name     = coalesce(p_patch->>'venue_name', e.venue_name),
    venue_address  = coalesce(p_patch->>'venue_address', e.venue_address),
    venue_lat      = coalesce((p_patch->>'venue_lat')::double precision, e.venue_lat),
    venue_lng      = coalesce((p_patch->>'venue_lng')::double precision, e.venue_lng),
    city           = coalesce(p_patch->>'city', e.city),
    community_slug = case when p_patch ? 'community_slug'
                          then p_patch->>'community_slug' else e.community_slug end,
    category       = case when p_patch ? 'category'
                          then p_patch->>'category' else e.category end,
    cover_url      = case when p_patch ? 'cover_url'
                          then p_patch->>'cover_url' else e.cover_url end,
    starts_at      = coalesce((p_patch->>'starts_at')::timestamptz, e.starts_at),
    ends_at        = case when p_patch ? 'ends_at'
                          then (p_patch->>'ends_at')::timestamptz else e.ends_at end,
    price_value    = coalesce((p_patch->>'price_value')::integer, e.price_value),
    capacity       = case when p_patch ? 'capacity'
                          then (p_patch->>'capacity')::integer else e.capacity end,
    contact        = case when p_patch ? 'contact'
                          then p_patch->>'contact' else e.contact end,
    -- an admin correction clears the review flag: it has been looked at
    needs_review   = false,
    -- and lets a deleted event be put back, which nothing else can do
    status         = coalesce(p_patch->>'status', e.status),
    updated_at     = now()
  where e.id = target.id;

  select * into result from public.events_public where short_id = p_short_id;
  return result;
end $$;

grant execute on function public.admin_update_event(uuid, text, text, jsonb) to anon;


-- Remove anyone's event. Soft by default, like every other delete here,
-- so a share link still resolves and says the event is off rather than
-- 404ing at somebody standing outside the venue.
create or replace function public.admin_cancel_event(
  p_user uuid, p_secret text, p_short_id text, p_hard boolean default false
)
returns boolean
language plpgsql security definer set search_path = public, extensions
as $$
declare target public.events;
begin
  if not public.is_admin(p_user, p_secret) then
    raise exception 'not an admin' using errcode = '42501';
  end if;

  select * into target from public.events where short_id = p_short_id;
  if not found then return false; end if;

  if p_hard then
    -- Only for genuine rubbish. Attendances and visits go with it.
    delete from public.events where id = target.id;
  else
    update public.events set status = 'deleted', updated_at = now()
     where id = target.id;
  end if;
  return true;
end $$;

grant execute on function public.admin_cancel_event(uuid, text, text, boolean) to anon;


-- ── 3. grant it ───────────────────────────────────────────────────

update public.users set is_admin = true where handle = 'pine tem';


-- ── afterwards ────────────────────────────────────────────────────
--   select handle, is_admin, magic_enabled from public.users order by created_at;
--   select * from public.admin_all_events('<uuid>', '<secret>', 50);
--
-- Make somebody else an admin:
--   update public.users set is_admin = true where handle = 'heath quill';
--
-- Turn magic off for one account, now that it is on by default:
--   update public.users set magic_enabled = false where handle = 'heath quill';
