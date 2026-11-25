-- Migration 0032: the consultant as a world rule (spec 14.25, owner's decision 22 Nov 2026).
-- A world's founder chooses Off, Free, Standard or Premium when founding it; the choice is fixed once the world exists
-- (no function changes it) and is the same for players and, later, the computer-run airlines. Worlds made before 0032
-- get Standard, written to their own values so a later change of the game's defaults does not move them.
-- Free worlds charge nothing (nothing is booked or refunded); Off worlds show a plain reason.

insert into public.game_params (key, num, note) values
('consultant_on', 1, 'Claude consultant: 1 available in a world, 0 not (a world rule from 0032)')
on conflict (key) do nothing;

insert into public.world_options (setting, option, sort, label, blurb, vals, is_default) values
('consultant', 'off', 1, 'Off', 'No consultant: every decision is yours alone.',
  '{"consultant_on": 0}', false),
('consultant', 'free', 2, 'Free', 'Advice from Claude costs nothing: a world for learning. One report a game quarter.',
  '{"consultant_on": 1, "consultant_fee_share": 0, "consultant_fee_min_inr": 0}', false),
('consultant', 'standard', 3, 'Standard', '1% of last quarter''s revenue, at least ₹25 lakh a report.',
  '{"consultant_on": 1, "consultant_fee_share": 0.01, "consultant_fee_min_inr": 2500000}', true),
('consultant', 'premium', 4, 'Premium', '3% of last quarter''s revenue, at least ₹1 crore: asking is a real decision.',
  '{"consultant_on": 1, "consultant_fee_share": 0.03, "consultant_fee_min_inr": 10000000}', false)
on conflict (setting, option) do nothing;

-- worlds made before 0032: Standard, fixed
insert into public.world_params (world_id, key, num, public)
select w.id, e.key, e.value::numeric, true
  from public.worlds w, public.world_options o, jsonb_each_text(o.vals) e
 where o.setting = 'consultant' and o.option = 'standard'
on conflict (world_id, key) do nothing;
update public.worlds set rules = rules || '{"consultant": "standard"}' where not rules ? 'consultant';

create or replace function game.consultant_fee(p_airline uuid) returns numeric
language sql stable set search_path = '' as $$
  with w as (select world_id from public.airlines where id = p_airline)
  select greatest(game.wparam(w.world_id, 'consultant_fee_min_inr'),
                  round(game.wparam(w.world_id, 'consultant_fee_share')
                        * coalesce((select q.revenue from public.quarterly_reports q
                                     where q.airline_id = p_airline order by q.quarter desc limit 1), 0) / 100000) * 100000)
    from w
$$;

-- consultant_status from 0031: the world's rule (on or off, and its fee) in the reason and the answer
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
    when game.wparam(rw.id, 'consultant_on') < 1 then 'This world was founded without the consultant'
    when game.param('consultant_open') < 1 and not v_admin then 'The consultant is being tested by the admins'
    when v_spent >= game.param('consultant_budget_usd_month') then 'The consultant is fully booked this month; back on the 1st'
    when v_today >= game.param('consultant_per_day') then format('%s reports in 24 hours is the most', game.param('consultant_per_day')::int)
    when v_qtr >= game.param('consultant_per_quarter') and not v_admin then 'One report a game quarter: the next one opens next quarter'
    when v_fee > 0 and (select cash_inr from public.airline_finance where airline_id = p_airline) < v_fee then 'Not enough cash for the fee'
  end;
  return jsonb_build_object('fee_inr', v_fee, 'can_ask', v_why is null, 'reason', v_why, 'asked_today', v_today,
    'on', game.wparam(rw.id, 'consultant_on') >= 1, 'fee_share', game.wparam(rw.id, 'consultant_fee_share'),
    'fee_min_inr', game.wparam(rw.id, 'consultant_fee_min_inr'),
    'per_day', game.param('consultant_per_day'), 'this_quarter', v_qtr, 'admin', v_admin,
    'busy', exists (select 1 from public.consultant_reports where airline_id = p_airline and status = 'working'
                     and created_at > now() - interval '10 minutes'));
end $$;

-- consultant_start from 0031: a free world books nothing
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
  if v_fee > 0 then perform game.book(p_airline, rw.game_day + 1, -v_fee, 'consultant', 'Claude consultant report', -v_fee); end if;
  insert into public.consultant_reports (airline_id, world_id, user_id, game_day, fee_inr, model, playbook)
  values (p_airline, rw.id, auth.uid(), rw.game_day + 1, v_fee, pb.model, pb.version) returning id into v_id;
  return jsonb_build_object('report_id', v_id, 'fee_inr', v_fee, 'model', pb.model, 'playbook', pb.body,
                            'max_turns', game.param('consultant_max_turns'),
                            'usd_mtok', jsonb_build_object('in', game.param('consultant_usd_mtok_in'),
                                                           'cache_write', game.param('consultant_usd_mtok_cache_write'),
                                                           'cache_read', game.param('consultant_usd_mtok_cache_read'),
                                                           'out', game.param('consultant_usd_mtok_out')));
end $$;

-- consultant_finish from 0030: nothing to refund in a free world
create or replace function public.consultant_finish(p_report uuid, p_ok boolean, p_report_json jsonb, p_tokens_in int,
                                                    p_tokens_cached int, p_tokens_out int, p_cost_usd numeric, p_error text)
returns void
language plpgsql security definer set search_path = '' as $$
declare r public.consultant_reports%rowtype;
begin
  select * into r from public.consultant_reports where id = p_report for update;
  if not found or r.status <> 'working' then raise exception 'No report is being written with that id'; end if;
  update public.consultant_reports
     set status = case when p_ok then 'done' else 'failed' end, report = p_report_json,
         tokens_in = coalesce(p_tokens_in, 0), tokens_cached = coalesce(p_tokens_cached, 0), tokens_out = coalesce(p_tokens_out, 0),
         cost_usd = coalesce(p_cost_usd, 0), error = left(p_error, 500)
   where id = p_report;
  if not p_ok and r.fee_inr > 0 then   -- the fee comes back when no report could be written (a free world pays none)
    perform game.book(r.airline_id, (select game_day + 1 from public.worlds where id = r.world_id), r.fee_inr,
                      'consultant', 'Claude consultant fee refunded', r.fee_inr, true);
  end if;
end $$;

-- create_world from 0028: the consultant choice, written to the world's own values
create or replace function public.create_world(p_name text, p_rules jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_admin boolean := game.is_server() or exists (select 1 from public.profiles where user_id = auth.uid() and is_admin);
  v_name text := trim(p_name);
  r jsonb := coalesce(p_rules, '{}');
  v_rules jsonb := '{}';
  v_set text; v_opt text; v_lic jsonb;
  v_id uuid; v_code text; v_hours numeric; v_places int; v_min int; v_mult numeric;
begin
  if v_uid is null and not game.is_server() then raise exception 'Sign in first'; end if;
  if not v_admin then
    v_lic := game.founder_status(v_uid);
    if v_lic->>'live_world' is not null then raise exception 'You already run a world (%): one at a time', v_lic->>'live_world'; end if;
    if not (v_lic->>'ok')::boolean then
      raise exception 'Found a world after % game quarters running an airline, with an operating profit in the last %',
        v_lic->>'need_quarters', v_lic->>'need_profit_quarters';
    end if;
  end if;
  if v_name is null or length(v_name) not between 3 and 40 then raise exception 'World name must be 3 to 40 characters'; end if;
  if exists (select 1 from public.worlds where lower(name) = lower(v_name)) then raise exception 'That world name is taken'; end if;
  foreach v_set in array array['region', 'pace', 'turn', 'places', 'money', 'banks', 'growth', 'seats', 'shocks', 'bots', 'consultant'] loop
    v_opt := coalesce(r->>v_set, (select option from public.world_options where setting = v_set and is_default));
    if not exists (select 1 from public.world_options where setting = v_set and option = v_opt and available) then
      raise exception 'Choose one of the % options', v_set;
    end if;
    v_rules := v_rules || jsonb_build_object(v_set, v_opt);
  end loop;
  select (vals->>'week_hours')::numeric into v_hours from public.world_options where setting = 'pace' and option = v_rules->>'pace';
  select (vals->>'places')::int into v_places from public.world_options where setting = 'places' and option = v_rules->>'places';
  v_min := game.param('world_min_players')::int;
  if v_admin and r ? 'min_players' then v_min := (r->>'min_players')::int; end if;
  if v_min is null or v_min < 1 or v_min > v_places then raise exception 'Players to start must be between 1 and %', v_places; end if;

  insert into public.worlds (name, speed, max_airlines, demand_scale, founder_id, turn_mode, min_players, join_deadline, rules, bot_scale)
  values (v_name, round(168 / v_hours, 4), v_places, round(v_places / 50.0, 3), v_uid, v_rules->>'turn', v_min,
          now() + make_interval(days => game.param('world_join_days')::int), v_rules,
          case when v_rules->>'bots' = 'none' then 0 else 1 end)
  returning id into v_id;
  v_code := substr(md5(random()::text || clock_timestamp()::text), 1, 8);
  insert into public.world_secrets (world_id, invite_code) values (v_id, v_code);
  -- the game values each choice sets, readable by the world's players
  insert into public.world_params (world_id, key, num, public)
  select v_id, e.key, e.value::numeric, true
    from public.world_options o, jsonb_each_text(o.vals) e
   where o.setting in ('money', 'banks', 'growth', 'seats', 'bots', 'consultant') and o.option = v_rules->>o.setting and e.key <> 'bot_scale';
  -- shocks: how often each comes, against the game's default (not shown to players, as on the Admin screen)
  select (vals->>'prob_mult')::numeric into v_mult from public.world_options where setting = 'shocks' and option = v_rules->>'shocks';
  if v_mult is not null then
    insert into public.world_params (world_id, key, num, public)
    select v_id, k, least(12.0 / 364, game.param(k) * v_mult), false
      from unnest(array['ground_prob_day', 'event_fuel_prob_day', 'event_fx_prob_day', 'event_engine_prob_day']) k;
  end if;
  -- 0028: the newer shocks' own values for the choice (airport and airspace closures, late deliveries, fare caps), hidden
  insert into public.world_params (world_id, key, num, public)
  select v_id, e.key, e.value::numeric, false
    from public.world_options o, jsonb_each_text(o.vals) e
   where o.setting = 'shocks' and o.option = v_rules->>'shocks' and e.key <> 'prob_mult'
  on conflict (world_id, key) do update set num = excluded.num;
  return jsonb_build_object('world_id', v_id, 'invite', v_code);
end $$;
