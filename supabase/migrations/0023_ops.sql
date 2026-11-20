-- Migration 0023: Ops (spec section 14.17). Three strategies for the whole fleet replace the pilot settings, each with a
-- cost or revenue the player sees within weeks (principle 8). Every number is (G).
-- 1. Fuel hedging: none, 25%, 50% or 75% of each week's fuel bought 13 weeks ahead at that week's price + 2%.
-- 2. Maintenance strategy: pay as you go, flight-hour contract (52 weeks), own hangar (setup cost and 13 weeks), lean.
-- 3. Operating style: fuel saver, standard, high utilisation (quick turns), punctual.
-- Also: cost per seat-km benchmarks (industry median by cost line), groundings counted, fuel shocks +25 to 45%, pilot pay and
-- spare pilots set automatically (market pay, 10% spare).

insert into public.game_params (key, num, note) values
('hedge_premium', 0.02, 'a fuel hedge costs this share above the week''s price'),
('hedge_lead_weeks', 13, 'fuel hedges are bought this many weeks ahead'),
('hedge_step', 0.25, 'hedged share of fuel goes in steps of this'),
('hedge_max', 0.75, 'most of a week''s fuel an airline can hedge'),
('turn_floor_min', 15, 'no turnaround is shorter than this, whatever the operating style'),
('benchmark_days', 28, 'cost benchmarks look back this many days'),
('benchmark_min_airlines', 3, 'a cost benchmark shows only with this many airlines flying')
on conflict (key) do update set num = excluded.num, note = excluded.note;
update public.game_params set num = 1.25 where key = 'event_fuel_mult_min';   -- fuel shocks +25 to 45% (owner, 20 Nov 2026)

-- Maintenance strategies (G). rate_mult multiplies maintenance per flight hour and per flight; age_k is how much it rises a
-- year of aircraft age; fixed_inr_week is the own hangar's cost a week; ground_mult and ground_len_mult scale technical
-- groundings and how long they last; engine_mult scales the share grounded in an engine crisis; otp_delta adds to
-- punctuality; lock_weeks: once in effect, kept at least this long; setup: paid on choosing, and the weeks before it opens.
create table public.maint_plans (
  key             text primary key,
  sort            int not null,
  name            text not null,
  blurb           text not null,
  good_for        text not null,
  rate_mult       numeric not null,
  age_k           numeric not null,
  fixed_inr_week  numeric not null default 0,
  ground_mult     numeric not null default 1,
  ground_len_mult numeric not null default 1,
  engine_mult     numeric not null default 1,
  otp_delta       numeric not null default 0,
  lock_weeks      int not null default 0,
  setup_inr       numeric not null default 0,
  setup_weeks     int not null default 0
);
insert into public.maint_plans values
('payg', 1, 'Pay as you go', 'Pay for each job as it comes. Bills climb as aircraft age.', 'Good for a young, small fleet.',
  1.00, 0.03, 0, 1.0, 1.0, 1.0, 0, 0, 0, 0),
('contract', 2, 'Flight-hour contract', 'A fixed rate per flight hour to the manufacturers. They carry the age risk and lend spare engines.',
  'Good for an ageing fleet, or when groundings hurt most.', 1.12, 0, 0, 0.7, 1.0, 0.5, 0.01, 52, 0, 0),
('hangar', 3, 'Own hangar', 'Your own engineers and hangar: a fixed cost a week, cheaper work, aircraft back sooner.',
  'Pays off from about 40 aircraft.', 0.75, 0.03, 60000000, 0.8, 0.7, 1.0, 0, 0, 1000000000, 13),
('lean', 4, 'Lean', 'Stretch every limit and keep few spares. The cheapest bills and the most breakdowns.',
  'A gamble for a cash crunch.', 0.85, 0.04, 0, 1.8, 1.0, 1.0, -0.02, 0, 0, 0);

-- Operating styles (G). fuel_mult multiplies fuel; hour_cost_mult multiplies pilots' flying pay, cabin crew hours and
-- maintenance (slower flights take longer); turn_delta_min changes every turnaround (and so how many round trips fit);
-- allowance_inr_turn is paid to cabin crew for each quick turn; otp_delta and brand_delta add to punctuality and to the
-- brand's target.
create table public.op_styles (
  key                text primary key,
  sort               int not null,
  name               text not null,
  blurb              text not null,
  good_for           text not null,
  fuel_mult          numeric not null default 1,
  hour_cost_mult     numeric not null default 1,
  turn_delta_min     numeric not null default 0,
  allowance_inr_turn numeric not null default 0,
  otp_delta          numeric not null default 0,
  brand_delta        numeric not null default 0
);
insert into public.op_styles values
('saver', 1, 'Fuel saver', 'Cruise a little slower: 4% less fuel, flights take 5% longer.', 'Good when fuel is dear.', 0.96, 1.05, 0, 0, -0.04, 0),
('standard', 2, 'Standard', 'Normal cruise speed and turnaround times.', 'A safe default.', 1, 1, 0, 0, 0, 0),
('quick', 3, 'High utilisation', 'Quick turns: cabin crew clean and board fast, turns 10 minutes shorter.',
  'Good when aircraft are scarce, or in peak weeks.', 1, 1, -10, 2500, -0.04, -2),
('punctual', 4, 'Punctual', 'Cruise faster and pad the turns: 4% more fuel, fewer round trips fit.',
  'Good for business-heavy routes or a weak brand.', 1.04, 1, 8, 0, 0.06, 3);

