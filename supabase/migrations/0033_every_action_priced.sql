-- Migration 0033 (spec 14.26): every money action has a price, and the rules are written for any region.
-- The owner asked on 25 Nov 2026 to close all ten loopholes of the audit doc "Airline game: every action mapped to cost
-- and revenue", for players and computer-run airlines alike, and to set the rules so a world can be founded anywhere:
-- India, the Middle East, the USA, Canada, Europe, Africa, South America or China. Only India is open today; the other
-- regions carry their passenger-rights, tax and interest values ready for when their airports are added.
--
--  1. Cancelling flights already sold. An airline's own cancellation (a cut in round trips, a route closed, a technical
--     grounding without a spare, too few pilots) refunds the traveller and, when the notice is shorter than the region's
--     rule, pays compensation: by distance band, capped at a multiple of the fare, plus a share of the fare. Flights
--     stopped by an airport or airspace closure pay refunds only. Cancelled flights count against brand, cuts included.
--     Overbooked travellers get the region's denied-boarding amount plus a multiple of the fare.
--  2. A fuel or dollar hedge locks the expected price 13 weeks ahead (the walk drifting back, the average shock) plus
--     the premium, not today's price.
--  3. Administration restarts with a share of the world's own starting money, and every administration costs the season
--     score one starting stake.
--  4. Cash earns the region's deposit rate (credit keeps the Banks choice's rate).
--  5. Giving a leased aircraft back early costs the rest of the rent up to lease_break_months (6), not just the deposit.
--  6. A new route costs route_launch_inr to launch; moving an aircraft to another base costs a ferry flight.
--  7. Bases can be closed (close_base) when nothing is based or starts there.
--  8. Wet leases come from a limited supply per world (wet_per_place per type, per place), run at least wet_min_weeks,
--     and the starter aircraft is cheaper (wet_starter_mult).
--  9. Computer-run airlines take new aircraft from the lessor pool like players, the bank's limit applies to them, they
--     trim to the free seats between countries (their starting network excepted), and when they run out of money their
--     owners restructure them: the hole is filled, the worst routes close and brand falls.
-- 10. Tax on each quarter's profit after losses carried forward, and hull insurance on every aircraft not wet leased.
-- The old rules stay reachable through game values for the older checks (run.mjs).

-- ---------- game values (G) ----------
insert into public.game_params (key, num, note) values
('cancel_notice_days', 1, 'region: an airline''s own cancellation of a flight sold, made fewer than this many days before it flies, pays compensation (India: under 24 hours)'),
('cancel_km_1', 250, 'region: compensation band 1 up to this distance (India: block time under an hour)'),
('cancel_km_2', 1080, 'region: compensation band 2 up to this distance (India: block time up to two hours)'),
('cancel_comp_1_inr', 5000, 'region: compensation a traveller, band 1'),
('cancel_comp_2_inr', 7500, 'region: compensation a traveller, band 2'),
('cancel_comp_3_inr', 10000, 'region: compensation a traveller, band 3'),
('cancel_cap_fare_mult', 1, 'region: the band amount is capped at this multiple of the fare (India: one-way fare)'),
('cancel_fare_share', 0, 'region: compensation as a share of the fare, on top of the band amount'),
('denied_fare_mult', 0, 'region: denied-boarding compensation as a multiple of the fare, on top of denied_comp_inr'),
('cash_interest_year', 0.06, 'region: interest earned on cash, a year'),
('tax_rate', 0.25, 'region: tax on a quarter''s profit after losses carried forward'),
('insurance_year', 0.003, 'hull insurance a year, as a share of an aircraft''s value (not on wet leases)'),
('restart_cash_share', 0.5, 'administration: cash after a restart, as a share of the world''s starting money'),
('restart_score_mult', 1, 'administration: season score lost per administration, in starting stakes'),
('lease_break_months', 6, 'giving a leased aircraft back early costs the rest of the rent, up to this many months'),
('route_launch_inr', 2500000, 'launching a route: stations, sales and launch marketing (Rs 25 lakh)'),
('ferry_on', 1, '1: moving an aircraft to another base costs one empty flight'),
('wet_per_place', 0.2, 'wet lessors in a world: aircraft of each type per place'),
('wet_min_weeks', 13, 'a wet lease runs at least this long; ending sooner pays the minimum hours left'),
('wet_starter_mult', 1.5, 'the starter wet lease: cost as a multiple of all-in hourly cost (others: wet_lease_mult)'),
('hedge_expected', 1, '1: hedges lock the expected price 13 weeks ahead; 0: today''s price (before 0033)'),
('bot_from_pool', 1, '1: computer-run airlines take new aircraft from the lessor pool'),
('bot_equal_rules', 1, '1: banks, seat limits and money troubles apply to computer-run airlines too')
on conflict (key) do nothing;

