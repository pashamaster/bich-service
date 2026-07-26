-- ════════════════════════════════════════════════════════════════
-- bich.service — schema part 5: what the client fixes need
--
-- Run after parts 1-4. Safe to re-run.
--
-- Almost nothing here is urgent. Parts 1-4 already permit everything
-- the corrected frontend does; I checked each policy against each
-- call. Section 1 is the one that matters, and only because the app
-- now writes to venues, which it never did before.
--
-- Sections 2 and 3 are optional and marked as such.
-- ════════════════════════════════════════════════════════════════


-- ── 1. stop the venue book filling with duplicates ───────────────
-- REQUIRED if you deploy the new index.html.
--
-- venues has `unique (source, source_id)`. Every venue the app creates
-- has source_id = null, and Postgres allows unlimited nulls in a unique
-- constraint, so that line stops nothing. Without the index below,
-- publishing "Casa Eira" ten times creates ten venues, use_count never
-- concentrates on the real row, and search_venues ranks noise.
--
-- Rounding to 3 decimals is roughly 100 m: the same place pinned twice
-- by two people collapses into one row, two genuinely different rooms
-- on the same street stay separate.
create unique index if not exists venues_dedupe_idx
  on public.venues (lower(name), round(lat::numeric, 3), round(lng::numeric, 3));

-- If that fails, you already have duplicates. Look first:
--   select lower(name), round(lat::numeric,3), round(lng::numeric,3), count(*)
--   from public.venues
--   group by 1,2,3 having count(*) > 1;
-- then merge or delete the extras and re-run.


-- ── 2. OPTIONAL: let a device recover its own "going" list ───────
-- attendances deliberately has no select policy, which is the right
-- call: nobody should read the attendee list. The side effect is that
-- "going" exists only in that phone's localStorage. Safari evicts that
-- after seven days of not opening the site, and the marks are then
-- invisible to the user forever while still counting in going_count.
--
-- This returns only the caller's own rows, for event ids it already
-- knows. It leaks nothing: you must supply the ids, and you only ever
-- learn about yourself.
create or replace function public.my_going(viewer uuid, event_ids uuid[])
returns table (event_id uuid, status text)
language sql stable
security definer
set search_path = public
as $$
  select a.event_id, a.status
  from public.attendances a
  where a.user_id = viewer
    and a.event_id = any(event_ids)
    and a.status in ('going','attended');
$$;

grant execute on function public.my_going(uuid, uuid[]) to anon;

-- The frontend does not call this yet. Decide whether you want going
-- state to survive a lost device before wiring it up - it is a product
-- question, not a technical one.


-- ── 3. OPTIONAL: make decay_unconfirmed actually run ─────────────
-- Part 2 wrote it, part 3 revoked it from anon, and nothing has ever
-- called it. Until something does, "going" markers never expire, so
-- going_count on past events only grows.
--
-- Needs pg_cron enabled (Supabase: Database > Extensions).
--
--   create extension if not exists pg_cron;
--   select cron.schedule(
--     'bich-decay-unconfirmed',
--     '17 4 * * *',                       -- 04:17 daily
--     $$ select public.decay_unconfirmed('7 days'::interval); $$
--   );
--
-- Left commented on purpose: enabling pg_cron is a project-level
-- change and this is not urgent while the event count is small.


-- ── not changed, and why ─────────────────────────────────────────
-- Checked against every call the corrected frontend makes:
--
--   users        insert + select      OK. All 60 handle words match
--                                     the ^[a-z]{3,5} [a-z]{3,5}$ check.
--   events       insert + select      OK. status='live' satisfies both
--                                     the with-check and the read-back
--                                     that Prefer: return=representation
--                                     needs for saved[0].id.
--   attendances  insert + update      OK. Upsert sends return=minimal,
--                                     so the missing select policy is
--                                     not a problem.
--   venues       insert + select      OK, once section 1 is in.
--   communities  select               OK.
--   feed()       execute              granted to anon in part 3.
--   search_venues() execute           granted to anon in part 3.
--
-- One thing to know rather than fix: the attendances update policy is
-- `using (status in ('going','cancelled'))`. Once a post-event flow
-- sets a row to 'attended', that row fails the USING clause, so a
-- later going/not-going toggle returns 42501 instead of quietly
-- overwriting the graph signal. That is the safe failure. The frontend
-- now logs it rather than swallowing it. Handle it in the UI when you
-- build the post-event flow; do not loosen this policy.