-- Each airline's choices. A new maintenance strategy waits in maint_next until maint_next_day.
create table public.airline_ops (
  airline_id         uuid primary key references public.airlines on delete cascade,
  maint_plan         text not null default 'payg' references public.maint_plans,
  maint_next         text references public.maint_plans,
  maint_next_day     int,
  maint_locked_until int not null default 0,
  op_style           text not null default 'standard' references public.op_styles,
  hedge_share        numeric not null default 0 check (hedge_share between 0 and 1)
);
insert into public.airline_ops (airline_id) select id from public.airlines on conflict do nothing;
create or replace function game.airline_ops_new() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.airline_ops (airline_id) values (new.id) on conflict do nothing;
  return new;
end $$;
create trigger airlines_ops_new after insert on public.airlines for each row execute function game.airline_ops_new();

-- Fuel bought ahead: for each flight week, the share of fuel hedged and its locked price.
create table public.fuel_hedges (
  airline_id   uuid not null references public.airlines on delete cascade,
  week         int not null,
  share        numeric not null,
  price_inr_kg numeric not null,
  primary key (airline_id, week)
);

-- Industry cost per seat-km by line: the median over airlines that flew in the last 28 days (G), refreshed each week.
create table public.cost_benchmarks (
  world_id  uuid not null references public.worlds on delete cascade,
  line      text not null,
  week      int not null,
  airlines  int not null,
  median_inr_ask numeric not null,
  primary key (world_id, line)
);

alter table public.airline_daily add column fuel_kg numeric not null default 0,
  add column hedge_inr numeric not null default 0,      -- fuel saved by hedges against today's price (negative: cost)
  add column groundings int not null default 0;          -- aircraft that went technical today
alter table public.aircraft add column grounded_day int;

alter table public.maint_plans enable row level security;
alter table public.op_styles enable row level security;
alter table public.airline_ops enable row level security;
alter table public.fuel_hedges enable row level security;
alter table public.cost_benchmarks enable row level security;
revoke all on public.maint_plans, public.op_styles, public.airline_ops, public.fuel_hedges, public.cost_benchmarks from anon, authenticated;
grant select on public.maint_plans, public.op_styles, public.airline_ops, public.fuel_hedges, public.cost_benchmarks to authenticated;
create policy read_all on public.maint_plans for select to authenticated using (true);
create policy read_all on public.op_styles for select to authenticated using (true);
create policy read_all on public.cost_benchmarks for select to authenticated using (true);
create policy read_own on public.airline_ops for select to authenticated
  using (airline_id in (select id from public.airlines where user_id = (select auth.uid())));
create policy read_own on public.fuel_hedges for select to authenticated
  using (airline_id in (select id from public.airlines where user_id = (select auth.uid())));

-- Pilot pay and spare pilots are no longer player settings: market pay and 10% spare for every airline.
update public.airline_finance f set pilot_pay = 1, pilot_buffer = 0.10
  from public.airlines a where a.id = f.airline_id and not a.is_ai;

-- The airline's operating style changes every turnaround, so how many round trips fit (rotations, refits).
create or replace function game.schedule_issue(p_aircraft uuid, p_range int, p_turn numeric,
                                               p_route uuid default null, p_trips int default null) returns text
language plpgsql stable set search_path = '' as $$
declare
  rt public.aircraft_types%rowtype;
  v_hours numeric;
  v_far text;
  v_turn numeric;
begin
  select y.* into rt from public.aircraft x join public.aircraft_types y on y.id = x.type_id where x.id = p_aircraft;
  select greatest(game.param('turn_floor_min'), p_turn + coalesce(st.turn_delta_min, 0)) into v_turn
    from public.aircraft x left join public.airline_ops ao on ao.airline_id = x.airline_id
    left join public.op_styles st on st.key = ao.op_style
   where x.id = p_aircraft;
  with plan as (
    select r.origin, r.dest, m.km, ro.weekly_trips as trips
      from public.rotations ro
      join public.routes r on r.id = ro.route_id
      join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
     where ro.aircraft_id = p_aircraft and r.id is distinct from p_route
    union all
    select r.origin, r.dest, m.km, p_trips
      from public.routes r
      join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
     where r.id = p_route and p_trips > 0)
  select sum(trips * 2 * (km::numeric / rt.cruise_kmh + rt.block_offset_h + v_turn / 60)),
         min(origin || '-' || dest) filter (where km > p_range)
    into v_hours, v_far from plan;
  if v_far is not null then
    return 'Route ' || v_far || ' is beyond this cabin''s range of ' || p_range || ' km';
  end if;
  if coalesce(v_hours, 0) > 7 * rt.day_window_h then
    return 'This plan needs ' || round(v_hours, 1) || ' hours a week; the aircraft can fly '
           || round(7 * rt.day_window_h) || '. Cut some frequencies first.';
  end if;
  return null;
end $$;