-- ---------- the regions ----------
-- Passenger rights, tax and the interest cash earns, by region (the credit line's rate stays with the Banks choice), in rupees at the game's reference rates ($1 = Rs 90, EUR 1 = Rs 100,
-- CAD 1 = Rs 65). Sources and judgement calls are in spec 14.26. Only India is open; the others wait for their airports.
update public.world_options set vals = v.vals::jsonb
  from (values
    ('india',         '{"cancel_notice_days": 1, "cancel_km_1": 250, "cancel_km_2": 1080, "cancel_comp_1_inr": 5000, "cancel_comp_2_inr": 7500, "cancel_comp_3_inr": 10000, "cancel_cap_fare_mult": 1, "cancel_fare_share": 0, "denied_comp_inr": 10000, "denied_fare_mult": 0, "tax_rate": 0.25, "cash_interest_year": 0.06}'),
    ('europe',        '{"cancel_notice_days": 14, "cancel_km_1": 1500, "cancel_km_2": 3500, "cancel_comp_1_inr": 25000, "cancel_comp_2_inr": 40000, "cancel_comp_3_inr": 60000, "cancel_cap_fare_mult": 99, "cancel_fare_share": 0, "denied_comp_inr": 40000, "denied_fare_mult": 0, "tax_rate": 0.22, "cash_interest_year": 0.02}'),
    ('usa',           '{"cancel_notice_days": 0, "cancel_km_1": 1500, "cancel_km_2": 3500, "cancel_comp_1_inr": 0, "cancel_comp_2_inr": 0, "cancel_comp_3_inr": 0, "cancel_cap_fare_mult": 99, "cancel_fare_share": 0, "denied_comp_inr": 0, "denied_fare_mult": 2, "tax_rate": 0.256, "cash_interest_year": 0.035}'),
    ('canada',        '{"cancel_notice_days": 14, "cancel_km_1": 1500, "cancel_km_2": 3500, "cancel_comp_1_inr": 26000, "cancel_comp_2_inr": 26000, "cancel_comp_3_inr": 26000, "cancel_cap_fare_mult": 99, "cancel_fare_share": 0, "denied_comp_inr": 60000, "denied_fare_mult": 0, "tax_rate": 0.261, "cash_interest_year": 0.025}'),
    ('china',         '{"cancel_notice_days": 1, "cancel_km_1": 1500, "cancel_km_2": 3500, "cancel_comp_1_inr": 4000, "cancel_comp_2_inr": 4000, "cancel_comp_3_inr": 4000, "cancel_cap_fare_mult": 99, "cancel_fare_share": 0, "denied_comp_inr": 5000, "denied_fare_mult": 0, "tax_rate": 0.25, "cash_interest_year": 0.015}'),
    ('middle_east',   '{"cancel_notice_days": 14, "cancel_km_1": 1500, "cancel_km_2": 3500, "cancel_comp_1_inr": 0, "cancel_comp_2_inr": 0, "cancel_comp_3_inr": 0, "cancel_cap_fare_mult": 99, "cancel_fare_share": 0.75, "denied_comp_inr": 0, "denied_fare_mult": 2, "tax_rate": 0.15, "cash_interest_year": 0.04}'),
    ('africa',        '{"cancel_notice_days": 1, "cancel_km_1": 1500, "cancel_km_2": 3500, "cancel_comp_1_inr": 0, "cancel_comp_2_inr": 0, "cancel_comp_3_inr": 0, "cancel_cap_fare_mult": 99, "cancel_fare_share": 0.25, "denied_comp_inr": 0, "denied_fare_mult": 0.3, "tax_rate": 0.27, "cash_interest_year": 0.08}'),
    ('south_america', '{"cancel_notice_days": 3, "cancel_km_1": 1500, "cancel_km_2": 3500, "cancel_comp_1_inr": 5000, "cancel_comp_2_inr": 5000, "cancel_comp_3_inr": 5000, "cancel_cap_fare_mult": 99, "cancel_fare_share": 0, "denied_comp_inr": 30000, "denied_fare_mult": 0, "tax_rate": 0.34, "cash_interest_year": 0.09}')
  ) v(opt, vals)
 where world_options.setting = 'region' and world_options.option = v.opt;

-- every world made before 0033 is an India world: its region values, fixed like its other rules
insert into public.world_params (world_id, key, num, public)
select w.id, e.key, e.value::numeric, true
  from public.worlds w, public.world_options o, jsonb_each_text(o.vals) e
 where o.setting = 'region' and o.option = coalesce(w.rules ->> 'region', 'india')
on conflict (world_id, key) do nothing;

-- ---------- tables ----------
alter table public.route_weeks add column if not exists cut_in_e numeric not null default 0,
  add column if not exists cut_in_b numeric not null default 0,
  add column if not exists cut_in_trips numeric not null default 0;   -- seats and flights cut inside the notice (cancel_notice_days)
alter table public.airline_weeks add column if not exists cut_flights numeric not null default 0,   -- flights cut inside the notice
  add column if not exists cancel_comp_inr numeric not null default 0;                               -- compensation for them
alter table public.airline_daily add column if not exists c_insurance numeric not null default 0,
  add column if not exists i_cash numeric not null default 0,      -- interest earned on cash
  add column if not exists c_tax numeric not null default 0,       -- tax, on the last day of a quarter
  add column if not exists c_comp numeric not null default 0;      -- compensation for cancelled flights today (in c_other too)
alter table public.airline_finance add column if not exists tax_loss_inr numeric not null default 0;   -- losses carried forward
alter table public.aircraft_terms add column if not exists wet_min_until int,
  add column if not exists starter boolean not null default false;
alter table public.quarterly_reports add column if not exists tax_inr numeric;

-- ---------- helpers ----------
-- compensation a traveller for an airline's own cancellation, by distance band, capped at a multiple of the fare,
-- plus a share of the fare (the world's region values)
create or replace function game.cancel_comp(p_world uuid, p_km numeric, p_fare numeric) returns numeric
language sql stable set search_path = '' as $$
  select least(case when p_km <= game.wparam(p_world, 'cancel_km_1') then game.wparam(p_world, 'cancel_comp_1_inr')
                    when p_km <= game.wparam(p_world, 'cancel_km_2') then game.wparam(p_world, 'cancel_comp_2_inr')
                    else game.wparam(p_world, 'cancel_comp_3_inr') end,
               game.wparam(p_world, 'cancel_cap_fare_mult') * greatest(coalesce(p_fare, 0), 0))
         + game.wparam(p_world, 'cancel_fare_share') * greatest(coalesce(p_fare, 0), 0)
$$;

-- the expected fuel price p_days ahead: the walk drifting back to the reference, times the shock then in force (a shock
-- running past that day) or the average shock weighted by the share of time a shock is on
create or replace function game.fuel_expect(p_world uuid, p_days int) returns numeric
language sql stable set search_path = '' as $$
  select round((game.param('fuel_ref_inr_kg') * power(w.fuel_walk / game.param('fuel_ref_inr_kg'),
                                                       power(1 - game.param('fuel_revert_day'), p_days)))
         * coalesce((select (e.payload ->> 'mult')::numeric from public.events e
                      where e.world_id = w.id and e.kind = 'fuel_shock' and e.starts_day <= w.game_day and e.ends_day >= w.game_day + p_days
                      order by e.ends_day desc limit 1),
                    1 + s.share * ((game.wparam(w.id, 'event_fuel_mult_min') + game.wparam(w.id, 'event_fuel_mult_max')) / 2 - 1)), 2)
    from public.worlds w
    cross join lateral (select game.wparam(w.id, 'event_fuel_prob_day')
                               * (game.wparam(w.id, 'event_fuel_days_min') + game.wparam(w.id, 'event_fuel_days_max')) / 2 as pd) p
    cross join lateral (select p.pd / (1 + p.pd) as share) s
   where w.id = p_world
$$;

-- the expected rupee rate p_days ahead: the walk's drift, times a swing then in force or the average swing
create or replace function game.fx_expect(p_world uuid, p_days int) returns numeric
language sql stable set search_path = '' as $$
  select round(w.fx_walk * exp(game.param('fx_drift_year') * p_days / 364)
         * coalesce((select (e.payload ->> 'mult')::numeric from public.events e
                      where e.world_id = w.id and e.kind = 'fx_swing' and e.starts_day <= w.game_day and e.ends_day >= w.game_day + p_days
                      order by e.ends_day desc limit 1),
                    1 + s.share * ((game.wparam(w.id, 'event_fx_mult_min') + game.wparam(w.id, 'event_fx_mult_max')) / 2 - 1)), 3)
    from public.worlds w
    cross join lateral (select game.wparam(w.id, 'event_fx_prob_day')
                               * (game.wparam(w.id, 'event_fx_days_min') + game.wparam(w.id, 'event_fx_days_max')) / 2 as pd) p
    cross join lateral (select p.pd / (1 + p.pd) as share) s
   where w.id = p_world
$$;

-- one empty flight between two airports with this aircraft: fuel, crew, maintenance, landing and navigation
create or replace function game.ferry_cost(p_aircraft uuid, p_from text, p_to text) returns numeric
language sql stable set search_path = '' as $$
  select case when p_from = p_to or game.param('ferry_on') < 1 then 0 else round(
           (t.fuel_fixed_kg + t.fuel_per_km_kg * d.km) * 0.8 * w.fuel_inr_kg
           + (d.km / t.cruise_kmh + t.block_offset_h) * (t.pilot_inr_bh + game.cabin_crew(w.crew_rule, ac.seats_econ + ac.seats_biz) * game.param('cabin_inr_bh'))
           + ((d.km / t.cruise_kmh + game.param('maint_fh_offset')) * t.maint_usd_fh + t.maint_usd_cycle) * w.fx_inr_usd
           + t.landing_inr + t.nav_inr_km * d.km) end
    from public.aircraft ac
    join public.aircraft_types t on t.id = ac.type_id
    join public.worlds w on w.id = ac.world_id
    cross join lateral (select game.haversine_km(a.lat::float8, a.lon::float8, b.lat::float8, b.lon::float8)::numeric as km
                          from public.airports a, public.airports b where a.iata = p_from and b.iata = p_to) d
   where ac.id = p_aircraft
$$;

-- wet lessors: how many of a type are out with airlines in a world, and how many there are
create or replace function game.wet_room(p_world uuid, p_type text, out n_out int, out n_max int)
language sql stable set search_path = '' as $$
  select (select count(*)::int from public.aircraft ac join public.aircraft_terms tm on tm.aircraft_id = ac.id
           where ac.world_id = p_world and ac.type_id = p_type and tm.holding = 'wet' and not tm.starter
             and ac.status in ('delivering', 'active', 'grounded', 'refit')),
         (select ceil(game.param('wet_per_place') * w.max_airlines)::int from public.worlds w where w.id = p_world)
$$;


-- 8. wet leases: the starter rate and the minimum term
drop function if exists game.add_wet(uuid, uuid, text, text, int, int);
create or replace function game.add_wet(p_airline uuid, p_world uuid, p_type text, p_base text, p_day int, p_arrive int,
  p_starter boolean default false, out o_id uuid, out o_reg text, out o_rate numeric)
language plpgsql set search_path = '' as $$
declare
  s record; l record;
begin
  select * into s from game.std_layout(p_type, 1);
  select * into l from public.layout_calc(p_type, s.biz_rows, s.biz_pitch, s.econ_pitch,
                                          (select crew_rule from public.worlds where id = p_world));
  o_rate := game.wet_rate_usd(p_world, p_type);
  if p_starter then   -- 0033: the starter aircraft at wet_starter_mult instead of wet_lease_mult
    o_rate := round(o_rate * game.param('wet_starter_mult') / game.param('wet_lease_mult'));
  end if;
  insert into public.aircraft (world_id, type_id, airline_id, reg, built_day, status, available_day, base_iata,
                               biz_rows, biz_pitch, econ_pitch, seats_biz, seats_econ)
  values (p_world, p_type, p_airline, game.next_reg(), p_day - game.param('wet_age_years')::int * 364,
          case when p_arrive <= p_day then 'active' else 'delivering' end, p_arrive, p_base,
          s.biz_rows, s.biz_pitch, s.econ_pitch, l.seats_biz, l.seats_econ)
  returning id, reg into o_id, o_reg;
  insert into public.aircraft_terms (aircraft_id, airline_id, holding, wet_usd_bh, start_day, starter, wet_min_until)
  values (o_id, p_airline, 'wet', o_rate, p_arrive, p_starter,
          case when p_starter then null else p_arrive + game.param('wet_min_weeks')::int * 7 end);
end $$;


-- wet_lease from 0007: the supply limit and the minimum term
create or replace function public.wet_lease(p_airline uuid, p_type text, p_base text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rt public.aircraft_types%rowtype;
  w record;
  v_day int; v_base text; v_arr int; r record;
begin
  rw := game.actor(p_airline); v_day := rw.game_day + 1;
  select * into rt from public.aircraft_types where id = p_type;
  if not found then raise exception 'Unknown aircraft type'; end if;
  perform game.check_fleet_room(p_airline);
  v_base := game.check_base(p_airline, p_base, rt.runway_class);
  -- 0033: wet lessors are few, sized by the world's places
  select * into r from game.wet_room(rw.id, p_type);
  if r.n_out >= r.n_max then
    raise exception 'Wet lessors have no % free in this world: all % are out with airlines. Lease from the pool or order new.',
      rt.name, r.n_max;
  end if;
  v_arr := v_day + game.param('wet_lead_days')::int;
  select * into w from game.add_wet(p_airline, rw.id, p_type, v_base, v_day, v_arr);
  return jsonb_build_object('aircraft_id', w.o_id, 'reg', w.o_reg, 'arrives_day', v_arr, 'wet_usd_bh', w.o_rate,
                            'min_until_day', v_arr + game.param('wet_min_weeks')::int * 7);
end $$;


-- found_airline from 0027: the starter wet lease at its own rate
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
      select * into w from game.add_wet(v_id, rw.id, v_type, rp.iata, v_day, v_day, true);
      insert into public.news (world_id, game_day, airline_id, kind, body, private)
      select rw.id, v_day, v_id, 'fleet', 'A wet-leased ' || t.name || ', ' || w.o_reg || ', is ready at ' || rp.iata
             || ' and flies from your first flights in week ' || game.week_of(al.first_flight_day) || '. It costs $' || w.o_rate
             || ' a block hour, at least ' || game.param('wet_min_hours_day') || ' hours a day.', true
        from public.aircraft_types t, public.airlines al where t.id = v_type and al.id = v_id;
    end loop;
  end if;
  return v_id;
end $$;


-- return_aircraft from 0026: breaking a lease costs up to six months of rent; a wet lease its minimum term
create or replace function public.return_aircraft(p_airline uuid, p_aircraft uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rc public.aircraft%rowtype;
  rm public.aircraft_terms%rowtype;
  v_day int; v_cash numeric := 0; v_pnl numeric := 0; v_book numeric; v_note text; v_pool boolean := false;
begin
  rw := game.actor(p_airline); v_day := rw.game_day + 1;
  select * into rc from public.aircraft where id = p_aircraft and airline_id = p_airline for update;
  if not found or rc.status not in ('delivering', 'active', 'grounded', 'refit') then
    raise exception 'That aircraft is not in your fleet';
  end if;
  select * into rm from public.aircraft_terms where aircraft_id = rc.id;
  if rm.holding = 'lease' then
    -- the rent for the rest of the term is owed, up to lease_break_months of rent (0033; before: the deposit)
    v_pnl := -case when rc.status = 'delivering' then rm.deposit_inr
                   else least(round(rm.lease_usd_month * rw.fx_inr_usd * game.param('lease_break_months')),
                              round(rm.lease_usd_month * rw.fx_inr_usd / 30.33 * greatest(0, rm.lease_end_day - v_day))) end;
    v_cash := rm.deposit_inr + v_pnl; v_pool := true;
    v_note := 'Returned ' || rc.reg || case when v_pnl < 0 then '; early-return fee taken from the deposit' else '' end;
  elsif rm.holding = 'wet' then
    -- 0033: before the minimum term ends, the minimum hours left are owed
    v_pnl := -case when rm.wet_min_until is not null and rm.wet_min_until > v_day
                   then round(rm.wet_usd_bh * game.param('wet_min_hours_day') * rw.fx_inr_usd * (rm.wet_min_until - greatest(v_day, rm.start_day))) else 0 end;
    v_cash := v_pnl;
    v_note := 'Ended the wet lease of ' || rc.reg || case when v_pnl < 0 then '; the minimum term was paid' else '' end;
  elsif rc.status = 'delivering' then
    v_pnl := -rm.deposit_inr;
    v_note := 'Cancelled the order for ' || rc.reg || '; deposit forfeited';
  else
    v_book := round(game.book_value_usd(rm.price_usd, rm.start_day, v_day) * rw.fx_inr_usd);
    v_cash := round(v_book * game.param('sale_discount')); v_pnl := v_cash - v_book; v_pool := true;
    v_note := 'Sold ' || rc.reg;
    if coalesce(rm.loan_usd, 0) > 0 or rm.loan_inr > 0 then
      v_cash := v_cash - round(coalesce(rm.loan_usd, 0) * rw.fx_inr_usd) - round(rm.loan_inr);   -- 0026: rupee loans too
      v_note := v_note || '; its loan was repaid from the sale';
    end if;
  end if;
  delete from public.rotations where aircraft_id = rc.id;
  delete from public.aircraft_terms where aircraft_id = rc.id;
  update public.aircraft
     set airline_id = null, base_iata = null, available_day = v_day,
         status = case when v_pool then 'pool' else 'returned' end
   where id = rc.id;
  perform game.book(p_airline, v_day, v_cash, 'return', v_note, v_pnl, true);   -- 0033: owed even when cash is short
  return jsonb_build_object('cash_inr', v_cash, 'pnl_inr', v_pnl);
end $$;


-- open_route from 0022: the launch cost
create or replace function public.open_route(p_airline uuid, p_origin text, p_dest text,
                                             p_fare_econ int default null, p_fare_biz int default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rk public.markets%rowtype;
  f record;
  v_day int; v_o text := upper(trim(p_origin)); v_d text := upper(trim(p_dest)); v_id uuid;
begin
  rw := game.actor(p_airline, false);
  if rw.status not in ('setup', 'running') then raise exception 'This world is not running'; end if; v_day := rw.game_day + 1;
  if not exists (select 1 from public.bases where airline_id = p_airline and iata = v_o) then
    raise exception 'Routes must start at one of your bases';
  end if;
  select * into rk from public.markets where a = least(v_o, v_d) and b = greatest(v_o, v_d);
  if not found then raise exception 'There is no market between % and %', v_o, v_d; end if;
  if exists (select 1 from public.airports where iata in (v_o, v_d) and opens_day > v_day) then
    raise exception 'That airport has not opened yet';
  end if;
  select * into f from game.check_fares(rk.ref_fare, p_fare_econ, p_fare_biz);
  -- 0033: a launch costs stations, sales and launch marketing (a computer-run airline's starting network excepted)
  if not ((select is_ai from public.airlines where id = p_airline) and rw.game_day = 0) and game.param('route_launch_inr') > 0 then
    perform game.book(p_airline, v_day, -game.param('route_launch_inr'), 'launch',
                      'Launched ' || v_o || '-' || v_d, -game.param('route_launch_inr'));
  end if;
  select id into v_id from public.routes
   where airline_id = p_airline and least(origin, dest) = rk.a and greatest(origin, dest) = rk.b;
  if found then
    update public.routes set status = 'open', origin = v_o, dest = v_d, fare_econ = f.econ, fare_biz = f.biz, opened_day = v_day
     where id = v_id and status = 'closed';
    if not found then raise exception 'You already fly this route'; end if;
  else
    insert into public.routes (world_id, airline_id, origin, dest, fare_econ, fare_biz, opened_day)
    values (rw.id, p_airline, v_o, v_d, f.econ, f.biz, v_day) returning id into v_id;
  end if;
  return v_id;
end $$;


-- rebase_aircraft from 0004: a ferry flight
create or replace function public.rebase_aircraft(p_airline uuid, p_aircraft uuid, p_base text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rc public.aircraft%rowtype;
  v_base text; v_cost numeric;
begin
  rw := game.actor(p_airline);
  select * into rc from public.aircraft where id = p_aircraft and airline_id = p_airline for update;
  if not found then raise exception 'That aircraft is not in your fleet'; end if;
  if exists (select 1 from public.rotations where aircraft_id = rc.id) then
    raise exception 'Remove this aircraft''s rotations before moving it';
  end if;
  v_base := game.check_base(p_airline, p_base, (select runway_class from public.aircraft_types where id = rc.type_id));
  -- 0033: one empty flight to the new base (none for an aircraft still on its way)
  v_cost := case when rc.status = 'delivering' or rc.base_iata is null then 0 else game.ferry_cost(rc.id, rc.base_iata, v_base) end;
  if v_cost > 0 then
    perform game.book(p_airline, rw.game_day + 1, -v_cost, 'ferry', 'Ferry flight of ' || rc.reg || ' to ' || v_base, -v_cost, true);
  end if;
  update public.aircraft set base_iata = v_base where id = rc.id;
end $$;


-- 7. close a base
create or replace function public.close_base(p_airline uuid, p_iata text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  v_iata text := upper(trim(p_iata));
begin
  rw := game.actor(p_airline, false);
  if rw.status not in ('setup', 'running', 'paused') then raise exception 'This world is not running'; end if;
  if not exists (select 1 from public.bases where airline_id = p_airline and iata = v_iata) then
    raise exception 'You have no base at %', v_iata;
  end if;
  if (select count(*) from public.bases where airline_id = p_airline) <= 1 then raise exception 'An airline needs at least one base'; end if;
  if exists (select 1 from public.aircraft where airline_id = p_airline and base_iata = v_iata) then
    raise exception 'Move or return the aircraft based at % first', v_iata;
  end if;
  if exists (select 1 from public.routes where airline_id = p_airline and status = 'open' and origin = v_iata) then
    raise exception 'Close the routes that start at % first', v_iata;
  end if;
  delete from public.bases where airline_id = p_airline and iata = v_iata;
  insert into public.transactions (airline_id, game_day, kind, amount_inr, note, pnl_inr)
  values (p_airline, rw.game_day + 1, 'base', 0, 'Closed the base at ' || v_iata, 0);
end $$;
grant execute on function public.close_base(uuid, text) to authenticated, service_role;


-- administer from 0027: the restart is a share of the world's own starting money (0033)
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
  select p_airline, p_day, 'administration', round(game.param('restart_cash_share') * game.wparam(p_world, 'start_cash_inr')) - cash_inr,
         'Administration: fleet and debts gone, restart capital paid in'
    from public.airline_finance where airline_id = p_airline;
  update public.airline_finance
     set cash_inr = round(game.param('restart_cash_share') * game.wparam(p_world, 'start_cash_inr')), debt_inr = 0, insolvent_days = 0,
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


-- 9. a computer-run airline out of money is restructured by its owners
create or replace function game.bot_restructure(p_airline uuid, p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  r record; v_n int := 0; v_close int;
begin
  -- the worst quarter of its routes by the last 28 days' result close (never below bot_keep_routes)
  v_close := greatest(0, least(ceil((select count(*) from public.routes where airline_id = p_airline and status = 'open') * 0.25)::int,
                               (select count(*) from public.routes where airline_id = p_airline and status = 'open')::int
                                 - game.param('bot_keep_routes')::int));
  for r in
    select rt.id from public.routes rt
      left join (select route_id, sum(revenue_inr - var_cost_inr - aircraft_cost_inr) as res from public.route_daily
                  where airline_id = p_airline and game_day > p_day - 28 group by route_id) d on d.route_id = rt.id
     where rt.airline_id = p_airline and rt.status = 'open'
     order by coalesce(d.res, 0) limit v_close
  loop
    perform game.bot_close(p_airline, r.id, p_day); v_n := v_n + 1;
  end loop;
  insert into public.transactions (airline_id, game_day, kind, amount_inr, note)
  select p_airline, p_day, 'equity', -cash_inr, 'Owners fill the hole in a restructuring' from public.airline_finance where airline_id = p_airline;
  update public.airline_finance set cash_inr = 0, insolvent_days = 0 where airline_id = p_airline;
  update public.airlines set brand = greatest(0, brand - game.param('restart_brand_hit')) where id = p_airline;
  insert into public.news (world_id, game_day, airline_id, kind, body)
  select p_world, p_day, p_airline, 'administration',
         name || ' has run out of money. Its owners fill the hole and close ' || v_n || ' of its routes.'
    from public.airlines where id = p_airline;
end $$;


-- day_solvency from 0007: computer-run airlines restructured, not exempt (0033)
create or replace function game.day_solvency(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  rec record;
begin
  -- a shortfall is drawn from the credit line while it lasts. 0033: computer-run airlines count too; instead of
  -- administration their owners restructure them (game.bot_restructure), unless bot_equal_rules is 0.
  insert into public.transactions (airline_id, game_day, kind, amount_inr, note)
  select fin.airline_id, p_day, 'borrow', least(-fin.cash_inr, fin.credit_limit_inr - fin.debt_inr), 'Shortfall covered from the credit line'
    from public.airline_finance fin join public.airlines al on al.id = fin.airline_id
   where al.world_id = p_world and fin.cash_inr < 0 and fin.debt_inr < fin.credit_limit_inr;
  update public.airline_finance fin
     set debt_inr = fin.debt_inr + least(-fin.cash_inr, fin.credit_limit_inr - fin.debt_inr),
         cash_inr = fin.cash_inr + least(-fin.cash_inr, fin.credit_limit_inr - fin.debt_inr)
    from public.airlines al
   where al.id = fin.airline_id and al.world_id = p_world and fin.cash_inr < 0 and fin.debt_inr < fin.credit_limit_inr;

  update public.airline_finance fin
     set insolvent_days = case when fin.cash_inr < 0 then fin.insolvent_days + 1 else 0 end
    from public.airlines al
   where al.id = fin.airline_id and al.world_id = p_world and al.status = 'active'
     and (not al.is_ai or game.param('bot_equal_rules') >= 1);

  update public.airline_daily d set cash_end = fin.cash_inr, brand = al.brand, otp = al.otp
    from public.airline_finance fin join public.airlines al on al.id = fin.airline_id
   where d.airline_id = fin.airline_id and d.game_day = p_day and al.world_id = p_world;

  for rec in
    select fin.airline_id, al.is_ai from public.airline_finance fin join public.airlines al on al.id = fin.airline_id
     where al.world_id = p_world and al.status = 'active' and fin.insolvent_days >= game.param('insolvency_days')
  loop
    if rec.is_ai then perform game.bot_restructure(rec.airline_id, p_world, p_day);
    else perform game.administer(rec.airline_id, p_world, p_day); end if;
  end loop;
end $$;


-- bank_week from 0027: banks watch computer-run airlines too (0033)
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
     where al.world_id = p_world and (not al.is_ai or game.param('bot_equal_rules') >= 1) and al.status = 'active'
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


-- set_rotation from 0028: computer-run airlines trim to the free seats (0033)
create or replace function public.set_rotation(p_airline uuid, p_aircraft uuid, p_route uuid, p_weekly_trips int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rc public.aircraft%rowtype;
  rr public.routes%rowtype;
  l record;
  v_issue text;
  v_cc text; v_cname text; v_lim numeric; v_used numeric; v_seats int;
begin
  rw := game.actor(p_airline, false);
  if rw.status not in ('setup', 'running') then raise exception 'This world is not running'; end if;
  select * into rc from public.aircraft where id = p_aircraft and airline_id = p_airline for update;
  if not found or rc.status not in ('delivering', 'active', 'grounded', 'refit') then
    raise exception 'That aircraft is not in your fleet';
  end if;
  select * into rr from public.routes where id = p_route and airline_id = p_airline and status = 'open';
  if not found then raise exception 'That route is not open'; end if;
  if coalesce(p_weekly_trips, 0) = 0 then
    delete from public.rotations where aircraft_id = rc.id and route_id = rr.id;
    return jsonb_build_object('weekly_trips', 0);
  end if;
  if p_weekly_trips not between 1 and 84 then raise exception 'Round trips a week must be between 0 and 84'; end if;
  if rc.base_iata is null or rc.base_iata not in (rr.origin, rr.dest) then
    raise exception 'This aircraft is based at %, which is not on this route', rc.base_iata;
  end if;
  if (select min(runway_class) from public.airports where iata in (rr.origin, rr.dest))
     < (select runway_class from public.aircraft_types where id = rc.type_id) then
    raise exception 'A runway on this route is too short for this aircraft';
  end if;
  select * into l from public.layout_calc(rc.type_id, rc.biz_rows, rc.biz_pitch, rc.econ_pitch, rw.crew_rule);
  v_issue := game.schedule_issue(rc.id, l.range_km, l.min_turn_min, rr.id, p_weekly_trips);
  if v_issue is not null then raise exception '%', v_issue; end if;
  -- 0028: seats between countries. A player may add seats to a country with a limit only while seats are free; the
  -- computer-run airlines (incumbents) are counted but never refused.
  select f.country, sl.name into v_cc, v_cname
    from public.airports f join public.seat_limits sl on sl.country = f.country
   where f.iata in (rr.origin, rr.dest) and not f.is_india
     and exists (select 1 from public.airports i where i.iata in (rr.origin, rr.dest) and i.is_india);
  v_lim := case when v_cc is not null then game.seat_limit(rw.id, v_cc) end;
  -- 0033: a computer-run airline trims its flights to the free seats (its starting network excepted)
  if v_lim is not null and (select is_ai from public.airlines where id = p_airline) and rw.game_day > 0
     and game.param('bot_equal_rules') >= 1 then
    v_seats := rc.seats_econ + rc.seats_biz;
    v_used := game.seats_used(rw.id, v_cc) - coalesce((select weekly_trips from public.rotations
                                                         where aircraft_id = rc.id and route_id = rr.id), 0) * v_seats;
    if v_used + p_weekly_trips * v_seats > v_lim then
      p_weekly_trips := least(p_weekly_trips, greatest(0, floor((v_lim - v_used) / v_seats))::int);
      if p_weekly_trips = 0 then
        delete from public.rotations where aircraft_id = rc.id and route_id = rr.id;
        return jsonb_build_object('weekly_trips', 0);
      end if;
    end if;
  end if;
  if v_lim is not null and not (select is_ai from public.airlines where id = p_airline) then
    v_seats := rc.seats_econ + rc.seats_biz;
    v_used := game.seats_used(rw.id, v_cc) - coalesce((select weekly_trips from public.rotations
                                                         where aircraft_id = rc.id and route_id = rr.id), 0) * v_seats;
    if p_weekly_trips * v_seats > coalesce((select weekly_trips from public.rotations where aircraft_id = rc.id and route_id = rr.id), 0) * v_seats
       and v_used + p_weekly_trips * v_seats > v_lim then
      raise exception 'Seats between India and % are full in this world: % of % a week are taken, so % are free (% round trips with this aircraft). Free seats go to whoever flies them first.',
        v_cname, round(v_used), round(v_lim), greatest(0, round(v_lim - v_used)), greatest(0, floor((v_lim - v_used) / v_seats));
    end if;
  end if;
  insert into public.rotations (aircraft_id, route_id, weekly_trips) values (rc.id, rr.id, p_weekly_trips)
    on conflict (aircraft_id, route_id) do update set weekly_trips = excluded.weekly_trips;
  return jsonb_build_object('weekly_trips', p_weekly_trips);
end $$;


-- bot_balance from 0024: new aircraft from the lessor pool (0033)
create or replace function game.bot_balance(p_airline uuid, p_day int, p_quarter boolean) returns int
language plpgsql set search_path = '' as $$
declare
  grp record; r record; a record;
  v_world uuid; v_need int; v_have int; v_excess float8; v_cut int; v_ac uuid; v_n int := 0; v_adds int := 0;
  v_ret int := 0; v_ret_max int; v_min int := game.param('bot_min_weekly')::int;
begin
  select world_id into v_world from public.airlines where id = p_airline;
  create temp table if not exists _bot_grow (route_id uuid primary key) on commit drop;
  drop table if exists pg_temp._bg;
  create temp table _bg on commit drop as
  select p.base, p.type_id, p.biz_rows, coalesce(p.biz_pitch, 0) as bp, max(p.biz_pitch) as biz_pitch, p.econ_pitch,
         sum(p.trips::float8 / game.bot_fit(p.type_id, p.biz_rows, p.biz_pitch, p.econ_pitch, m.km)) as need,
         bool_or(p.route_id in (select g.route_id from pg_temp._bot_grow g)) as grew
    from game.bot_plan p join public.routes rt on rt.id = p.route_id
    join public.markets m on m.a = least(rt.origin, rt.dest) and m.b = greatest(rt.origin, rt.dest)
   where p.airline_id = p_airline and p.trips > 0
   group by p.base, p.type_id, p.biz_rows, coalesce(p.biz_pitch, 0), p.econ_pitch;

  for grp in select * from pg_temp._bg order by need desc loop
    v_need := ceil(grp.need - 1e-6)::int - (select count(*) from public.aircraft x
                 where x.airline_id = p_airline and x.status in ('active', 'grounded') and x.base_iata = grp.base
                   and x.type_id = grp.type_id and x.biz_rows = grp.biz_rows and coalesce(x.biz_pitch, 0) = grp.bp
                   and x.econ_pitch = grp.econ_pitch);
    -- idle aircraft of the same type and cabin at a base that has more than it needs
    while v_need > 0 loop
      select x.id into v_ac from public.aircraft x
       where x.airline_id = p_airline and x.status = 'active' and x.base_iata <> grp.base and x.type_id = grp.type_id
         and x.biz_rows = grp.biz_rows and coalesce(x.biz_pitch, 0) = grp.bp and x.econ_pitch = grp.econ_pitch
         and (select count(*) from public.aircraft y
               where y.airline_id = p_airline and y.status in ('active', 'grounded') and y.base_iata = x.base_iata
                 and y.type_id = x.type_id and y.biz_rows = x.biz_rows and coalesce(y.biz_pitch, 0) = coalesce(x.biz_pitch, 0)
                 and y.econ_pitch = x.econ_pitch)
             > coalesce((select ceil(b.need - 1e-6) from pg_temp._bg b
                          where b.base = x.base_iata and b.type_id = x.type_id and b.biz_rows = x.biz_rows
                            and b.bp = coalesce(x.biz_pitch, 0) and b.econ_pitch = x.econ_pitch), 0)
       order by (select count(*) from public.rotations ro where ro.aircraft_id = x.id), x.id
       limit 1;
      exit when not found;
      begin
        delete from public.rotations where aircraft_id = v_ac;
        perform public.rebase_aircraft(p_airline, v_ac, grp.base);
        v_need := v_need - 1; v_n := v_n + 1;
      exception when others then
        exit;
      end;
    end loop;
    -- new aircraft for routes that grew, at a quarter end. 0033: from the lessor pool, like a player (deposit, wait,
    -- at most pool_lease_max_qtr a quarter); before 0033 (bot_from_pool 0) they were made new
    while p_quarter and grp.grew and v_need > 0 and v_adds < game.param('bot_grow_adds')
          and (select count(*) from public.aircraft where airline_id = p_airline and status in ('active', 'grounded', 'refit', 'delivering'))
              < game.bot_fleet_cap(p_airline) loop
      if game.param('bot_from_pool') >= 1 then
        select x.id into v_ac from public.aircraft x
         where x.world_id = v_world and x.type_id = grp.type_id and x.status = 'pool'
         order by (x.seats_econ = (select seats_econ from public.layout_calc(grp.type_id, grp.biz_rows, grp.biz_pitch, grp.econ_pitch,
                                       (select crew_rule from public.worlds where id = v_world)))) desc, x.built_day desc
         limit 1;
        exit when v_ac is null;
        begin
          perform public.lease_aircraft(p_airline, v_ac, grp.base);
        exception when others then
          exit;
        end;
      else
        insert into public.aircraft (world_id, type_id, airline_id, reg, built_day, status, available_day, base_iata,
                                     biz_rows, biz_pitch, econ_pitch, seats_biz, seats_econ)
        select v_world, grp.type_id, p_airline, game.next_reg(), p_day, 'active', p_day, grp.base,
               grp.biz_rows, grp.biz_pitch, grp.econ_pitch, l.seats_biz, l.seats_econ
          from public.layout_calc(grp.type_id, grp.biz_rows, grp.biz_pitch, grp.econ_pitch,
                                  (select crew_rule from public.worlds where id = v_world)) l
        returning id into v_ac;
        insert into public.aircraft_terms (aircraft_id, airline_id, holding, lease_usd_month, lease_end_day, deposit_inr, start_day)
        values (v_ac, p_airline, 'lease', game.lease_rent_usd(v_world, grp.type_id, p_day, p_day),
                p_day + game.param('lease_term_days')::int, 0, p_day);
      end if;
      v_ac := null;
      v_need := v_need - 1; v_adds := v_adds + 1; v_n := v_n + 1;
    end loop;
    -- what still does not fit is trimmed: worst-earning route first, routes new to the plan last
    if v_need > 0 then
      v_have := ceil(grp.need - 1e-6)::int - v_need;
      v_excess := grp.need - v_have;
      for r in
        select p.route_id, p.trips, game.bot_fit(p.type_id, p.biz_rows, p.biz_pitch, p.econ_pitch, m.km) as fit,
               (p.since_day > p_day - game.param('bot_exit_min_days')) as fresh, game.bot_margin(p.route_id, p_day) as margin
          from game.bot_plan p join public.routes rt on rt.id = p.route_id
          join public.markets m on m.a = least(rt.origin, rt.dest) and m.b = greatest(rt.origin, rt.dest)
         where p.airline_id = p_airline and p.base = grp.base and p.type_id = grp.type_id and p.biz_rows = grp.biz_rows
           and coalesce(p.biz_pitch, 0) = grp.bp and p.econ_pitch = grp.econ_pitch and p.trips > 0
         order by fresh, margin nulls last, p.trips
      loop
        exit when v_excess <= 1e-6;
        v_cut := least(greatest(0, r.trips - v_min), ceil(v_excess * r.fit - 1e-6)::int);
        if v_cut > 0 then
          update game.bot_plan set trips = trips - v_cut where route_id = r.route_id;
          v_excess := v_excess - v_cut::float8 / r.fit; v_n := v_n + 1;
        end if;
      end loop;
      for r in   -- still too much: routes come off, worst first
        select p.route_id, p.trips, game.bot_fit(p.type_id, p.biz_rows, p.biz_pitch, p.econ_pitch, m.km) as fit,
               (p.since_day > p_day - game.param('bot_exit_min_days')) as fresh, game.bot_margin(p.route_id, p_day) as margin
          from game.bot_plan p join public.routes rt on rt.id = p.route_id
          join public.markets m on m.a = least(rt.origin, rt.dest) and m.b = greatest(rt.origin, rt.dest)
         where p.airline_id = p_airline and p.base = grp.base and p.type_id = grp.type_id and p.biz_rows = grp.biz_rows
           and coalesce(p.biz_pitch, 0) = grp.bp and p.econ_pitch = grp.econ_pitch and p.trips > 0
         order by fresh, margin nulls last, p.trips
      loop
        exit when v_excess <= 1e-6;
        update game.bot_plan set trips = 0 where route_id = r.route_id;
        v_excess := v_excess - r.trips::float8 / r.fit; v_n := v_n + 1;
      end loop;
    end if;
  end loop;

  -- the flights go onto the aircraft; routes with no flights left are closed
  perform game.bot_pack(p_airline);
  for r in select p.route_id from game.bot_plan p where p.airline_id = p_airline and p.trips < 1 loop
    perform game.bot_close(p_airline, r.route_id, p_day);
  end loop;

  -- idle aircraft at a quarter end: one spare stays at a big base, the rest go back (they leave the world)
  if p_quarter then
    v_ret_max := greatest(2, ceil(game.param('bot_return_share')
                   * (select count(*) from public.aircraft where airline_id = p_airline and status in ('active', 'grounded', 'refit'))))::int;
    for a in
      select x.id, row_number() over (partition by x.base_iata, x.type_id, x.biz_rows, coalesce(x.biz_pitch, 0), x.econ_pitch
                                      order by tm.lease_end_day desc nulls first, x.id) as k,
             (select count(*) from public.aircraft y
               where y.airline_id = p_airline and y.status in ('active', 'grounded') and y.base_iata = x.base_iata
                 and y.type_id = x.type_id and y.biz_rows = x.biz_rows and coalesce(y.biz_pitch, 0) = coalesce(x.biz_pitch, 0)
                 and y.econ_pitch = x.econ_pitch) as at_base
        from public.aircraft x left join public.aircraft_terms tm on tm.aircraft_id = x.id
       where x.airline_id = p_airline and x.status in ('active', 'grounded')
         and not exists (select 1 from public.rotations ro where ro.aircraft_id = x.id)
       order by tm.lease_end_day nulls last, x.id
    loop
      continue when a.k = 1 and a.at_base >= game.param('bot_spare_min');
      exit when v_ret >= v_ret_max;
      begin
        perform public.return_aircraft(p_airline, a.id);
        update public.aircraft set status = 'returned' where id = a.id and status = 'pool';
        v_ret := v_ret + 1; v_n := v_n + 1;
      exception when others then
        null;
      end;
    end loop;
  end if;
  return v_n;
end $$;


-- ops_week from 0027: hedges lock the expected price (0033)
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
  select ao.airline_id, v_w + v_lead, ao.hedge_share,
         round(case when game.param('hedge_expected') >= 1 then game.fuel_expect(p_world, v_lead * 7) else rw.fuel_inr_kg end
               * (1 + game.param('hedge_premium')), 2)
    from public.airline_ops ao join public.airlines al on al.id = ao.airline_id
   where al.world_id = p_world and al.status = 'active' and ao.hedge_share > 0
  on conflict (airline_id, week) do update set share = excluded.share, price_inr_kg = excluded.price_inr_kg;
  delete from public.fuel_hedges fh using public.airlines al
   where al.id = fh.airline_id and al.world_id = p_world and fh.week < v_w;
  -- 0026: dollars bought ahead for the same week, for that share of the week's dollar costs, at today's rate plus a premium
  -- (0033: both at the expected price 13 weeks ahead, game.fuel_expect and game.fx_expect)
  insert into public.usd_hedges (airline_id, week, share, rate_inr_usd)
  select ao.airline_id, v_w + v_lead, ao.usd_hedge_share,
         round(case when game.param('hedge_expected') >= 1 then game.fx_expect(p_world, v_lead * 7) else rw.fx_inr_usd end
               * (1 + game.param('usd_hedge_premium')), 3)
    from public.airline_ops ao join public.airlines al on al.id = ao.airline_id
   where al.world_id = p_world and al.status = 'active' and ao.usd_hedge_share > 0
  on conflict (airline_id, week) do update set share = excluded.share, rate_inr_usd = excluded.rate_inr_usd;
  delete from public.usd_hedges uh using public.airlines al
   where al.id = uh.airline_id and al.world_id = p_world and uh.week < v_w;
  perform game.bank_week(p_world, p_day);   -- 0027: banks check debt against the world's limit
end $$;


-- ops_preview from 0026: the price a hedge locks today (0033)
create or replace function public.ops_preview(p_airline uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  ra public.airlines%rowtype; rw public.worlds%rowtype; ao public.airline_ops%rowtype;
  cp public.maint_plans%rowtype; cs public.op_styles%rowtype;
  v_day int; v_n int; v_age numeric; v_gq numeric; v_floor numeric := game.param('turn_floor_min');
  v_plans jsonb; v_styles jsonb; v_hedges jsonb; v_usd jsonb;
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
  v_gq := v_n * game.wparam(ra.world_id, 'ground_prob_day') * (1 + game.wparam(ra.world_id, 'ground_age_k') * v_age) * 91;

  select jsonb_agg(jsonb_build_object(
           'key', mp.key, 'cost_week', round(coalesce(x.v, 0) * mp.rate_mult * cs.hour_cost_mult + mp.fixed_inr_week),
           'fixed_week', mp.fixed_inr_week, 'groundings_qtr', round(v_gq * mp.ground_mult, 1),
           'days_qtr', round(v_gq * mp.ground_mult * (game.wparam(ra.world_id, 'ground_days_min') + game.wparam(ra.world_id, 'ground_days_max')) / 2 * mp.ground_len_mult, 1),
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
  -- 0026: dollar hedging: this week's dollar costs, what is bought, and the rate
  select jsonb_build_object(
           'share', ao.usd_hedge_share, 'rate', rw.fx_inr_usd, 'ref', game.param('fx_ref_inr_usd'),
           'premium', game.param('usd_hedge_premium'), 'step', game.param('usd_hedge_step'), 'max', game.param('usd_hedge_max'),
           'expected', game.fx_expect(rw.id, game.param('hedge_lead_weeks')::int * 7),
           'lock', round(case when game.param('hedge_expected') >= 1 then game.fx_expect(rw.id, game.param('hedge_lead_weeks')::int * 7) else rw.fx_inr_usd end
                         * (1 + game.param('usd_hedge_premium')), 3),
           'week_usd', coalesce((select sum(d.usd_cost_usd) from public.airline_daily d
                                  where d.airline_id = p_airline and d.game_day > rw.game_day - 7), 0),
           'bought', coalesce((select jsonb_agg(jsonb_build_object('week', uh.week, 'share', uh.share, 'rate', uh.rate_inr_usd) order by uh.week)
                                 from public.usd_hedges uh where uh.airline_id = p_airline), '[]'::jsonb))
    into v_usd;

  return jsonb_build_object(
    'day', v_day, 'aircraft', v_n, 'avg_age', round(v_age, 1),
    'plan', ao.maint_plan, 'plan_next', ao.maint_next, 'plan_next_day', ao.maint_next_day, 'locked_until', ao.maint_locked_until,
    'style', ao.op_style, 'hedge_share', ao.hedge_share,
    'fuel_price', rw.fuel_inr_kg, 'fuel_normal', rw.fuel_walk, 'hedge_premium', game.param('hedge_premium'),
    'fuel_expected', game.fuel_expect(rw.id, game.param('hedge_lead_weeks')::int * 7),
    'fuel_lock', round(case when game.param('hedge_expected') >= 1 then game.fuel_expect(rw.id, game.param('hedge_lead_weeks')::int * 7) else rw.fuel_inr_kg end
                       * (1 + game.param('hedge_premium')), 2),
    'hedge_lead_weeks', game.param('hedge_lead_weeks'), 'hedges', v_hedges, 'usd', v_usd,
    'plans', v_plans, 'styles', v_styles);
end $$;

-- day_quarter from 0026: tax, insurance and interest earned in the results; administrations in the score (0033)
create or replace function game.day_quarter(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rec record;
  v_q int := p_day / 91;
  v_n int;
begin
  select * into rw from public.worlds where id = p_world;

  insert into public.quarterly_reports (airline_id, quarter, revenue, op_profit, net_profit, pax, load_factor, rask, cask,
                                        otp, brand, net_worth)
  select al.id, v_q, s.rev, s.rev - s.cost, s.rev - s.cost - s.interest + s.earned, s.pax,
         round(s.rpk / nullif(s.ask, 0), 4), round(s.rev / nullif(s.ask, 0), 3), round(s.cost / nullif(s.ask, 0), 3),
         al.otp, al.brand, round(fin.cash_inr - fin.debt_inr + coalesce(ast.v, 0) - coalesce(adv.v, 0))
    from public.airlines al
    join public.airline_finance fin on fin.airline_id = al.id
    join (select airline_id, sum(rev_ticket + rev_anc) as rev, sum(c_interest) as interest, sum(pax) as pax,
                 sum(ask) as ask, sum(rpk) as rpk,
                 sum(c_fuel + c_crew + c_maint + c_airport + c_rent + c_slots + c_dist + c_marketing + c_overhead
                     + c_other + c_depr + c_insurance) as cost, sum(i_cash) as earned
            from public.airline_daily where game_day > p_day - 91 and game_day <= p_day group by airline_id) s
      on s.airline_id = al.id
    left join (select airline_id,
                      sum(deposit_inr + case when holding = 'owned' and ordered_day is null
                            then game.book_value_usd(price_usd, start_day, p_day) * rw.fx_inr_usd else 0 end
                          - coalesce(loan_usd, 0) * rw.fx_inr_usd - loan_inr) as v
                 from public.aircraft_terms group by airline_id) ast on ast.airline_id = al.id
    left join (select airline_id, 2 * sum(rev_e + rev_b) as v from public.route_weeks   -- 0019: tickets sold, not yet flown
                where world_id = p_world and week > game.week_of(p_day) group by airline_id) adv on adv.airline_id = al.id
   where al.world_id = p_world and al.status = 'active';

  -- 0033: tax on the quarter's profit after losses carried forward (the world's region rate), paid today
  with t as (
    select q.airline_id, q.net_profit as pre, fin.tax_loss_inr as cf, game.wparam(p_world, 'tax_rate') as rate
      from public.quarterly_reports q
      join public.airline_finance fin on fin.airline_id = q.airline_id
      join public.airlines al on al.id = q.airline_id
     where al.world_id = p_world and q.quarter = v_q),
  x as (select airline_id, pre, round(rate * greatest(0, pre - cf)) as tax,
               case when pre < 0 then cf - pre else greatest(0, cf - pre) end as cf_new from t),
  f as (update public.airline_finance fin set cash_inr = fin.cash_inr - x.tax, tax_loss_inr = x.cf_new
          from x where fin.airline_id = x.airline_id returning fin.airline_id),
  d as (update public.airline_daily d set c_tax = x.tax from x where d.airline_id = x.airline_id and d.game_day = p_day and x.tax > 0
        returning d.airline_id),
  tr as (insert into public.transactions (airline_id, game_day, kind, amount_inr, note, pnl_inr)
         select x.airline_id, p_day, 'tax', -x.tax, 'Tax on quarter ' || v_q || '''s profit', 0 from x where x.tax > 0 returning 1)
  update public.quarterly_reports q set tax_inr = x.tax, net_profit = q.net_profit - x.tax, net_worth = q.net_worth - x.tax
    from x where q.airline_id = x.airline_id and q.quarter = v_q;

  -- season score: net worth + 5 x profit after interest and tax of the last four quarters, less one starting stake for
  -- each administration (0033). Computer-run airlines are not ranked.
  update public.quarterly_reports q
     set score = round(q.net_worth + game.param('score_profit_mult')
                 * (select sum(h.net_profit) from public.quarterly_reports h
                     where h.airline_id = q.airline_id and h.quarter > v_q - 4 and h.quarter <= v_q)
                 - al.administrations * game.param('restart_score_mult') * game.wparam(p_world, 'start_cash_inr'))
    from public.airlines al
   where al.id = q.airline_id and al.world_id = p_world and q.quarter = v_q;
  update public.quarterly_reports q set rank = s.rk
    from (select h.airline_id, rank() over (order by h.score desc) as rk
            from public.quarterly_reports h join public.airlines al on al.id = h.airline_id
           where al.world_id = p_world and h.quarter = v_q and not al.is_ai) s
   where q.airline_id = s.airline_id and q.quarter = v_q;

  insert into public.news (world_id, game_day, kind, body)
  select p_world, p_day, 'results', 'Quarter ' || v_q || ' results are out. Leaders: ' || string_agg(s.name, ', ' order by s.rank) || '.'
    from (select al.name, q.rank from public.quarterly_reports q join public.airlines al on al.id = q.airline_id
           where al.world_id = p_world and q.quarter = v_q and q.rank <= 3) s
  having count(*) > 0;

  -- lessors add aircraft, up to the target
  for rec in select type_id, target from public.pool_targets where world_id = p_world loop
    select count(*) into v_n from public.aircraft where world_id = p_world and type_id = rec.type_id and status = 'pool';
    perform game.fill_pool(p_world, rec.type_id,
                           least(ceil(rec.target * game.param('pool_refill_share'))::int, rec.target - v_n), p_day);
  end loop;
end $$;


-- create_world from 0032: the region's passenger rights, tax and interest become the world's own values (0033)
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
   where o.setting in ('region', 'money', 'banks', 'growth', 'seats', 'bots', 'consultant') and o.option = v_rules->>o.setting and e.key <> 'bot_scale';
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


-- day_ops from 0029: compensation for own cancellations, cuts counted for brand, interest on cash, insurance (0033)
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
    loan_rate_year numeric, anc_biz_share numeric, slot_ref_seats numeric, overhead_full_fleet numeric, overhead_min_share numeric,
    cash_interest_year numeric, insurance_year numeric);   -- 0033

  select biz, lei, bud into v_sb, v_sl, v_su from public.season_factors
   where month = ((g.season_start_month::int - 1 + (((p_day - 1) % 364) * 12) / 364) % 12) + 1;
  v_grow := power(1 + g.growth_year, (p_day - 1) / 364.0) * rw.demand_scale;

  create temp table if not exists _rot (   -- one row per aircraft per route
    route_id uuid, airline_id uuid, aircraft_id uuid, type_id text, a text, b text, km int, intl boolean,
    f numeric,                -- round trips a day
    flown boolean, wet boolean, seats_e int, seats_b int, comf_e numeric, comf_b numeric,
    block_h numeric, turn_min numeric, age_y numeric, crew int,
    fuel_kg numeric default 0, c_fuel numeric default 0, c_crew numeric default 0, c_maint numeric default 0,
    c_airport numeric default 0, c_slots numeric default 0,
    xo boolean default false  -- 0033: cancelled by an airport or airspace closure (no compensation)
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
    sales_x numeric default 0,                              -- 0026: sales team abroad on international routes
    comp numeric default 0, xo boolean default false        -- 0033: compensation for today's own cancellations
  ) on commit drop;
  create temp table if not exists _acx (   -- migration 0017: what holding each aircraft costs today, and the hours it flew
    aircraft_id uuid primary key, airline_id uuid, fixed numeric, bh numeric
  ) on commit drop;
  create temp table if not exists _cxl (   -- 0028: refunds on routes with every flight cancelled today (0033: or none left)
    airline_id uuid, refund numeric, comp numeric default 0
  ) on commit drop;
  truncate pg_temp._rot, pg_temp._prod, pg_temp._acx, pg_temp._cxl;

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

  -- 0028: an airspace closure. Routes between north India and the regions behind it fly round it (airspace_detours):
  -- more km, block hours, fuel, crew and maintenance.
  update pg_temp._rot x set km = x.km + d.detour_km,
                            block_h = (x.km + d.detour_km)::numeric / t.cruise_kmh + t.block_offset_h
    from public.events e, public.airports ia, public.airports fa, public.airspace_detours d, public.aircraft_types t
   where e.world_id = p_world and e.kind = 'airspace_closed' and e.starts_day <= p_day and e.ends_day >= p_day
     and x.intl and t.id = x.type_id
     and ia.iata in (x.a, x.b) and fa.iata in (x.a, x.b) and ia.is_india and not fa.is_india
     and ia.lat >= coalesce((e.payload ->> 'lat_min')::numeric, game.param('airspace_lat_min')) and d.region = fa.region;

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

  -- 0028: an aircraft that cannot reach on a longer way round cancels; so does every flight to or from a closed airport
  update pg_temp._rot x set flown = false, xo = true
    from public.aircraft_types t
   where x.flown and t.id = x.type_id
     and x.km > t.range_km * least(1.10, 1 - 0.4 * (x.seats_e + x.seats_b - t.ref_seats)::numeric / t.ref_seats);
  update pg_temp._rot x set flown = false, xo = true
    from public.events e
   where x.flown and e.world_id = p_world and e.kind = 'airport_closed' and e.starts_day <= p_day and e.ends_day >= p_day
     and e.payload ->> 'airport' in (x.a, x.b);

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
  -- 0033: a route that lost flights to an airport or airspace closure today pays no compensation
  update pg_temp._prod p set xo = true where exists (select 1 from pg_temp._rot x where x.route_id = p.route_id and x.xo);

  if rw.selling then
    -- Selling worlds (migration 0019): today's passengers are a seventh of the week's bookings who turned up and could
    -- board; each fare counts as paid (no-shows' fares with them). Flights cancelled today refund their passengers.
    update pg_temp._prod p
       set pax_e = least(p.cap_e, coalesce(w.flown_e, 0) / 7), pax_b = least(p.cap_b, coalesce(w.flown_b, 0) / 7),
           fare_e = coalesce(w.rev_flown_e / nullif(w.flown_e, 0), p.fare_e),
           fare_b = coalesce(w.rev_flown_b / nullif(w.flown_b, 0), p.fare_b),
           refund = 2 * (greatest(0, coalesce(w.flown_e, 0) / 7 - p.cap_e) * coalesce(w.rev_e / nullif(w.bk_be + w.bk_l + w.bk_u, 0), 0)
                       + greatest(0, coalesce(w.flown_b, 0) / 7 - p.cap_b) * coalesce(w.rev_b / nullif(w.bk_b, 0), 0)),
           -- 0033: the airline's own cancellations today also pay the region's compensation
           comp = case when p.xo then 0 else 2 * (
                    greatest(0, coalesce(w.flown_e, 0) / 7 - p.cap_e) * game.cancel_comp(p_world, p.km, w.rev_e / nullif(w.bk_be + w.bk_l + w.bk_u, 0))
                  + greatest(0, coalesce(w.flown_b, 0) / 7 - p.cap_b) * game.cancel_comp(p_world, p.km, w.rev_b / nullif(w.bk_b, 0))) end
      from public.route_weeks w
     where w.route_id = p.route_id and w.week = game.week_of(p_day);
    update pg_temp._prod set pax_e = coalesce(pax_e, 0), pax_b = coalesce(pax_b, 0), dem_e = 0, dem_b = 0, dg = 0,
                             refund = coalesce(refund, 0);
    -- 0028: a route with every flight cancelled today refunds all of today's travellers. 0033: so does a route whose
    -- flights were all taken off (closed, or no rotations left) during a week already flying, and the airline's own
    -- cancellations pay the region's compensation too
    insert into pg_temp._cxl (airline_id, refund, comp)
    select w.airline_id,
           2 * (coalesce(w.flown_e, 0) / 7 * coalesce(w.rev_e / nullif(w.bk_be + w.bk_l + w.bk_u, 0), 0)
              + coalesce(w.flown_b, 0) / 7 * coalesce(w.rev_b / nullif(w.bk_b, 0), 0)),
           case when exists (select 1 from pg_temp._rot x where x.route_id = w.route_id and x.xo) then 0 else 2 * (
                  coalesce(w.flown_e, 0) / 7 * game.cancel_comp(p_world, m.km, w.rev_e / nullif(w.bk_be + w.bk_l + w.bk_u, 0))
                + coalesce(w.flown_b, 0) / 7 * game.cancel_comp(p_world, m.km, w.rev_b / nullif(w.bk_b, 0))) end
      from public.route_weeks w
      join public.routes r on r.id = w.route_id
      join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
      join public.airlines al on al.id = w.airline_id and al.status = 'active' and al.first_flight_day <= p_day
     where w.world_id = p_world and w.week = game.week_of(p_day) and w.flown_e is not null
       and coalesce(w.flown_e, 0) + coalesce(w.flown_b, 0) > 0
       and not exists (select 1 from pg_temp._prod p where p.route_id = w.route_id);
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
             + game.cabin_crew(rw.crew_rule, ac.seats_econ + ac.seats_biz) * g.cabin_fixed_inr_day
             -- 0033: hull insurance on the aircraft's value (new price less depreciation, at least 40%)
             + t.price_usd_m * 1e6 * rw.fx_inr_usd * greatest(0.4, 1 - g.depreciation_year * greatest(0, p_day - ac.built_day) / 364.0)
               * g.insurance_year / 364 end,
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

  -- 0033: compensation for today's own cancellations: a cost in the day's results (Other) and out of cash now
  create temp table if not exists _comp (airline_id uuid primary key, comp numeric) on commit drop;
  truncate pg_temp._comp;
  insert into pg_temp._comp
  select airline_id, round(sum(comp)) from (select airline_id, comp from pg_temp._prod union all select airline_id, comp from pg_temp._cxl) z
   group by airline_id having sum(comp) >= 1;
  insert into public.transactions (airline_id, game_day, kind, amount_inr, note, pnl_inr)
  select airline_id, p_day, 'cancellation', -comp, 'Compensation for cancelled flights', -comp from pg_temp._comp;
  update public.airline_finance fin set cash_inr = fin.cash_inr - c.comp from pg_temp._comp c where c.airline_id = fin.airline_id;
  -- 0033: flights sold and then taken off: today's share of the week's flights that no longer have a rotation, and the
  -- week's cuts made inside the notice (sell_week); they count as cancellations for brand
  create temp table if not exists _cut (airline_id uuid primary key, n numeric) on commit drop;
  truncate pg_temp._cut;
  insert into pg_temp._cut
  select z.airline_id, sum(z.n) from (
    select w.airline_id, greatest(0, 2 * w.trips / 7 - coalesce((select sum(2 * x.f) from pg_temp._rot x where x.route_id = w.route_id), 0)) as n
      from public.route_weeks w
     where rw.selling and w.world_id = p_world and w.week = game.week_of(p_day) and w.flown_e is not null and w.trips > 0
    union all
    select aw.airline_id, aw.cut_flights / 7 from public.airline_weeks aw join public.airlines al on al.id = aw.airline_id
     where al.world_id = p_world and aw.week = game.week_of(p_day) and aw.cut_flights > 0) z
   group by z.airline_id;

  insert into public.airline_daily (airline_id, game_day, pax, ask, rpk, rev_ticket, rev_anc, c_fuel, c_crew, c_maint,
    c_airport, c_rent, c_slots, c_dist, c_marketing, c_overhead, c_interest, c_other, c_depr, flights, cancelled, loan_repaid, refunds_inr,
    fuel_kg, hedge_inr, groundings, usd_cost_usd, usd_cost_inr, usd_hedge_inr, fx_effect_inr, c_insurance, i_cash, c_comp)
  select al.id, p_day, coalesce(pr.pax, 0), coalesce(pr.ask, 0), coalesce(pr.rpk, 0),
         coalesce(pr.rev, 0), round(coalesce(pr.anc, 0)),
         round(coalesce(rc.fuel, 0)), round(coalesce(rc.crew, 0) + coalesce(fl.crew_fixed, 0) + coalesce(sal.pay, 0)), round(coalesce(rc.maint, 0) + coalesce(ox.fixed_day, 0)),
         round(coalesce(rc.airport, 0)), round(coalesce(fl.rent, 0)), round(coalesce(rc.slots, 0)),
         round(coalesce(g.dist_rev_share * pr.rev + g.service_inr_pax * pr.pax + pr.anc_cost + pr.sales_x, 0)), al.marketing_inr_day,
         -- 0029: head office grows with the fleet up to overhead_full_fleet aircraft, from overhead_min_share of the full cost
         round(g.overhead_fixed_inr_day * greatest(g.overhead_min_share, least(1, coalesce(fl.n, 0) / g.overhead_full_fleet))
               + g.overhead_aircraft_inr_day * coalesce(fl.n, 0) + g.overhead_seat_inr_day * coalesce(fl.seats, 0)
               + g.base_fixed_inr_day * (select count(*) from public.bases bs where bs.airline_id = al.id)),
         round(fin.debt_inr * g.interest_year / 364 + coalesce(fl.loan_int, 0)), coalesce(tx.other, 0), round(coalesce(fl.depr, 0)),
         coalesce(rc.flights, 0), coalesce(rc.cancelled, 0) + round(coalesce(cu.n, 0), 2), round(coalesce(fl.loan_prin, 0)), round(coalesce(pr.refund, 0)),
         round(coalesce(rc.kg, 0)), round(coalesce(rc.kg * rw.fuel_inr_kg - rc.fuel, 0)), coalesce(gr.n, 0),
         -- 0026: dollar-linked costs (rent, maintenance, dollar loan interest, depreciation), what the dollar hedge saved on the
         -- cash ones (repayments included), and what the rupee's move against the reference rate added
         round(coalesce(fl.rent_usd, 0) + coalesce(rc.maint, 0) / ox.fx + coalesce(fl.int_usd, 0) + coalesce(fl.depr_usd, 0), 2),
         round(coalesce(fl.rent, 0) + coalesce(rc.maint, 0) + coalesce(fl.int_d, 0) + coalesce(fl.depr, 0)),
         round((coalesce(fl.rent_usd, 0) + coalesce(rc.maint, 0) / ox.fx + coalesce(fl.int_usd, 0) + coalesce(fl.prin_usd, 0)) * rw.fx_inr_usd
               - (coalesce(fl.rent, 0) + coalesce(rc.maint, 0) + coalesce(fl.int_d, 0) + coalesce(fl.prin_d, 0))),
         round(coalesce(fl.rent, 0) + coalesce(rc.maint, 0) + coalesce(fl.int_d, 0) + coalesce(fl.depr, 0)
               - (coalesce(fl.rent_usd, 0) + coalesce(rc.maint, 0) / ox.fx + coalesce(fl.int_usd, 0) + coalesce(fl.depr_usd, 0)) * game.param('fx_ref_inr_usd')),
         round(coalesce(fl.ins, 0)), round(greatest(0, fin.cash_inr) * g.cash_interest_year / 364), coalesce(cp.comp, 0)
    from public.airlines al
    join public.airline_finance fin on fin.airline_id = al.id
    left join (select airline_id, sum(pe + pb) as pax, sum(2 * (cap_e + cap_b) * km) as ask,
                      sum((pe + pb) * km) as rpk, sum(rev) as rev, sum(anc) as anc, sum(anc_cost) as anc_cost, sum(refund) as refund, sum(sales_x) as sales_x
                 from (select airline_id, pe, pb, cap_e, cap_b, km, rev, anc, anc_cost, refund, sales_x from pg_temp._prod
                       union all select airline_id, 0, 0, 0, 0, 0, 0, 0, 0, refund, 0 from pg_temp._cxl) u
                group by airline_id) pr on pr.airline_id = al.id
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
                            + game.cabin_crew(rw.crew_rule, ac.seats_econ + ac.seats_biz) * g.cabin_fixed_inr_day end) as crew_fixed,
                      sum(case when tm.holding = 'wet' then 0 else
                            t.price_usd_m * 1e6 * rw.fx_inr_usd * greatest(0.4, 1 - g.depreciation_year * greatest(0, p_day - ac.built_day) / 364.0)
                            * g.insurance_year / 364 end) as ins
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
    left join pg_temp._comp cp on cp.airline_id = al.id
    left join pg_temp._cut cu on cu.airline_id = al.id
   where al.world_id = p_world and al.status = 'active' and al.first_flight_day <= p_day;

  update public.airline_finance fin
     set cash_inr = fin.cash_inr + case when rw.selling then -d.refunds_inr else d.rev_ticket end + d.rev_anc - (d.c_fuel + d.c_crew + d.c_maint + d.c_airport + d.c_rent
                    + d.c_slots + d.c_dist + d.c_marketing + d.c_overhead + d.c_interest + d.loan_repaid + d.c_insurance) + d.i_cash
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


-- sell_week from 0028: cuts inside the region's notice pay compensation and count as cancellations; denied boarding by region (0033)
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
    news_fare_move float8, news_flights_move float8, insight_min_routes float8,
    cancel_notice_days float8, denied_fare_mult float8);   -- 0033

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
  create temp table _money (airline_id uuid, sales float8 default 0, refunds float8 default 0, comp float8 default 0,
                       ccomp float8 default 0, cut float8 default 0) on commit drop;   -- 0033: compensation and flights for cuts

  -- 1. Routes closed: their tickets are refunded. 0033: the flights of a closed route that fly within the region's notice
  -- (cancel_notice_days from today) also pay compensation, and count as cut for brand.
  with gone as (
    delete from public.route_weeks x using public.routes r, public.markets m
     where x.world_id = p_world and x.flown_e is null and r.id = x.route_id and r.status <> 'open'
       and m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
    returning x.airline_id, 2 * (x.rev_e + x.rev_b) as amt,
              least(7, greatest(0, g.cancel_notice_days - ((x.week - 1) * 7 + 1 - p_day))) / 7 as sh,
              2 * ((x.bk_be + x.bk_l + x.bk_u) * game.cancel_comp(p_world, m.km, x.rev_e / nullif(x.bk_be + x.bk_l + x.bk_u, 0))
                   + x.bk_b * game.cancel_comp(p_world, m.km, x.rev_b / nullif(x.bk_b, 0))) as cc,
              case when x.bk_be + x.bk_l + x.bk_u + x.bk_b = 0 then 0 else 2 * x.trips end as cut)
  insert into pg_temp._money (airline_id, refunds, ccomp, cut)
  select airline_id, sum(amt), sum(sh * cc), sum(sh * cut) from gone group by airline_id;

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
        seats_max_b = greatest(public.route_weeks.seats_max_b, excluded.seats_b),
        -- 0033: seats and flights cut since last week, for the share of the week's flights within the region's notice
        cut_in_e = public.route_weeks.cut_in_e + greatest(0, public.route_weeks.seats_e - excluded.seats_e)
                   * least(7, greatest(0, g.cancel_notice_days - ((public.route_weeks.week - 1) * 7 + 1 - p_day))) / 7,
        cut_in_b = public.route_weeks.cut_in_b + greatest(0, public.route_weeks.seats_b - excluded.seats_b)
                   * least(7, greatest(0, g.cancel_notice_days - ((public.route_weeks.week - 1) * 7 + 1 - p_day))) / 7,
        cut_in_trips = public.route_weeks.cut_in_trips + greatest(0, public.route_weeks.trips - excluded.trips)
                   * least(7, greatest(0, g.cancel_notice_days - ((public.route_weeks.week - 1) * 7 + 1 - p_day))) / 7;
  update public.route_weeks x set trips = 0, seats_e = 0, seats_b = 0,
         cut_in_e = x.cut_in_e + x.seats_e * least(7, greatest(0, g.cancel_notice_days - ((x.week - 1) * 7 + 1 - p_day))) / 7,
         cut_in_b = x.cut_in_b + x.seats_b * least(7, greatest(0, g.cancel_notice_days - ((x.week - 1) * 7 + 1 - p_day))) / 7,
         cut_in_trips = x.cut_in_trips + x.trips * least(7, greatest(0, g.cancel_notice_days - ((x.week - 1) * 7 + 1 - p_day))) / 7
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

  -- 0028: fare caps in a crisis. While a cap is in force, economy on domestic routes to and from its airport sells at
  -- most at the cap (its multiple of the reference fare), for every flight week on sale.
  update pg_temp._sell z set pe = least(z.pe, floor(fc.mult * z.ref / 10) * 10)
    from (select e.payload ->> 'airport' as ap, min((e.payload ->> 'mult')::float8) as mult
            from public.events e
           where e.world_id = p_world and e.kind = 'fare_cap' and e.starts_day <= p_day and e.ends_day >= p_day
           group by 1) fc
   where not z.intl and fc.ap in (z.a, z.b);

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
           x.cut_in_e, x.cut_in_b, x.cut_in_trips, m.km,   -- 0033
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
  -- 0033: of those who cannot board, the overbooked (beyond the most seats ever on sale) get denied-boarding money; those
  -- whose seats were cut within the region's notice get cancellation money; earlier cuts a refund only
  dz as (
    select dn.*, greatest(0, dn.den_e - (dn.seats_max_e - dn.seats_e)) as ob_e, greatest(0, dn.den_b - (dn.seats_max_b - dn.seats_b)) as ob_b,
           least(dn.den_e - greatest(0, dn.den_e - (dn.seats_max_e - dn.seats_e)), dn.cut_in_e) as cn_e,
           least(dn.den_b - greatest(0, dn.den_b - (dn.seats_max_b - dn.seats_b)), dn.cut_in_b) as cn_b,
           coalesce(dn.rev_e / nullif(dn.sold_e, 0), 0) as fe, coalesce(dn.rev_b / nullif(dn.sold_b, 0), 0) as fb
      from dn),
  upd as (
    update public.route_weeks x
       set noshow = dn.ns_e + dn.ns_b, denied = dn.den_e + dn.den_b,
           comp = dn.ob_e + dn.ob_b,
           flown_e = dn.sold_e - dn.ns_e - dn.den_e, flown_b = dn.sold_b - dn.ns_b - dn.den_b,
           rev_flown_e = dn.rev_e - dn.den_e * dn.fe,
           rev_flown_b = dn.rev_b - dn.den_b * dn.fb
      from dz dn where x.route_id = dn.route_id and x.week = v_w
    returning x.airline_id, 2 * (x.rev_e + x.rev_b - x.rev_flown_e - x.rev_flown_b) as refund,
              2 * (dn.ob_e * (g.denied_comp_inr + g.denied_fare_mult * dn.fe) + dn.ob_b * (g.denied_comp_inr + g.denied_fare_mult * dn.fb)) as comp,
              2 * (dn.cn_e * game.cancel_comp(p_world, dn.km, dn.fe) + dn.cn_b * game.cancel_comp(p_world, dn.km, dn.fb)) as cc,
              case when dn.cn_e + dn.cn_b > 0 then 2 * dn.cut_in_trips else 0 end as cut)
  insert into pg_temp._money (airline_id, refunds, comp, ccomp, cut)
  select airline_id, sum(refund), sum(comp), sum(cc), sum(cut) from upd group by airline_id;

  -- the money: tickets sold in, refunds and compensation out (compensation is a cost; the rest moves cash only)
  update public.airline_finance fin set cash_inr = round(fin.cash_inr + m.sales - m.refunds - m.comp - m.ccomp)
    from (select airline_id, sum(sales) as sales, sum(refunds) as refunds, sum(comp) as comp, sum(ccomp) as ccomp from pg_temp._money group by airline_id) m
   where fin.airline_id = m.airline_id;
  insert into public.transactions (airline_id, game_day, kind, amount_inr, note, pnl_inr)   -- 0033
  select airline_id, p_day, 'cancellation', -round(sum(ccomp)), 'Compensation for flights cut after the notice', -round(sum(ccomp))
    from pg_temp._money group by airline_id having sum(ccomp) >= 1;
  insert into public.transactions (airline_id, game_day, kind, amount_inr, note, pnl_inr)
  select airline_id, p_day, 'denied_boarding', -round(sum(comp)), 'Compensation to passengers who could not board', -round(sum(comp))
    from pg_temp._money group by airline_id having sum(comp) >= 1;
  insert into public.airline_weeks (airline_id, week, sales_inr, refunds_inr, comp_inr, cancel_comp_inr, cut_flights, advance_inr)
  select al.id, v_w, round(coalesce(m.sales, 0)), round(coalesce(m.refunds, 0)), round(coalesce(m.comp, 0)),
         round(coalesce(m.ccomp, 0)), round(coalesce(m.cut, 0)::numeric, 2),
         round(coalesce((select 2 * sum(x.rev_e + x.rev_b) from public.route_weeks x where x.airline_id = al.id and x.week > v_w), 0))
    from public.airlines al
    left join (select airline_id, sum(sales) as sales, sum(refunds) as refunds, sum(comp) as comp, sum(ccomp) as ccomp, sum(cut) as cut
                 from pg_temp._money group by airline_id) m
           on m.airline_id = al.id
   where al.world_id = p_world and (al.status = 'active' or m.airline_id is not null)
  on conflict (airline_id, week) do update
    set sales_inr = excluded.sales_inr, refunds_inr = excluded.refunds_inr, comp_inr = excluded.comp_inr, advance_inr = excluded.advance_inr,
        cancel_comp_inr = excluded.cancel_comp_inr, cut_flights = excluded.cut_flights;

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


-- ops_benchmarks from 0023: hull insurance is an aircraft cost (0033)
create or replace function game.ops_benchmarks(p_world uuid, p_day int) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_days int := game.param('benchmark_days')::int;
begin
  -- each cost line per seat-km over the last benchmark_days, the median over the airlines that flew
  with per as (
    select d.airline_id, sum(d.ask) as ask,
           sum(d.c_fuel) as fuel, sum(d.c_rent + d.c_depr + d.c_insurance) as aircraft, sum(d.c_maint) as maint, sum(d.c_crew) as crew,
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


-- What an action would cost before it is taken, for the app (principle 8). Read-only: PostgREST runs it in a read-only
-- transaction, so it locks nothing. Kinds: 'return' (an aircraft given back: the fee and the cash), 'ferry' (an aircraft
-- moved to the base p_text), 'close_route' (refunds and compensation if the route closes now), 'wet' (wet lessors' free
-- aircraft of the type p_text).
create or replace function public.price_quote(p_airline uuid, p_kind text, p_id uuid default null, p_text text default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  ra public.airlines%rowtype; rw public.worlds%rowtype; rc public.aircraft%rowtype; rm public.aircraft_terms%rowtype;
  v_day int; v_ws int; v numeric; r record;
begin
  select * into ra from public.airlines where id = p_airline;
  if not found then raise exception 'Airline not found'; end if;
  if not game.is_server() and (auth.uid() is null or ra.user_id is distinct from auth.uid()) then
    raise exception 'This is not your airline';
  end if;
  select * into rw from public.worlds where id = ra.world_id;
  v_day := rw.game_day + 1;
  if p_kind in ('return', 'ferry') then
    select * into rc from public.aircraft where id = p_id and airline_id = p_airline;
    if not found then return jsonb_build_object('gone', true); end if;   -- given back since (the app asks again after acting)
    select * into rm from public.aircraft_terms where aircraft_id = rc.id;
  end if;

  if p_kind = 'return' then   -- the sums of return_aircraft
    if rm.holding = 'lease' then
      v := case when rc.status = 'delivering' then rm.deposit_inr
                else least(round(rm.lease_usd_month * rw.fx_inr_usd * game.param('lease_break_months')),
                           round(rm.lease_usd_month * rw.fx_inr_usd / 30.33 * greatest(0, rm.lease_end_day - v_day))) end;
      return jsonb_build_object('fee_inr', v, 'cash_inr', rm.deposit_inr - v, 'deposit_inr', rm.deposit_inr,
                                'months', game.param('lease_break_months'));
    elsif rm.holding = 'wet' then
      v := case when rm.wet_min_until is not null and rm.wet_min_until > v_day
                then round(rm.wet_usd_bh * game.param('wet_min_hours_day') * rw.fx_inr_usd * (rm.wet_min_until - greatest(v_day, rm.start_day)))
                else 0 end;
      return jsonb_build_object('fee_inr', v, 'cash_inr', -v, 'min_until_day', rm.wet_min_until);
    end if;
    return jsonb_build_object('fee_inr', null);

  elsif p_kind = 'ferry' then
    return jsonb_build_object('cost_inr', case when rc.status = 'delivering' or rc.base_iata is null then 0
                                               else coalesce(game.ferry_cost(rc.id, rc.base_iata, upper(trim(p_text))), 0) end);

  elsif p_kind = 'close_route' then
    -- the week now flying refunds and compensates its remaining days (day_ops); later weeks are refunded at the next week
    -- start, with compensation for the flights within the region's notice (sell_week)
    v_ws := ((v_day + 5) / 7) * 7 + 1;
    select coalesce(round(sum(case when x.flown_e is not null
                then (x.week * 7 - rw.game_day) / 7.0 * 2 * (coalesce(x.flown_e, 0) * coalesce(x.rev_e / nullif(x.bk_be + x.bk_l + x.bk_u, 0), 0)
                                                          + coalesce(x.flown_b, 0) * coalesce(x.rev_b / nullif(x.bk_b, 0), 0))
                else 2 * (x.rev_e + x.rev_b) end)), 0) as refund,
           coalesce(round(sum(case when x.flown_e is not null
                then (x.week * 7 - rw.game_day) / 7.0 * 2 * (coalesce(x.flown_e, 0) * game.cancel_comp(rw.id, m.km, x.rev_e / nullif(x.bk_be + x.bk_l + x.bk_u, 0))
                                                          + coalesce(x.flown_b, 0) * game.cancel_comp(rw.id, m.km, x.rev_b / nullif(x.bk_b, 0)))
                else least(7, greatest(0, game.wparam(rw.id, 'cancel_notice_days') - ((x.week - 1) * 7 + 1 - v_ws))) / 7.0 * 2
                     * ((x.bk_be + x.bk_l + x.bk_u) * game.cancel_comp(rw.id, m.km, x.rev_e / nullif(x.bk_be + x.bk_l + x.bk_u, 0))
                        + x.bk_b * game.cancel_comp(rw.id, m.km, x.rev_b / nullif(x.bk_b, 0))) end)), 0) as comp
      into r
      from public.route_weeks x
      join public.routes rt on rt.id = x.route_id and rt.airline_id = p_airline
      join public.markets m on m.a = least(rt.origin, rt.dest) and m.b = greatest(rt.origin, rt.dest)
     where x.route_id = p_id and x.week >= game.week_of(v_day)
       and (x.flown_e is null or x.week * 7 > rw.game_day);
    return jsonb_build_object('refund_inr', r.refund, 'comp_inr', r.comp, 'notice_days', game.wparam(rw.id, 'cancel_notice_days'));

  elsif p_kind = 'wet' then
    select * into r from game.wet_room(rw.id, p_text);
    return jsonb_build_object('free', greatest(0, r.n_max - r.n_out), 'max', r.n_max, 'min_weeks', game.param('wet_min_weeks'),
                              'starter_mult', game.param('wet_starter_mult'));
  end if;
  raise exception 'Unknown quote';
end $$;
revoke all on function public.price_quote(uuid, text, uuid, text) from public, anon;
grant execute on function public.price_quote(uuid, text, uuid, text) to authenticated, service_role;
revoke all on function public.close_base(uuid, text) from public, anon;


-- consultant_data from 0030: the new money lines and the world's rules in the overview (0033)
create or replace function public.consultant_data(p_report uuid, p_tool text, p_args jsonb default '{}') returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  r public.consultant_reports%rowtype; w public.worlds%rowtype; v_a uuid; v_d int; v_out jsonb; v_route uuid;
begin
  select * into r from public.consultant_reports where id = p_report;
  if not found then raise exception 'No such report'; end if;
  select * into w from public.worlds where id = r.world_id;
  v_a := r.airline_id; v_d := w.game_day;

  if p_tool = 'overview' then
    select jsonb_build_object(
      'airline_code', al.code, 'game_week', game.week_of(v_d + 1), 'first_flight_week', game.week_of(al.first_flight_day),
      'cash_inr', round(f.cash_inr), 'debt_inr', round(f.debt_inr), 'credit_line_inr', round(f.credit_limit_inr),
      'credit_line_cut_from_inr', f.credit_cut_from, 'weeks_below_zero_cash', round(f.insolvent_days / 7.0, 1),
      'brand', round(al.brand, 1), 'on_time', round(al.otp, 3), 'marketing_inr_day', al.marketing_inr_day,
      'advance_sales_inr', (select round(advance_inr) from public.airline_weeks where airline_id = v_a order by week desc limit 1),
      -- 0033: the world's region rules that price actions
      'world_rules', jsonb_build_object('cancel_notice_days', game.wparam(w.id, 'cancel_notice_days'),
          'cancel_compensation_inr_by_band', jsonb_build_array(game.wparam(w.id, 'cancel_comp_1_inr'), game.wparam(w.id, 'cancel_comp_2_inr'), game.wparam(w.id, 'cancel_comp_3_inr')),
          'cancel_band_km', jsonb_build_array(game.wparam(w.id, 'cancel_km_1'), game.wparam(w.id, 'cancel_km_2')),
          'cancel_cap_fare_mult', game.wparam(w.id, 'cancel_cap_fare_mult'), 'cancel_fare_share', game.wparam(w.id, 'cancel_fare_share'),
          'denied_boarding_inr', game.wparam(w.id, 'denied_comp_inr'), 'denied_fare_mult', game.wparam(w.id, 'denied_fare_mult'),
          'tax_rate', game.wparam(w.id, 'tax_rate'), 'cash_interest_year', game.wparam(w.id, 'cash_interest_year'),
          'tax_losses_carried_inr', round(f.tax_loss_inr), 'route_launch_inr', game.param('route_launch_inr'),
          'lease_break_months', game.param('lease_break_months'), 'wet_min_weeks', game.param('wet_min_weeks')),
      'last_28_days', (select jsonb_build_object(
          'revenue_tickets', round(sum(rev_ticket)), 'revenue_extras', round(sum(rev_anc)),
          'fuel', round(sum(c_fuel)), 'crew', round(sum(c_crew)), 'maintenance', round(sum(c_maint)), 'airports', round(sum(c_airport)),
          'aircraft_rent', round(sum(c_rent)), 'depreciation', round(sum(c_depr)), 'slots', round(sum(c_slots)),
          'sales_and_service', round(sum(c_dist)), 'marketing', round(sum(c_marketing)), 'head_office_and_bases', round(sum(c_overhead)),
          'interest', round(sum(c_interest)), 'other', round(sum(c_other - c_comp)),
          -- 0033: insurance, compensation for cancelled flights, interest earned on cash, tax
          'insurance', round(sum(c_insurance)), 'cancellation_compensation', round(sum(c_comp)),
          'interest_earned_on_cash', round(sum(i_cash)), 'tax', round(sum(c_tax)),
          'operating_profit', round(sum(rev_ticket + rev_anc - c_fuel - c_crew - c_maint - c_airport - c_rent - c_slots - c_dist
                                        - c_marketing - c_overhead - c_other - c_depr - c_insurance)),
          'passengers', sum(pax), 'load_factor', round(sum(rpk) / nullif(sum(ask), 0), 3),
          'flights', sum(flights), 'cancelled', sum(cancelled), 'groundings', sum(groundings),
          'currency_effect_inr', round(sum(fx_effect_inr)), 'fuel_hedge_saved_inr', round(sum(hedge_inr)))
        from public.airline_daily where airline_id = v_a and game_day > v_d - 28),
      'cost_per_seat_km_vs_industry', (select jsonb_object_agg(b.line, jsonb_build_object('industry_median', round(b.median_inr_ask, 3)))
        from public.cost_benchmarks b where b.world_id = w.id and b.week = (select max(week) from public.cost_benchmarks where world_id = w.id)),
      'ask_last_28_days', (select sum(ask) from public.airline_daily where airline_id = v_a and game_day > v_d - 28),
      'quarters', (select jsonb_agg(jsonb_build_object('quarter', q.quarter, 'revenue', round(q.revenue), 'operating_profit', round(q.op_profit),
                                                       'tax', round(q.tax_inr), 'load_factor', q.load_factor, 'rank', q.rank) order by q.quarter desc)
        from (select * from public.quarterly_reports where airline_id = v_a order by quarter desc limit 4) q),
      'strategies', (select jsonb_build_object('fuel_hedge', o.hedge_share, 'dollar_hedge', o.usd_hedge_share,
                                               'maintenance', o.maint_plan, 'operating_style', o.op_style)
        from public.airline_ops o where o.airline_id = v_a),
      'fleet', (select jsonb_object_agg(s, n) from (select status s, count(*) n from public.aircraft where airline_id = v_a group by 1) x),
      'shocks_now', (select jsonb_agg(jsonb_build_object('kind', e.kind, 'until_week', game.week_of(e.ends_day), 'details', e.payload))
        from public.events e where e.world_id = w.id and e.starts_day <= v_d + 1 and coalesce(e.ends_day, v_d + 1) >= v_d + 1),
      'rupee_per_dollar', round(w.fx_inr_usd, 2), 'fuel_inr_kg', round(w.fuel_inr_kg, 1))
      into v_out
      from public.airlines al join public.airline_finance f on f.airline_id = al.id where al.id = v_a;

  elsif p_tool = 'routes' then
    select jsonb_agg(x order by (x ->> 'operating_result_28d')::numeric) into v_out from (
      select jsonb_build_object(
        'route_id', rt.id, 'from', rt.origin, 'to', rt.dest, 'km', m.km, 'international', m.intl,
        'opened_week', game.week_of(rt.opened_day), 'reference_fare', round(m.ref_fare),
        'way_of_selling', pl.strategy, 'sells_where', pl.sell_where,
        'round_trips_a_week', (select coalesce(sum(weekly_trips), 0) from public.rotations where route_id = rt.id),
        'aircraft', (select count(*) from public.rotations where route_id = rt.id),
        'seats_28d', d.seats, 'passengers_28d', d.pax, 'load_factor_28d', round(d.pax / nullif(d.seats, 0), 3),
        'turned_away_28d', d.spill, 'revenue_28d', round(d.rev), 'flying_cost_28d', round(d.var), 'aircraft_cost_28d', round(d.ac),
        'operating_result_28d', round(coalesce(d.rev, 0) - coalesce(d.var, 0) - coalesce(d.ac, 0)),
        'average_fare', round(d.rev / nullif(d.pax, 0)),
        'my_share_of_market_seats', round(coalesce(mine.s, 0) / nullif(allw.s, 0), 3),
        'rivals', (select jsonb_agg(jsonb_build_object('airline', al2.code, 'computer_run', al2.is_ai, 'fare_4_weeks_out', mw.fare_e,
                                                       'round_trips_next_week', mw.trips, 'seats_next_week', mw.seats))
                     from public.market_watch mw join public.airlines al2 on al2.id = mw.airline_id
                    where mw.world_id = w.id and mw.a = m.a and mw.b = m.b and mw.airline_id <> v_a)) as x
        from public.routes rt
        join public.markets m on m.a = least(rt.origin, rt.dest) and m.b = greatest(rt.origin, rt.dest)
        left join public.route_plans pl on pl.route_id = rt.id
        left join lateral (select sum(seats_econ + seats_biz) seats, sum(pax_econ + pax_biz) pax, sum(spill) spill, sum(revenue_inr) rev,
                                  sum(var_cost_inr) var, sum(aircraft_cost_inr) ac
                             from public.route_daily where route_id = rt.id and game_day > v_d - 28) d on true
        left join lateral (select sum(seats_e + seats_b) s from public.route_weeks where route_id = rt.id and week = game.week_of(v_d + 1)) mine on true
        left join lateral (select sum(w2.seats_e + w2.seats_b) s from public.route_weeks w2 join public.routes r2 on r2.id = w2.route_id
                            where r2.world_id = w.id and r2.status = 'open' and w2.week = game.week_of(v_d + 1)
                              and least(r2.origin, r2.dest) = m.a and greatest(r2.origin, r2.dest) = m.b) allw on true
       where rt.airline_id = v_a and rt.status = 'open') y(x);

  elsif p_tool = 'route_weeks' then
    v_route := (p_args ->> 'route_id')::uuid;
    if not exists (select 1 from public.routes where id = v_route and airline_id = v_a) then
      return jsonb_build_object('error', 'Not one of this airline''s routes');
    end if;
    select jsonb_agg(jsonb_build_object('week', week, 'flown', flown_e is not null, 'round_trips', trips,
                                        'seats_economy', seats_e, 'seats_business', seats_b, 'sold_economy', bk_be + bk_l + bk_u,
                                        'sold_business', bk_b, 'economy_fare_now', price_e, 'business_fare_now', price_b,
                                        'flown_economy', flown_e, 'flown_business', flown_b, 'turned_away', spill,
                                        'denied_boarding', denied, 'way_of_selling', strategy) order by week)
      into v_out from public.route_weeks
     where route_id = v_route and week between game.week_of(v_d + 1) - 6 and game.week_of(v_d + 1) + 8;

  elsif p_tool = 'fleet' then
    select jsonb_agg(jsonb_build_object(
      'aircraft_id', x.id, 'reg', x.reg, 'type', t.name, 'base', x.base_iata, 'status', x.status,
      'arrives_week', case when x.status = 'delivering' then game.week_of(x.available_day) end,
      'late_by_weeks', nullif(y.delay_weeks, 0), 'age_years', round((v_d - x.built_day) / 364.0, 1),
      'seats', x.seats_econ + x.seats_biz, 'business_seats', x.seats_biz, 'holding', y.holding,
      'routes', (select jsonb_agg(jsonb_build_object('route_id', ro.route_id, 'round_trips_a_week', ro.weekly_trips))
                   from public.rotations ro where ro.aircraft_id = x.id),
      'block_hours_last_7d', (select round(sum(block_h), 1) from public.aircraft_daily where aircraft_id = x.id and game_day > v_d - 7),
      'flying_day_hours', t.day_window_h,
      'result_last_7d', (select round(sum(revenue_inr - flying_cost_inr - aircraft_cost_inr)) from public.aircraft_daily
                          where aircraft_id = x.id and game_day > v_d - 7)) order by x.status, x.reg)
      into v_out
      from public.aircraft x join public.aircraft_types t on t.id = x.type_id
      left join public.aircraft_terms y on y.aircraft_id = x.id
     where x.airline_id = v_a and x.status <> 'returned';

  elsif p_tool = 'market' then
    select jsonb_build_object(
      'from', m.a, 'to', m.b, 'km', m.km, 'international', m.intl, 'reference_fare', round(m.ref_fare),
      'airlines_flying', (select jsonb_agg(jsonb_build_object('airline', al2.code, 'computer_run', al2.is_ai, 'fare_4_weeks_out', mw.fare_e,
                                                              'round_trips_next_week', mw.trips, 'seats_next_week', mw.seats))
                            from public.market_watch mw join public.airlines al2 on al2.id = mw.airline_id
                           where mw.world_id = w.id and mw.a = m.a and mw.b = m.b),
      'my_route_studies', (select jsonb_agg(jsonb_build_object('week', game.week_of(s.game_day), 'depth', s.depth,
                                                               'travellers_a_day_each_way', jsonb_build_array(s.flying_lo, s.flying_hi),
                                                               'turned_away', jsonb_build_array(s.turned_lo, s.turned_hi),
                                                               'load', jsonb_build_array(s.lf_lo, s.lf_hi)) order by s.game_day desc)
                             from public.route_studies s where s.airline_id = v_a and s.a = m.a and s.b = m.b),
      'note', 'The game never shows predicted passenger numbers; a route study gives a range.')
      into v_out
      from public.markets m where m.a = least(upper(p_args ->> 'a'), upper(p_args ->> 'b')) and m.b = greatest(upper(p_args ->> 'a'), upper(p_args ->> 'b'));
    if v_out is null then return jsonb_build_object('error', 'No market between those airports'); end if;

  elsif p_tool = 'what_works_where' then
    select jsonb_agg(jsonb_build_object('sector', band, 'airlines_on_market', shape, 'way_of_selling', strategy, 'routes', routes,
                                        'load', round(load, 3), 'fare_vs_reference', round(fare_index, 3), 'revenue_per_seat_vs_reference', round(rev_index, 3)))
      into v_out from public.sector_insights
     where world_id = w.id and week = (select max(week) from public.sector_insights where world_id = w.id);

  elsif p_tool = 'ops_preview' then
    v_out := public.ops_preview(v_a);

  else
    return jsonb_build_object('error', 'Unknown look-up ' || p_tool);
  end if;
  return coalesce(v_out, '[]'::jsonb);
end $$;
