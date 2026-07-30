-- ═══════════════════════════════════════════════════════════════════
-- bich.service — schema part 22
--
--   events that belong to nobody
--
-- Run after 21. Idempotent.
-- ═══════════════════════════════════════════════════════════════════


-- ── the problem ───────────────────────────────────────────────────
-- saveEvent() writes `host_id: CURRENT_USER.id || null`. For a long
-- stretch ensureUser() was failing silently — the 4-retry handle loop,
-- and later the digest() search_path fault that broke
-- claim_device_secret — so CURRENT_USER.id was null and those events
-- were published with NO HOST.
--
-- owns_event() checks `p_event.host_id is distinct from p_user`, so a
-- null host matches nobody. Every one of those events refuses both
-- update_event_as and cancel_event_as, permanently, for everyone. They
-- can only be reached by their per-event token, which lives in one
-- browser and cannot be recovered.
--
-- First, see how many there are:
--
--   select count(*) filter (where host_id is null) as orphaned,
--          count(*)                                as total
--     from public.events where status = 'live';


-- ── adopt them ────────────────────────────────────────────────────
-- Give ownerless events to a real account so they can be edited and
-- cancelled again. Run it with your own handle.

create or replace function public.adopt_orphan_events(
  p_user uuid, p_secret text, p_handle text default null
)
returns integer
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_target uuid;
  n integer;
begin
  -- Only an admin may do this: it hands over other people's events.
  if not public.is_admin(p_user, p_secret) then
    raise exception 'not an admin' using errcode = '42501';
  end if;

  if p_handle is null then
    v_target := p_user;
  else
    select id into v_target from public.users where handle = p_handle;
    if not found then
      raise exception 'no user with handle %', p_handle using errcode = 'P0002';
    end if;
  end if;

  update public.events set host_id = v_target, updated_at = now()
   where host_id is null;
  get diagnostics n = row_count;
  return n;
end $$;

grant execute on function public.adopt_orphan_events(uuid, text, text) to anon;


-- ── stop it happening again ───────────────────────────────────────
-- An event with no host cannot be edited, cancelled, or counted toward
-- anyone's hosting list. There is no situation in which a null host is
-- the right outcome — it only ever meant the client failed and carried
-- on anyway. Refuse it at the door instead.

drop policy if exists "anyone may publish a well formed event" on public.events;
create policy "anyone may publish a well formed event"
  on public.events for insert to anon
  with check (
    host_id is not null                              -- ← the new line
    and length(title) between 1 and 200
    and (description is null or length(description) <= 2000)
    and (venue_name is null or length(venue_name) <= 200)
    and starts_at > now() - interval '90 days'
    and starts_at < now() + interval '2 years'
    and (ends_at is null or ends_at > starts_at)
    and price_value >= 0 and price_value <= 10000000
    and (capacity is null or (capacity > 0 and capacity <= 100000))
    and ((venue_lat is null and venue_lng is null)
      or (venue_lat between -90 and 90 and venue_lng between -180 and 180))
    and status = 'live'
  );

/* This turns a silent, permanent orphaning into a loud, immediate
   failure at publish time. Better: the app already tells somebody when
   publishing fails, and an event nobody can ever edit tells them
   nothing at all until they try. */


-- ── afterwards ────────────────────────────────────────────────────
-- Count them:
--   select count(*) from public.events where host_id is null;
--
-- Adopt them all to yourself (needs your uuid and device secret —
-- run bichCheck() in the browser console to read both):
--   select public.adopt_orphan_events('<your uuid>', '<your secret>');
--
-- Or hand them to a specific handle:
--   select public.adopt_orphan_events('<your uuid>', '<your secret>', 'pine tem');
--
-- Then confirm nothing is left:
--   select count(*) from public.events where host_id is null;
