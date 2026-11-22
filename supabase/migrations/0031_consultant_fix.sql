-- Migration 0031: the consultant, two fixes found in the owner's first live test (22 Nov 2026, spec 14.25).
-- 1. consultant_status is STABLE, so the app's call runs in a read-only transaction, but it called game.actor, which takes
--    row locks (FOR SHARE, FOR UPDATE): Postgres refused, and the app's status card never loaded (HTTP 405). It now checks
--    the owner the same way without locks.
-- 2. game.actor refused a paused world ('This world is not running'). The consultant may now be asked in a running or
--    paused world; a world in setup or one that has ended gets a plain reason instead.
-- Nothing else changes: same fee, limits, budget and look-ups.

create or replace function public.consultant_status(p_airline uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  ra public.airlines%rowtype; rw public.worlds%rowtype; v_admin boolean; v_fee numeric; v_today int; v_qtr int; v_spent numeric; v_why text;
begin
  -- the owner check of game.actor, without its row locks: the app reads this through a read-only transaction
  select * into ra from public.airlines where id = p_airline;
  if not found then raise exception 'Airline not found'; end if;
  if not game.is_server() and (auth.uid() is null or ra.user_id is distinct from auth.uid()) then
    raise exception 'This is not your airline';
  end if;
  select * into rw from public.worlds where id = ra.world_id;
  v_admin := coalesce((select is_admin from public.profiles where user_id = auth.uid()), false);
  v_fee := game.consultant_fee(p_airline);
  select count(*) into v_today from public.consultant_reports
   where user_id = auth.uid() and created_at > now() - interval '24 hours' and status <> 'failed';
  select count(*) into v_qtr from public.consultant_reports
   where airline_id = p_airline and status <> 'failed' and (game_day - 1) / 91 = rw.game_day / 91;
  select coalesce(sum(cost_usd), 0) into v_spent from public.consultant_reports where created_at >= date_trunc('month', now());
  v_why := case
    when ra.status <> 'active' then 'This airline is not active'
    when rw.status = 'setup' then 'The consultant opens once the world has started'
    when rw.status = 'ended' then 'This world has ended'
    when game.param('consultant_open') < 1 and not v_admin then 'The consultant is being tested by the admins'
    when v_spent >= game.param('consultant_budget_usd_month') then 'The consultant is fully booked this month; back on the 1st'
    when v_today >= game.param('consultant_per_day') then format('%s reports in 24 hours is the most', game.param('consultant_per_day')::int)
    when v_qtr >= game.param('consultant_per_quarter') and not v_admin then 'One report a game quarter: the next one opens next quarter'
    when (select cash_inr from public.airline_finance where airline_id = p_airline) < v_fee then 'Not enough cash for the fee'
  end;
  return jsonb_build_object('fee_inr', v_fee, 'can_ask', v_why is null, 'reason', v_why, 'asked_today', v_today,
    'per_day', game.param('consultant_per_day'), 'this_quarter', v_qtr, 'admin', v_admin,
    'busy', exists (select 1 from public.consultant_reports where airline_id = p_airline and status = 'working'
                     and created_at > now() - interval '10 minutes'));
end $$;

create or replace function public.consultant_start(p_airline uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare rw public.worlds%rowtype; s jsonb; v_fee numeric; v_id uuid; pb public.consultant_playbook%rowtype;
begin
  rw := game.actor(p_airline, false);          -- a paused world may ask too; setup and ended are refused by the status
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  perform pg_advisory_xact_lock(hashtext('consultant:' || p_airline::text));
  -- a report still 'working' after 10 minutes never finished (the edge function stops at 150 seconds): fee back
  perform public.consultant_finish(x.id, false, null, 0, 0, 0, 0, 'Did not finish')
     from public.consultant_reports x where x.airline_id = p_airline and x.status = 'working' and x.created_at < now() - interval '10 minutes';
  s := public.consultant_status(p_airline);
  if (s ->> 'busy')::boolean then raise exception 'A report for this airline is already being written'; end if;
  if not (s ->> 'can_ask')::boolean then raise exception '%', s ->> 'reason'; end if;
  select * into pb from public.consultant_playbook where active order by version desc limit 1;
  if not found then raise exception 'The consultant has no playbook yet'; end if;
  v_fee := (s ->> 'fee_inr')::numeric;
  perform game.book(p_airline, rw.game_day + 1, -v_fee, 'consultant', 'Claude consultant report', -v_fee);
  insert into public.consultant_reports (airline_id, world_id, user_id, game_day, fee_inr, model, playbook)
  values (p_airline, rw.id, auth.uid(), rw.game_day + 1, v_fee, pb.model, pb.version) returning id into v_id;
  return jsonb_build_object('report_id', v_id, 'fee_inr', v_fee, 'model', pb.model, 'playbook', pb.body,
                            'max_turns', game.param('consultant_max_turns'),
                            'usd_mtok', jsonb_build_object('in', game.param('consultant_usd_mtok_in'),
                                                           'cache_write', game.param('consultant_usd_mtok_cache_write'),
                                                           'cache_read', game.param('consultant_usd_mtok_cache_read'),
                                                           'out', game.param('consultant_usd_mtok_out')));
end $$;
