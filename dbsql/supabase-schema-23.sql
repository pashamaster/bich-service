-- ═══════════════════════════════════════════════════════════════════
-- bich.service — schema part 23
--
--   "Could not find the function public.update_event(...)"
--
-- Run after 22. Idempotent.
-- ═══════════════════════════════════════════════════════════════════


-- ── what happened ─────────────────────────────────────────────────
-- Schema 9 defined update_event() as `returns public.events_public`.
-- Schemas 11 and 12 both contain:
--
--     drop view if exists public.events_public cascade;
--
-- A cascade drop of a view destroys every function whose return type
-- IS that view. So update_event was deleted by a later migration, and
-- nothing ever recreated it. The token fallback in the app has been
-- calling a function that does not exist.
--
-- Fixing this one function would leave the trap in place: the next time
-- events_public is rebuilt, the same thing happens to update_event_as,
-- admin_update_event and my_hosted.
--
-- So every one of them now returns JSONB instead of the view's row
-- type. jsonb has no dependency on any view, and the app already reads
-- these results by key name, so nothing on the client changes.

create or replace function public.event_json(p_short_id text)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select to_jsonb(p) from public.events_public p where p.short_id = p_short_id;
$$;

grant execute on function public.event_json(text) to anon;


-- ── the token path, restored ──────────────────────────────────────
-- Still needed. Events published before ownership moved to the person,
-- and any whose host_id was null, are reachable only by their token.

drop function if exists public.update_event(text, text, jsonb);

create or replace function public.update_event(
  p_short_id text, p_token text, p_patch jsonb
)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  target    public.events;
  new_start timestamptz;
  others    integer;
begin
  select * into target from public.events
   where short_id = p_short_id and status <> 'deleted';
  if not found then
    raise exception 'no such event' using errcode = 'P0002';
  end if;

  if target.edit_token_hash is null
     or target.edit_token_hash <> public.bich_hash(p_token) then
    raise exception 'not yours to edit' using errcode = '42501';
  end if;

  new_start := coalesce((p_patch->>'starts_at')::timestamptz, target.starts_at);
  if new_start < now() - interval '90 days' then
    raise exception 'events may not be moved more than 90 days into the past'
      using errcode = '22023';
  end if;

  -- the host's own attendance never locks their own date
  if new_start <> target.starts_at then
    select count(*) into others from public.attendances
     where event_id = target.id and status in ('going','attended')
       and user_id is distinct from target.host_id;
    if others > 0 then
      raise exception 'cannot move an event once % other people are going', others
        using errcode = '23514';
    end if;
  end if;

  update public.events e set
    title          = coalesce(p_patch->>'title', e.title),
    description    = coalesce(p_patch->>'description', e.description),
    venue_name     = coalesce(p_patch->>'venue_name', e.venue_name),
    venue_address  = coalesce(p_patch->>'venue_address', e.venue_address),
    venue_lat      = coalesce((p_patch->>'venue_lat')::double precision, e.venue_lat),
    venue_lng      = coalesce((p_patch->>'venue_lng')::double precision, e.venue_lng),
    venue_source   = coalesce(p_patch->>'venue_source', e.venue_source),
    city           = coalesce(p_patch->>'city', e.city),
    community_slug = case when p_patch ? 'community_slug'
                          then p_patch->>'community_slug' else e.community_slug end,
    category       = case when p_patch ? 'category'
                          then p_patch->>'category' else e.category end,
    cover_url      = case when p_patch ? 'cover_url'
                          then p_patch->>'cover_url' else e.cover_url end,
    starts_at      = new_start,
    ends_at        = case when p_patch ? 'ends_at'
                          then (p_patch->>'ends_at')::timestamptz else e.ends_at end,
    price_value    = coalesce((p_patch->>'price_value')::integer, e.price_value),
    capacity       = case when p_patch ? 'capacity'
                          then (p_patch->>'capacity')::integer else e.capacity end,
    contact        = case when p_patch ? 'contact'
                          then p_patch->>'contact' else e.contact end,
    updated_at     = now()
  where e.id = target.id;

  return public.event_json(p_short_id);
end $$;

grant execute on function public.update_event(text, text, jsonb) to anon;


drop function if exists public.cancel_event(text, text);

