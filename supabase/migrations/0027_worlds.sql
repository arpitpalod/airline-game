-- Migration 0027 (spec 14.22): worlds with their own rules, founded by players. Part 1 of 3 (owner, 21 Nov 2026).
--  * Founding: a player who has run an airline for 4 game quarters, with an operating profit in the last 2, may found a
--    world (admins at any time). One live world per founder. It starts by itself once 6 players have joined (the
--    scheduler), or closes if that takes more than 7 days. The founder is that world's admin: invite code, pace, pause,
--    places (only upwards once started). Everything else is fixed at the start.
--  * The rules a founder chooses (table world_options, G): region (India only so far), pace (a game week in 15 minutes,
--    1 hour, 4 hours or 1 day; on the clock, or when every player is ready), places, starting money, banks (credit
--    line, interest, rupee aircraft loans, deposits on new aircraft, a debt limit), demand growth, shocks (Calm, Real,
--    Rough) and computer-run airlines (None, Calm, Normal, Fierce). Each choice writes game values into world_params,
--    which the engine reads per world (game.params_for, game.wparam).
--  * Banks: from an airline's fifth quarter, at each week start, debt above the world's limit times the last 4
--    quarters' operating profit (or any debt while those quarters lost money) halves the credit line; it comes back
--    once debt is under the limit again.
--  * When all are ready: in such a world the next week is played as soon as every player has tapped Ready, and at the
--    latest when the clock runs out; the clock then counts the following week from that moment. The scheduler runs
--    every minute (was 5).
-- Parts 2 (four new shocks) and 3 (seat limits between countries) come later.

-- ---------- game values ----------
insert into public.game_params (key, num, note) values
('world_min_players', 6, 'a founded world starts once this many players have joined'),
('world_join_days', 7, 'a founded world closes if it has not filled to its minimum within this many days'),
('founder_quarters', 4, 'quarters of results an airline needs before its owner may found a world'),
('founder_profit_quarters', 2, 'the latest quarters that must show an operating profit to found a world'),
('credit_debt_limit', 0, 'banks: debt above this times the last 4 quarters'' operating profit halves the credit line (0: no limit)'),
('credit_cut_share', 0.5, 'banks: the share of the credit line left when it is cut'),
('bot_aggression_mult', 1, 'computer-run airlines: their aggression times this (fights and fare following)');

-- ---------- the choices a founder makes (G) ----------
create table public.world_options (
  setting text not null,       -- region, pace, turn, places, money, banks, growth, shocks, bots
  option text not null,
  sort int not null,
  label text not null,
  blurb text not null,
  vals jsonb not null default '{}',   -- game values the choice sets (shocks: prob_mult; pace: week_hours; places: places)
  available boolean not null default true,
  is_default boolean not null default false,
  primary key (setting, option)
);
alter table public.world_options enable row level security;
revoke all on public.world_options from anon, authenticated;
grant select on public.world_options to authenticated;
create policy read_all on public.world_options for select to authenticated using (true);

insert into public.world_options (setting, option, sort, label, blurb, vals, available, is_default) values
('region', 'india', 1, 'India', '93 airports', '{}', true, true),
('region', 'middle_east', 2, 'Middle East', 'coming', '{}', false, false),
('region', 'usa', 3, 'USA', 'coming', '{}', false, false),
('region', 'canada', 4, 'Canada', 'coming', '{}', false, false),
('region', 'europe', 5, 'Europe', 'coming', '{}', false, false),
('region', 'africa', 6, 'Africa', 'coming', '{}', false, false),
('region', 'south_america', 7, 'South America', 'coming', '{}', false, false),
('region', 'china', 8, 'China', 'coming', '{}', false, false),
('pace', '15m', 1, '15 min', 'A season (6.5 game years) lasts about 3.5 days.', '{"week_hours": 0.25}', true, false),
('pace', '1h', 2, '1 hour', 'A season lasts about 2 weeks.', '{"week_hours": 1}', true, false),
('pace', '4h', 3, '4 hours', 'A season lasts about 8 weeks.', '{"week_hours": 4}', true, true),
('pace', '1d', 4, '1 day', 'A season lasts about 11 months.', '{"week_hours": 24}', true, false),
('turn', 'clock', 1, 'On the clock', 'Weeks move on time, ready or not. Best for big worlds.', '{}', true, true),
('turn', 'ready', 2, 'When all are ready', 'The week moves as soon as every player taps Ready, and at the latest when the clock runs out. Nobody misses a week. Best for office groups.', '{}', true, false),
('places', '12', 1, '12', 'A small world: travellers, aircraft, pilots and slots for 12 airlines.', '{"places": 12}', true, false),
('places', '25', 2, '25', 'Travellers, aircraft, pilots and slots for 25 airlines.', '{"places": 25}', true, true),
('places', '50', 3, '50', 'A big world: travellers, aircraft, pilots and slots for 50 airlines.', '{"places": 50}', true, false),
('money', '250', 1, '₹250 cr', 'Lean: little room for mistakes. Expansion leans on the banks.', '{"start_cash_inr": 2500000000}', true, false),
('money', '500', 2, '₹500 cr', 'Enough for a careful first year of losses.', '{"start_cash_inr": 5000000000}', true, true),
('money', '1000', 3, '₹1,000 cr', 'Rich: bold growth from day one, and bigger mistakes.', '{"start_cash_inr": 10000000000}', true, false),
('banks', 'easy', 1, 'Easy', 'Cheap money and no debt limit: growth on debt pays, until it does not.',
 '{"credit_limit_inr": 3000000000, "interest_year": 0.08, "loan_rate_inr_year": 0.085, "order_deposit_share": 0.10, "credit_debt_limit": 0}', true, false),
('banks', 'normal', 2, 'Normal', 'The bank steps in only when debt runs far ahead of profit.',
 '{"credit_limit_inr": 2000000000, "interest_year": 0.11, "loan_rate_inr_year": 0.105, "order_deposit_share": 0.15, "credit_debt_limit": 6}', true, true),
('banks', 'tight', 3, 'Tight', 'Banks watch you closely: run debt high and the credit line is cut, as lenders did before airlines failed.',
 '{"credit_limit_inr": 1000000000, "interest_year": 0.15, "loan_rate_inr_year": 0.13, "order_deposit_share": 0.25, "credit_debt_limit": 4}', true, false),
('growth', 'slump', 1, 'Slump', 'Every extra aircraft fights for the same travellers. Fares fall fast.', '{"growth_year": 0.02, "growth_year_intl": 0.06}', true, false),
('growth', 'normal', 2, 'Normal', 'About what India''s forecasts say.', '{"growth_year": 0.07, "growth_year_intl": 0.12}', true, true),
('growth', 'boom', 3, 'Boom', 'Planes fill themselves; aircraft and pilots run short first.', '{"growth_year": 0.12, "growth_year_intl": 0.18}', true, false),
('shocks', 'calm', 1, 'Calm', 'Groundings, fuel shocks, currency swings and engine problems half as often as in reality.', '{"prob_mult": 0.5}', true, false),
('shocks', 'real', 2, 'Real', 'About as often as Indian airlines see them today.', '{}', true, true),
('shocks', 'rough', 3, 'Rough', 'Twice as often as in reality.', '{"prob_mult": 2}', true, false),
('bots', 'none', 1, 'None', 'Only players. Markets stay empty until someone flies them.', '{"bot_scale": 0}', true, false),
('bots', 'calm', 2, 'Calm', 'They fly their networks and rarely fight a newcomer.', '{"bot_aggression_mult": 0.5}', true, false),
('bots', 'normal', 3, 'Normal', 'They fight entries, follow fare cuts and learn what sells.', '{"bot_aggression_mult": 1}', true, true),
('bots', 'fierce', 4, 'Fierce', 'They fight almost every entry, down to their lowest profitable fare.', '{"bot_aggression_mult": 1.6}', true, false);

-- ---------- worlds, airlines, banks ----------
alter table public.worlds
  add column founder_id uuid,                        -- the player who founded it, its admin (null: made by the game's admins)
  add column turn_mode text not null default 'clock' check (turn_mode in ('clock', 'ready')),
  add column min_players int,                        -- a founded world starts once this many players have joined
  add column join_deadline timestamptz,              -- ... or closes at this time
  add column closed_at timestamptz,
  add column rules jsonb not null default '{}';      -- the founder's choices, by setting (world_options)
alter table public.airlines add column ready_day int;   -- When all are ready: the game day this airline was ready to play on from
alter table public.airline_finance add column credit_cut_from numeric;   -- the credit line before a bank cut it

alter table public.world_params add column public boolean not null default false;
create policy read_public on public.world_params for select to authenticated using (public);

-- A world's game values: the game's, with the world's own on top (migration 0025's world_params).
create or replace function game.params_for(p_world uuid) returns jsonb
language sql stable set search_path = '' as $$
  select (select jsonb_object_agg(key, num) from public.game_params)
         || coalesce((select jsonb_object_agg(key, num) from public.world_params where world_id = p_world), '{}'::jsonb)
$$;

create or replace function game.require_world_admin(p_world uuid) returns void
language plpgsql stable set search_path = '' as $$
begin
  if not game.is_server()
     and not exists (select 1 from public.profiles where user_id = auth.uid() and is_admin)
     and not exists (select 1 from public.worlds where id = p_world and founder_id is not null and founder_id = auth.uid()) then
    raise exception 'Only this world''s founder or an admin can do that';
  end if;
end $$;

-- ---------- founding ----------
-- How close a player is to founding a world: their best airline's quarters of results and the latest quarters' operating
-- profit, and any world they already run.
create or replace function game.founder_status(p_uid uuid) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  v_need int := game.param('founder_quarters')::int;
  v_prof int := game.param('founder_profit_quarters')::int;
  b record;
  v_live text;
begin
  select a.id, a.name, w.name as world,
         (select count(*) from public.quarterly_reports q where q.airline_id = a.id) as quarters,
         (select coalesce(jsonb_agg(jsonb_build_object('quarter', x.quarter, 'op_profit', x.op_profit) order by x.quarter desc), '[]')
            from (select quarter, op_profit from public.quarterly_reports q where q.airline_id = a.id order by quarter desc limit v_prof) x) as last
    into b
    from public.airlines a join public.worlds w on w.id = a.world_id
   where a.user_id = p_uid
   order by (select count(*) from public.quarterly_reports q where q.airline_id = a.id) desc,
            (select coalesce(sum(op_profit), 0) from (select op_profit from public.quarterly_reports q where q.airline_id = a.id
                                                       order by quarter desc limit v_prof) y) desc
   limit 1;
  select name into v_live from public.worlds where founder_id = p_uid and status in ('setup', 'running', 'paused') limit 1;
  return jsonb_build_object(
    'need_quarters', v_need, 'need_profit_quarters', v_prof, 'live_world', v_live,
    'airline', b.name, 'world', b.world, 'quarters', coalesce(b.quarters, 0), 'last', coalesce(b.last, '[]'),
    'ok', v_live is null and coalesce(b.quarters, 0) >= v_need and jsonb_array_length(coalesce(b.last, '[]')) >= v_prof
          and not exists (select 1 from jsonb_array_elements(b.last) e where (e->>'op_profit')::numeric <= 0));
end $$;

create or replace function public.founder_status() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  return game.founder_status(auth.uid())
         || jsonb_build_object('admin', exists (select 1 from public.profiles where user_id = auth.uid() and is_admin));
end $$;

-- Found a world. p_rules: {"region": "india", "pace": "4h", "turn": "clock", "places": "25", "money": "500", "banks": "normal",
-- "growth": "normal", "shocks": "real", "bots": "normal"}; a missing setting takes its default. Admins may also give
-- "min_players" (1 to the places). Returns the world's id and invite code.
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
  foreach v_set in array array['region', 'pace', 'turn', 'places', 'money', 'banks', 'growth', 'shocks', 'bots'] loop
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
   where o.setting in ('money', 'banks', 'growth', 'bots') and o.option = v_rules->>o.setting and e.key <> 'bot_scale';
  -- shocks: how often each comes, against the game's default (not shown to players, as on the Admin screen)
  select (vals->>'prob_mult')::numeric into v_mult from public.world_options where setting = 'shocks' and option = v_rules->>'shocks';
  if v_mult is not null then
    insert into public.world_params (world_id, key, num, public)
    select v_id, k, least(12.0 / 364, game.param(k) * v_mult), false
      from unnest(array['ground_prob_day', 'event_fuel_prob_day', 'event_fx_prob_day', 'event_engine_prob_day']) k;
  end if;
  return jsonb_build_object('world_id', v_id, 'invite', v_code);
end $$;

create or replace function public.set_turn_mode(p_world uuid, p_mode text) returns text
language plpgsql security definer set search_path = '' as $$
declare w public.worlds%rowtype;
begin
  perform game.require_world_admin(p_world);
  if p_mode is null or p_mode not in ('clock', 'ready') then raise exception 'Choose clock or ready'; end if;
  select * into w from public.worlds where id = p_world for update;
  if not found then raise exception 'World not found'; end if;
  if w.status = 'ended' then raise exception 'This season is over'; end if;
  if w.turn_mode = p_mode then return p_mode; end if;
  update public.worlds set turn_mode = p_mode, rules = rules || jsonb_build_object('turn', p_mode) where id = p_world;
  if w.status <> 'setup' then
    insert into public.news (world_id, game_day, kind, body, private)
    values (p_world, w.game_day, 'world', case when p_mode = 'ready'
      then 'From now on the next week is played as soon as every player taps Ready, and at the latest when the clock runs out.'
      else 'From now on weeks move on the clock, ready or not.' end, false);
  end if;
  return p_mode;
end $$;

-- When all are ready: an airline marks itself ready for the next week (or takes it back).
create or replace function public.set_ready(p_airline uuid, p_ready boolean default true) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare rw public.worlds%rowtype; v_wait int; v_all int;
begin
  rw := game.actor(p_airline, false);
  if rw.status <> 'running' then raise exception 'This world is not running'; end if;
  if rw.turn_mode <> 'ready' then raise exception 'This world moves on the clock'; end if;
  update public.airlines set ready_day = case when coalesce(p_ready, true) then rw.game_day end where id = p_airline;
  select count(*) filter (where coalesce(ready_day, -1) < rw.game_day), count(*) into v_wait, v_all
    from public.airlines where world_id = rw.id and not is_ai and status = 'active';
  return jsonb_build_object('ready', coalesce(p_ready, true), 'waiting_for', v_wait, 'players', v_all, 'week', game.week_of(rw.game_day + 1));
end $$;

-- A world founded by a player is open while it waits for players: anyone signed in may take its invite code from the
-- Worlds screen. Worlds made by the game's admins, and founded worlds once started, need the invite link.
create or replace function public.world_join_code(p_world uuid) returns text
language plpgsql stable security definer set search_path = '' as $$
declare w public.worlds%rowtype; v_code text;
begin
  if auth.uid() is null and not game.is_server() then raise exception 'Sign in first'; end if;
  select * into w from public.worlds where id = p_world;
  if not found or w.founder_id is null or w.status <> 'setup' then raise exception 'This world takes players by invite only'; end if;
  if (select count(*) from public.airlines a where a.world_id = p_world and not a.is_ai) >= w.max_airlines then
    raise exception 'This world is full';
  end if;
  select invite_code into v_code from public.world_secrets where world_id = p_world;
  return v_code;
end $$;

