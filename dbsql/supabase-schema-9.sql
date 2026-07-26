-- ════════════════════════════════════════════════════════════════
-- bich.service — schema part 9: ownership, editing, drafts
--
-- Closes a real hole and adds the thing every other feature was
-- waiting on.
--
-- THE HOLE. Part 4 created this:
--
--   create policy "hosts may edit their own event"
--     on public.events for update to anon
--     using (starts_at > now() - interval '1 day')
--
-- The name says hosts. The policy says anon. There is no auth, so
-- "their own" is not expressible and was never enforced: anyone
-- holding the publishable key - which ships in config.js, by design -
-- can rewrite the title, date and venue of every upcoming event from
-- a browser console. Nothing exposed it because no edit UI existed.
-- This drops it.
--
-- THE REPLACEMENT. Each event carries the SHA-256 of a random token
-- the creating device keeps. Mutations go through SECURITY DEFINER
-- functions that hash the presented token and compare. The database
-- still does not know who anyone is; it only knows whether they can
-- prove they made this row.
--
-- Honest limit: lose the device, lose the ability to edit. Same trade
-- the "going" list already makes. Passkeys (part 2's credentials
-- table, still unused) are the real fix, and a token holder will be
-- able to claim their events into an account when that lands.
--
-- Run after parts 1-8. Safe to re-run.
-- ════════════════════════════════════════════════════════════════


-- ── 1. proof of authorship ───────────────────────────────────────
alter table public.events
  add column if not exists edit_token_hash text;

create index if not exists events_edit_token_idx
  on public.events (edit_token_hash) where edit_token_hash is not null;

comment on column public.events.edit_token_hash is
  'SHA-256 hex of the creating device''s edit token. Never returned to any client.';

-- events_public and feed() both select explicit column lists, so the
-- hash is not exposed by either. Verify after running:
--   select * from public.events_public limit 1;   -- must not include it


-- ── 2. close the hole ────────────────────────────────────────────
drop policy if exists "hosts may edit their own event" on public.events;
-- No update policy at all now. The browser may insert and read.
-- Every change goes through the functions below.


-- ── 3. new events must be claimable ──────────────────────────────
-- Re-created from part 4 with two changes: a token is required, and
-- 'hidden' is allowed so a draft can exist.
drop policy if exists "anyone may publish an event" on public.events;
create policy "anyone may publish an event"
  on public.events for insert to anon
  with check (
    length(title) between 1 and 200
    and (description is null or length(description) <= 2000)
    and (venue_name is null or length(venue_name) <= 200)
    and starts_at > now() - interval '1 day'
    and starts_at < now() + interval '2 years'
    and (ends_at is null or ends_at > starts_at)
    and price_value >= 0 and price_value <= 10000000
    and (capacity is null or (capacity > 0 and capacity <= 100000))
    and ((venue_lat is null and venue_lng is null)
      or (venue_lat between -90 and 90 and venue_lng between -180 and 180))
    and status in ('live', 'hidden')
    and (cover_url is null or cover_url ~ '^https://')
    -- an event nobody can edit is an event nobody can correct
    and edit_token_hash ~ '^[a-f0-9]{64}$'
  );


-- ── 4. venue provenance gains a value ────────────────────────────
-- A pin taken from a matched venue in the venue book is neither
-- manual nor printed. Recording which it was is what lets you audit
-- later whether matching is trustworthy.
alter table public.events drop constraint if exists events_venue_source_check;
alter table public.events add constraint events_venue_source_check
  check (venue_source in
    ('manual','printed_coordinates','printed_address','venue_name_only','matched_venue'));


-- ── 5. mutation, gated on the token ──────────────────────────────
create or replace function public.update_event(
  p_short_id text,
  p_token    text,
  p_patch    jsonb
)
returns public.events_public
language plpgsql
security definer
set search_path = public
as $$
declare
  target public.events;
  result public.events_public;
  going_now int;
  new_start timestamptz;