create or replace function public.cancel_event(p_short_id text, p_token text)
returns boolean
language plpgsql security definer set search_path = public, extensions
as $$
declare target public.events;
begin
  select * into target from public.events where short_id = p_short_id;
  if not found then return false; end if;
  if target.edit_token_hash is null
     or target.edit_token_hash <> public.bich_hash(p_token) then
    raise exception 'not yours to cancel' using errcode = '42501';
  end if;
  update public.events set status = 'deleted', updated_at = now() where id = target.id;
  return true;
end $$;

grant execute on function public.cancel_event(text, text) to anon;


-- ── the owner and admin paths, now cascade-proof ──────────────────

drop function if exists public.update_event_as(text, uuid, text, jsonb);

create or replace function public.update_event_as(
  p_short_id text, p_user uuid, p_secret text, p_patch jsonb
)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  target    public.events;
  new_start timestamptz;
  others    integer;
begin
  select * into target from public.events
   where short_id = p_short_id and status <> 'deleted';
  if not found then
    raise exception 'no such event' using errcode = 'P0002';
  end if;

  if not public.owns_event(target, p_user, p_secret) then
    raise exception 'not yours to edit' using errcode = '42501';
  end if;

  new_start := coalesce((p_patch->>'starts_at')::timestamptz, target.starts_at);
  if new_start < now() - interval '90 days' then
    raise exception 'events may not be moved more than 90 days into the past'
      using errcode = '22023';
  end if;

  if new_start <> target.starts_at then
    select count(*) into others from public.attendances
     where event_id = target.id and status in ('going','attended')
       and user_id is distinct from target.host_id;
    if others > 0 then
      raise exception 'cannot move an event once % other people are going', others
        using errcode = '23514';
    end if;
  end if;

  update public.events e set
    title          = coalesce(p_patch->>'title', e.title),
    description    = coalesce(p_patch->>'description', e.description),
    venue_name     = coalesce(p_patch->>'venue_name', e.venue_name),
    venue_address  = coalesce(p_patch->>'venue_address', e.venue_address),
    venue_lat      = coalesce((p_patch->>'venue_lat')::double precision, e.venue_lat),
    venue_lng      = coalesce((p_patch->>'venue_lng')::double precision, e.venue_lng),
    venue_source   = coalesce(p_patch->>'venue_source', e.venue_source),
    city           = coalesce(p_patch->>'city', e.city),
    community_slug = case when p_patch ? 'community_slug'
                          then p_patch->>'community_slug' else e.community_slug end,
    category       = case when p_patch ? 'category'
                          then p_patch->>'category' else e.category end,
    cover_url      = case when p_patch ? 'cover_url'
                          then p_patch->>'cover_url' else e.cover_url end,
    starts_at      = new_start,
    ends_at        = case when p_patch ? 'ends_at'
                          then (p_patch->>'ends_at')::timestamptz else e.ends_at end,
    price_value    = coalesce((p_patch->>'price_value')::integer, e.price_value),
    price_currency = coalesce(p_patch->>'price_currency', e.price_currency),
    capacity       = case when p_patch ? 'capacity'
                          then (p_patch->>'capacity')::integer else e.capacity end,
    recurrence     = case when p_patch ? 'recurrence'
                          then p_patch->>'recurrence' else e.recurrence end,
    contact        = case when p_patch ? 'contact'
                          then p_patch->>'contact' else e.contact end,
    updated_at     = now()
  where e.id = target.id;

  return public.event_json(p_short_id);
end $$;

grant execute on function public.update_event_as(text, uuid, text, jsonb) to anon;


drop function if exists public.admin_update_event(uuid, text, text, jsonb);

create or replace function public.admin_update_event(
  p_user uuid, p_secret text, p_short_id text, p_patch jsonb
)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare target public.events;
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
    venue_source   = coalesce(p_patch->>'venue_source', e.venue_source),
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
    needs_review   = false,      -- an admin has now looked at it
    status         = coalesce(p_patch->>'status', e.status),
    updated_at     = now()
  where e.id = target.id;

  return public.event_json(p_short_id);
end $$;

grant execute on function public.admin_update_event(uuid, text, text, jsonb) to anon;


-- ── afterwards ────────────────────────────────────────────────────
-- Every editing path should be present, and none of them should have
-- events_public as its return type any more:
--
--   select p.proname, pg_get_function_result(p.oid) as returns
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public'
--      and p.proname in ('update_event','update_event_as','admin_update_event',
--                        'cancel_event','cancel_event_as','my_hosted','event_json')
--    order by p.proname;
--
-- Anything still reporting `events_public` will be deleted the next
-- time that view is rebuilt.