-- ---------- banks ----------
-- At each week start (ops_week): from an airline's fifth quarter, debt above the world's limit times the last 4 quarters'
-- operating profit, or any debt while those quarters lost money, halves the credit line; it comes back once debt is
-- under the limit again.
create or replace function game.bank_week(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  v_limit numeric := game.wparam(p_world, 'credit_debt_limit');
  r record;
  v_line numeric;
begin
  if coalesce(v_limit, 0) <= 0 then return; end if;
  for r in
    select al.id, fin.debt_inr, fin.credit_limit_inr, fin.credit_cut_from, q.n, q.op
      from public.airlines al
      join public.airline_finance fin on fin.airline_id = al.id
      cross join lateral (select count(*) as n, coalesce(sum(op_profit), 0) as op
                            from (select op_profit from public.quarterly_reports where airline_id = al.id order by quarter desc limit 4) x) q
     where al.world_id = p_world and not al.is_ai and al.status = 'active'
  loop
    continue when r.n < 4;
    if r.debt_inr > 0 and (r.op <= 0 or r.debt_inr > v_limit * r.op) then
      if r.credit_cut_from is null then
        v_line := round(r.credit_limit_inr * game.param('credit_cut_share'));
        update public.airline_finance set credit_cut_from = credit_limit_inr, credit_limit_inr = v_line where airline_id = r.id;
        insert into public.news (world_id, game_day, airline_id, kind, body, private)
        values (p_world, p_day, r.id, 'bank', format('Your bank cut your credit line to Rs %s cr: %s, and this world''s banks allow debt of at most %s times a year''s operating profit. Bring debt down or earn more, and the full line comes back.',
          round(v_line / 1e7), case when r.op <= 0 then 'your last 4 quarters lost money while you owe Rs ' || round(r.debt_inr / 1e7) || ' cr'
                                     else 'debt is ' || round(r.debt_inr / r.op, 1) || ' times your last 4 quarters'' operating profit' end,
          v_limit), true);
      end if;
    elsif r.credit_cut_from is not null then
      update public.airline_finance set credit_limit_inr = greatest(credit_limit_inr, credit_cut_from), credit_cut_from = null where airline_id = r.id;
      insert into public.news (world_id, game_day, airline_id, kind, body, private)
      values (p_world, p_day, r.id, 'bank', format('Your bank restored your credit line to Rs %s cr: debt is back within the limit.',
              round(r.credit_cut_from / 1e7)), true);
    end if;
  end loop;
end $$;

-- ops_week from 0026: banks check debt each week (0027)
create or replace function game.ops_week(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  v_w int := game.week_of(p_day);
  v_lead int := game.param('hedge_lead_weeks')::int;
begin
  -- G: the fuel price fares follow moves fuel_fare_smooth of the way to today's price each week; fares follow fuel_pass of
  -- the change in fuel cost per passenger (fuel_fare_share of the reference fare at fuel_ref_inr_kg)
  update public.worlds w
     set fuel_avg = round((coalesce(w.fuel_avg, w.fuel_inr_kg) * (1 - game.param('fuel_fare_smooth'))
                           + w.fuel_inr_kg * game.param('fuel_fare_smooth'))::numeric, 2)
   where w.id = p_world;
  update public.worlds w
     set fare_index = round((1 + game.param('fuel_pass') * game.param('fuel_fare_share')
                                 * (w.fuel_avg / game.param('fuel_ref_inr_kg') - 1))::numeric, 4)
   where w.id = p_world;
  select * into rw from public.worlds where id = p_world;
  insert into public.fuel_hedges (airline_id, week, share, price_inr_kg)
  select ao.airline_id, v_w + v_lead, ao.hedge_share, round(rw.fuel_inr_kg * (1 + game.param('hedge_premium')), 2)
    from public.airline_ops ao join public.airlines al on al.id = ao.airline_id
   where al.world_id = p_world and al.status = 'active' and ao.hedge_share > 0
  on conflict (airline_id, week) do update set share = excluded.share, price_inr_kg = excluded.price_inr_kg;
  delete from public.fuel_hedges fh using public.airlines al
   where al.id = fh.airline_id and al.world_id = p_world and fh.week < v_w;
  -- 0026: dollars bought ahead for the same week, for that share of the week's dollar costs, at today's rate plus a premium
  insert into public.usd_hedges (airline_id, week, share, rate_inr_usd)
  select ao.airline_id, v_w + v_lead, ao.usd_hedge_share, round(rw.fx_inr_usd * (1 + game.param('usd_hedge_premium')), 3)
    from public.airline_ops ao join public.airlines al on al.id = ao.airline_id
   where al.world_id = p_world and al.status = 'active' and ao.usd_hedge_share > 0
  on conflict (airline_id, week) do update set share = excluded.share, rate_inr_usd = excluded.rate_inr_usd;
  delete from public.usd_hedges uh using public.airlines al
   where al.id = uh.airline_id and al.world_id = p_world and uh.week < v_w;
  perform game.bank_week(p_world, p_day);   -- 0027: banks check debt against the world's limit
end $$;

-- bot_selling from 0025: the world's computer-run airlines are calmer or fiercer (0027)
create or replace function game.bot_selling(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  v_w int := game.week_of(p_day);
  g record;
begin
  select * into g from jsonb_to_record((select jsonb_object_agg(key, num) from public.game_params)) as x(
    bot_review_weeks int, bot_explore_prob float8, bot_switch_gain float8, bot_fight_weeks int, bot_follow_cut float8);

  -- last week a player started flying one of its markets (it may fight with low fares) or cut fares there (it may follow)
  with mv as (
    select distinct on (m.a, m.b) m.a, m.b, case when m.kind = 'enter' and game.param('bot_fight_follow') = 0 then 'fill' else 'follow' end as answer
      from public.market_moves m join public.airlines al on al.id = m.airline_id and not al.is_ai
     where m.world_id = p_world and m.week = v_w - 1
       and (m.kind = 'enter' or (m.kind = 'fare_down' and m.new_value <= m.old_value * (1 - g.bot_follow_cut)))
     order by m.a, m.b, case when m.kind = 'enter' then 0 else 1 end)
  update public.route_plans pl
     set prev_strategy = pl.strategy, strategy = mv.answer, fight_until = v_w + g.bot_fight_weeks,
         -- 0025: where between its profitable lowest fare (0) and the player's fare (1) it fights; aggressive airlines draw lower
         fight_pos = case when game.param('bot_fight_random') > 0 then power(random(), least(1, b.aggression * game.wparam(p_world, 'bot_aggression_mult')) * game.param('bot_fight_skew')) end
    from public.routes r
    join public.airlines al on al.id = r.airline_id and al.is_ai and al.status = 'active'
    join public.bot_airlines b on b.code = al.code
    join mv on mv.a = least(r.origin, r.dest) and mv.b = greatest(r.origin, r.dest)
   where pl.route_id = r.id and r.world_id = p_world and r.status = 'open' and pl.fight_until is null
     and random() < least(1, b.aggression * game.wparam(p_world, 'bot_aggression_mult'));

  -- reviews, a few routes each week: move to a way that earned clearly more per seat than its own way on routes like it
  -- (What works where), or now and then try another way at random
  with own as (
    select x.route_id, m.a, m.b, m.km, m.intl,
           sum(x.rev_flown_e + x.rev_flown_b) / nullif(sum((x.seats_e + x.seats_b) * m.ref_fare), 0) as idx
      from public.route_weeks x
      join public.routes r on r.id = x.route_id
      join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
     where x.world_id = p_world and x.flown_e is not null and x.week >= v_w - 8
     group by x.route_id, m.a, m.b, m.km, m.intl),
  shp as (select a, b, count(*) as n from public.market_watch where world_id = p_world and trips > 0 group by a, b),
  cand as (
    select pl.route_id, pl.strategy, o.idx,
           case when o.intl then 'intl' when o.km < 800 then 'short' when o.km < 1800 then 'medium' else 'long' end as band,
           case when coalesce(s.n, 1) <= 1 then 'alone' when s.n = 2 then 'two' when s.n <= 4 then 'few' else 'many' end as shape
      from public.route_plans pl
      join public.routes r on r.id = pl.route_id and r.world_id = p_world and r.status = 'open'
      join public.airlines al on al.id = r.airline_id and al.is_ai and al.status = 'active'
      join own o on o.route_id = pl.route_id
      left join shp s on s.a = o.a and s.b = o.b
     where pl.fight_until is null and (v_w + abs(hashtext(pl.route_id::text))) % greatest(1, g.bot_review_weeks) = 0),
  best as (
    select distinct on (c.route_id) c.route_id, si.strategy, si.rev_index
      from cand c join public.sector_insights si on si.world_id = p_world and si.band = c.band and si.shape = c.shape
     order by c.route_id, si.rev_index desc),
  -- how its own way did on routes like it (or, with too few such routes, how the route itself did)
  mine as (
    select c.route_id, coalesce(si.rev_index, c.idx, 0) as v
      from cand c left join public.sector_insights si on si.world_id = p_world and si.band = c.band and si.shape = c.shape
                                                     and si.strategy = c.strategy),
  pick as (
    select c.route_id,
           case when b.strategy is not null and b.strategy <> c.strategy and b.rev_index > mi.v * (1 + g.bot_switch_gain)
                then b.strategy
                when random() < g.bot_explore_prob
                then (select k.key from public.rm_strategies k where k.key <> c.strategy order by random() limit 1)
                else c.strategy end as s
      from cand c join mine mi on mi.route_id = c.route_id left join best b on b.route_id = c.route_id)
  update public.route_plans pl set strategy = p.s from pick p where pl.route_id = p.route_id and pl.strategy <> p.s;

  -- fights that are over: back to the way it sold before (after the reviews, so its first week back is not reviewed)
  update public.route_plans pl set strategy = coalesce(pl.prev_strategy, pl.strategy), prev_strategy = null, fight_until = null, fight_pos = null
    from public.routes r
   where r.id = pl.route_id and r.world_id = p_world and pl.fight_until is not null and pl.fight_until <= v_w;
end $$;

-- day_ops from 0026: reads the world's own game values (interest, rupee loans) (0027)
create or replace function game.day_ops(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  g record;
  v_sb numeric; v_sl numeric; v_su numeric; v_grow numeric;
  v_pbh numeric; v_res numeric := game.param('pilot_reserve'); v_aug_bh numeric := game.param('pilot_aug_bh'); v_aug numeric := game.param('pilot_aug_mult');
begin
  select * into rw from public.worlds where id = p_world;
  select * into g from jsonb_to_record(game.params_for(p_world)) as x(   -- 0027: the world's own values
    seg_biz_a numeric, seg_biz_price numeric, seg_biz_freq numeric, seg_biz_comfort numeric, seg_biz_brand numeric,
    seg_lei_a numeric, seg_lei_price numeric, seg_lei_freq numeric, seg_lei_comfort numeric, seg_lei_brand numeric,
    seg_bud_a numeric, seg_bud_price numeric, seg_bud_freq numeric, seg_bud_comfort numeric, seg_bud_brand numeric,
    biz_fare_mult numeric, spill_recapture numeric, ancillary_share numeric, demand_noise_sd numeric,
    growth_year numeric, season_start_month numeric, age_fuel_per_year numeric, age_maint_per_year numeric,
    maint_fh_offset numeric, cabin_inr_bh numeric, cabin_fixed_inr_day numeric, intl_airport_mult numeric,
    handling_inr_pax numeric, slot_base_inr numeric, slot_util_cap numeric, dist_rev_share numeric,
    service_inr_pax numeric, wet_min_hours_day numeric, depreciation_year numeric, overhead_fixed_inr_day numeric,
    overhead_aircraft_inr_day numeric, overhead_seat_inr_day numeric, base_fixed_inr_day numeric, interest_year numeric, otp_base numeric,
    otp_util_k numeric, otp_smooth numeric, brand_drift numeric, brand_otp_ref numeric, brand_otp_k numeric, brand_cancel_k numeric,
    brand_comfort_ref numeric, brand_comfort_k numeric, brand_mkt_max numeric, brand_mkt_inr_pax numeric,
    brand_mkt_min_pax numeric, route_keep_days numeric, nest_lambda numeric, biz_downgrade_share numeric, seg_biz_cabin_a numeric,
    loan_rate_year numeric, anc_biz_share numeric, slot_ref_seats numeric);

  select biz, lei, bud into v_sb, v_sl, v_su from public.season_factors
   where month = ((g.season_start_month::int - 1 + (((p_day - 1) % 364) * 12) / 364) % 12) + 1;
  v_grow := power(1 + g.growth_year, (p_day - 1) / 364.0) * rw.demand_scale;

  create temp table if not exists _rot (   -- one row per aircraft per route
    route_id uuid, airline_id uuid, aircraft_id uuid, type_id text, a text, b text, km int, intl boolean,
    f numeric,                -- round trips a day
    flown boolean, wet boolean, seats_e int, seats_b int, comf_e numeric, comf_b numeric,
    block_h numeric, turn_min numeric, age_y numeric, crew int,
    fuel_kg numeric default 0, c_fuel numeric default 0, c_crew numeric default 0, c_maint numeric default 0,
    c_airport numeric default 0, c_slots numeric default 0
  ) on commit drop;
  create temp table if not exists _prod (  -- one row per airline per market: what it offers and what it sells
    route_id uuid primary key, airline_id uuid, a text, b text, km int,
    f numeric, f_b numeric, cap_e numeric, cap_b numeric,   -- flights and seats a day, each way
    comf_e numeric, comf_b numeric, block_h numeric, fare_e numeric, fare_b numeric, ref numeric, brand numeric,
    n_biz numeric, n_lei numeric, n_bud numeric,
    xb_e numeric, xb_b numeric, xl numeric, xu numeric,     -- exp(utility / lambda) by segment and cabin
    d_be numeric, d_bb numeric, d_l numeric, d_u numeric,   -- demand by segment: business in economy, in business, leisure, budget
    dg numeric,                                             -- business travellers moved down to economy
    dem_e numeric, dem_b numeric, pax_e numeric, pax_b numeric, spill numeric,
    pe numeric, pb numeric, rev numeric,                     -- both directions
    ad_b numeric, ad_l numeric, ad_u numeric,               -- extras: change in perceived fare by segment, in reference fares
    an_y numeric, an_c numeric, anc numeric, anc_cost numeric, -- extras: revenue and cost per economy passenger (reference fares), totals
    refund numeric default 0,                               -- selling worlds: money back for today's cancelled flights
    sales_x numeric default 0                               -- 0026: sales team abroad on international routes
  ) on commit drop;
  create temp table if not exists _acx (   -- migration 0017: what holding each aircraft costs today, and the hours it flew
    aircraft_id uuid primary key, airline_id uuid, fixed numeric, bh numeric
  ) on commit drop;
  truncate pg_temp._rot, pg_temp._prod, pg_temp._acx;

  -- Ops (migration 0023): each airline's maintenance strategy, operating style and this week's fuel hedge
  create temp table if not exists _ops (
    airline_id uuid primary key, rate numeric, age_k numeric, fixed_day numeric, fuel_mult numeric, hour_mult numeric,
    turn_d numeric, allowance numeric, otp_d numeric, brand_d numeric, h_share numeric, h_price numeric,
    fx numeric                                     -- 0026: the airline's rupees a dollar this week, with its dollar hedge
  ) on commit drop;
  truncate pg_temp._ops;
  insert into pg_temp._ops
  select al.id, coalesce(mp.rate_mult, 1), coalesce(mp.age_k, g.age_maint_per_year), coalesce(mp.fixed_inr_week, 0) / 7,
         coalesce(st.fuel_mult, 1), coalesce(st.hour_cost_mult, 1), coalesce(st.turn_delta_min, 0), coalesce(st.allowance_inr_turn, 0),
         coalesce(mp.otp_delta, 0) + coalesce(st.otp_delta, 0), coalesce(st.brand_delta, 0),
         coalesce(fh.share, 0), coalesce(fh.price_inr_kg, rw.fuel_inr_kg),
         coalesce(uh.share, 0) * coalesce(uh.rate_inr_usd, rw.fx_inr_usd) + (1 - coalesce(uh.share, 0)) * rw.fx_inr_usd
    from public.airlines al
    left join public.airline_ops ao on ao.airline_id = al.id
    left join public.maint_plans mp on mp.key = ao.maint_plan
    left join public.op_styles st on st.key = ao.op_style
    left join public.fuel_hedges fh on fh.airline_id = al.id and fh.week = game.week_of(p_day)
    left join public.usd_hedges uh on uh.airline_id = al.id and uh.week = game.week_of(p_day)
   where al.world_id = p_world and al.status = 'active';

  -- Step 3: capacity from the rotations of aircraft in service (grounded aircraft cancel their flights)
  insert into pg_temp._rot (route_id, airline_id, aircraft_id, type_id, a, b, km, intl, f, flown, wet,
                            seats_e, seats_b, comf_e, comf_b, block_h, turn_min, age_y, crew)
  select r.id, r.airline_id, ac.id, ac.type_id, m.a, m.b, m.km, m.intl, ro.weekly_trips / 7.0,
         ac.status = 'active', tm.holding = 'wet', ac.seats_econ, ac.seats_biz,
         (ac.econ_pitch - 28) / 6.0,
         case when ac.seats_biz = 0 then 0 when t.biz_kind = 'lieflat' then 2.6 else 1.6 + (ac.biz_pitch - 36) / 12.0 end,
         m.km::numeric / t.cruise_kmh + t.block_offset_h,
         greatest(t.base_turn_min - 5, t.base_turn_min + 0.1 * (ac.seats_econ + ac.seats_biz - t.ref_seats)),
         greatest(0, p_day - ac.built_day) / 364.0,
         game.cabin_crew(rw.crew_rule, ac.seats_econ + ac.seats_biz)
    from public.routes r
    join public.airlines al on al.id = r.airline_id and al.status = 'active' and al.first_flight_day <= p_day
    join public.rotations ro on ro.route_id = r.id
    join public.aircraft ac on ac.id = ro.aircraft_id and ac.airline_id = r.airline_id and ac.status in ('active', 'grounded')
    join public.aircraft_types t on t.id = ac.type_id
    join public.aircraft_terms tm on tm.aircraft_id = ac.id
    join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
   where r.world_id = p_world and r.status = 'open' and r.first_flight_day <= p_day;

  -- an idle aircraft (no rotations) of the same type at the same base flies a grounded aircraft's rotations
  with gr as (
    select x.aircraft_id, x.airline_id, x.type_id, ac.base_iata,
           row_number() over (partition by x.airline_id, x.type_id, ac.base_iata order by x.aircraft_id) as n
      from (select distinct aircraft_id, airline_id, type_id from pg_temp._rot where not flown) x
      join public.aircraft ac on ac.id = x.aircraft_id),
  sp as (
    select ac.*, tm.holding,
           row_number() over (partition by ac.airline_id, ac.type_id, ac.base_iata order by ac.id) as n
      from public.aircraft ac
      join public.aircraft_terms tm on tm.aircraft_id = ac.id
     where ac.world_id = p_world and ac.status = 'active' and ac.airline_id is not null
       and not exists (select 1 from public.rotations ro where ro.aircraft_id = ac.id))
  update pg_temp._rot x
     set aircraft_id = sp.id, flown = true, wet = sp.holding = 'wet', seats_e = sp.seats_econ, seats_b = sp.seats_biz,
         comf_e = (sp.econ_pitch - 28) / 6.0,
         comf_b = case when sp.seats_biz = 0 then 0 when t.biz_kind = 'lieflat' then 2.6 else 1.6 + (sp.biz_pitch - 36) / 12.0 end,
         turn_min = greatest(t.base_turn_min - 5, t.base_turn_min + 0.1 * (sp.seats_econ + sp.seats_biz - t.ref_seats)),
         age_y = greatest(0, p_day - sp.built_day) / 364.0,
         crew = game.cabin_crew(rw.crew_rule, sp.seats_econ + sp.seats_biz)
    from gr
    join sp on sp.airline_id = gr.airline_id and sp.type_id = gr.type_id and sp.base_iata = gr.base_iata and sp.n = gr.n
    join public.aircraft_types t on t.id = sp.type_id
   where x.aircraft_id = gr.aircraft_id and not x.flown;

  -- operating style (0023): every turnaround changes by the style's minutes, never below the floor
  update pg_temp._rot x set turn_min = greatest(game.param('turn_floor_min'), x.turn_min + o.turn_d)
    from pg_temp._ops o where o.airline_id = x.airline_id and o.turn_d <> 0;

  -- pilots (migration 0013): an airline short of crew for a fleet family cancels flights at random until the rest can be crewed.
  -- A family's crews can fly least(captains, first officers) x hours per pilot / (1 + reserve) block hours a day.
  if rw.pilots then
    v_pbh := game.pilot_bh(p_world, p_day);
    update pg_temp._rot x set flown = false
      from (select z.rid
              from (select x2.ctid as rid, x2.airline_id, t.pilot_family as family,
                           sum(2 * x2.f * x2.block_h * case when x2.block_h > v_aug_bh then v_aug else 1 end)
                             over (partition by x2.airline_id, t.pilot_family order by random() rows unbounded preceding) as cum
                      from pg_temp._rot x2 join public.aircraft_types t on t.id = x2.type_id
                     where x2.flown and not x2.wet) z
              left join public.airline_pilots ap on ap.airline_id = z.airline_id and ap.family = z.family
             where z.cum > coalesce(least(ap.captains, ap.fos), 0) * v_pbh / (1 + v_res) + 1e-6) c
     where x.ctid = c.rid;
  end if;

  -- Step 4: demand. Market size today, then each airline's share, then spill.
  insert into pg_temp._prod (route_id, airline_id, a, b, km, f, f_b, cap_e, cap_b, comf_e, comf_b, block_h,
                             fare_e, fare_b, ref, brand, n_biz, n_lei, n_bud, ad_b, ad_l, ad_u, an_y, an_c)
  with ax as materialized (   -- each airline's extras, set for its whole network
    select q.airline_id, t.d_biz, t.d_lei, t.d_bud, t.yield, t.cost
      from (select distinct airline_id from pg_temp._rot where flown) q cross join lateral game.anc_terms(q.airline_id) t),
  mk as materialized (
    select q.a, q.b, exp(g.demand_noise_sd * game.rand_normal() - g.demand_noise_sd * g.demand_noise_sd / 2) * v_grow as k
      from (select distinct a, b from pg_temp._rot where flown) q)
  select s.route_id, s.airline_id, s.a, s.b, s.km, s.f, s.f_b, s.cap_e, s.cap_b, coalesce(s.comf_e, 0), coalesce(s.comf_b, 0),
         s.block_h, r.fare_econ, coalesce(r.fare_biz, round(m.ref_fare * g.biz_fare_mult)), m.ref_fare, al.brand,
         m.n_biz * v_sb * mk.k, m.n_lei * v_sl * mk.k, m.n_bud * v_su * mk.k,
         ax.d_biz, ax.d_lei, ax.d_bud, ax.yield, ax.cost
    from (select route_id, airline_id, a, b, km, sum(f) as f, coalesce(sum(f) filter (where seats_b > 0), 0) as f_b,
                 sum(f * seats_e) as cap_e, sum(f * seats_b) as cap_b,
                 sum(f * seats_e * comf_e) / nullif(sum(f * seats_e), 0) as comf_e,
                 sum(f * seats_b * comf_b) / nullif(sum(f * seats_b), 0) as comf_b,
                 sum(f * block_h) / sum(f) as block_h
            from pg_temp._rot where flown group by route_id, airline_id, a, b, km) s
    join public.routes r on r.id = s.route_id
    join public.airlines al on al.id = s.airline_id
    join public.markets m on m.a = s.a and m.b = s.b
    join mk on mk.a = s.a and mk.b = s.b
    join ax on ax.airline_id = s.airline_id;

  if rw.selling then
    -- Selling worlds (migration 0019): today's passengers are a seventh of the week's bookings who turned up and could
    -- board; each fare counts as paid (no-shows' fares with them). Flights cancelled today refund their passengers.
    update pg_temp._prod p
       set pax_e = least(p.cap_e, coalesce(w.flown_e, 0) / 7), pax_b = least(p.cap_b, coalesce(w.flown_b, 0) / 7),
           fare_e = coalesce(w.rev_flown_e / nullif(w.flown_e, 0), p.fare_e),
           fare_b = coalesce(w.rev_flown_b / nullif(w.flown_b, 0), p.fare_b),
           refund = 2 * (greatest(0, coalesce(w.flown_e, 0) / 7 - p.cap_e) * coalesce(w.rev_e / nullif(w.bk_be + w.bk_l + w.bk_u, 0), 0)
                       + greatest(0, coalesce(w.flown_b, 0) / 7 - p.cap_b) * coalesce(w.rev_b / nullif(w.bk_b, 0), 0))
      from public.route_weeks w
     where w.route_id = p.route_id and w.week = game.week_of(p_day);
    update pg_temp._prod set pax_e = coalesce(pax_e, 0), pax_b = coalesce(pax_b, 0), dem_e = 0, dem_b = 0, dg = 0,
                             refund = coalesce(refund, 0);
  else
    -- U = a - b x fare / reference + c x ln(1 + flights) + d x comfort x sqrt(block hours) + e x (brand - 50) / 50
    -- Nested logit: the airlines form one group against the option of not flying.
    -- x = exp(U / lambda); with S the sum of x on the market, P(fly) = S^lambda / (1 + S^lambda), and an airline's share of fliers is x / S.
    update pg_temp._prod set
      xb_e = case when cap_e > 0 then exp(((g.seg_biz_a - g.seg_biz_price * (fare_e / ref + ad_b) + g.seg_biz_freq * ln(1 + f)
               + g.seg_biz_comfort * comf_e * sqrt(block_h) + g.seg_biz_brand * (brand - 50) / 50) / g.nest_lambda)::float8) else 0 end,
      xb_b = case when cap_b > 0 then exp(((g.seg_biz_a + g.seg_biz_cabin_a - g.seg_biz_price * fare_b / (ref * g.biz_fare_mult) + g.seg_biz_freq * ln(1 + f_b)
               + g.seg_biz_comfort * comf_b * sqrt(block_h) + g.seg_biz_brand * (brand - 50) / 50) / g.nest_lambda)::float8) else 0 end,
      xl   = case when cap_e > 0 then exp(((g.seg_lei_a - g.seg_lei_price * (fare_e / ref + ad_l) + g.seg_lei_freq * ln(1 + f)
               + g.seg_lei_comfort * comf_e * sqrt(block_h) + g.seg_lei_brand * (brand - 50) / 50) / g.nest_lambda)::float8) else 0 end,
      xu   = case when cap_e > 0 then exp(((g.seg_bud_a - g.seg_bud_price * (fare_e / ref + ad_u) + g.seg_bud_freq * ln(1 + f)
               + g.seg_bud_comfort * comf_e * sqrt(block_h) + g.seg_bud_brand * (brand - 50) / 50) / g.nest_lambda)::float8) else 0 end;

    update pg_temp._prod p
       set d_be = p.n_biz * p.xb_e * s.kb, d_bb = p.n_biz * p.xb_b * s.kb, d_l = p.n_lei * p.xl * s.kl, d_u = p.n_bud * p.xu * s.ku
      from (select route_id, game.nest_k(sum(xb_e + xb_b) over mkt, g.nest_lambda) as kb,
                   game.nest_k(sum(xl) over mkt, g.nest_lambda) as kl, game.nest_k(sum(xu) over mkt, g.nest_lambda) as ku
              from pg_temp._prod window mkt as (partition by a, b)) s
     where s.route_id = p.route_id;

    -- Business cabin. When it is full, part of the overflow takes economy on the same airline; the rest is spilled.
    -- Spilled travellers try airlines with seats left in the same cabin, in proportion to how attractive they are:
    -- a share spill_recapture x P(fly | airlines with seats) / P(fly | all airlines) finds a seat.
    update pg_temp._prod p
       set dem_b = p.d_bb, dg = g.biz_downgrade_share * greatest(p.d_bb - p.cap_b, 0),
           pax_b = least(p.d_bb, p.cap_b)
                   + case when p.cap_b > p.d_bb and s.sf > 0
                          then least(p.cap_b - p.d_bb, s.r * s.sp * p.xb_b / s.sf) else 0 end
      from (select route_id, sp, sf,
                   g.spill_recapture * least(1, game.nest_p(sf, g.nest_lambda) / nullif(game.nest_p(st, g.nest_lambda), 0)) as r
              from (select route_id,
                           sum((1 - g.biz_downgrade_share) * greatest(d_bb - cap_b, 0)) over mkt as sp,
                           sum(case when cap_b > d_bb then xb_b else 0 end) over mkt as sf,
                           sum(xb_e + xb_b) over mkt as st
                      from pg_temp._prod window mkt as (partition by a, b)) z) s
     where s.route_id = p.route_id;

    -- Economy cabin, with the business travellers who moved down.
    update pg_temp._prod set dem_e = d_be + dg + d_l + d_u;
    update pg_temp._prod p
       set pax_e = least(p.dem_e, p.cap_e)
                   + case when p.cap_e > p.dem_e then least(p.cap_e - p.dem_e,
                            coalesce(s.rb * s.spb * p.xb_e / nullif(s.sfb, 0), 0)
                          + coalesce(s.rl * s.spl * p.xl / nullif(s.sfl, 0), 0)
                          + coalesce(s.ru * s.spu * p.xu / nullif(s.sfu, 0), 0)) else 0 end
      from (select route_id, spb, spl, spu, sfb, sfl, sfu,
                   g.spill_recapture * least(1, game.nest_p(sfb, g.nest_lambda) / nullif(game.nest_p(stb, g.nest_lambda), 0)) as rb,
                   g.spill_recapture * least(1, game.nest_p(sfl, g.nest_lambda) / nullif(game.nest_p(stl, g.nest_lambda), 0)) as rl,
                   g.spill_recapture * least(1, game.nest_p(sfu, g.nest_lambda) / nullif(game.nest_p(stu, g.nest_lambda), 0)) as ru
              from (select route_id,
                           sum(case when dem_e > cap_e then (dem_e - cap_e) * (d_be + dg) / dem_e else 0 end) over mkt as spb,
                           sum(case when dem_e > cap_e then (dem_e - cap_e) * d_l / dem_e else 0 end) over mkt as spl,
                           sum(case when dem_e > cap_e then (dem_e - cap_e) * d_u / dem_e else 0 end) over mkt as spu,
                           sum(case when cap_e > dem_e then xb_e else 0 end) over mkt as sfb,
                           sum(case when cap_e > dem_e then xl else 0 end) over mkt as sfl,
                           sum(case when cap_e > dem_e then xu else 0 end) over mkt as sfu,
                           sum(xb_e + xb_b) over mkt as stb, sum(xl) over mkt as stl, sum(xu) over mkt as stu
                      from pg_temp._prod window mkt as (partition by a, b)) z) s
     where s.route_id = p.route_id;
  end if;

  update pg_temp._prod
     set spill = greatest(dem_e - cap_e, 0) + greatest(dem_b - cap_b, 0) - dg,
         pe = round(2 * pax_e), pb = round(2 * pax_b), rev = round(2 * pax_e) * fare_e + round(2 * pax_b) * fare_b,
         anc = round(2 * pax_e) * ref * an_y + round(2 * pax_b) * fare_b * g.anc_biz_share,
         anc_cost = round(2 * pax_e) * ref * an_c;

  -- 0026: a sales team abroad costs a share of an international route's revenue
  update pg_temp._prod p set sales_x = p.rev * po.sales_cost_share
    from public.route_plans rp join public.pos_options po on po.key = rp.sell_where, public.markets m
   where rw.selling and rp.route_id = p.route_id and m.a = p.a and m.b = p.b and m.intl and po.sales_cost_share > 0;

  if rw.selling then   -- travellers turned away while the week was on sale, a seventh a day
    update pg_temp._prod p set spill = coalesce(w.spill, 0) / 7
      from public.route_weeks w where w.route_id = p.route_id and w.week = game.week_of(p_day);
  end if;

  -- Step 5: costs per flight. Slots at congested airports are priced by how full the airport is, per movement scaled by the
  -- aircraft's size; a world scaled down in demand has proportionally fewer slots.
  with mv as (
    select z.iata, sum(z.m) as moves
      from (select a as iata, 2 * f as m from pg_temp._rot where flown
            union all select b, 2 * f from pg_temp._rot where flown) z
     group by z.iata),
  sp as (
    select ap.iata, g.slot_base_inr / power(1 - least(g.slot_util_cap, mv.moves / (ap.slot_cap * rw.slot_scale * rw.demand_scale)), 2) as price
      from mv join public.airports ap on ap.iata = mv.iata
     where ap.slot_cap is not null)
  update pg_temp._rot x set
    fuel_kg = 2 * x.f * (t.fuel_fixed_kg + t.fuel_per_km_kg * x.km)
             * (0.80 + 0.20 * (x.seats_e * p.lf_e + x.seats_b * p.lf_b) / t.ref_seats)
             * (1 + g.age_fuel_per_year * x.age_y) * o.fuel_mult,
    c_crew = case when x.wet then 0 else
               2 * x.f * (x.block_h * (t.pilot_inr_bh + x.crew * g.cabin_inr_bh) * o.hour_mult + o.allowance) end,
    c_maint = case when x.wet then 0 else
                2 * x.f * ((x.km::numeric / t.cruise_kmh + g.maint_fh_offset) * t.maint_usd_fh + t.maint_usd_cycle)
                * o.rate * (1 + o.age_k * x.age_y) * o.hour_mult * o.fx end,
    c_airport = 2 * x.f * (t.landing_inr * case when x.intl then (1 + g.intl_airport_mult) / 2 else 1 end
                           + t.nav_inr_km * x.km + g.handling_inr_pax * (x.seats_e * p.lf_e + x.seats_b * p.lf_b)),
    c_slots = 2 * x.f * (coalesce(sa.price, 0) + coalesce(sb.price, 0)) * t.ref_seats / g.slot_ref_seats   -- 0016: by aircraft size
  from (select route_id, a, b, coalesce(pax_e / nullif(cap_e, 0), 0) as lf_e, coalesce(pax_b / nullif(cap_b, 0), 0) as lf_b
          from pg_temp._prod) p
  join public.aircraft_types t on true
  join pg_temp._ops o on true
  left join sp sa on sa.iata = p.a
  left join sp sb on sb.iata = p.b
  where x.flown and p.route_id = x.route_id and t.id = x.type_id and o.airline_id = x.airline_id;
  -- fuel at this week's hedged price (0023): the hedged share at its locked price, the rest at today's
  update pg_temp._rot x set c_fuel = x.fuel_kg * (o.h_share * o.h_price + (1 - o.h_share) * rw.fuel_inr_kg)
    from pg_temp._ops o where x.flown and o.airline_id = x.airline_id;

  -- Step 6: results
  -- What holding each aircraft costs a day (migration 0017): rent, wet-lease hours, or depreciation and loan interest for
  -- an owned one, plus its cabin crew's base pay (and the flat pilot cost in a world without pilots). Pilot salaries, head
  -- office and marketing are not split by aircraft.
  insert into pg_temp._acx (aircraft_id, airline_id, fixed, bh)
  select ac.id, tm.airline_id,
         case tm.holding
           when 'lease' then tm.lease_usd_month * coalesce(ox.fx, rw.fx_inr_usd) / 30.33
           when 'wet' then tm.wet_usd_bh * coalesce(ox.fx, rw.fx_inr_usd) * greatest(g.wet_min_hours_day, coalesce(u.bh, 0))
           else tm.price_usd * rw.fx_inr_usd * g.depreciation_year / 364
                + case when tm.loan_usd > 0 then tm.loan_usd * g.loan_rate_year / 364 * coalesce(ox.fx, rw.fx_inr_usd) else 0 end
                + tm.loan_inr * game.wparam(p_world, 'loan_rate_inr_year') / 364 end
         + case when tm.holding = 'wet' then 0 else
             case when rw.pilots then 0 else t.pilot_fixed_inr_day end
             + game.cabin_crew(rw.crew_rule, ac.seats_econ + ac.seats_biz) * g.cabin_fixed_inr_day end,
         coalesce(u.bh, 0)
    from public.aircraft ac
    join public.aircraft_terms tm on tm.aircraft_id = ac.id
    join public.aircraft_types t on t.id = ac.type_id
    left join (select aircraft_id, sum(2 * f * block_h) as bh from pg_temp._rot where flown group by aircraft_id) u on u.aircraft_id = ac.id
    left join pg_temp._ops ox on ox.airline_id = tm.airline_id
   where ac.world_id = p_world and ac.status in ('active', 'grounded', 'refit')
     and exists (select 1 from public.airlines a0 where a0.id = ac.airline_id and a0.first_flight_day <= p_day);

  insert into public.route_daily (route_id, game_day, airline_id, flights, seats_econ, seats_biz, pax_econ, pax_biz,
                                  spill, revenue_inr, var_cost_inr, aircraft_cost_inr)
  select p.route_id, p_day, p.airline_id, 2 * p.f, round(2 * p.cap_e), round(2 * p.cap_b), p.pe, p.pb, round(2 * p.spill),
         round(p.rev + p.anc),
         round(c.var + g.dist_rev_share * p.rev + g.service_inr_pax * (p.pe + p.pb) + p.anc_cost + p.sales_x),
         round(c.acx)
    from pg_temp._prod p
    join (select x.route_id, sum(x.c_fuel + x.c_crew + x.c_maint + x.c_airport + x.c_slots) as var,
                 -- each aircraft's holding cost, shared across its routes by the hours it flew on each
                 sum(a.fixed * 2 * x.f * x.block_h / nullif(a.bh, 0)) as acx
            from pg_temp._rot x join pg_temp._acx a on a.aircraft_id = x.aircraft_id
           where x.flown group by x.route_id) c on c.route_id = p.route_id;

  -- Each aircraft's day (migration 0017): its share of its routes' revenue and of their sales and service costs (by seats
  -- it flew in each cabin), its own flying costs, and its holding cost. Idle and grounded aircraft get a row too.
  insert into public.aircraft_daily (aircraft_id, game_day, airline_id, flights, block_h, seats, pax, revenue_inr, flying_cost_inr, aircraft_cost_inr)
  select a.aircraft_id, p_day, a.airline_id, coalesce(z.flights, 0), round(a.bh, 2), coalesce(z.seats, 0), round(coalesce(z.pax, 0)),
         round(coalesce(z.rev, 0)), round(coalesce(z.cost, 0)), round(a.fixed)
    from pg_temp._acx a
    left join (select x.aircraft_id, sum(2 * x.f) as flights, round(sum(2 * x.f * (x.seats_e + x.seats_b))) as seats,
                      sum(s.e * p.pe + s.b * p.pb) as pax,
                      sum(s.e * (p.pe * p.fare_e + p.pe * p.ref * p.an_y) + s.b * p.pb * p.fare_b * (1 + g.anc_biz_share)) as rev,
                      sum(x.c_fuel + x.c_crew + x.c_maint + x.c_airport + x.c_slots
                          + s.all_ * (g.dist_rev_share * p.rev + g.service_inr_pax * (p.pe + p.pb) + p.anc_cost + p.sales_x)) as cost
                 from pg_temp._rot x
                 join pg_temp._prod p on p.route_id = x.route_id
                 cross join lateral (select coalesce(x.f * x.seats_e / nullif(p.cap_e, 0), 0) as e,
                                            coalesce(x.f * x.seats_b / nullif(p.cap_b, 0), 0) as b,
                                            coalesce(x.f * (x.seats_e + x.seats_b) / nullif(p.cap_e + p.cap_b, 0), 0) as all_) s
                where x.flown group by x.aircraft_id) z on z.aircraft_id = a.aircraft_id
   where a.airline_id is not null;

  insert into public.airline_daily (airline_id, game_day, pax, ask, rpk, rev_ticket, rev_anc, c_fuel, c_crew, c_maint,
    c_airport, c_rent, c_slots, c_dist, c_marketing, c_overhead, c_interest, c_other, c_depr, flights, cancelled, loan_repaid, refunds_inr,
    fuel_kg, hedge_inr, groundings, usd_cost_usd, usd_cost_inr, usd_hedge_inr, fx_effect_inr)
  select al.id, p_day, coalesce(pr.pax, 0), coalesce(pr.ask, 0), coalesce(pr.rpk, 0),
         coalesce(pr.rev, 0), round(coalesce(pr.anc, 0)),
         round(coalesce(rc.fuel, 0)), round(coalesce(rc.crew, 0) + coalesce(fl.crew_fixed, 0) + coalesce(sal.pay, 0)), round(coalesce(rc.maint, 0) + coalesce(ox.fixed_day, 0)),
         round(coalesce(rc.airport, 0)), round(coalesce(fl.rent, 0)), round(coalesce(rc.slots, 0)),
         round(coalesce(g.dist_rev_share * pr.rev + g.service_inr_pax * pr.pax + pr.anc_cost + pr.sales_x, 0)), al.marketing_inr_day,
         round(g.overhead_fixed_inr_day + g.overhead_aircraft_inr_day * coalesce(fl.n, 0) + g.overhead_seat_inr_day * coalesce(fl.seats, 0)
               + g.base_fixed_inr_day * (select count(*) from public.bases bs where bs.airline_id = al.id)),
         round(fin.debt_inr * g.interest_year / 364 + coalesce(fl.loan_int, 0)), coalesce(tx.other, 0), round(coalesce(fl.depr, 0)),
         coalesce(rc.flights, 0), coalesce(rc.cancelled, 0), round(coalesce(fl.loan_prin, 0)), round(coalesce(pr.refund, 0)),
         round(coalesce(rc.kg, 0)), round(coalesce(rc.kg * rw.fuel_inr_kg - rc.fuel, 0)), coalesce(gr.n, 0),
         -- 0026: dollar-linked costs (rent, maintenance, dollar loan interest, depreciation), what the dollar hedge saved on the
         -- cash ones (repayments included), and what the rupee's move against the reference rate added
         round(coalesce(fl.rent_usd, 0) + coalesce(rc.maint, 0) / ox.fx + coalesce(fl.int_usd, 0) + coalesce(fl.depr_usd, 0), 2),
         round(coalesce(fl.rent, 0) + coalesce(rc.maint, 0) + coalesce(fl.int_d, 0) + coalesce(fl.depr, 0)),
         round((coalesce(fl.rent_usd, 0) + coalesce(rc.maint, 0) / ox.fx + coalesce(fl.int_usd, 0) + coalesce(fl.prin_usd, 0)) * rw.fx_inr_usd
               - (coalesce(fl.rent, 0) + coalesce(rc.maint, 0) + coalesce(fl.int_d, 0) + coalesce(fl.prin_d, 0))),
         round(coalesce(fl.rent, 0) + coalesce(rc.maint, 0) + coalesce(fl.int_d, 0) + coalesce(fl.depr, 0)
               - (coalesce(fl.rent_usd, 0) + coalesce(rc.maint, 0) / ox.fx + coalesce(fl.int_usd, 0) + coalesce(fl.depr_usd, 0)) * game.param('fx_ref_inr_usd'))
    from public.airlines al
    join public.airline_finance fin on fin.airline_id = al.id
    left join (select airline_id, sum(pe + pb) as pax, sum(2 * (cap_e + cap_b) * km) as ask,
                      sum((pe + pb) * km) as rpk, sum(rev) as rev, sum(anc) as anc, sum(anc_cost) as anc_cost, sum(refund) as refund, sum(sales_x) as sales_x
                 from pg_temp._prod group by airline_id) pr on pr.airline_id = al.id
    left join (select airline_id, sum(c_fuel) as fuel, sum(fuel_kg) as kg, sum(c_crew) as crew, sum(c_maint) as maint,
                      sum(c_airport) as airport, sum(c_slots) as slots,
                      sum(2 * f) filter (where flown) as flights, sum(2 * f) filter (where not flown) as cancelled
                 from pg_temp._rot group by airline_id) rc on rc.airline_id = al.id
    left join (select tm.airline_id, count(*) as n, sum(ac.seats_econ + ac.seats_biz) as seats,
                      sum(case tm.holding
                            when 'lease' then tm.lease_usd_month / 30.33
                            when 'wet' then tm.wet_usd_bh * greatest(g.wet_min_hours_day, coalesce(u.bh, 0))
                            else 0 end) as rent_usd,
                      sum(case tm.holding
                            when 'lease' then tm.lease_usd_month / 30.33
                            when 'wet' then tm.wet_usd_bh * greatest(g.wet_min_hours_day, coalesce(u.bh, 0))
                            else 0 end) * max(coalesce(ox.fx, rw.fx_inr_usd)) as rent,
                      sum(case when tm.holding = 'owned' then tm.price_usd * g.depreciation_year / 364 else 0 end) as depr_usd,
                      sum(case when tm.holding = 'owned' then tm.price_usd * rw.fx_inr_usd * g.depreciation_year / 364 else 0 end) as depr,
                      sum(case when tm.holding = 'owned' and tm.loan_usd > 0 then tm.loan_usd * g.loan_rate_year / 364 else 0 end) as int_usd,
                      sum(case when tm.holding = 'owned' and tm.loan_usd > 0 then tm.loan_usd * g.loan_rate_year / 364 else 0 end)
                        * max(coalesce(ox.fx, rw.fx_inr_usd)) as int_d,
                      sum(case when tm.holding = 'owned' and tm.loan_usd > 0 then least(tm.loan_usd, tm.loan_pay_usd_day) else 0 end) as prin_usd,
                      sum(case when tm.holding = 'owned' and tm.loan_usd > 0 then least(tm.loan_usd, tm.loan_pay_usd_day) else 0 end)
                        * max(coalesce(ox.fx, rw.fx_inr_usd)) as prin_d,
                      sum(case when tm.holding = 'owned' and tm.loan_usd > 0 then tm.loan_usd * g.loan_rate_year / 364 else 0 end)
                        * max(coalesce(ox.fx, rw.fx_inr_usd))
                        + sum(case when tm.holding = 'owned' then tm.loan_inr * game.wparam(p_world, 'loan_rate_inr_year') / 364 else 0 end) as loan_int,
                      sum(case when tm.holding = 'owned' and tm.loan_usd > 0 then least(tm.loan_usd, tm.loan_pay_usd_day) else 0 end)
                        * max(coalesce(ox.fx, rw.fx_inr_usd))
                        + sum(case when tm.holding = 'owned' and tm.loan_inr > 0 then least(tm.loan_inr, tm.loan_pay_inr_day) else 0 end) as loan_prin,
                      sum(case when tm.holding = 'wet' then 0 else
                            case when rw.pilots then 0 else t.pilot_fixed_inr_day end
                            + game.cabin_crew(rw.crew_rule, ac.seats_econ + ac.seats_biz) * g.cabin_fixed_inr_day end) as crew_fixed
                 from public.aircraft ac
                 join public.aircraft_terms tm on tm.aircraft_id = ac.id
                 join public.aircraft_types t on t.id = ac.type_id
                 left join (select aircraft_id, sum(2 * f * block_h) as bh from pg_temp._rot where flown group by aircraft_id) u
                        on u.aircraft_id = ac.id
                 left join pg_temp._ops ox on ox.airline_id = tm.airline_id
                where ac.world_id = p_world and ac.status in ('active', 'grounded', 'refit')
                group by tm.airline_id) fl on fl.airline_id = al.id
    left join (select ap.airline_id,   -- pilot salaries: market pay x the airline's pay level; foreign captains at their own rate
                      sum(pm.pay_index * ((ap.captains - ap.expats) * pf.pay_c_inr_day * pfin.pilot_pay
                                          + ap.expats * pf.pay_c_inr_day * game.param('pilot_expat_mult')
                                          + ap.fos * pf.pay_f_inr_day * pfin.pilot_pay)) as pay
                 from public.airline_pilots ap
                 join public.airline_finance pfin on pfin.airline_id = ap.airline_id
                 join public.pilot_families pf on pf.id = ap.family
                 join public.pilot_market pm on pm.world_id = p_world and pm.family = ap.family
                where rw.pilots
                group by ap.airline_id) sal on sal.airline_id = al.id
    left join (select airline_id, -sum(pnl_inr) as other from public.transactions where game_day = p_day group by airline_id) tx
           on tx.airline_id = al.id
    left join pg_temp._ops ox on ox.airline_id = al.id
    left join (select airline_id, count(*) as n from public.aircraft where world_id = p_world and grounded_day = p_day group by airline_id) gr
           on gr.airline_id = al.id
   where al.world_id = p_world and al.status = 'active' and al.first_flight_day <= p_day;

  update public.airline_finance fin
     set cash_inr = fin.cash_inr + case when rw.selling then -d.refunds_inr else d.rev_ticket end + d.rev_anc - (d.c_fuel + d.c_crew + d.c_maint + d.c_airport + d.c_rent
                    + d.c_slots + d.c_dist + d.c_marketing + d.c_overhead + d.c_interest + d.loan_repaid)
    from public.airline_daily d join public.airlines al on al.id = d.airline_id
   where d.airline_id = fin.airline_id and d.game_day = p_day and al.world_id = p_world;

  update public.aircraft_terms tm set loan_usd = tm.loan_usd - least(tm.loan_usd, tm.loan_pay_usd_day)
    from public.aircraft ac join public.airlines al on al.id = ac.airline_id and al.status = 'active'
   where ac.id = tm.aircraft_id and ac.world_id = p_world and ac.status in ('active', 'grounded', 'refit')
     and tm.holding = 'owned' and tm.loan_usd > 0;
  update public.aircraft_terms tm set loan_inr = tm.loan_inr - least(tm.loan_inr, tm.loan_pay_inr_day)   -- 0026: rupee loans
    from public.aircraft ac join public.airlines al on al.id = ac.airline_id and al.status = 'active'
   where ac.id = tm.aircraft_id and ac.world_id = p_world and ac.status in ('active', 'grounded', 'refit')
     and tm.holding = 'owned' and tm.loan_inr > 0;

  -- punctuality: tight schedules run late. Brand drifts toward a target built from punctuality,
  -- cancellations, cabin comfort and marketing per passenger.
  update public.airlines al set otp = round((1 - g.otp_smooth) * al.otp + g.otp_smooth * least(0.99, greatest(0, s.otp)), 4)
    from (select u.airline_id, sum(u.fl * (g.otp_base - g.otp_util_k * greatest(0, u.util - 0.85) / 0.15)) / sum(u.fl)
                 + coalesce(max(o.otp_d), 0) as otp
            from (select x.airline_id, x.aircraft_id, sum(2 * x.f) as fl,
                         sum(2 * x.f * (x.block_h + x.turn_min / 60)) / max(t.day_window_h) as util
                    from pg_temp._rot x join public.aircraft_types t on t.id = x.type_id
                   where x.flown group by x.airline_id, x.aircraft_id) u
            left join pg_temp._ops o on o.airline_id = u.airline_id
           group by u.airline_id) s
   where al.id = s.airline_id;

  update public.airlines al
     set brand = round(least(100, greatest(0, al.brand + g.brand_drift * (
           50 + coalesce((select o.brand_d from pg_temp._ops o where o.airline_id = al.id), 0)
              + g.brand_otp_k * (al.otp - g.brand_otp_ref)
              - g.brand_cancel_k * coalesce(d.cancelled / nullif(d.flights + d.cancelled, 0), 0)
              + g.brand_comfort_k * (coalesce(c.comf, g.brand_comfort_ref) - g.brand_comfort_ref)
              + g.brand_mkt_max * (1 - exp(-al.marketing_inr_day / (g.brand_mkt_inr_pax * greatest(d.pax, g.brand_mkt_min_pax))))
           - al.brand))), 2)
    from public.airline_daily d
    left join (select airline_id, sum(cap_e * comf_e) / nullif(sum(cap_e), 0) as comf from pg_temp._prod group by airline_id) c
           on c.airline_id = d.airline_id
   where d.airline_id = al.id and d.game_day = p_day and al.world_id = p_world and al.status = 'active';

  delete from public.route_daily rd using public.airlines al
   where al.id = rd.airline_id and al.world_id = p_world and rd.game_day <= p_day - g.route_keep_days::int;
  delete from public.aircraft_daily ad using public.airlines al
   where al.id = ad.airline_id and al.world_id = p_world and ad.game_day <= p_day - g.route_keep_days::int;
end $$;

-- sell_week from 0026: reads the world's own game values (demand growth) (0027)
create or replace function game.sell_week(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' set jit = off as $$
declare
  rw public.worlds%rowtype;
  g record;
  v_w int := game.week_of(p_day);
  v_h int := game.param('sale_weeks')::int;
begin
  select * into rw from public.worlds where id = p_world;
  select * into g from jsonb_to_record(game.params_for(p_world)) as x(   -- 0027: the world's own values (growth)
    seg_biz_a float8, seg_biz_price float8, seg_biz_freq float8, seg_biz_comfort float8, seg_biz_brand float8,
    seg_lei_a float8, seg_lei_price float8, seg_lei_freq float8, seg_lei_comfort float8, seg_lei_brand float8,
    seg_bud_a float8, seg_bud_price float8, seg_bud_freq float8, seg_bud_comfort float8, seg_bud_brand float8,
    biz_fare_mult float8, nest_lambda float8, biz_downgrade_share float8, seg_biz_cabin_a float8,
    growth_year float8, growth_year_intl float8, season_start_month float8, demand_noise_sd float8,
    book_shape_biz float8, book_scale_biz float8, book_shape_lei float8, book_scale_lei float8,
    book_shape_bud float8, book_scale_bud float8, fare_ramp_power float8,
    noshow_biz float8, noshow_lei float8, noshow_bud float8, noshow_market_sd float8, noshow_week_sd float8,
    denied_comp_inr float8, rm_history_weeks float8, watch_ahead_weeks float8,
    news_fare_move float8, news_flights_move float8, insight_min_routes float8);

  -- booking curves: the share of each traveller type deciding n weeks before the flight week (arr), and the share who have
  -- decided before week n (pre)
  drop table if exists pg_temp._curve;
  create temp table _curve on commit drop as
  with k as (select n, (n + 0.5)::float8 as x from generate_series(0, v_h - 1) n),
  raw as (select n, x ^ g.book_shape_biz * exp(-x / g.book_scale_biz) as b, x ^ g.book_shape_lei * exp(-x / g.book_scale_lei) as l,
                 x ^ g.book_shape_bud * exp(-x / g.book_scale_bud) as u from k),
  nrm as (select n, b / sum(b) over () as b, l / sum(l) over () as l, u / sum(u) over () as u from raw)
  select n, b as arr_b, l as arr_l, u as arr_u,
         coalesce(sum(b) over w, 0) as pre_b, coalesce(sum(l) over w, 0) as pre_l, coalesce(sum(u) over w, 0) as pre_u,
         ((v_h - 1 - n)::float8 / (v_h - 1)) ^ g.fare_ramp_power as ramp
    from nrm window w as (order by n desc rows between unbounded preceding and 1 preceding);

  drop table if exists pg_temp._money;
  create temp table _money (airline_id uuid, sales float8 default 0, refunds float8 default 0, comp float8 default 0) on commit drop;

  -- 1. Routes closed: their tickets are refunded.
  with gone as (
    delete from public.route_weeks x using public.routes r
     where x.world_id = p_world and x.flown_e is null and r.id = x.route_id and r.status <> 'open'
    returning x.airline_id, 2 * (x.rev_e + x.rev_b) as amt)
  insert into pg_temp._money (airline_id, refunds) select airline_id, sum(amt) from gone group by airline_id;

  -- 2. Seats on sale: for each open route, each flight week from this one to the end of the sale, the rotations of the
  -- aircraft that are in the fleet by the start of that week.
  drop table if exists pg_temp._cap;
  create temp table _cap on commit drop as
  select r.id as route_id, wk.w as week, r.airline_id, m.a, m.b,
         sum(ro.weekly_trips)::float8 as trips,
         sum(ro.weekly_trips * ac.seats_econ)::float8 as seats_e, sum(ro.weekly_trips * ac.seats_biz)::float8 as seats_b,
         coalesce(sum(ro.weekly_trips * ac.seats_econ * (ac.econ_pitch - 28) / 6.0) / nullif(sum(ro.weekly_trips * ac.seats_econ), 0), 0)::float8 as comf_e,
         coalesce(sum(ro.weekly_trips * ac.seats_biz * case when t.biz_kind = 'lieflat' then 2.6 else 1.6 + (ac.biz_pitch - 36) / 12.0 end)
                  / nullif(sum(ro.weekly_trips * ac.seats_biz), 0), 0)::float8 as comf_b,
         (sum(ro.weekly_trips * (m.km::numeric / t.cruise_kmh + t.block_offset_h)) / sum(ro.weekly_trips))::float8 as block_h
    from public.routes r
    join public.airlines al on al.id = r.airline_id and al.status = 'active'
    join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
    cross join generate_series(v_w, v_w + v_h - 1) wk(w)
    join public.rotations ro on ro.route_id = r.id
    join public.aircraft ac on ac.id = ro.aircraft_id and ac.airline_id = r.airline_id
         and ac.status in ('active', 'grounded', 'refit', 'delivering') and coalesce(ac.available_day, 0) <= (wk.w - 1) * 7 + 1
    join public.aircraft_types t on t.id = ac.type_id
   where r.world_id = p_world and r.status = 'open'
     and greatest(r.first_flight_day, al.first_flight_day) <= (wk.w - 1) * 7 + 1
   group by r.id, wk.w, r.airline_id, m.a, m.b;

  -- a flight week new on sale starts from what the route has learnt: the fare changes of the week now closing
  insert into public.route_weeks (route_id, week, world_id, airline_id, trips, seats_e, seats_b, seats_max_e, seats_max_b, adj_e, adj_b, listed)
  select c.route_id, c.week, p_world, c.airline_id, c.trips, c.seats_e, c.seats_b, c.seats_e, c.seats_b,
         coalesce(y.adj_e, 1), coalesce(y.adj_b, 1), v_w
    from pg_temp._cap c left join public.route_weeks y on y.route_id = c.route_id and y.week = v_w
  on conflict (route_id, week) do update
    set trips = excluded.trips, seats_e = excluded.seats_e, seats_b = excluded.seats_b,
        seats_max_e = greatest(public.route_weeks.seats_max_e, excluded.seats_e),
        seats_max_b = greatest(public.route_weeks.seats_max_b, excluded.seats_b);
  update public.route_weeks x set trips = 0, seats_e = 0, seats_b = 0
   where x.world_id = p_world and x.week >= v_w and x.flown_e is null
     and (x.trips > 0 or x.seats_e > 0)
     and not exists (select 1 from pg_temp._cap c where c.route_id = x.route_id and c.week = x.week);

  -- 3. Fares. Every flight week on sale with seats; n is weeks before the flight week.
  drop table if exists pg_temp._sell;
  create temp table _sell on commit drop as
  with ax as materialized (
    select q.airline_id, t.d_biz, t.d_lei, t.d_bud
      from (select distinct airline_id from pg_temp._cap) q cross join lateral game.anc_terms(q.airline_id) t)
  select x.route_id, x.week, x.week - v_w as n, x.airline_id, c.a, c.b, m.intl, m.ref_fare::float8 as ref, m.ref_fare::float8 * coalesce(rw.fare_index, 1)::float8 as rp, p.strategy,
         -- 0026: where the route sells: reach abroad, and the rupees a ticket brings when part is priced in dollars
         coalesce(po.util_bonus, 0)::float8 as pu,
         case when m.intl then 1 + coalesce(po.usd_share, 0) * (rw.fx_inr_usd / game.param('fx_ref_inr_usd') - 1) else 1 end::float8 as fxm,
         s.target_lf::float8 as tlf, s.early_mult::float8 as em, s.late_mult::float8 as lm,
         s.biz_early_mult::float8 as bem, s.biz_late_mult::float8 as blm, s.min_mult::float8 as mn, s.max_mult::float8 as mx,
         s.step::float8 as st, s.band::float8 as bd, s.follow_gap::float8 as gap, s.overbook::float8 as ob,
         c.trips / 7 as f, c.seats_e as se, c.seats_b as sb, c.comf_e as ce, c.comf_b as cb, c.block_h as bh,
         al.brand::float8 as brand, ax.d_biz::float8 as adb, ax.d_lei::float8 as adl, ax.d_bud::float8 as adu,
         (x.bk_be + x.bk_l + x.bk_u)::float8 as sold_e, x.bk_b::float8 as sold_b, x.adj_e::float8 as adj_e, x.adj_b::float8 as adj_b, x.listed,
         m.n_biz::float8 as nb, m.n_lei::float8 as nl, m.n_bud::float8 as nu,
         -- the market's own (hidden) no-show factor, and the no-show share the engine expects in economy from the traveller mix
         mf.v as mf,
         (m.n_biz * g.noshow_biz + m.n_lei * g.noshow_lei + m.n_bud * g.noshow_bud) / nullif(m.n_biz + m.n_lei + m.n_bud, 0) * mf.v as ns,
         0::float8 as pe, 0::float8 as pb, 0::float8 as room_e, 0::float8 as room_b,
         0::float8 as xb_e, 0::float8 as xb_b, 0::float8 as xl, 0::float8 as xu,
         0::float8 as got_be, 0::float8 as got_l, 0::float8 as got_u, 0::float8 as got_b, 0::float8 as lost
    from public.route_weeks x
    join pg_temp._cap c on c.route_id = x.route_id and c.week = x.week
    join public.route_plans p on p.route_id = x.route_id
    join public.rm_strategies s on s.key = p.strategy
    join public.markets m on m.a = c.a and m.b = c.b
    left join public.pos_options po on po.key = p.sell_where and m.intl
    join public.airlines al on al.id = x.airline_id
    join ax on ax.airline_id = x.airline_id
    cross join lateral (select exp(g.noshow_market_sd * game.hash_normal('ns:' || m.a || m.b) - g.noshow_market_sd ^ 2 / 2) as v) mf
   where x.world_id = p_world and x.week >= v_w and x.flown_e is null;

  -- pace: compare seats sold with the target curve; outside the band, move this week's fares by the step for each band's
  -- width they are off (up to three steps), within the strategy's bounds
  update pg_temp._sell z set
    adj_e = least(z.mx / q.base_e, greatest(z.mn / q.base_e, z.adj_e * case
              when q.tgt_e < 0.02 * z.se or abs(z.sold_e / q.tgt_e - 1) <= z.bd then 1
              else 1 + z.st * greatest(-3, least(3, (z.sold_e / q.tgt_e - 1) / greatest(z.bd, 0.01))) end)),
    adj_b = least(z.mx / q.base_b, greatest(z.mn / q.base_b, z.adj_b * case
              when z.sb = 0 or q.tgt_b < 0.02 * z.sb or abs(z.sold_b / q.tgt_b - 1) <= z.bd then 1
              else 1 + z.st * greatest(-3, least(3, (z.sold_b / q.tgt_b - 1) / greatest(z.bd, 0.01))) end))
    from (select z0.route_id, z0.week,
                 z0.em + (z0.lm - z0.em) * c.ramp as base_e, z0.bem + (z0.blm - z0.bem) * c.ramp as base_b,
                 z0.tlf * z0.se * (z0.nb * case when z0.sb > 0 then 0.3 else 1 end * c.pre_b + z0.nl * c.pre_l + z0.nu * c.pre_u)
                     / nullif(z0.nb * case when z0.sb > 0 then 0.3 else 1 end + z0.nl + z0.nu, 0) as tgt_e,
                 z0.tlf * z0.sb * c.pre_b as tgt_b
            from pg_temp._sell z0 join pg_temp._curve c on c.n = z0.n) q
   where q.route_id = z.route_id and q.week = z.week;
  update pg_temp._sell z set
    pe = round(z.rp * (z.em + (z.lm - z.em) * c.ramp) * z.adj_e / 10) * 10,
    pb = round(z.rp * g.biz_fare_mult * (z.bem + (z.blm - z.bem) * c.ramp) * z.adj_b / 10) * 10
    from pg_temp._curve c where c.n = z.n;
  -- follow the market: the rivals' average for the same flight week
  update pg_temp._sell z set
    pe = round(least(z.mx * z.rp, greatest(z.mn * z.rp, q.e * (1 + z.gap))) / 10) * 10,
    pb = coalesce(round(least(z.mx * z.rp * g.biz_fare_mult, greatest(z.mn * z.rp * g.biz_fare_mult, q.b * (1 + z.gap))) / 10) * 10, z.pb)
    from (select z1.route_id, z1.week, avg(z2.pe) as e, avg(z2.pb) filter (where z2.sb > 0) as b
            from pg_temp._sell z1 join pg_temp._sell z2 on z2.a = z1.a and z2.b = z1.b and z2.week = z1.week and z2.airline_id <> z1.airline_id
           where z1.strategy = 'follow' and z2.se > 0
           group by z1.route_id, z1.week) q
   where z.route_id = q.route_id and z.week = q.week;

  -- 0024 (F): computer-run airlines never sell economy below the fare that covers the route's flying and aircraft costs at
  -- bot_sell_floor_lf full over the last 28 days (business seats counted at the business multiple, extras at bot_floor_anc),
  -- within the strategy's highest fare
  drop table if exists pg_temp._bfloor;
  create temp table _bfloor on commit drop as
  select d.route_id,
         sum(d.var_cost_inr + d.aircraft_cost_inr)::float8
           / nullif(game.param('bot_sell_floor_lf') * (1 + game.param('bot_floor_anc'))
                    * sum(d.seats_econ + g.biz_fare_mult * d.seats_biz), 0) as floor_e
    from public.route_daily d join public.airlines al on al.id = d.airline_id and al.is_ai
   where al.world_id = p_world and d.game_day > p_day - 28
   group by d.route_id having count(*) >= 7;
  if game.param('bot_sell_floor_lf') > 0 then
    update pg_temp._sell z set pe = greatest(z.pe, round(least(z.mx * z.rp, f.floor_e) / 10) * 10)
      from pg_temp._bfloor f where f.route_id = z.route_id and f.floor_e is not null;
  end if;
  -- 0025: a computer-run airline fighting a player prices each flight week at the point drawn for the fight
  -- (route_plans.fight_pos) between its profitable lowest fare (that floor plus bot_fight_margin; the strategy's lowest
  -- before it has 7 days of results) and the lowest player fare on the market that week; below that lowest it holds
  if game.param('bot_fight_random') > 0 then
    update pg_temp._sell z
       set pe = round(least(z.mx * z.rp, greatest(k.fp, least(k.lo, k.fp + k.pos * (k.lo - k.fp)))) / 10) * 10
      from (select y.route_id, y.week, pp.fight_pos::float8 as pos,
                   coalesce(f.floor_e, y.mn * y.rp) * (1 + game.param('bot_fight_margin')) as fp,
                   (select min(o.pe) from pg_temp._sell o join public.airlines oa on oa.id = o.airline_id and not oa.is_ai
                     where o.a = y.a and o.b = y.b and o.week = y.week) as lo
              from pg_temp._sell y
              join public.route_plans pp on pp.route_id = y.route_id and pp.fight_until is not null and pp.fight_pos is not null
              left join pg_temp._bfloor f on f.route_id = y.route_id) k
     where k.route_id = z.route_id and k.week = z.week and k.lo is not null;
  end if;

  -- 4. This week's bookings. Seats can be sold beyond the cabin by the strategy's overbooking share of expected no-shows.
  update pg_temp._sell set
    room_e = greatest(0, se * (1 + ob * ns) - sold_e),
    room_b = greatest(0, sb * (1 + ob * g.noshow_biz * mf) - sold_b);
  update pg_temp._sell set
    xb_e = case when room_e > 0.5 then game.sell_x(g.seg_biz_a - g.seg_biz_price * (pe / ref + adb) + g.seg_biz_freq * ln(1 + f)
             + g.seg_biz_comfort * ce * sqrt(bh) + g.seg_biz_brand * (brand - 50) / 50 + pu, g.nest_lambda) else 0 end,
    xb_b = case when room_b > 0.5 then game.sell_x(g.seg_biz_a + g.seg_biz_cabin_a - g.seg_biz_price * pb / (ref * g.biz_fare_mult)
             + g.seg_biz_freq * ln(1 + f) + g.seg_biz_comfort * cb * sqrt(bh) + g.seg_biz_brand * (brand - 50) / 50 + pu, g.nest_lambda) else 0 end,
    xl   = case when room_e > 0.5 then game.sell_x(g.seg_lei_a - g.seg_lei_price * (pe / ref + adl) + g.seg_lei_freq * ln(1 + f)
             + g.seg_lei_comfort * ce * sqrt(bh) + g.seg_lei_brand * (brand - 50) / 50 + pu, g.nest_lambda) else 0 end,
    xu   = case when room_e > 0.5 then game.sell_x(g.seg_bud_a - g.seg_bud_price * (pe / ref + adu) + g.seg_bud_freq * ln(1 + f)
             + g.seg_bud_comfort * ce * sqrt(bh) + g.seg_bud_brand * (brand - 50) / 50 + pu, g.nest_lambda) else 0 end;

  -- festivals and events (G): each day of a flight week inside an event adds a seventh of the event's extra demand
  drop table if exists pg_temp._ev;
  create temp table _ev on commit drop as
  select q.a, q.b, q.week,
         (1 + sum(e.biz - 1) / 7.0)::float8 as fb, (1 + sum(e.lei - 1) / 7.0)::float8 as fl, (1 + sum(e.bud - 1) / 7.0)::float8 as fu
    from (select distinct a, b, week, intl from pg_temp._sell) q
    join public.airports pa on pa.iata = q.a
    join public.airports pb on pb.iata = q.b
    cross join generate_series(0, 6) dd
    join public.demand_events e
      on (((q.week - 1) * 7 + dd) % 364 + 1 - e.start_doy + 364) % 364 < e.days
     and (e.domestic is null or e.domestic = not q.intl)
     and (e.airports is null or q.a = any (e.airports) or q.b = any (e.airports))
     and (e.regions is null or pa.region = any (e.regions) or pb.region = any (e.regions))
   group by q.a, q.b, q.week;

  -- travellers who decide this week on each market and flight week: the week's demand (7 days, season of its middle day,
  -- growth, a swing fixed per market and week) times the share of each type who book n weeks ahead (when the week first
  -- opens on its market, everyone who would have booked by then)
  with wk as (
    select w, (w - 1) * 7 + 4 as mid,
           power(1 + g.growth_year, ((w - 1) * 7 + 3) / 364.0) * rw.demand_scale as grow,
           power(1 + coalesce(g.growth_year_intl, g.growth_year), ((w - 1) * 7 + 3) / 364.0) * rw.demand_scale as grow_i
      from generate_series(v_w, v_w + v_h - 1) w),
  sf as (
    select wk.w, wk.grow, wk.grow_i, s.biz, s.lei, s.bud from wk join public.season_factors s
      on s.month = ((g.season_start_month::int - 1 + (((wk.mid - 1) % 364) * 12) / 364) % 12) + 1),
  -- a flight week opens for sale on its market when no airline had it on sale before (a new market, or the world's
  -- first week): travellers who would have booked earlier book now
  op as (
    select route_id, week, min(listed) over (partition by a, b, week) = v_w as opening from pg_temp._sell),
  arr as (
    select z.route_id, z.week,
           7 * z.nb * sf.biz * coalesce(ev.fb, 1) * k.v * case when z.opening then c.pre_b + c.arr_b else c.arr_b end as ab,
           7 * z.nl * sf.lei * coalesce(ev.fl, 1) * k.v * case when z.opening then c.pre_l + c.arr_l else c.arr_l end as al_,
           7 * z.nu * sf.bud * coalesce(ev.fu, 1) * k.v * case when z.opening then c.pre_u + c.arr_u else c.arr_u end as au,
           game.sell_k(sum(z.xb_e + z.xb_b) over mkt, g.nest_lambda) as kb,
           game.sell_k(sum(z.xl) over mkt, g.nest_lambda) as kl,
           game.sell_k(sum(z.xu) over mkt, g.nest_lambda) as ku
      from (select z0.*, op.opening from pg_temp._sell z0 join op on op.route_id = z0.route_id and op.week = z0.week) z
      join sf on sf.w = z.week
      join pg_temp._curve c on c.n = z.n
      left join pg_temp._ev ev on ev.a = z.a and ev.b = z.b and ev.week = z.week
      cross join lateral (select case when z.intl then sf.grow_i else sf.grow end * exp(g.demand_noise_sd / sqrt(7) * game.hash_normal(p_world::text || z.a || z.b || z.week)
                                               - g.demand_noise_sd ^ 2 / 14) as v) k
    window mkt as (partition by z.a, z.b, z.week)),
  dem as (
    select z.route_id, z.week, a.ab * z.xb_e * a.kb as d_be, a.ab * z.xb_b * a.kb as d_bb,
           a.al_ * z.xl * a.kl as d_l, a.au * z.xu * a.ku as d_u
      from pg_temp._sell z join arr a on a.route_id = z.route_id and a.week = z.week),
  -- business cabin first; part of its overflow takes economy on the same airline
  bz as (
    select d.*, least(d.d_bb, z.room_b) as got_b, g.biz_downgrade_share * greatest(d.d_bb - z.room_b, 0) as dg, z.room_e
      from dem d join pg_temp._sell z on z.route_id = d.route_id and z.week = d.week)
  update pg_temp._sell z
     set got_b = bz.got_b,
         got_be = (bz.d_be + bz.dg) * e.fac, got_l = bz.d_l * e.fac, got_u = bz.d_u * e.fac,
         lost = (bz.d_bb - bz.got_b - bz.dg) + (bz.d_be + bz.dg + bz.d_l + bz.d_u) * (1 - e.fac)
    from bz cross join lateral (select case when bz.d_be + bz.dg + bz.d_l + bz.d_u > bz.room_e
                                            then bz.room_e / (bz.d_be + bz.dg + bz.d_l + bz.d_u) else 1 end as fac) e
   where bz.route_id = z.route_id and bz.week = z.week;

  update public.route_weeks x
     set price_e = z.pe, price_b = case when z.sb > 0 then z.pb end, adj_e = z.adj_e, adj_b = z.adj_b, strategy = z.strategy,
         bk_be = x.bk_be + z.got_be, bk_l = x.bk_l + z.got_l, bk_u = x.bk_u + z.got_u, bk_b = x.bk_b + z.got_b,
         rev_e = x.rev_e + (z.got_be + z.got_l + z.got_u) * z.pe * z.fxm, rev_b = x.rev_b + z.got_b * z.pb * z.fxm,
         sold_wk = z.got_be + z.got_l + z.got_u + z.got_b, spill = x.spill + z.lost
    from pg_temp._sell z
   where x.route_id = z.route_id and x.week = z.week;
  -- weeks with no seats on sale this week sold nothing
  update public.route_weeks x set sold_wk = 0
   where x.world_id = p_world and x.week >= v_w and x.flown_e is null and x.sold_wk <> 0
     and not exists (select 1 from pg_temp._sell z where z.route_id = x.route_id and z.week = x.week);
  insert into pg_temp._money (airline_id, sales)
  select airline_id, 2 * sum(((got_be + got_l + got_u) * pe + got_b * pb) * fxm) from pg_temp._sell group by airline_id;

  -- 5. The flight week now starting closes. No-shows by traveller type (the market's hidden factor and a weekly swing);
  -- passengers who turn up beyond the seats cannot board: a refund, plus compensation unless the seats were cut by the
  -- airline's own schedule change (then a refund only).
  with fl as (
    select x.route_id, x.airline_id, x.seats_e, x.seats_b, x.seats_max_e, x.seats_max_b,
           x.bk_be + x.bk_l + x.bk_u as sold_e, x.bk_b as sold_b, x.rev_e, x.rev_b,
           f.k * (x.bk_be * g.noshow_biz + x.bk_l * g.noshow_lei + x.bk_u * g.noshow_bud) as ns_e,
           f.k * x.bk_b * g.noshow_biz as ns_b
      from public.route_weeks x
      join public.routes r on r.id = x.route_id
      join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
      cross join lateral (select least(0.9, exp(g.noshow_market_sd * game.hash_normal('ns:' || m.a || m.b) - g.noshow_market_sd ^ 2 / 2
                                  + g.noshow_week_sd * game.hash_normal('nsw:' || p_world::text || m.a || m.b || x.week) - g.noshow_week_sd ^ 2 / 2)) as k) f
     where x.world_id = p_world and x.week = v_w and x.flown_e is null),
  dn as (
    select fl.*, greatest(0, fl.sold_e - fl.ns_e - fl.seats_e) as den_e, greatest(0, fl.sold_b - fl.ns_b - fl.seats_b) as den_b
      from fl),
  upd as (
    update public.route_weeks x
       set noshow = dn.ns_e + dn.ns_b, denied = dn.den_e + dn.den_b,
           comp = greatest(0, dn.den_e - (dn.seats_max_e - dn.seats_e)) + greatest(0, dn.den_b - (dn.seats_max_b - dn.seats_b)),
           flown_e = dn.sold_e - dn.ns_e - dn.den_e, flown_b = dn.sold_b - dn.ns_b - dn.den_b,
           rev_flown_e = dn.rev_e - dn.den_e * coalesce(dn.rev_e / nullif(dn.sold_e, 0), 0),
           rev_flown_b = dn.rev_b - dn.den_b * coalesce(dn.rev_b / nullif(dn.sold_b, 0), 0)
      from dn where x.route_id = dn.route_id and x.week = v_w
    returning x.airline_id, 2 * (x.rev_e + x.rev_b - x.rev_flown_e - x.rev_flown_b) as refund, 2 * x.comp * g.denied_comp_inr as comp)
  insert into pg_temp._money (airline_id, refunds, comp) select airline_id, sum(refund), sum(comp) from upd group by airline_id;

  -- the money: tickets sold in, refunds and compensation out (compensation is a cost; the rest moves cash only)
  update public.airline_finance fin set cash_inr = round(fin.cash_inr + m.sales - m.refunds - m.comp)
    from (select airline_id, sum(sales) as sales, sum(refunds) as refunds, sum(comp) as comp from pg_temp._money group by airline_id) m
   where fin.airline_id = m.airline_id;
  insert into public.transactions (airline_id, game_day, kind, amount_inr, note, pnl_inr)
  select airline_id, p_day, 'denied_boarding', -round(sum(comp)), 'Compensation to passengers who could not board', -round(sum(comp))
    from pg_temp._money group by airline_id having sum(comp) >= 1;
  insert into public.airline_weeks (airline_id, week, sales_inr, refunds_inr, comp_inr, advance_inr)
  select al.id, v_w, round(coalesce(m.sales, 0)), round(coalesce(m.refunds, 0)), round(coalesce(m.comp, 0)),
         round(coalesce((select 2 * sum(x.rev_e + x.rev_b) from public.route_weeks x where x.airline_id = al.id and x.week > v_w), 0))
    from public.airlines al
    left join (select airline_id, sum(sales) as sales, sum(refunds) as refunds, sum(comp) as comp from pg_temp._money group by airline_id) m
           on m.airline_id = al.id
   where al.world_id = p_world and (al.status = 'active' or m.airline_id is not null)
  on conflict (airline_id, week) do update
    set sales_inr = excluded.sales_inr, refunds_inr = excluded.refunds_inr, comp_inr = excluded.comp_inr, advance_inr = excluded.advance_inr;

  -- the fares shown on each route: next week's
  update public.routes r set fare_econ = greatest(1, x.price_e), fare_biz = coalesce(x.price_b, r.fare_biz)
    from public.route_weeks x
   where x.route_id = r.id and x.week = v_w + 1 and r.world_id = p_world and x.price_e is not null;

  -- 6. What rivals can see: each airline's fare a few weeks ahead and next week's flights, and what changed.
  drop table if exists pg_temp._watch;
  create temp table _watch on commit drop as
  select r.id as route_id, r.airline_id, least(r.origin, r.dest) as a, greatest(r.origin, r.dest) as b,
         f.price_e as fare_e, f.price_b as fare_b, coalesce(nx.trips, 0) as trips, coalesce(nx.seats_e + nx.seats_b, 0) as seats
    from public.routes r
    left join public.route_weeks f on f.route_id = r.id and f.week = v_w + g.watch_ahead_weeks::int
    left join public.route_weeks nx on nx.route_id = r.id and nx.week = v_w + 1
   where r.world_id = p_world and r.status = 'open';
  insert into public.market_moves (world_id, a, b, week, airline_id, kind, old_value, new_value)
  select p_world, a, b, v_w, airline_id, kind,
         case when kind in ('fare_up', 'fare_down') then o_fare else o_trips end,
         case when kind in ('fare_up', 'fare_down') then n_fare else n_trips end
    from (select coalesce(n.a, o.a) as a, coalesce(n.b, o.b) as b, coalesce(n.airline_id, o.airline_id) as airline_id,
                 o.trips as o_trips, n.trips as n_trips, o.fare_e as o_fare, n.fare_e as n_fare,
                 case when coalesce(o.trips, 0) = 0 and coalesce(n.trips, 0) > 0 then 'enter'
                      when coalesce(n.trips, 0) = 0 and coalesce(o.trips, 0) > 0 then 'leave'
                      when n.trips >= o.trips * 1.1 + 0.5 then 'more_flights'
                      when n.trips <= o.trips / 1.1 - 0.5 then 'fewer_flights'
                      when n.fare_e >= o.fare_e * 1.07 then 'fare_up'
                      when n.fare_e <= o.fare_e / 1.07 then 'fare_down' end as kind
            from pg_temp._watch n
            full join (select * from public.market_watch where world_id = p_world) o on o.route_id = n.route_id) q
   where kind is not null;
  -- rivals' bigger moves reach every player flying the same market, as private news
  insert into public.news (world_id, game_day, airline_id, kind, body, private)
  select p_world, p_day, r.airline_id, 'rival',
         al.name || case mv.kind when 'enter' then ' starts flying ' when 'leave' then ' stops flying '
                                 when 'fare_up' then ' raises fares on ' when 'fare_down' then ' cuts fares on '
                                 when 'more_flights' then ' adds flights on ' else ' cuts flights on ' end
         || pa.city || '–' || pb.city
         || case when mv.kind in ('fare_up', 'fare_down')
                 then ': ₹' || to_char(mv.old_value, 'FM999,999,990') || ' → ₹' || to_char(mv.new_value, 'FM999,999,990') || ' four weeks out'
                 when mv.kind in ('more_flights', 'fewer_flights')
                 then ': ' || round(mv.old_value) || ' → ' || round(mv.new_value) || ' flights a week' else '' end || '.',
         true
    from public.market_moves mv
    join public.airlines al on al.id = mv.airline_id
    join public.routes r on r.world_id = p_world and r.status = 'open' and least(r.origin, r.dest) = mv.a and greatest(r.origin, r.dest) = mv.b
                        and r.airline_id <> mv.airline_id
    join public.airports pa on pa.iata = r.origin
    join public.airports pb on pb.iata = r.dest
    join public.airlines me on me.id = r.airline_id and not me.is_ai and me.status = 'active'
   where mv.world_id = p_world and mv.week = v_w
     and (mv.kind in ('enter', 'leave')
          or (mv.kind in ('fare_up', 'fare_down') and abs(mv.new_value / nullif(mv.old_value, 0) - 1) >= g.news_fare_move)
          or (mv.kind in ('more_flights', 'fewer_flights') and abs(mv.new_value / nullif(mv.old_value, 0) - 1) >= g.news_flights_move));
  delete from public.market_watch where world_id = p_world;
  insert into public.market_watch (route_id, world_id, airline_id, a, b, week, fare_e, fare_b, trips, seats)
  select route_id, p_world, airline_id, a, b, v_w, fare_e, fare_b, trips, seats from pg_temp._watch;

  -- What works where (0020): the last 13 flown weeks of every route, by kind of sector, how many airlines fly the market
  -- and how the route sold. A cell needs insight_min_routes routes, so no single airline's results can be read off it.
  delete from public.sector_insights where world_id = p_world;
  insert into public.sector_insights (world_id, week, band, shape, strategy, routes, weeks, load, fare_index, rev_index)
  with fw as (
    select x.route_id, x.week, x.strategy, (x.seats_e + x.seats_b)::float8 as seats,
           (x.flown_e + x.flown_b)::float8 as flown, (x.rev_flown_e + x.rev_flown_b)::float8 as rev,
           m.ref_fare::float8 as ref, m.a, m.b, m.km, m.intl
      from public.route_weeks x
      join public.routes r on r.id = x.route_id
      join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
     where x.world_id = p_world and x.flown_e is not null and x.week > v_w - 13 and x.seats_e + x.seats_b > 0 and x.strategy is not null),
  sh as (select a, b, week, count(*) as n from fw group by a, b, week)
  select p_world, v_w,
         case when fw.intl then 'intl' when fw.km < 800 then 'short' when fw.km < 1800 then 'medium' else 'long' end,
         case when sh.n = 1 then 'alone' when sh.n = 2 then 'two' when sh.n <= 4 then 'few' else 'many' end,
         fw.strategy, count(distinct fw.route_id), count(*),
         round((sum(fw.flown) / sum(fw.seats))::numeric, 4),
         round((sum(fw.rev) / nullif(sum(fw.flown * fw.ref), 0))::numeric, 4),
         round((sum(fw.rev) / sum(fw.seats * fw.ref))::numeric, 4)
    from fw join sh on sh.a = fw.a and sh.b = fw.b and sh.week = fw.week
   group by 3, 4, 5
  having count(distinct fw.route_id) >= g.insight_min_routes;

  -- history
  delete from public.route_weeks where world_id = p_world and week < v_w - g.rm_history_weeks::int;
  delete from public.market_moves where world_id = p_world and week < v_w - 13;
end $$;

-- found_airline from 0018: the world's starting money and credit line (0027)
create or replace function public.found_airline(p_invite text, p_name text, p_code text, p_base text,
                                                p_display_name text default null, p_livery jsonb default '{}')
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rp public.airports%rowtype;
  v_uid uuid := auth.uid();
  v_name text := trim(p_name);
  v_code text := upper(trim(p_code));
  v_day int;
  v_id uuid;
  v_type text;
  w record;
begin
  if v_uid is null and not game.is_server() then raise exception 'Sign in first'; end if;
  select x.* into rw from public.world_secrets s join public.worlds x on x.id = s.world_id
   where s.invite_code = lower(trim(p_invite)) for update of x;
  if not found then raise exception 'That invite code is not valid'; end if;
  if rw.status = 'ended' then raise exception 'This world has ended'; end if;
  v_day := rw.game_day + 1;
  if (select count(*) from public.airlines where world_id = rw.id and not is_ai) >= rw.max_airlines then
    raise exception 'This world is full';
  end if;
  if v_uid is not null and exists (select 1 from public.airlines where world_id = rw.id and user_id = v_uid) then
    raise exception 'You already have an airline in this world';
  end if;
  if v_name is null or length(v_name) not between 3 and 30 then raise exception 'Airline name must be 3 to 30 characters'; end if;
  if v_code is null or v_code !~ '^[A-Z0-9]{2,3}$' then raise exception 'Airline code must be 2 or 3 letters or digits'; end if;
  if exists (select 1 from public.airlines where world_id = rw.id and (lower(name) = lower(v_name) or code = v_code))
     or exists (select 1 from public.bot_airlines where lower(name) = lower(v_name) or code = v_code) then
    raise exception 'That name or code is already taken in this world';
  end if;
  select * into rp from public.airports where iata = upper(trim(p_base));
  if not found or not rp.is_india then raise exception 'Bases can only be opened at Indian airports'; end if;
  if rp.opens_day > v_day then raise exception '% airport has not opened yet', rp.city; end if;
  if length(coalesce(p_livery, '{}')::text) > 2000 then raise exception 'That livery is too large'; end if;

  if v_uid is not null then
    insert into public.profiles (user_id, display_name)
    values (v_uid, left(coalesce(nullif(trim(p_display_name), ''), v_name), 40)) on conflict (user_id) do nothing;
  end if;
  insert into public.airlines (world_id, user_id, name, code, livery, created_day)
  values (rw.id, v_uid, v_name, v_code, coalesce(p_livery, '{}'), v_day) returning id into v_id;
  insert into public.airline_finance (airline_id, cash_inr, credit_limit_inr)
  values (v_id, 0, game.wparam(rw.id, 'credit_limit_inr'));   -- 0027: the world's banks and starting money
  perform game.book(v_id, v_day, game.wparam(rw.id, 'start_cash_inr'), 'equity', 'Founding equity');
  insert into public.bases (airline_id, iata, opened_day) values (v_id, rp.iata, v_day);
  insert into public.news (world_id, game_day, airline_id, kind, body)
  values (rw.id, v_day, v_id, 'founded', v_name || ' has been founded, based at ' || rp.city || '.');

  select t.id into v_type from public.aircraft_types t
   where t.starter_rank is not null and t.runway_class <= rp.runway_class order by t.starter_rank limit 1;
  if v_type is not null then
    for i in 1..game.param('starter_aircraft')::int loop
      select * into w from game.add_wet(v_id, rw.id, v_type, rp.iata, v_day, v_day);
      insert into public.news (world_id, game_day, airline_id, kind, body, private)
      select rw.id, v_day, v_id, 'fleet', 'A wet-leased ' || t.name || ', ' || w.o_reg || ', is ready at ' || rp.iata
             || ' and flies from your first flights in week ' || game.week_of(al.first_flight_day) || '. It costs $' || w.o_rate
             || ' a block hour, at least ' || game.param('wet_min_hours_day') || ' hours a day.', true
        from public.aircraft_types t, public.airlines al where t.id = v_type and al.id = v_id;
    end loop;
  end if;
  return v_id;
end $$;

-- order_aircraft from 0026: the world's deposit on new aircraft (0027)
create or replace function public.order_aircraft(p_airline uuid, p_type text, p_base text, p_biz_rows int,
                                                 p_biz_pitch int, p_econ_pitch int, p_pay text default 'cash')
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rt public.aircraft_types%rowtype;
  l record; q record;
  v_day int; v_base text; v_dep numeric; v_id uuid; v_reg text;
begin
  rw := game.actor(p_airline); v_day := rw.game_day + 1;
  select * into rt from public.aircraft_types where id = p_type;
  if not found then raise exception 'Unknown aircraft type'; end if;
  if p_pay is null or p_pay not in ('cash', 'loan', 'loan_inr', 'slb') then
    raise exception 'Payment plan must be cash, loan or slb, or loan_inr for a rupee loan';
  end if;
  perform game.check_fleet_room(p_airline);
  v_base := game.check_base(p_airline, p_base, rt.runway_class);
  select * into l from public.layout_calc(p_type, p_biz_rows, p_biz_pitch, p_econ_pitch, rw.crew_rule);
  if not l.valid then raise exception '%', l.reason; end if;
  perform pg_advisory_xact_lock(hashtextextended('order:' || rw.id || ':' || p_type, 0));
  select * into q from game.order_quote(rw.id, p_type, v_day);
  if q.delivery_day > rw.season_days then raise exception 'The next delivery slot is after the season ends'; end if;
  v_dep := round(q.price_usd * game.wparam(rw.id, 'order_deposit_share') * rw.fx_inr_usd);
  perform game.book(p_airline, v_day, -v_dep, 'deposit', 'Order deposit for one ' || rt.name);
  insert into public.aircraft (world_id, type_id, airline_id, reg, built_day, status, available_day, base_iata,
                               biz_rows, biz_pitch, econ_pitch, seats_biz, seats_econ)
  values (rw.id, p_type, p_airline, game.next_reg(), q.delivery_day, 'delivering', q.delivery_day, v_base, p_biz_rows,
          case when p_biz_rows > 0 then case when rt.biz_kind = 'lieflat' then 44 else p_biz_pitch end end,
          p_econ_pitch, l.seats_biz, l.seats_econ)
  returning id, reg into v_id, v_reg;
  insert into public.aircraft_terms (aircraft_id, airline_id, holding, deposit_inr, price_usd, start_day, ordered_day,
                                     pay_plan, finance_loan, loan_ccy)
  values (v_id, p_airline, 'owned', v_dep, q.price_usd, q.delivery_day, v_day,
          case when p_pay = 'slb' then 'slb' else 'cash' end, p_pay in ('loan', 'loan_inr'),
          case when p_pay = 'loan_inr' then 'inr' else 'usd' end);
  return jsonb_build_object('aircraft_id', v_id, 'reg', v_reg, 'arrives_day', q.delivery_day,
                            'price_usd', q.price_usd, 'deposit_inr', v_dep);
end $$;

-- route_study from 0022: the world's demand growth (0027)
create or replace function public.route_study(p_airline uuid, p_a text, p_b text, p_depth text default 'quick') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype; m public.markets%rowtype; s public.route_studies%rowtype;
  v_day int; v_w numeric; v_cost numeric; v_e numeric;
  v_fly numeric; v_turn numeric; v_seats numeric; v_days int; v_grow numeric; v_untap numeric; v_block numeric;
  v_sb numeric; v_sl numeric; v_su numeric;
begin
  rw := game.actor(p_airline); v_day := rw.game_day + 1;
  if p_depth is null or p_depth not in ('quick', 'full') then raise exception 'A study is quick or full'; end if;
  select * into m from public.markets where a = least(upper(p_a), upper(p_b)) and b = greatest(upper(p_a), upper(p_b));
  if not found then raise exception 'There is no market between % and %', p_a, p_b; end if;
  v_cost := game.param('study_' || p_depth || '_inr');
  v_w := game.param('study_' || p_depth || '_width');
  perform game.book(p_airline, v_day, -v_cost, 'study',
                    format('%s route study, %s-%s', initcap(p_depth), m.a, m.b), -v_cost);

  select sum(d.pax_econ + d.pax_biz), sum(d.spill), sum(d.seats_econ + d.seats_biz), count(distinct d.game_day)
    into v_fly, v_turn, v_seats, v_days
    from public.routes r join public.route_daily d on d.route_id = r.id and d.game_day > rw.game_day - 28
   where r.world_id = rw.id and least(r.origin, r.dest) = m.a and greatest(r.origin, r.dest) = m.b;

  s.airline_id := p_airline; s.world_id := rw.id; s.a := m.a; s.b := m.b; s.game_day := v_day; s.depth := p_depth;
  select count(distinct r.airline_id) into s.carriers from public.routes r
   where r.world_id = rw.id and r.status = 'open' and least(r.origin, r.dest) = m.a and greatest(r.origin, r.dest) = m.b
     and exists (select 1 from public.rotations ro where ro.route_id = r.id);

  -- each figure gets its own error, then the range around it
  if coalesce(v_fly, 0) > 0 then
    v_e := greatest(0.3, 1 + v_w / 2 * game.rand_normal());
    s.flying_lo := round(v_fly / v_days / 2 * v_e * (1 - v_w)); s.flying_hi := round(v_fly / v_days / 2 * v_e * (1 + v_w));
    v_e := greatest(0.3, 1 + v_w / 2 * game.rand_normal());
    s.turned_lo := round(v_turn / v_days / 2 * v_e * (1 - v_w)); s.turned_hi := round(v_turn / v_days / 2 * v_e * (1 + v_w));
    v_e := greatest(0.3, 1 + v_w / 4 * game.rand_normal());
    s.lf_lo := round(least(1, v_fly / v_seats * v_e * (1 - v_w / 2)), 3); s.lf_hi := round(least(1, v_fly / v_seats * v_e * (1 + v_w / 2)), 3);
  else
    -- one airline, two round trips a day, reference fare, standard A320neo cabin: P(fly) = e^U / (1 + e^U) per segment
    v_grow := power(1 + game.wparam(rw.id, case when m.intl then 'growth_year_intl' else 'growth_year' end), (v_day - 1) / 364.0) * rw.demand_scale;
    v_block := m.km / 830.0 + 0.7;
    select f.biz, f.lei, f.bud into v_sb, v_sl, v_su from public.season_factors f
     where f.month = ((game.param('season_start_month')::int - 1 + (((v_day - 1) % 364) * 12) / 364) % 12) + 1;
    select sum(n * exp(u) / (1 + exp(u))) into v_untap from (values
      (m.n_biz * v_sb, game.param('seg_biz_a') - game.param('seg_biz_price') + game.param('seg_biz_freq') * ln(3)
                       + game.param('seg_biz_comfort') * (1 / 6.0) * sqrt(v_block)),
      (m.n_lei * v_sl, game.param('seg_lei_a') - game.param('seg_lei_price') + game.param('seg_lei_freq') * ln(3)
                       + game.param('seg_lei_comfort') * (1 / 6.0) * sqrt(v_block)),
      (m.n_bud * v_su, game.param('seg_bud_a') - game.param('seg_bud_price') + game.param('seg_bud_freq') * ln(3)
                       + game.param('seg_bud_comfort') * (1 / 6.0) * sqrt(v_block))) as x(n, u);
    v_untap := v_untap * v_grow;
    v_e := greatest(0.3, 1 + v_w / 2 * game.rand_normal());
    s.untapped_lo := round(v_untap * v_e * (1 - v_w)); s.untapped_hi := round(v_untap * v_e * (1 + v_w));
  end if;

  if p_depth = 'full' then
    s.biz_share := round(m.n_biz / (m.n_biz + m.n_lei + m.n_bud), 2);
    s.lei_share := round(m.n_lei / (m.n_biz + m.n_lei + m.n_bud), 2);
    s.bud_share := round(1 - s.biz_share - s.lei_share, 2);
    s.next_qtr := round(game.season_mix(v_day + 91, m.n_biz, m.n_lei, m.n_bud) / game.season_mix(v_day, m.n_biz, m.n_lei, m.n_bud)
                        * power(1 + game.wparam(rw.id, case when m.intl then 'growth_year_intl' else 'growth_year' end), 91 / 364.0), 2);
  end if;

  insert into public.route_studies (airline_id, world_id, a, b, game_day, depth, carriers, flying_lo, flying_hi, turned_lo, turned_hi,
                                    lf_lo, lf_hi, untapped_lo, untapped_hi, biz_share, lei_share, bud_share, next_qtr)
  values (s.airline_id, s.world_id, s.a, s.b, s.game_day, s.depth, s.carriers, s.flying_lo, s.flying_hi, s.turned_lo, s.turned_hi,
          s.lf_lo, s.lf_hi, s.untapped_lo, s.untapped_hi, s.biz_share, s.lei_share, s.bud_share, s.next_qtr)
  returning id into s.id;
  return to_jsonb(s);
end $$;

-- administer from 0014: the world's credit line; a bank's cut ends with administration (0027)
create or replace function game.administer(p_airline uuid, p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
begin
  delete from public.rotations ro using public.routes r where r.id = ro.route_id and r.airline_id = p_airline;
  update public.routes set status = 'closed' where airline_id = p_airline and status = 'open';
  update public.aircraft x
     set airline_id = null, base_iata = null, available_day = p_day,
         status = case when y.holding = 'wet' or (x.status = 'delivering' and y.ordered_day is not null)
                       then 'returned' else 'pool' end
    from public.aircraft_terms y
   where y.aircraft_id = x.id and y.airline_id = p_airline;
  delete from public.aircraft_terms where airline_id = p_airline;
  -- pilots (migration 0013): everyone is let go; local pilots, and hires not yet joined, go back to the market
  update public.pilot_market pm
     set captains = pm.captains + x.c, fos = pm.fos + x.f
    from (select family, sum(c) as c, sum(f) as f from (
            select family, captains - expats as c, fos as f from public.airline_pilots where airline_id = p_airline
            union all
            select family, coalesce(sum(n) filter (where rank = 'c'), 0), coalesce(sum(n) filter (where rank = 'f'), 0) from public.pilot_moves
             where airline_id = p_airline and not done and kind = 'hire' group by family) y
          group by family) x
   where pm.world_id = p_world and pm.family = x.family;
  update public.airline_pilots set captains = 0, fos = 0, expats = 0, need = 0 where airline_id = p_airline;
  update public.pilot_moves set done = true where airline_id = p_airline and not done;
  insert into public.transactions (airline_id, game_day, kind, amount_inr, note)
  select p_airline, p_day, 'administration', game.param('restart_cash_inr') - cash_inr,
         'Administration: fleet and debts gone, restart capital paid in'
    from public.airline_finance where airline_id = p_airline;
  update public.airline_finance
     set cash_inr = game.param('restart_cash_inr'), debt_inr = 0, insolvent_days = 0,
         credit_limit_inr = round(game.wparam((select world_id from public.airlines where id = p_airline), 'credit_limit_inr') * game.param('restart_credit_share')),
         credit_cut_from = null
   where airline_id = p_airline;
  update public.airlines
     set administrations = administrations + 1, brand = greatest(0, brand - game.param('restart_brand_hit')), marketing_inr_day = 0
   where id = p_airline;
  insert into public.news (world_id, game_day, airline_id, kind, body)
  select p_world, p_day, p_airline, 'administration', name || ' has gone into administration and restarts with reduced capital.'
    from public.airlines where id = p_airline;
end $$;

-- admin_set_week_hours: the world's founder too (0027)
create or replace function public.admin_set_week_hours(p_world uuid, p_hours numeric) returns numeric
language plpgsql security definer set search_path = '' as $$
declare w public.worlds; v_speed numeric;
begin
  perform game.require_world_admin(p_world);   -- 0027: or the world's founder
  if p_hours is null or p_hours < 0.25 or p_hours > 168 then
    raise exception 'Choose between 15 minutes and 7 days for a game week';
  end if;
  select * into w from public.worlds where id = p_world for update;
  if not found then raise exception 'World not found'; end if;
  if w.status = 'ended' then raise exception 'This season is over'; end if;
  v_speed := round(168 / p_hours, 4);
  w.speed := v_speed;
  if w.status in ('running', 'paused') then
    update public.worlds
       set speed = v_speed, paused_seconds = 0,
           started_at = now() - make_interval(secs => game.clock_seconds(w, w.game_day)),
           paused_at = case when w.status = 'paused' then now() else null end
     where id = p_world;
  else
    update public.worlds set speed = v_speed where id = p_world;
  end if;
  insert into public.news (world_id, game_day, kind, body, private)
  values (p_world, w.game_day, 'world', format('The clock changes: a game week now takes %s of real time.',
          case when p_hours < 1 then round(p_hours * 60) || ' minutes' when p_hours = 1 then '1 hour' else round(p_hours, 1) || ' hours' end), false);
  return v_speed;
end $$;

-- admin_set_places: the world's founder too (0027)
create or replace function public.admin_set_places(p_world uuid, p_places int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare w public.worlds; v_players int;
begin
  perform game.require_world_admin(p_world);   -- 0027: or the world's founder
  if p_places is null or p_places < 2 or p_places > 200 then raise exception 'Choose between 2 and 200 places'; end if;
  select * into w from public.worlds where id = p_world for update;
  if not found then raise exception 'World not found'; end if;
  if w.status = 'ended' then raise exception 'This season is over'; end if;
  if w.status <> 'setup' and p_places < w.max_airlines then raise exception 'Once a world has started, places can only go up'; end if;
  select count(*) into v_players from public.airlines where world_id = p_world and not is_ai;
  if p_places < v_players then raise exception 'This world already has % airlines', v_players; end if;
  update public.worlds set max_airlines = p_places, demand_scale = round(p_places / 50.0, 3) where id = p_world;
  -- pilots for the new places join the market at once; aircraft follow through the quarterly lessor refill and delivery slots
  update public.pilot_market pm
     set captains = pm.captains + f.pool_c * greatest(0, p_places - w.max_airlines), fos = pm.fos + f.pool_f * greatest(0, p_places - w.max_airlines)
    from public.pilot_families f where pm.world_id = p_world and f.id = pm.family;
  if w.status <> 'setup' then
    insert into public.news (world_id, game_day, kind, body)
    values (p_world, w.game_day, 'world', format('The world grows to %s places: more travellers, aircraft to lease and order, pilots and airport capacity.', p_places));
  end if;
  return jsonb_build_object('places', p_places, 'demand_scale', round(p_places / 50.0, 3));
end $$;

-- admin_pause_world: the world's founder too (0027)
create or replace function public.admin_pause_world(p_world uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform game.require_world_admin(p_world);   -- 0027: or the world's founder
  update public.worlds set status = 'paused', paused_at = now() where id = p_world and status = 'running';
  if not found then raise exception 'This world is not running'; end if;
end $$;

-- admin_resume_world: the world's founder too (0027)
create or replace function public.admin_resume_world(p_world uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform game.require_world_admin(p_world);   -- 0027: or the world's founder
  update public.worlds
     set status = 'running', paused_seconds = paused_seconds + extract(epoch from now() - paused_at), paused_at = null
   where id = p_world and status = 'paused';
  if not found then raise exception 'This world is not paused'; end if;
end $$;

-- admin_world_invite: the world's founder too (0027)
create or replace function public.admin_world_invite(p_world uuid) returns text
language plpgsql stable security definer set search_path = '' as $$
declare v_code text;
begin
  perform game.require_world_admin(p_world);   -- 0027: or the world's founder
  select invite_code into v_code from public.world_secrets where world_id = p_world;
  if v_code is null then raise exception 'World not found'; end if;
  return v_code;
end $$;

-- tick from 0018: founded worlds start once enough players have joined, or close after their deadline; worlds played
-- When all are ready move on as soon as every player is ready (0027)
create or replace function game.tick() returns int
language plpgsql set search_path = '' as $$
declare
  rec record;
  w public.worlds%rowtype;
  v_due int; v_done int := 0; v_n int; v_early boolean;
  v_max int := 7 * greatest(1, game.param('tick_max_days')::int / 7);   -- whole weeks
begin
  for rec in
    select x.id, x.name, x.min_players, x.join_deadline,
           (select count(*) from public.airlines a where a.world_id = x.id and not a.is_ai) as players
      from public.worlds x where x.status = 'setup' and x.min_players is not null
  loop
    if rec.players >= rec.min_players then
      begin
        perform game.start_world(rec.id);
        insert into public.news (world_id, game_day, kind, body)
        values (rec.id, 0, 'world', format('%s starts with %s airlines: 13 weeks of pre-launch, then first flights.', rec.name, rec.players));
        if coalesce(game.param('start_first_week'), 0) >= 1 then
          select * into w from public.worlds where id = rec.id;
          update public.worlds set started_at = now() - make_interval(secs => game.clock_seconds(w, 7)) where id = rec.id;
          for i in 1..7 loop perform game.run_day(rec.id); end loop;
        end if;
      exception when others then
        insert into game.engine_log (world_id, game_day, message) values (rec.id, 0, 'start: ' || sqlerrm);
      end;
    elsif rec.join_deadline is not null and rec.join_deadline < now() then
      update public.worlds set status = 'ended', closed_at = now() where id = rec.id;
      insert into public.news (world_id, game_day, kind, body)
      values (rec.id, 0, 'world', format('%s closed: %s of the %s players needed joined in time.', rec.name, rec.players, rec.min_players));
    end if;
  end loop;

  for rec in select id from public.worlds where status = 'running' loop
    v_due := game.due_day(rec.id);
    select * into w from public.worlds where id = rec.id;
    v_early := w.turn_mode = 'ready' and w.game_day >= w.prelaunch_weeks * 7 and w.game_day + 7 <= w.season_days
               and v_due < w.game_day + 7
               and exists (select 1 from public.airlines a where a.world_id = w.id and not a.is_ai and a.status = 'active')
               and not exists (select 1 from public.airlines a where a.world_id = w.id and not a.is_ai and a.status = 'active'
                                                              and coalesce(a.ready_day, -1) < w.game_day);
    if v_early then v_due := w.game_day + 7; end if;
    v_n := 0;
    while v_n < v_max and (select game_day from public.worlds where id = rec.id) < v_due loop
      begin
        perform game.run_day(rec.id);
      exception when others then
        insert into game.engine_log (world_id, game_day, message)
        select rec.id, game_day + 1, sqlerrm from public.worlds where id = rec.id;
        exit;
      end;
      v_n := v_n + 1;
      v_done := v_done + 1;
    end loop;
    if v_early then   -- played early: the clock counts the next week from now
      select * into w from public.worlds where id = rec.id;
      update public.worlds set started_at = now() - make_interval(secs => game.clock_seconds(w, w.game_day)), paused_seconds = 0
       where id = rec.id;
    end if;
  end loop;
  return v_done;
end $$;

-- The scheduler runs every minute (was every 5), so ready worlds and full worlds move on quickly.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('game-tick');
    perform cron.schedule('game-tick', '* * * * *', 'select game.tick()');
  end if;
end $$;

-- Worlds made before 0027 keep their rules: a record of them for the app.
update public.worlds set rules = jsonb_build_object('region', 'india', 'turn', 'clock', 'places', max_airlines::text, 'money', '500',
       'banks', 'normal', 'growth', 'normal', 'shocks', 'real', 'bots', case when bot_scale = 0 then 'none' else 'normal' end)
 where rules = '{}'::jsonb;

revoke all on function game.params_for(uuid), game.require_world_admin(uuid), game.founder_status(uuid), game.bank_week(uuid, int)
  from public, anon, authenticated;
revoke all on function public.founder_status(), public.create_world(text, jsonb), public.set_turn_mode(uuid, text),
  public.set_ready(uuid, boolean), public.world_join_code(uuid) from public, anon;
grant execute on function public.founder_status(), public.create_world(text, jsonb), public.set_turn_mode(uuid, text),
  public.set_ready(uuid, boolean), public.world_join_code(uuid) to authenticated, service_role;

-- ... and the game values of those rules (as before, plus the Normal banks' debt limit; it only bites from an airline's
-- fifth quarter).
insert into public.world_params (world_id, key, num, public)
select w.id, e.key, e.value::numeric, true
  from public.worlds w, public.world_options o, jsonb_each_text(o.vals) e
 where w.status <> 'ended' and o.setting in ('money', 'banks', 'growth')
   and o.option = case o.setting when 'money' then '500' else 'normal' end
on conflict (world_id, key) do nothing;