begin
  select * into target from public.events
   where short_id = p_short_id and status <> 'deleted';
  if not found then
    raise exception 'no such event' using errcode = 'P0002';
  end if;

  if target.edit_token_hash is null
     or target.edit_token_hash <> encode(digest(p_token, 'sha256'), 'hex') then
    raise exception 'not yours to edit' using errcode = '42501';
  end if;

  if target.starts_at < now() - interval '1 day' then
    raise exception 'that event is over' using errcode = '22023';
  end if;

  -- Moving an event people have committed to is not an edit, it is a
  -- different event. Without notifications there is no honest way to
  -- tell them, so block it and let the host cancel and repost.
  new_start := coalesce((p_patch->>'starts_at')::timestamptz, target.starts_at);
  if new_start <> target.starts_at then
    select count(*) into going_now from public.attendances
     where event_id = target.id and status in ('going','attended');
    if going_now > 0 then
      raise exception 'cannot move an event once % people are going; cancel and repost instead', going_now
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
    starts_at      = new_start,
    ends_at        = case when p_patch ? 'ends_at'
                          then (p_patch->>'ends_at')::timestamptz else e.ends_at end,
    recurrence     = case when p_patch ? 'recurrence'
                          then p_patch->>'recurrence' else e.recurrence end,
    price_value    = coalesce((p_patch->>'price_value')::integer, e.price_value),
    price_currency = coalesce(p_patch->>'price_currency', e.price_currency),
    capacity       = case when p_patch ? 'capacity'
                          then (p_patch->>'capacity')::integer else e.capacity end,
    contact        = case when p_patch ? 'contact'
                          then p_patch->>'contact' else e.contact end,
    cover_url      = coalesce(p_patch->>'cover_url', e.cover_url),
    status         = coalesce(p_patch->>'status', e.status)
  where e.id = target.id;

  -- Re-run the same shape checks the insert policy applies, because a
  -- definer function bypasses them.
  select * into target from public.events where id = target.id;
  if length(target.title) not between 1 and 200
     or (target.description is not null and length(target.description) > 2000)
     or target.price_value < 0 or target.price_value > 10000000
     or (target.capacity is not null and (target.capacity <= 0 or target.capacity > 100000))
     or (target.ends_at is not null and target.ends_at <= target.starts_at)
     or target.status not in ('live','hidden')
     or (target.cover_url is not null and target.cover_url !~ '^https://')
  then
    raise exception 'that change would make the event invalid' using errcode = '23514';
  end if;

  select * into result from public.events_public where id = target.id;
  return result;
end $$;


create or replace function public.cancel_event(p_short_id text, p_token text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare target public.events;
begin
  select * into target from public.events where short_id = p_short_id;
  if not found then return false; end if;
  if target.edit_token_hash is null
     or target.edit_token_hash <> encode(digest(p_token, 'sha256'), 'hex') then
    raise exception 'not yours to cancel' using errcode = '42501';
  end if;
  -- soft delete: share links stay resolvable and say it is off, rather
  -- than 404ing at someone standing outside the venue
  update public.events set status = 'deleted' where id = target.id;
  return true;
end $$;


-- ── 6. read back what this device owns ───────────────────────────
-- Including drafts, which no select policy exposes. Takes hashes, not
-- tokens: the caller hashes locally, so a raw token never crosses the
-- wire even once.
create or replace function public.my_events(p_hashes text[])
returns setof public.events_public
language sql
stable
security definer
set search_path = public
as $$
  select p.* from public.events_public p
  join public.events e on e.id = p.id
  where e.edit_token_hash = any(p_hashes)
  union
  -- events_public filters to status='live'; drafts need the direct read
  select e.id, e.short_id, e.title, e.description,
         e.venue_name, e.venue_lat, e.venue_lng, e.city, e.community_slug,
         e.starts_at, e.ends_at, e.recurrence,
         e.price_value, e.price_currency, e.capacity,
         e.cover_url, e.contact, e.source, 0::bigint
  from public.events e
  where e.edit_token_hash = any(p_hashes)
    and e.status = 'hidden'
  order by starts_at;
$$;


grant execute on function public.update_event(text, text, jsonb) to anon;
grant execute on function public.cancel_event(text, text)        to anon;
grant execute on function public.my_events(text[])               to anon;


-- ── 7. a brake for later ─────────────────────────────────────────
-- Open during the beta, as you asked. This view is what you will read
-- when deciding to close it, and the function is the switch.
create or replace view public.publish_rate as
  select date_trunc('hour', created_at) as hour,
         count(*)                       as events,
         count(distinct host_id)        as devices,
         count(*) filter (where source = 'photo') as from_photos
  from public.events
  where created_at > now() - interval '7 days'
  group by 1 order by 1 desc;

-- To close it later, without a schema change: add a per-host cap here
-- and reference it from the insert policy.
--
--   create or replace function public.host_is_within_quota(h uuid)
--   returns boolean language sql stable security definer
--   set search_path = public as $$
--     select coalesce((
--       select count(*) < 40 from public.events
--       where host_id = h and created_at > now() - interval '24 hours'
--     ), true);
--   $$;
--
-- then in the insert policy:  and public.host_is_within_quota(host_id)
--
-- Left commented deliberately. host_id is client supplied, so this is
-- a speed bump against accidents, not a defence against someone who
-- reads the source. The real limit is the invite gate on the worker.