-- Groundings follow the maintenance strategy and are dated; a strategy chosen earlier takes effect (0023).
create or replace function game.day_fleet(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rec record;
  v_bal numeric; v_rent numeric; v_dep numeric; v_loan numeric;
  v_term int := game.param('lease_term_days')::int;
  v_gmin int := game.param('ground_days_min')::int;
  v_gmax int := game.param('ground_days_max')::int;
  v_gprob numeric := game.param('ground_prob_day');
  v_gage numeric := game.param('ground_age_k');
begin
  select * into rw from public.worlds where id = p_world;

  -- a maintenance strategy chosen earlier takes effect today (0023)
  insert into public.news (world_id, game_day, airline_id, kind, body, private)
  select p_world, p_day, ao.airline_id, 'fleet',
         case when ao.maint_next = 'hangar' then 'Your own hangar is open: maintenance now runs in-house.'
              else 'Your maintenance strategy is now ' || lower(mp.name) || '.' end, true
    from public.airline_ops ao
    join public.airlines al on al.id = ao.airline_id and al.world_id = p_world
    join public.maint_plans mp on mp.key = ao.maint_next
   where ao.maint_next_day <= p_day;
  update public.airline_ops ao
     set maint_plan = ao.maint_next, maint_next = null, maint_next_day = null, maint_locked_until = p_day + mp.lock_weeks * 7
    from public.airlines al, public.maint_plans mp
   where al.id = ao.airline_id and al.world_id = p_world and mp.key = ao.maint_next and ao.maint_next_day <= p_day;

  insert into public.news (world_id, game_day, airline_id, kind, body, private)
  select p_world, p_day, x.airline_id, 'fleet', t.name || ' ' || x.reg || ' has joined your fleet at ' || x.base_iata || '.', true
    from public.aircraft x join public.aircraft_types t on t.id = x.type_id
   where x.world_id = p_world and x.status = 'delivering' and x.available_day <= p_day and x.airline_id is not null;

  -- new aircraft from the manufacturer: borrow the balance, pay it, or sell and lease back
  for rec in
    select x.id, x.reg, y.airline_id, y.price_usd, y.deposit_inr, y.pay_plan, y.finance_loan, t.lease_usd_month
      from public.aircraft x
      join public.aircraft_terms y on y.aircraft_id = x.id
      join public.aircraft_types t on t.id = x.type_id
     where x.world_id = p_world and x.status = 'delivering' and x.available_day <= p_day and y.ordered_day is not null
  loop
    v_bal := round(rec.price_usd * rw.fx_inr_usd) - rec.deposit_inr;
    if rec.finance_loan then
      v_loan := round(v_bal / rw.fx_inr_usd, 2);
      update public.aircraft_terms
         set deposit_inr = 0, start_day = p_day, ordered_day = null, loan_usd = v_loan,
             loan_pay_usd_day = round(v_loan / (game.param('loan_years') * 364), 4)
       where aircraft_id = rec.id;
      perform game.book(rec.airline_id, p_day, 0, 'loan', 'Aircraft loan of $' || v_loan || ' for ' || rec.reg || ' on delivery');
    elsif rec.pay_plan = 'cash'
       and (select cash_inr from public.airline_finance where airline_id = rec.airline_id) >= v_bal then
      perform game.book(rec.airline_id, p_day, -v_bal, 'purchase', 'Balance paid on delivery of ' || rec.reg);
      update public.aircraft_terms set deposit_inr = 0, start_day = p_day, ordered_day = null where aircraft_id = rec.id;
    else
      v_rent := round(rec.lease_usd_month * game.param('slb_rent_mult'));
      v_dep := round(v_rent * game.param('lease_deposit_months') * rw.fx_inr_usd);
      perform game.book(rec.airline_id, p_day, rec.deposit_inr - v_dep, 'leaseback',
                        'Sale and leaseback of ' || rec.reg || ': order deposit returned, lease deposit paid', 0, true);
      update public.aircraft_terms
         set holding = 'lease', lease_usd_month = v_rent, lease_end_day = p_day + v_term, deposit_inr = v_dep,
             price_usd = null, start_day = p_day, ordered_day = null
       where aircraft_id = rec.id;
    end if;
  end loop;

  -- arrivals, finished refits, groundings that are over
  update public.aircraft set status = 'active'
   where world_id = p_world and airline_id is not null
     and status in ('delivering', 'refit', 'grounded') and available_day <= p_day;

  -- leases at the end of their term renew at today's market rent
  for rec in
    select y.aircraft_id, y.airline_id, y.lease_usd_month, x.reg, x.type_id, x.built_day
      from public.aircraft_terms y join public.aircraft x on x.id = y.aircraft_id
     where x.world_id = p_world and y.holding = 'lease' and y.lease_end_day < p_day and x.status <> 'delivering'
  loop
    v_rent := game.lease_rent_usd(p_world, rec.type_id, rec.built_day, p_day);
    update public.aircraft_terms set lease_usd_month = v_rent, lease_end_day = lease_end_day + v_term
     where aircraft_id = rec.aircraft_id;
    insert into public.news (world_id, game_day, airline_id, kind, body, private)
    values (p_world, p_day, rec.airline_id, 'fleet', 'The lease on ' || rec.reg || ' was renewed at $' || v_rent
            || ' a month (was $' || rec.lease_usd_month || ').', true);
  end loop;

  -- fleet-wide engine events starting today
  for rec in select * from public.events where world_id = p_world and kind = 'engine_grounding' and starts_day = p_day loop
    update public.aircraft x set status = 'grounded', available_day = rec.ends_day + 1, grounded_day = p_day
      from (select al.id, coalesce(mp.engine_mult, 1) as em
              from public.airlines al
              left join public.airline_ops ao on ao.airline_id = al.id
              left join public.maint_plans mp on mp.key = ao.maint_plan
             where al.world_id = p_world) q
     where x.world_id = p_world and x.type_id = rec.payload ->> 'type' and x.status = 'active' and x.airline_id = q.id
       and random() < (rec.payload ->> 'share')::numeric * q.em;
  end loop;

  -- random technical groundings, more often with age (a wet lessor covers its own aircraft)
  update public.aircraft x
     set status = 'grounded', grounded_day = p_day,
         available_day = p_day + greatest(1, round((v_gmin + floor(random() * (v_gmax - v_gmin + 1))) * q.gl))::int
    from (select al.id, coalesce(mp.ground_mult, 1) as gm, coalesce(mp.ground_len_mult, 1) as gl
            from public.airlines al
            left join public.airline_ops ao on ao.airline_id = al.id
            left join public.maint_plans mp on mp.key = ao.maint_plan
           where al.world_id = p_world) q
   where x.world_id = p_world and x.status = 'active' and x.airline_id = q.id
     and exists (select 1 from public.aircraft_terms y where y.aircraft_id = x.id and y.holding <> 'wet')
     and random() < v_gprob * (1 + v_gage * greatest(0, p_day - x.built_day) / 364.0) * q.gm;
end $$;

-- Costs, punctuality and brand follow the strategies; fuel at the hedged price (0023).
create or replace function game.day_ops(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  g record;
  v_sb numeric; v_sl numeric; v_su numeric; v_grow numeric;
  v_pbh numeric; v_res numeric := game.param('pilot_reserve'); v_aug_bh numeric := game.param('pilot_aug_bh'); v_aug numeric := game.param('pilot_aug_mult');
begin
  select * into rw from public.worlds where id = p_world;
  select * into g from jsonb_to_record((select jsonb_object_agg(key, num) from public.game_params)) as x(
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
    refund numeric default 0                                -- selling worlds: money back for today's cancelled flights
  ) on commit drop;
  create temp table if not exists _acx (   -- migration 0017: what holding each aircraft costs today, and the hours it flew
    aircraft_id uuid primary key, airline_id uuid, fixed numeric, bh numeric
  ) on commit drop;
  truncate pg_temp._rot, pg_temp._prod, pg_temp._acx;

  -- Ops (migration 0023): each airline's maintenance strategy, operating style and this week's fuel hedge
  create temp table if not exists _ops (
    airline_id uuid primary key, rate numeric, age_k numeric, fixed_day numeric, fuel_mult numeric, hour_mult numeric,
    turn_d numeric, allowance numeric, otp_d numeric, brand_d numeric, h_share numeric, h_price numeric
  ) on commit drop;
  truncate pg_temp._ops;
  insert into pg_temp._ops
  select al.id, coalesce(mp.rate_mult, 1), coalesce(mp.age_k, g.age_maint_per_year), coalesce(mp.fixed_inr_week, 0) / 7,
         coalesce(st.fuel_mult, 1), coalesce(st.hour_cost_mult, 1), coalesce(st.turn_delta_min, 0), coalesce(st.allowance_inr_turn, 0),
         coalesce(mp.otp_delta, 0) + coalesce(st.otp_delta, 0), coalesce(st.brand_delta, 0),
         coalesce(fh.share, 0), coalesce(fh.price_inr_kg, rw.fuel_inr_kg)
    from public.airlines al
    left join public.airline_ops ao on ao.airline_id = al.id
    left join public.maint_plans mp on mp.key = ao.maint_plan
    left join public.op_styles st on st.key = ao.op_style
    left join public.fuel_hedges fh on fh.airline_id = al.id and fh.week = game.week_of(p_day)
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
                * o.rate * (1 + o.age_k * x.age_y) * o.hour_mult * rw.fx_inr_usd end,
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
           when 'lease' then tm.lease_usd_month * rw.fx_inr_usd / 30.33
           when 'wet' then tm.wet_usd_bh * rw.fx_inr_usd * greatest(g.wet_min_hours_day, coalesce(u.bh, 0))
           else tm.price_usd * rw.fx_inr_usd * g.depreciation_year / 364
                + case when tm.loan_usd > 0 then tm.loan_usd * g.loan_rate_year / 364 * rw.fx_inr_usd else 0 end end
         + case when tm.holding = 'wet' then 0 else
             case when rw.pilots then 0 else t.pilot_fixed_inr_day end
             + game.cabin_crew(rw.crew_rule, ac.seats_econ + ac.seats_biz) * g.cabin_fixed_inr_day end,
         coalesce(u.bh, 0)
    from public.aircraft ac
    join public.aircraft_terms tm on tm.aircraft_id = ac.id
    join public.aircraft_types t on t.id = ac.type_id
    left join (select aircraft_id, sum(2 * f * block_h) as bh from pg_temp._rot where flown group by aircraft_id) u on u.aircraft_id = ac.id
   where ac.world_id = p_world and ac.status in ('active', 'grounded', 'refit')
     and exists (select 1 from public.airlines a0 where a0.id = ac.airline_id and a0.first_flight_day <= p_day);

  insert into public.route_daily (route_id, game_day, airline_id, flights, seats_econ, seats_biz, pax_econ, pax_biz,
                                  spill, revenue_inr, var_cost_inr, aircraft_cost_inr)
  select p.route_id, p_day, p.airline_id, 2 * p.f, round(2 * p.cap_e), round(2 * p.cap_b), p.pe, p.pb, round(2 * p.spill),
         round(p.rev + p.anc),
         round(c.var + g.dist_rev_share * p.rev + g.service_inr_pax * (p.pe + p.pb) + p.anc_cost),
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
                          + s.all_ * (g.dist_rev_share * p.rev + g.service_inr_pax * (p.pe + p.pb) + p.anc_cost)) as cost
                 from pg_temp._rot x
                 join pg_temp._prod p on p.route_id = x.route_id
                 cross join lateral (select coalesce(x.f * x.seats_e / nullif(p.cap_e, 0), 0) as e,
                                            coalesce(x.f * x.seats_b / nullif(p.cap_b, 0), 0) as b,
                                            coalesce(x.f * (x.seats_e + x.seats_b) / nullif(p.cap_e + p.cap_b, 0), 0) as all_) s
                where x.flown group by x.aircraft_id) z on z.aircraft_id = a.aircraft_id
   where a.airline_id is not null;

  insert into public.airline_daily (airline_id, game_day, pax, ask, rpk, rev_ticket, rev_anc, c_fuel, c_crew, c_maint,
    c_airport, c_rent, c_slots, c_dist, c_marketing, c_overhead, c_interest, c_other, c_depr, flights, cancelled, loan_repaid, refunds_inr,
    fuel_kg, hedge_inr, groundings)
  select al.id, p_day, coalesce(pr.pax, 0), coalesce(pr.ask, 0), coalesce(pr.rpk, 0),
         coalesce(pr.rev, 0), round(coalesce(pr.anc, 0)),
         round(coalesce(rc.fuel, 0)), round(coalesce(rc.crew, 0) + coalesce(fl.crew_fixed, 0) + coalesce(sal.pay, 0)), round(coalesce(rc.maint, 0) + coalesce(ox.fixed_day, 0)),
         round(coalesce(rc.airport, 0)), round(coalesce(fl.rent, 0)), round(coalesce(rc.slots, 0)),
         round(coalesce(g.dist_rev_share * pr.rev + g.service_inr_pax * pr.pax + pr.anc_cost, 0)), al.marketing_inr_day,
         round(g.overhead_fixed_inr_day + g.overhead_aircraft_inr_day * coalesce(fl.n, 0) + g.overhead_seat_inr_day * coalesce(fl.seats, 0)
               + g.base_fixed_inr_day * (select count(*) from public.bases bs where bs.airline_id = al.id)),
         round(fin.debt_inr * g.interest_year / 364 + coalesce(fl.loan_int, 0)), coalesce(tx.other, 0), round(coalesce(fl.depr, 0)),
         coalesce(rc.flights, 0), coalesce(rc.cancelled, 0), round(coalesce(fl.loan_prin, 0)), round(coalesce(pr.refund, 0)),
         round(coalesce(rc.kg, 0)), round(coalesce(rc.kg * rw.fuel_inr_kg - rc.fuel, 0)), coalesce(gr.n, 0)
    from public.airlines al
    join public.airline_finance fin on fin.airline_id = al.id
    left join (select airline_id, sum(pe + pb) as pax, sum(2 * (cap_e + cap_b) * km) as ask,
                      sum((pe + pb) * km) as rpk, sum(rev) as rev, sum(anc) as anc, sum(anc_cost) as anc_cost, sum(refund) as refund
                 from pg_temp._prod group by airline_id) pr on pr.airline_id = al.id
    left join (select airline_id, sum(c_fuel) as fuel, sum(fuel_kg) as kg, sum(c_crew) as crew, sum(c_maint) as maint,
                      sum(c_airport) as airport, sum(c_slots) as slots,
                      sum(2 * f) filter (where flown) as flights, sum(2 * f) filter (where not flown) as cancelled
                 from pg_temp._rot group by airline_id) rc on rc.airline_id = al.id
    left join (select tm.airline_id, count(*) as n, sum(ac.seats_econ + ac.seats_biz) as seats,
                      sum(case tm.holding
                            when 'lease' then tm.lease_usd_month * rw.fx_inr_usd / 30.33
                            when 'wet' then tm.wet_usd_bh * rw.fx_inr_usd * greatest(g.wet_min_hours_day, coalesce(u.bh, 0))
                            else 0 end) as rent,
                      sum(case when tm.holding = 'owned' then tm.price_usd * rw.fx_inr_usd * g.depreciation_year / 364 else 0 end) as depr,
                      sum(case when tm.holding = 'owned' and tm.loan_usd > 0
                               then tm.loan_usd * g.loan_rate_year / 364 * rw.fx_inr_usd else 0 end) as loan_int,
                      sum(case when tm.holding = 'owned' and tm.loan_usd > 0
                               then least(tm.loan_usd, tm.loan_pay_usd_day) * rw.fx_inr_usd else 0 end) as loan_prin,
                      sum(case when tm.holding = 'wet' then 0 else
                            case when rw.pilots then 0 else t.pilot_fixed_inr_day end
                            + game.cabin_crew(rw.crew_rule, ac.seats_econ + ac.seats_biz) * g.cabin_fixed_inr_day end) as crew_fixed
                 from public.aircraft ac
                 join public.aircraft_terms tm on tm.aircraft_id = ac.id
                 join public.aircraft_types t on t.id = ac.type_id
                 left join (select aircraft_id, sum(2 * f * block_h) as bh from pg_temp._rot where flown group by aircraft_id) u
                        on u.aircraft_id = ac.id
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

create or replace function game.run_day(p_world uuid) returns int
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  v_day int;
  v_ffd int;   -- first day of flights in this world (0018); before it, nothing flies and nothing is priced
begin
  perform pg_advisory_xact_lock(hashtextextended('day:' || p_world, 0));
  select * into rw from public.worlds where id = p_world for update;
  if not found or rw.status <> 'running' or rw.game_day >= rw.season_days then return null; end if;
  v_day := rw.game_day + 1;
  v_ffd := rw.prelaunch_weeks * 7 + 1;
  if rw.game_day = 0 then perform game.bot_seed(p_world); perform game.pilot_seed(p_world, v_day); end if;
  perform game.day_world(p_world, v_day);
  perform game.day_fleet(p_world, v_day);
  if (v_day - 1) % 7 = 0 then perform game.ops_week(p_world, v_day); end if;   -- fuel hedges (0023)
  if v_day >= v_ffd and not rw.selling then perform game.bot_prices(p_world, v_day); end if;
  perform game.day_pilots(p_world, v_day);
  if rw.selling and (v_day - 1) % 7 = 0 then   -- a week of selling (0019), after the computer-run airlines' choices (0021)
    perform game.bot_selling(p_world, v_day);
    perform game.sell_week(p_world, v_day);
  end if;
  perform game.day_ops(p_world, v_day);
  if v_day % 7 = 0 then perform game.ops_benchmarks(p_world, v_day); end if;   -- at each week's end, so a week flown shows at once (0023)
  if v_day % 91 = 0 and v_day >= v_ffd then
    perform game.day_quarter(p_world, v_day);
    perform game.bot_quarter(p_world, v_day);
  end if;
  perform game.day_solvency(p_world, v_day);
  update public.worlds set game_day = v_day, status = case when v_day >= season_days then 'ended' else status end
   where id = p_world;
  if v_day >= rw.season_days then
    insert into public.news (world_id, game_day, kind, body) values (p_world, v_day, 'season', 'The season has ended.');
  end if;
  return v_day;
end $$;

-- Pilot pay and spare pilots are set automatically (0023): only the engine and the admin change them.
create or replace function public.set_pilot_policy(p_airline uuid, p_pay numeric, p_buffer numeric, p_cadets int, p_expats boolean)
returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform game.actor(p_airline, false);
  if not game.is_server() then raise exception 'Pilot pay and spare pilots are set automatically'; end if;
  if p_pay is null or p_pay < game.param('pilot_pay_min') or p_pay > game.param('pilot_pay_max') then
    raise exception 'Pilot pay must be between % and % times the market rate', game.param('pilot_pay_min'), game.param('pilot_pay_max');
  end if;
  if p_buffer is null or p_buffer < 0 or p_buffer > game.param('pilot_buffer_max') then
    raise exception 'Spare pilots must be between 0 and % of need', game.param('pilot_buffer_max');
  end if;
  if p_cadets is null or p_cadets < 0 or p_cadets > game.param('pilot_cadets_max_qtr') then
    raise exception 'Cadets a quarter must be between 0 and %', game.param('pilot_cadets_max_qtr');
  end if;
  update public.airline_finance
     set pilot_pay = round(p_pay, 2), pilot_buffer = round(p_buffer, 2), pilot_cadets = p_cadets, pilot_expats = coalesce(p_expats, false)
   where airline_id = p_airline;
  return jsonb_build_object('pay', round(p_pay, 2), 'buffer', round(p_buffer, 2), 'cadets', p_cadets, 'expats', coalesce(p_expats, false));
end $$;

-- ---------- Ops: each week (run_day, at the start of every week) ----------
-- Fuel hedges for the week hedge_lead_weeks ahead, bought at today's price + the premium, and the cost benchmarks.
create or replace function game.ops_week(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  v_w int := game.week_of(p_day);
  v_lead int := game.param('hedge_lead_weeks')::int;
begin
  select * into rw from public.worlds where id = p_world;
  insert into public.fuel_hedges (airline_id, week, share, price_inr_kg)
  select ao.airline_id, v_w + v_lead, ao.hedge_share, round(rw.fuel_inr_kg * (1 + game.param('hedge_premium')), 2)
    from public.airline_ops ao join public.airlines al on al.id = ao.airline_id
   where al.world_id = p_world and al.status = 'active' and ao.hedge_share > 0
  on conflict (airline_id, week) do update set share = excluded.share, price_inr_kg = excluded.price_inr_kg;
  delete from public.fuel_hedges fh using public.airlines al
   where al.id = fh.airline_id and al.world_id = p_world and fh.week < v_w;

end $$;

-- The industry's cost per seat-km by line: the median over the airlines that flew in the last benchmark_days, refreshed at the
-- end of each week (after its last day is flown), so the week just flown shows at once.
create or replace function game.ops_benchmarks(p_world uuid, p_day int) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_days int := game.param('benchmark_days')::int;
begin
  -- each cost line per seat-km over the last benchmark_days, the median over the airlines that flew
  with per as (
    select d.airline_id, sum(d.ask) as ask,
           sum(d.c_fuel) as fuel, sum(d.c_rent + d.c_depr) as aircraft, sum(d.c_maint) as maint, sum(d.c_crew) as crew,
           sum(d.c_airport + d.c_slots) as airports, sum(d.c_dist + d.c_marketing) as sales, sum(d.c_overhead) as office
      from public.airline_daily d join public.airlines al on al.id = d.airline_id
     where al.world_id = p_world and al.status = 'active' and d.game_day > p_day - v_days
     group by d.airline_id having sum(d.ask) > 0),
  l as (
    select x.line, (x.v / p.ask)::float8 as cask from per p
    cross join lateral (values ('fuel', p.fuel), ('aircraft', p.aircraft), ('maintenance', p.maint), ('crew', p.crew),
                               ('airports', p.airports), ('sales', p.sales), ('office', p.office)) x(line, v))
  insert into public.cost_benchmarks (world_id, line, week, airlines, median_inr_ask)
  select p_world, line, game.week_of(p_day), count(*), round(percentile_cont(0.5) within group (order by cask)::numeric, 4)
    from l group by line having count(*) >= game.param('benchmark_min_airlines')
  on conflict (world_id, line) do update
    set week = excluded.week, airlines = excluded.airlines, median_inr_ask = excluded.median_inr_ask;
end $$;

-- ---------- Ops: the player's three strategies ----------
create or replace function public.set_hedge(p_airline uuid, p_share numeric) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  v_step numeric := game.param('hedge_step');
begin
  rw := game.actor(p_airline, false);
  if rw.status not in ('setup', 'running') then raise exception 'This world is not running'; end if;
  if p_share is null or p_share < 0 or p_share > game.param('hedge_max') + 1e-9
     or abs(p_share / v_step - round(p_share / v_step)) > 1e-9 then
    raise exception 'Choose no hedge, or up to % in steps of %', game.param('hedge_max'), v_step;
  end if;
  update public.airline_ops set hedge_share = round(p_share, 2) where airline_id = p_airline;
  return jsonb_build_object('share', round(p_share, 2),
                            'from_week', game.week_of(game.week_start_from(rw.game_day + 1)) + game.param('hedge_lead_weeks')::int);
end $$;

-- A new maintenance strategy takes effect at the start of the next week processed; an own hangar, after its setup weeks
-- (its setup cost is paid now). A flight-hour contract runs at least lock_weeks once in effect.
create or replace function public.set_maint_plan(p_airline uuid, p_plan text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  ao public.airline_ops%rowtype;
  mp public.maint_plans%rowtype;
  cur public.maint_plans%rowtype;
  v_day int; v_from int;
begin
  rw := game.actor(p_airline, false);
  if rw.status not in ('setup', 'running') then raise exception 'This world is not running'; end if;
  v_day := rw.game_day + 1;
  select * into mp from public.maint_plans where key = p_plan;
  if not found then raise exception 'Choose pay as you go, a flight-hour contract, an own hangar or lean'; end if;
  select * into ao from public.airline_ops where airline_id = p_airline for update;
  select * into cur from public.maint_plans where key = ao.maint_plan;
  if ao.maint_plan = p_plan and ao.maint_next is null then raise exception 'That is already your maintenance strategy'; end if;
  if ao.maint_plan <> p_plan and v_day < ao.maint_locked_until then
    raise exception 'Your % runs until week %', lower(cur.name), game.week_of(ao.maint_locked_until);
  end if;
  if ao.maint_plan = p_plan then   -- back to the strategy in effect: the change on its way is cancelled
    update public.airline_ops set maint_next = null, maint_next_day = null where airline_id = p_airline;
    return jsonb_build_object('plan', p_plan, 'from_day', null);
  end if;
  if ao.maint_next = p_plan then raise exception 'That change is already on its way'; end if;
  if mp.setup_inr > 0 then
    perform game.book(p_airline, v_day, -mp.setup_inr, 'maintenance', 'Setting up ' || lower(mp.name), -mp.setup_inr);
    v_from := game.week_start_from(v_day + mp.setup_weeks * 7);
  else
    v_from := game.week_start_from(v_day);
  end if;
  update public.airline_ops set maint_next = p_plan, maint_next_day = v_from where airline_id = p_airline;
  return jsonb_build_object('plan', p_plan, 'from_day', v_from);
end $$;

-- The operating style counts from the next day processed. Returns how many aircraft no longer fit their schedules.
create or replace function public.set_op_style(p_airline uuid, p_style text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  v_over int;
begin
  rw := game.actor(p_airline, false);
  if rw.status not in ('setup', 'running') then raise exception 'This world is not running'; end if;
  if not exists (select 1 from public.op_styles where key = p_style) then
    raise exception 'Choose fuel saver, standard, high utilisation or punctual';
  end if;
  update public.airline_ops set op_style = p_style where airline_id = p_airline;
  select count(*) into v_over
    from public.aircraft a
    cross join lateral public.layout_calc(a.type_id, a.biz_rows, a.biz_pitch, a.econ_pitch, rw.crew_rule) l
   where a.airline_id = p_airline and a.status in ('active', 'grounded', 'refit', 'delivering')
     and exists (select 1 from public.rotations ro where ro.aircraft_id = a.id)
     and game.schedule_issue(a.id, 1000000, l.min_turn_min) is not null;
  return jsonb_build_object('style', p_style, 'over', v_over);
end $$;

-- The airline's flying as scheduled now: one row per rotation, for the Ops previews.
create or replace function game.ops_rows(p_airline uuid, p_day int, p_rule text)
returns table (aircraft_id uuid, wet boolean, age_y numeric, trips int, km int, block_h numeric, fh numeric,
               maint_usd_fh numeric, maint_usd_cycle numeric, fuel_kg numeric, crew_inr_bh numeric, window_h numeric, turn_min numeric)
language sql stable set search_path = '' as $$
  select ac.id, tm.holding = 'wet', greatest(0, p_day - ac.built_day) / 364.0, ro.weekly_trips, m.km,
         m.km::numeric / t.cruise_kmh + t.block_offset_h, m.km::numeric / t.cruise_kmh + game.param('maint_fh_offset'),
         t.maint_usd_fh, t.maint_usd_cycle,
         (t.fuel_fixed_kg + t.fuel_per_km_kg * m.km) * 0.97 * (1 + game.param('age_fuel_per_year') * greatest(0, p_day - ac.built_day) / 364.0),
         t.pilot_inr_bh + game.cabin_crew(p_rule, ac.seats_econ + ac.seats_biz) * game.param('cabin_inr_bh'),
         t.day_window_h, l.min_turn_min
    from public.rotations ro
    join public.aircraft ac on ac.id = ro.aircraft_id
    join public.aircraft_terms tm on tm.aircraft_id = ac.id
    join public.aircraft_types t on t.id = ac.type_id
    join public.routes r on r.id = ro.route_id
    join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
    cross join lateral public.layout_calc(ac.type_id, ac.biz_rows, ac.biz_pitch, ac.econ_pitch, p_rule) l
   where ac.airline_id = p_airline and ac.status in ('active', 'grounded', 'refit', 'delivering')
$$;

-- What each option would do for this airline now, from its schedule as it stands (a fuel load of 85%, today's fuel price).
create or replace function public.ops_preview(p_airline uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  ra public.airlines%rowtype; rw public.worlds%rowtype; ao public.airline_ops%rowtype;
  cp public.maint_plans%rowtype; cs public.op_styles%rowtype;
  v_day int; v_n int; v_age numeric; v_gq numeric; v_floor numeric := game.param('turn_floor_min');
  v_plans jsonb; v_styles jsonb; v_hedges jsonb;
begin
  select * into ra from public.airlines where id = p_airline;
  if not found then raise exception 'Airline not found'; end if;
  if not game.is_server() and (auth.uid() is null or ra.user_id is distinct from auth.uid()) then
    raise exception 'This is not your airline';
  end if;
  select * into rw from public.worlds where id = ra.world_id;
  select * into ao from public.airline_ops where airline_id = p_airline;
  select * into cp from public.maint_plans where key = ao.maint_plan;
  select * into cs from public.op_styles where key = ao.op_style;
  v_day := greatest(rw.game_day, 1);
  select count(*), coalesce(avg(greatest(0, v_day - ac.built_day) / 364.0), 0) into v_n, v_age
    from public.aircraft ac join public.aircraft_terms tm on tm.aircraft_id = ac.id
   where ac.airline_id = p_airline and ac.status in ('active', 'grounded', 'refit') and tm.holding <> 'wet';
  -- technical groundings a quarter at today's ages, before the strategy
  v_gq := v_n * game.param('ground_prob_day') * (1 + game.param('ground_age_k') * v_age) * 91;

  select jsonb_agg(jsonb_build_object(
           'key', mp.key, 'cost_week', round(coalesce(x.v, 0) * mp.rate_mult * cs.hour_cost_mult + mp.fixed_inr_week),
           'fixed_week', mp.fixed_inr_week, 'groundings_qtr', round(v_gq * mp.ground_mult, 1),
           'days_qtr', round(v_gq * mp.ground_mult * (game.param('ground_days_min') + game.param('ground_days_max')) / 2 * mp.ground_len_mult, 1),
           'otp_delta', mp.otp_delta, 'lock_weeks', mp.lock_weeks, 'setup_inr', mp.setup_inr, 'setup_weeks', mp.setup_weeks)
         order by mp.sort) into v_plans
    from public.maint_plans mp
    left join lateral (select sum(r.trips * 2 * (r.fh * r.maint_usd_fh + r.maint_usd_cycle) * (1 + mp.age_k * r.age_y)) * rw.fx_inr_usd as v
                         from game.ops_rows(p_airline, v_day, rw.crew_rule) r where not r.wet) x on true;

  select jsonb_agg(jsonb_build_object(
           'key', s.key, 'fuel_kg_week', round(coalesce(f.kg, 0) * s.fuel_mult),
           'fuel_week', round(coalesce(f.kg, 0) * s.fuel_mult * rw.fuel_inr_kg),
           'other_week', round(coalesce(f.hours_cost, 0) * (s.hour_cost_mult - 1) + s.allowance_inr_turn * coalesce(f.deps, 0)),
           'trips_week', coalesce(f.trips, 0), 'trips_fit', coalesce(c.fit, 0), 'over', coalesce(c.over, 0),
           'otp', round(least(0.99, greatest(0, ra.otp - cp.otp_delta - cs.otp_delta + cp.otp_delta + s.otp_delta)), 3),
           'brand_delta', s.brand_delta)
         order by s.sort) into v_styles
    from public.op_styles s
    left join lateral (
      select sum(r.trips * 2 * r.fuel_kg) as kg, sum(r.trips) as trips,
             sum(r.trips * 2) filter (where not r.wet) as deps,
             sum(r.trips * 2 * r.block_h * r.crew_inr_bh) filter (where not r.wet)
               + sum(r.trips * 2 * (r.fh * r.maint_usd_fh + r.maint_usd_cycle) * cp.rate_mult * (1 + cp.age_k * r.age_y) * rw.fx_inr_usd)
                   filter (where not r.wet) as hours_cost
        from game.ops_rows(p_airline, v_day, rw.crew_rule) r) f on true
    left join lateral (
      select sum(floor(7 * a.window_h / (a.h / a.trips)))::int as fit, count(*) filter (where a.h > 7 * a.window_h)::int as over
        from (select r.aircraft_id, max(r.window_h) as window_h, sum(r.trips) as trips,
                     sum(r.trips * 2 * (r.block_h + greatest(v_floor, r.turn_min + s.turn_delta_min) / 60)) as h
                from game.ops_rows(p_airline, v_day, rw.crew_rule) r group by r.aircraft_id) a
       where a.trips > 0) c on true;

  select coalesce(jsonb_agg(jsonb_build_object('week', fh.week, 'share', fh.share, 'price', fh.price_inr_kg) order by fh.week), '[]'::jsonb)
    into v_hedges from public.fuel_hedges fh where fh.airline_id = p_airline;

  return jsonb_build_object(
    'day', v_day, 'aircraft', v_n, 'avg_age', round(v_age, 1),
    'plan', ao.maint_plan, 'plan_next', ao.maint_next, 'plan_next_day', ao.maint_next_day, 'locked_until', ao.maint_locked_until,
    'style', ao.op_style, 'hedge_share', ao.hedge_share,
    'fuel_price', rw.fuel_inr_kg, 'fuel_normal', rw.fuel_walk, 'hedge_premium', game.param('hedge_premium'),
    'hedge_lead_weeks', game.param('hedge_lead_weeks'), 'hedges', v_hedges,
    'plans', v_plans, 'styles', v_styles);
end $$;

revoke all on function game.ops_week(uuid, int), game.ops_benchmarks(uuid, int), game.ops_rows(uuid, int, text), game.airline_ops_new() from public, anon, authenticated;
revoke all on function public.set_hedge(uuid, numeric), public.set_maint_plan(uuid, text), public.set_op_style(uuid, text),
  public.ops_preview(uuid) from public, anon;
grant execute on function public.set_hedge(uuid, numeric), public.set_maint_plan(uuid, text), public.set_op_style(uuid, text),
  public.ops_preview(uuid) to authenticated, service_role;
