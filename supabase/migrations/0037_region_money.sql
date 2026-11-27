-- Migration 0037 (spec 14.29): each region's own money and economy (regions step 2 of 3).
--
-- What changes:
--  * Table public.regions (G, public): each home region's currency (India rupee, US dollar, Canadian dollar, euro, UAE
--    dirham, Chinese yuan, South African rand, Brazilian real), its rate at the game's reference rates, and its levels
--    against India: fuel, pay, airport and air-traffic charges, demand growth, price sensitivity, currency swings,
--    loan rates and pilot supply. Its price level (fares against India's) is worked out from the cost levels with
--    India's cost mix (game values region_w_*, measured in an India season run), so running an airline costs about the
--    same in every region and what differs is which costs dominate and how travellers behave; Africa and South America
--    (thin markets) and Europe (well-paying travellers, short stages) add a fare premium (fare_premium).
--  * The engine keeps counting in one internal unit (today's rupee numbers). A world shows money in its region's
--    currency: internal x price level / rupees per unit. Dollar costs follow the world's own rate, 90 / price level
--    rupees per dollar at the reference; a US world has no currency risk, the euro and the yuan swing less than the
--    rupee, the rand and the real more.
--  * game.apply_region(world), called by create_world: for a world outside India it writes the region's values as the
--    world's own (pay and charge multipliers, fuel and dollar reference prices, currency swings and shocks, cabin crew,
--    head office and base costs, pilot training, price sensitivity, pilot supply), turns the founder's choices into the
--    region's terms (growth times the region's, loan and credit rates moved by the region's difference, compensation
--    amounts into its money), starts the world's fuel and currency at the region's prices, and scales its demand so a
--    place has as many travellers as in India (regions.demand_mult; admin_set_places keeps it). India worlds are not
--    touched: every new value is 1 or India's own.
--  * Functions that read a global value where the world's own now matters read the world's (game.wparam): day_world,
--    fuel_expect, fx_expect, ops_week, sell_week, ops_preview, route_study, pilot_market_init, day_pilots, ops_rows,
--    ferry_cost, wet_rate_usd, bot_prices. day_ops multiplies pilot pay and landing and air-traffic charges by the
--    world's pay_mult and charge_mult. game.book's "Not enough cash" refusal names amounts in the world's money
--    (game.money_text). consultant_data tells the consultant the world's currency.
--  * airports.slot_cap_full: the full daily movements of Heathrow, JFK, Amsterdam, Hong Kong, Singapore and Dubai, whose
--    slot_cap is India's share of them; day_ops uses it in worlds outside India (India worlds: unchanged).
--  * One home region per world (owner's rule): found_airline and open_base accept only the world's region's airports
--    (India worlds: the same rule and message as before). bot_seed seeds the computer-run airlines only in India worlds
--    until each region has its own (step 3). public.invite_region(code) tells the founding screen which region's airports to
--    offer.

-- The full daily movements of the older foreign airports whose slot_cap is India's share of them (G): worlds outside India
-- use the full cap; India worlds keep India's share.
alter table public.airports add column slot_cap_full int;
update public.airports a set slot_cap_full = v.cap
  from (values ('LHR', 1300), ('JFK', 1250), ('AMS', 1370), ('HKG', 1100), ('SIN', 1000), ('DXB', 1150)) v (iata, cap)
 where a.iata = v.iata;

create table public.regions (
  key text primary key,
  name text not null,
  currency text not null,              -- ISO code
  symbol text not null,
  unit_inr numeric not null,           -- rupees for one unit of the currency at the game's reference rates
  style text not null check (style in ('indian', 'western')),   -- lakh and crore, or thousands, millions and billions
  fuel_level numeric not null,         -- jet fuel price against India's
  pay_level numeric not null,          -- pilots, cabin crew and head office pay against India's
  charge_level numeric not null,       -- landing, air-traffic, handling and slot charges against India's
  fare_premium numeric not null default 1,   -- fares above what the costs alone give (thin markets with few rivals)
  price_level numeric,                 -- fares against India's: worked out by game.refresh_regions()
  growth_mult numeric not null,        -- demand growth against India's (times the founder's Growth choice)
  price_sens_mult numeric not null,    -- how much travellers mind the price, against India's
  fx_vol_mult numeric not null,        -- day-to-day swings of the currency against the dollar, against the rupee's
  fx_event_mult numeric not null,      -- how often a currency shock comes, against the rupee's
  fx_drift_year numeric not null,      -- the currency's yearly drift against the dollar (positive: weaker)
  loan_rate_delta numeric not null,    -- loan and credit rates against India's (added to the Banks choice)
  pilot_pool_mult numeric not null,    -- pilots for hire at the start, against India's
  demand_mult numeric,                 -- India's travellers / the region's: keeps travellers per place equal (refresh_regions)
  reg_prefix text not null,            -- aircraft registrations: VT- for India, N for the USA, ...
  note text not null);
alter table public.regions enable row level security;
grant select on public.regions to anon, authenticated;
create policy read_all on public.regions for select to anon, authenticated using (true);

insert into public.game_params (key, num, note) values
  ('pay_mult', 1, 'pilot pay and per-hour pilot costs against the game''s, in the world''s money (0037: a region''s pay level / its price level)'),
  ('charge_mult', 1, 'landing and air-traffic charges against the game''s, in the world''s money (0037: charge level / price level)'),
  ('region_w_usd', 0.436, 'India''s cost mix (0037), dollar costs: aircraft rent, maintenance, dollar loans, depreciation'),
  ('region_w_fuel', 0.35, 'India''s cost mix (0037), fuel'),
  ('region_w_pay', 0.105, 'India''s cost mix (0037), pilots, cabin crew, head office and bases'),
  ('region_w_charge', 0.058, 'India''s cost mix (0037), landing, air-traffic, handling and slots'),
  ('region_w_other', 0.051, 'India''s cost mix (0037), everything else, priced like fares'),
  ('region_demand_markets', 150, 'a region''s demand factor matches the travellers of this many busiest markets to India''s (0037)')
on conflict (key) do nothing;

-- Levels are judgement against India (G), to be checked in a season run per region. Rates: the game's reference rates
-- ($1 = Rs 90, EUR 1 = Rs 100, CAD 1 = Rs 65) and close to late-2026 market rates for the others.
insert into public.regions (key, name, currency, symbol, unit_inr, style, fuel_level, pay_level, charge_level, growth_mult,
                            price_sens_mult, fx_vol_mult, fx_event_mult, fx_drift_year, loan_rate_delta, pilot_pool_mult, note, reg_prefix) values
('india', 'India', 'INR', '₹', 1, 'indian', 1, 1, 1, 1, 1, 1, 1, 0, 0, 1,
 'The reference. Fast growth, price-sensitive travellers, fuel dear from taxes, low pay.', 'VT-'),
('usa', 'USA', 'USD', '$', 90, 'western', 0.75, 4.0, 1.2, 0.4, 0.85, 0, 0, 0, -5, 0.85,
 'High-paying travellers and a huge domestic market; pay about four times India''s; slow growth; the dollar is home money, so no currency risk.', 'N'),
('canada', 'Canada', 'CAD', 'C$', 65, 'western', 0.85, 3.2, 1.6, 0.45, 0.9, 0.5, 0.5, 0, -5.5, 0.9,
 'Long thin domestic routes and the US border market; high airport and air-traffic fees; a currency that moves a little.', 'C-'),
('europe', 'Europe', 'EUR', '€', 100, 'western', 0.85, 3.0, 2.0, 0.45, 0.85, 0.6, 0.5, 0, -6, 1,
 'Well-paying travellers, trains under 500 km, short stages and the dearest charges.', 'EI-'),
('middle_east', 'Middle East', 'AED', 'AED ', 24.5, 'western', 0.7, 2.0, 1.0, 0.9, 0.9, 0, 0, 0, -5, 0.8,
 'Connecting traffic (once connections are built); cheap fuel; a currency pegged to the dollar; small home market.', 'A6-'),
('china', 'China', 'CNY', 'CN¥', 12.5, 'western', 0.9, 1.6, 0.8, 0.85, 1.0, 0.4, 0.3, 0.01, -7, 0.85,
 'Scale, with fast trains winning under about 800 km; a managed currency; cheap money.', 'B-'),
('africa', 'Africa', 'ZAR', 'R', 5, 'western', 1.1, 1.2, 1.6, 0.8, 1.1, 1.8, 2, 0.04, 2, 0.7,
 'High fares on thin routes, high fuel and fees, few pilots, and a currency that falls and crashes.', 'ZS-'),
('south_america', 'South America', 'BRL', 'R$', 16.5, 'western', 1.0, 1.4, 1.2, 0.7, 1.15, 2.0, 2, 0.05, 3, 1,
 'Flying is the only way across the Andes and the Amazon; dear money; a currency that swings hard.', 'PR-');

-- a region's fares against India's: its cost levels weighted by India's cost mix (measured in an India season run), so an
-- airline costs about the same to run; times the region's fare premium where thin markets carry higher fares
-- and its demand factor: the potential travellers of India's busiest markets (region_demand_markets of them, among every
-- market with an end in India) over the region's, so a world of the same places has as many travellers per place on the
-- routes players actually fly (principle 7). Total travellers would starve a region of many thin markets (Europe).
create or replace function game.refresh_regions() returns void
language sql set search_path = '' as $$
  update public.regions set price_level = round((game.param('region_w_usd') + game.param('region_w_fuel') * fuel_level
    + game.param('region_w_pay') * pay_level + game.param('region_w_charge') * charge_level + game.param('region_w_other'))
    * fare_premium, 4);
  with ranked as (
    select rg.key, m.n_biz + m.n_lei + m.n_bud as n,
           row_number() over (partition by rg.key order by m.n_biz + m.n_lei + m.n_bud desc) as rn
      from public.regions rg join public.markets m
        on exists (select 1 from public.airports x where x.iata in (m.a, m.b) and x.home = rg.key)),
  tot as (select key, sum(n) as n from ranked where rn <= game.param('region_demand_markets') group by key)
  update public.regions rg set demand_mult = round((select n from tot where key = 'india') / t.n, 4)
    from tot t where t.key = rg.key;
$$;
select game.refresh_regions();
alter table public.regions alter column price_level set not null, alter column demand_mult set not null;

-- money as a world shows it: internal amount x price level / rupees per unit, in the region's style
create or replace function game.money_text(p_world uuid, p numeric) returns text
language plpgsql stable set search_path = '' as $$
declare
  r public.regions%rowtype; v numeric;
begin
  select rg.* into r from public.regions rg where rg.key = game.world_region(p_world);
  if not found or r.style = 'indian' then return game.inr_text(p); end if;
  if p is null then return '–'; end if;
  v := abs(p) * r.price_level / r.unit_inr;
  return case when p < 0 then '−' else '' end || r.symbol ||
    case when v >= 999.5e6 then rtrim(to_char(round(v / 1e9, 2), 'FM999,990.99'), '.') || 'B'
         when v >= 999.5e3 then rtrim(to_char(round(v / 1e6, 1), 'FM990.9'), '.') || 'M'
         when v >= 1e4 then to_char(round(v / 1e3), 'FM990') || 'K'
         else to_char(round(v), 'FM9,990') end;
end $$;

-- A world outside India takes its region's values as its own (called once, by create_world). India worlds are left alone.
create or replace function game.apply_region(p_world uuid) returns void
language plpgsql set search_path = '' as $$
declare
  r public.regions%rowtype; v_p numeric; v_fuel numeric; v_fx numeric;
begin
  select rg.* into r from public.regions rg where rg.key = game.world_region(p_world);
  if not found or r.key = 'india' then return; end if;
  if exists (select 1 from public.world_params where world_id = p_world and key = 'pay_mult') then return; end if;   -- once
  v_p := r.price_level;
  v_fuel := round(game.param('fuel_ref_inr_kg') * r.fuel_level / v_p, 2);
  v_fx := round(game.param('fx_ref_inr_usd') / v_p, 3);
  insert into public.world_params (world_id, key, num, public)
  select p_world, x.k, x.v, false from (values
    ('pay_mult', round(r.pay_level / v_p, 4)),
    ('charge_mult', round(r.charge_level / v_p, 4)),
    ('fuel_ref_inr_kg', v_fuel),
    ('fx_ref_inr_usd', v_fx),
    ('fx_vol_day', game.param('fx_vol_day') * r.fx_vol_mult),
    ('fx_drift_year', r.fx_drift_year),
    ('event_fx_prob_day', game.wparam(p_world, 'event_fx_prob_day') * r.fx_event_mult),
    ('cabin_inr_bh', round(game.param('cabin_inr_bh') * r.pay_level / v_p, 2)),
    ('cabin_fixed_inr_day', round(game.param('cabin_fixed_inr_day') * r.pay_level / v_p, 2)),
    ('overhead_fixed_inr_day', round(game.param('overhead_fixed_inr_day') * r.pay_level / v_p)),
    ('overhead_aircraft_inr_day', round(game.param('overhead_aircraft_inr_day') * r.pay_level / v_p)),
    ('overhead_seat_inr_day', round(game.param('overhead_seat_inr_day') * r.pay_level / v_p, 2)),
    ('base_fixed_inr_day', round(game.param('base_fixed_inr_day') * r.pay_level / v_p)),
    ('pilot_cadet_inr', round(game.param('pilot_cadet_inr') * r.pay_level / v_p)),
    ('pilot_upgrade_inr', round(game.param('pilot_upgrade_inr') * r.pay_level / v_p)),
    ('handling_inr_pax', round(game.param('handling_inr_pax') * r.charge_level / v_p, 2)),
    ('slot_base_inr', round(game.param('slot_base_inr') * r.charge_level / v_p)),
    ('seg_biz_price', game.param('seg_biz_price') * r.price_sens_mult),
    ('seg_lei_price', game.param('seg_lei_price') * r.price_sens_mult),
    ('seg_bud_price', game.param('seg_bud_price') * r.price_sens_mult),
    ('pilot_pool_start_mult', game.param('pilot_pool_start_mult') * r.pilot_pool_mult),
    ('growth_year', round(game.wparam(p_world, 'growth_year') * r.growth_mult, 4)),
    ('growth_year_intl', round(game.wparam(p_world, 'growth_year_intl') * r.growth_mult, 4)),
    ('loan_rate_inr_year', greatest(0.01, game.wparam(p_world, 'loan_rate_inr_year') + r.loan_rate_delta / 100)),
    ('interest_year', greatest(0.01, game.wparam(p_world, 'interest_year') + r.loan_rate_delta / 100)),
    ('cancel_comp_1_inr', round(game.wparam(p_world, 'cancel_comp_1_inr') / v_p)),
    ('cancel_comp_2_inr', round(game.wparam(p_world, 'cancel_comp_2_inr') / v_p)),
    ('cancel_comp_3_inr', round(game.wparam(p_world, 'cancel_comp_3_inr') / v_p)),
    ('denied_comp_inr', round(game.wparam(p_world, 'denied_comp_inr') / v_p))) x(k, v)
  on conflict (world_id, key) do update set num = excluded.num;
  -- the founder's choices players can see stay visible in the region's terms
  update public.world_params set public = true
   where world_id = p_world and key in ('growth_year', 'growth_year_intl', 'loan_rate_inr_year', 'interest_year',
                                        'cancel_comp_1_inr', 'cancel_comp_2_inr', 'cancel_comp_3_inr', 'denied_comp_inr');
  update public.worlds set fuel_inr_kg = v_fuel, fuel_walk = v_fuel, fuel_avg = v_fuel, fx_inr_usd = v_fx, fx_walk = v_fx,
                           demand_scale = round(demand_scale * r.demand_mult, 3)
   where id = p_world;
end $$;

-- The region of the world an invite code opens, so the founding screen offers that region's airports (null if the code is
-- not valid). Read-only; reveals nothing but the region.
create or replace function public.invite_region(p_invite text) returns text
language sql stable security definer set search_path = '' as $$
  select game.world_region(s.world_id) from public.world_secrets s where s.invite_code = lower(trim(p_invite))
$$;
revoke all on function public.invite_region(text) from public;
grant execute on function public.invite_region(text) to anon, authenticated;

-- Aircraft registrations in the world's region's style (0037): VT- for India, N for the USA, C- Canada, EI- Europe, A6- the
-- Middle East, B- China, ZS- Africa, PR- South America. Without a world (older callers), VT- as before.
drop function game.next_reg();
create or replace function game.next_reg(p_world uuid default null) returns text
language plpgsql set search_path = '' as $$
declare
  n bigint := nextval('game.reg_seq') - 1;
  s text := '';
begin
  loop
    s := chr(65 + (n % 26)::int) || s;
    n := n / 26;
    exit when n = 0 and length(s) >= 3;
  end loop;
  return coalesce((select rg.reg_prefix from public.regions rg where p_world is not null and rg.key = game.world_region(p_world)), 'VT-') || s;
end $$;

-- Festivals and events belong to a region (0037): India's calendar moves demand only in India worlds.
alter table public.demand_events add column region text not null default 'india';

-- fare premiums (G), from one-year season runs per region: Africa and South America for thin markets with few rivals, Europe
-- for its well-paying travellers (with the USA's price tolerance), whose short stages make crew, charges and head office dear
update public.regions set fare_premium = v.p from (values ('africa', 1.3), ('south_america', 1.15), ('europe', 1.1)) v (k, p) where key = v.k;
select game.refresh_regions();

-- The world's own fuel and currency values (0037: a region's; India's are the game's).
CREATE OR REPLACE FUNCTION game.day_world(p_world uuid, p_day integer)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  rw public.worlds%rowtype;
  v_fuel numeric; v_fx numeric; v_mf numeric; v_mx numeric; v_m numeric; v_type text;
  v_ap text; v_city text; v_pax numeric; v_n int;
begin
  select * into rw from public.worlds where id = p_world;
  v_fuel := rw.fuel_walk * exp(game.wparam(p_world, 'fuel_vol_day') * game.rand_normal()
                               + game.wparam(p_world, 'fuel_revert_day') * ln(game.wparam(p_world, 'fuel_ref_inr_kg') / rw.fuel_walk));
  v_fx := rw.fx_walk * exp(game.wparam(p_world, 'fx_vol_day') * game.rand_normal() + game.wparam(p_world, 'fx_drift_year') / 364);

  if random() < game.wparam(p_world, 'event_fuel_prob_day') and not exists
     (select 1 from public.events where world_id = p_world and kind = 'fuel_shock' and ends_day >= p_day) then
    v_m := round(game.wrand_between(p_world, 'event_fuel_mult_min', 'event_fuel_mult_max'), 2);
    insert into public.events (world_id, kind, announced_day, starts_day, ends_day, payload)
    values (p_world, 'fuel_shock', p_day, p_day, p_day + game.wrand_between(p_world, 'event_fuel_days_min', 'event_fuel_days_max')::int, jsonb_build_object('mult', v_m));
    insert into public.news (world_id, game_day, kind, body)
    values (p_world, p_day, 'event', 'Fuel shock: jet fuel is up ' || round((v_m - 1) * 100) || '%.');
  end if;
  if random() < game.wparam(p_world, 'event_fx_prob_day') and not exists
     (select 1 from public.events where world_id = p_world and kind = 'fx_swing' and ends_day >= p_day) then
    v_m := round(game.wrand_between(p_world, 'event_fx_mult_min', 'event_fx_mult_max'), 3);
    insert into public.events (world_id, kind, announced_day, starts_day, ends_day, payload)
    values (p_world, 'fx_swing', p_day, p_day, p_day + game.wrand_between(p_world, 'event_fx_days_min', 'event_fx_days_max')::int, jsonb_build_object('mult', v_m));
    insert into public.news (world_id, game_day, kind, body)
    values (p_world, p_day, 'event', 'Currency swing: the rupee has weakened ' || round((v_m - 1) * 100, 1) || '% against the dollar.');
  end if;
  if random() < game.wparam(p_world, 'event_engine_prob_day') and not exists   -- 0025: one engine event at a time, like the others
     (select 1 from public.events where world_id = p_world and kind = 'engine_grounding' and ends_day >= p_day) then
    select x.type_id into v_type from public.aircraft x
     where x.world_id = p_world and x.status = 'active' and x.airline_id is not null
     group by x.type_id order by random() limit 1;
    if v_type is not null then
      insert into public.events (world_id, kind, announced_day, starts_day, ends_day, payload)
      values (p_world, 'engine_grounding', p_day, p_day, p_day + game.wrand_between(p_world, 'event_engine_days_min', 'event_engine_days_max')::int,
              jsonb_build_object('type', v_type, 'share', round(game.wrand_between(p_world, 'event_engine_share_min', 'event_engine_share_max'), 2)));
      insert into public.news (world_id, game_day, kind, body)
      select p_world, p_day, 'event', 'Engine inspections ground part of the ' || name || ' fleet for several weeks.'
        from public.aircraft_types where id = v_type;
    end if;
  end if;

  -- 0028: an Indian airport closes for a few days (storm, flood, runway work); bigger airports more often. After a big
  -- airport closes the government caps economy fares on domestic routes to and from it for some weeks.
  if random() < game.wparam(p_world, 'event_airport_prob_day') and not exists
     (select 1 from public.events where world_id = p_world and kind = 'airport_closed' and ends_day >= p_day) then
    select ap.iata, ap.city, ap.pax_m into v_ap, v_city, v_pax
      from public.airports ap
     where ap.is_india and ap.opens_day <= p_day and ap.pax_m > 0
     order by -ln(greatest(random(), 1e-12)) / ap.pax_m limit 1;
    if v_ap is not null then
      v_n := game.wrand_between(p_world, 'event_airport_days_min', 'event_airport_days_max')::int;
      insert into public.events (world_id, kind, announced_day, starts_day, ends_day, payload)
      values (p_world, 'airport_closed', p_day, p_day, p_day + v_n - 1, jsonb_build_object('airport', v_ap));
      insert into public.news (world_id, game_day, kind, body)
      values (p_world, p_day, 'event', format('%s airport (%s) is closed for %s by bad weather: every flight to and from it is cancelled and its travellers refunded.',
              v_city, v_ap, case when v_n = 1 then 'a day' else v_n || ' days' end));
      if game.wparam(p_world, 'fare_cap_on') >= 1 and v_pax >= game.wparam(p_world, 'fare_cap_min_pax') then
        v_m := game.wparam(p_world, 'fare_cap_mult');
        insert into public.events (world_id, kind, announced_day, starts_day, ends_day, payload)
        values (p_world, 'fare_cap', p_day, p_day, p_day + (game.wparam(p_world, 'fare_cap_weeks') * 7)::int - 1,
                jsonb_build_object('airport', v_ap, 'mult', v_m));
        insert into public.news (world_id, game_day, kind, body)
        values (p_world, p_day, 'event', format('The government caps economy fares on domestic routes to and from %s at %s times the reference fare for %s weeks.',
                v_city, round(v_m, 2), game.wparam(p_world, 'fare_cap_weeks')::int));
      end if;
    end if;
  end if;
  -- 0028: the airspace west of India closes; flights from north India to the west fly round it (airspace_detours)
  if random() < game.wparam(p_world, 'event_airspace_prob_day') and not exists
     (select 1 from public.events where world_id = p_world and kind = 'airspace_closed' and ends_day >= p_day) then
    v_n := game.wrand_between(p_world, 'event_airspace_days_min', 'event_airspace_days_max')::int;
    insert into public.events (world_id, kind, announced_day, starts_day, ends_day, payload)
    values (p_world, 'airspace_closed', p_day, p_day, p_day + v_n - 1, jsonb_build_object('lat_min', game.param('airspace_lat_min')));
    insert into public.news (world_id, game_day, kind, body)
    values (p_world, p_day, 'event', format('The airspace west of India is closed for about %s weeks. Flights from north India to the Gulf, Europe, Africa, Central Asia and North America fly round it: longer, with more fuel and crew hours. Aircraft that can no longer reach are cancelled.',
            round(v_n / 7.0)));
  end if;

  select coalesce(exp(sum(ln((payload ->> 'mult')::numeric)) filter (where kind = 'fuel_shock')), 1),
         coalesce(exp(sum(ln((payload ->> 'mult')::numeric)) filter (where kind = 'fx_swing')), 1)
    into v_mf, v_mx
    from public.events
   where world_id = p_world and kind in ('fuel_shock', 'fx_swing') and starts_day <= p_day and ends_day >= p_day;

  update public.worlds
     set fuel_walk = v_fuel, fx_walk = v_fx, fuel_inr_kg = round(v_fuel * v_mf, 2), fx_inr_usd = round(v_fx * v_mx, 3)
   where id = p_world;
  insert into public.world_daily (world_id, game_day, fuel_inr_kg, fx_inr_usd)
  values (p_world, p_day, round(v_fuel * v_mf, 2), round(v_fx * v_mx, 3));
  insert into public.news (world_id, game_day, kind, body)
  select p_world, p_day, 'event', city || ' airport (' || iata || ') opens today.'
    from public.airports where opens_day = p_day;
end $function$;

CREATE OR REPLACE FUNCTION game.fuel_expect(p_world uuid, p_days integer)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select round((game.wparam(w.id, 'fuel_ref_inr_kg') * power(w.fuel_walk / game.wparam(w.id, 'fuel_ref_inr_kg'),
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
$function$;

CREATE OR REPLACE FUNCTION game.fx_expect(p_world uuid, p_days integer)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select round(w.fx_walk * exp(game.wparam(w.id, 'fx_drift_year') * p_days / 364)
         * coalesce((select (e.payload ->> 'mult')::numeric from public.events e
                      where e.world_id = w.id and e.kind = 'fx_swing' and e.starts_day <= w.game_day and e.ends_day >= w.game_day + p_days
                      order by e.ends_day desc limit 1),
                    1 + s.share * ((game.wparam(w.id, 'event_fx_mult_min') + game.wparam(w.id, 'event_fx_mult_max')) / 2 - 1)), 3)
    from public.worlds w
    cross join lateral (select game.wparam(w.id, 'event_fx_prob_day')
                               * (game.wparam(w.id, 'event_fx_days_min') + game.wparam(w.id, 'event_fx_days_max')) / 2 as pd) p
    cross join lateral (select p.pd / (1 + p.pd) as share) s
   where w.id = p_world
$function$;

CREATE OR REPLACE FUNCTION game.ops_week(p_world uuid, p_day integer)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
                                 * (w.fuel_avg / game.wparam(p_world, 'fuel_ref_inr_kg') - 1))::numeric, 4)
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
end $function$;

CREATE OR REPLACE FUNCTION game.sell_week(p_world uuid, p_day integer)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
 SET jit TO 'off'
AS $function$
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
         case when m.intl then 1 + coalesce(po.usd_share, 0) * (rw.fx_inr_usd / game.wparam(p_world, 'fx_ref_inr_usd') - 1) else 1 end::float8 as fxm,
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
     and e.region = game.world_region(p_world)   -- 0037: the world's region's calendar
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
end $function$;

CREATE OR REPLACE FUNCTION public.ops_preview(p_airline uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
           'share', ao.usd_hedge_share, 'rate', rw.fx_inr_usd, 'ref', game.wparam(rw.id, 'fx_ref_inr_usd'),
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
end $function$;

-- Travellers' price sensitivity is the world's (0037).
CREATE OR REPLACE FUNCTION public.route_study(p_airline uuid, p_a text, p_b text, p_depth text DEFAULT 'quick'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  rw public.worlds%rowtype; m public.markets%rowtype; s public.route_studies%rowtype;
  v_day int; v_w numeric; v_cost numeric; v_e numeric;
  v_fly numeric; v_turn numeric; v_seats numeric; v_days int; v_grow numeric; v_untap numeric; v_block numeric;
  v_sb numeric; v_sl numeric; v_su numeric;
begin
  rw := game.actor(p_airline); v_day := rw.game_day + 1;
  if p_depth is null or p_depth not in ('quick', 'full') then raise exception 'A study is quick or full'; end if;
  select * into m from public.markets where a = least(upper(p_a), upper(p_b)) and b = greatest(upper(p_a), upper(p_b));
  if not found or not exists (select 1 from public.airports x where x.iata in (m.a, m.b) and x.home = game.world_region(rw.id)) then
    raise exception 'There is no market between % and %', p_a, p_b;
  end if;
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
      (m.n_biz * v_sb, game.param('seg_biz_a') - game.wparam(rw.id, 'seg_biz_price') + game.param('seg_biz_freq') * ln(3)
                       + game.param('seg_biz_comfort') * (1 / 6.0) * sqrt(v_block)),
      (m.n_lei * v_sl, game.param('seg_lei_a') - game.wparam(rw.id, 'seg_lei_price') + game.param('seg_lei_freq') * ln(3)
                       + game.param('seg_lei_comfort') * (1 / 6.0) * sqrt(v_block)),
      (m.n_bud * v_su, game.param('seg_bud_a') - game.wparam(rw.id, 'seg_bud_price') + game.param('seg_bud_freq') * ln(3)
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
end $function$;

-- Pilots for hire, training and severance at the world's pay (0037).
CREATE OR REPLACE FUNCTION game.pilot_market_init(p_world uuid)
 RETURNS void
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  insert into public.pilot_market (world_id, family, captains, fos)
  select w.id, f.id, round(f.pool_c * w.max_airlines * game.wparam(w.id, 'pilot_pool_start_mult')),
         round(f.pool_f * w.max_airlines * game.wparam(w.id, 'pilot_pool_start_mult'))
    from public.worlds w cross join public.pilot_families f
   where w.id = p_world
  on conflict (world_id, family) do nothing
$function$;

CREATE OR REPLACE FUNCTION game.day_pilots(p_world uuid, p_day integer)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  rw public.worlds%rowtype; rec record; fam record; rk text;
  v_res numeric := game.param('pilot_reserve'); v_plan int := game.param('pilot_plan_days')::int;
  v_pbh numeric; v_m numeric; v_n int; v_e int; v_take int; v_gap int; v_pool numeric; v_cost numeric; v_target int;
begin
  select * into rw from public.worlds where id = p_world;
  if not rw.pilots then return; end if;
  perform game.pilot_market_init(p_world);

  -- the regulator tightens duty-time rules, announced ahead, at most once a season
  if random() < game.param('event_duty_prob_day') and p_day + game.param('event_duty_notice') < rw.season_days
     and not exists (select 1 from public.events where world_id = p_world and kind = 'duty_rules') then
    insert into public.events (world_id, kind, announced_day, starts_day, ends_day, payload)
    values (p_world, 'duty_rules', p_day, game.week_start_from(p_day + game.param('event_duty_notice')::int), null,
            jsonb_build_object('mult', game.param('event_duty_mult')));
    insert into public.news (world_id, game_day, kind, body)
    values (p_world, p_day, 'event', format('The regulator tightens pilot duty-time rules from week %s: each pilot may fly about %s%% fewer hours. Airlines without spare pilots will cancel flights.',
            game.week_of(game.week_start_from(p_day + game.param('event_duty_notice')::int)), round((1 - game.param('event_duty_mult')) * 100)));
  end if;

  -- pilots joining, promoted or leaving today
  for rec in select * from public.pilot_moves where world_id = p_world and not done and due_day <= p_day order by id loop
    insert into public.airline_pilots (airline_id, family) values (rec.airline_id, rec.family) on conflict do nothing;
    if rec.kind = 'leave' then
      update public.airline_pilots
         set captains = captains - case when rec.rank = 'c' then least(rec.n, captains - expats) else 0 end,
             fos = fos - case when rec.rank = 'f' then least(rec.n, fos) else 0 end
       where airline_id = rec.airline_id and family = rec.family;
      update public.pilot_market
         set captains = captains + case when rec.rank = 'c' then rec.n else 0 end, fos = fos + case when rec.rank = 'f' then rec.n else 0 end
       where world_id = p_world and family = rec.family;
    elsif rec.kind = 'upgrade' then
      update public.airline_pilots set captains = captains + least(rec.n, fos), fos = fos - least(rec.n, fos)
       where airline_id = rec.airline_id and family = rec.family;
    else
      update public.airline_pilots
         set captains = captains + case when rec.rank = 'c' then rec.n else 0 end,
             fos = fos + case when rec.rank = 'f' then rec.n else 0 end,
             expats = expats + case when rec.kind = 'expat' then rec.n else 0 end
       where airline_id = rec.airline_id and family = rec.family;
    end if;
    update public.pilot_moves set done = true where id = rec.id;
  end loop;
  delete from public.pilot_moves where world_id = p_world and done and due_day < p_day - 182;

  -- the market: newly qualified pilots arrive, some leave for other work; market pay follows the captain shortage
  update public.pilot_market pm
     set captains = pm.captains * (1 - game.param('pilot_pool_out_qtr') / 91) + f.pool_c * rw.max_airlines * game.param('pilot_pool_in_qtr') / 91,
         fos = pm.fos * (1 - game.param('pilot_pool_out_qtr') / 91) + f.pool_f * rw.max_airlines * game.param('pilot_pool_in_qtr') / 91,
         pay_index = round(pm.pay_index + game.param('pilot_pay_smooth')
                     * (1 + game.param('pilot_pay_k') * power(1 - least(1, pm.captains / (f.pool_c * rw.max_airlines)), 2) - pm.pay_index), 4)
    from public.pilot_families f
   where pm.world_id = p_world and f.id = pm.family;

  -- what each airline needs, planned at the duty-time rules that will apply when its next aircraft arrive
  v_pbh := game.pilot_bh(p_world, p_day + v_plan);
  update public.airline_pilots ap set need = 0
    from public.airlines al where al.id = ap.airline_id and al.world_id = p_world and ap.need <> 0;
  insert into public.airline_pilots (airline_id, family, need)
  select n.airline_id, n.family, ceil(n.bh / v_pbh * (1 + v_res))
    from game.pilot_need(p_world, p_day, v_plan) n
    join public.airlines al on al.id = n.airline_id and al.status = 'active'
  on conflict (airline_id, family) do update set need = excluded.need;

  -- resignations: pay below the market or below a rival, too few colleagues, an airline in trouble
  for rec in
    select ap.airline_id, ap.family, ap.captains, ap.fos, ap.expats, ap.need, fin.pilot_pay, fin.cash_inr, al.is_ai, pf.name,
           (select max(f2.pilot_pay) from public.airline_finance f2 join public.airlines a2 on a2.id = f2.airline_id
             where a2.world_id = p_world and a2.status = 'active' and a2.id <> ap.airline_id) as best,
           coalesce((select sum(mv.n) from public.pilot_moves mv where mv.airline_id = ap.airline_id and mv.family = ap.family
                      and not mv.done and mv.kind = 'leave' and mv.rank = 'c'), 0) as out_c,
           coalesce((select sum(mv.n) from public.pilot_moves mv where mv.airline_id = ap.airline_id and mv.family = ap.family
                      and not mv.done and mv.kind = 'leave' and mv.rank = 'f'), 0) as out_f
      from public.airline_pilots ap
      join public.airlines al on al.id = ap.airline_id and al.world_id = p_world and al.status = 'active'
      join public.airline_finance fin on fin.airline_id = ap.airline_id
      join public.pilot_families pf on pf.id = ap.family
     where ap.captains + ap.fos > 0
  loop
    v_m := game.param('pilot_quit_year') / 364
           * exp(-game.param('pilot_quit_pay_k') * (rec.pilot_pay - 1))
           * exp(game.param('pilot_quit_poach_k') * greatest(0, coalesce(rec.best, 0) - rec.pilot_pay))
           * case when least(rec.captains, rec.fos) < rec.need then game.param('pilot_quit_stretch') else 1 end
           * case when rec.cash_inr < 0 then game.param('pilot_quit_trouble') else 1 end;
    foreach rk in array array['c', 'f'] loop
      v_n := floor(greatest(0, case when rk = 'c' then rec.captains - rec.expats - rec.out_c else rec.fos - rec.out_f end) * v_m + random())::int;
      if v_n > 0 then
        insert into public.pilot_moves (airline_id, world_id, family, rank, kind, n, start_day, due_day)
        values (rec.airline_id, p_world, rec.family, rk, 'leave', v_n, p_day, p_day + game.param('pilot_notice_' || rk)::int);
        if not rec.is_ai then
          insert into public.news (world_id, game_day, airline_id, kind, body, private)
          values (p_world, p_day, rec.airline_id, 'pilots',
                  v_n || ' ' || rec.name || ' ' || case when rk = 'c' then case when v_n = 1 then 'captain has' else 'captains have' end
                                                         else case when v_n = 1 then 'first officer has' else 'first officers have' end end
                  || ' resigned. They keep flying until week ' || game.week_of(p_day + game.param('pilot_notice_' || rk)::int) || ', then leave.'
                  || case when coalesce(rec.best, 0) > rec.pilot_pay then ' Another airline pays more.' else '' end, true);
        end if;
      end if;
    end loop;
  end loop;

  -- hiring up to need x (1 + spare): the market first, best payers first; captains next from command upgrades of the
  -- airline's own first officers; then foreign captains if the airline allows them
  for fam in select id, name from public.pilot_families order by sort loop
    foreach rk in array array['c', 'f'] loop
      select case when rk = 'c' then captains else fos end into v_pool from public.pilot_market where world_id = p_world and family = fam.id;
      for rec in
        select ap.airline_id, fin.pilot_expats, ap.captains, ap.fos, ceil(ap.need * (1 + fin.pilot_buffer))::int as target,
               coalesce(sum(mv.n) filter (where not mv.done and mv.rank = rk and mv.kind in ('hire', 'expat', 'cadet')), 0)
                 + coalesce(sum(mv.n) filter (where not mv.done and mv.kind = 'upgrade'), 0) * case when rk = 'c' then 1 else -1 end
                 - coalesce(sum(mv.n) filter (where not mv.done and mv.rank = rk and mv.kind = 'leave'), 0) as pending,
               coalesce(sum(mv.n) filter (where mv.kind = 'hire' and mv.rank = rk and mv.start_day > p_day - 91), 0) as hired_qtr,
               coalesce(sum(mv.n) filter (where mv.kind = 'upgrade' and mv.start_day > p_day - 91), 0) as upg_qtr,
               coalesce(sum(mv.n) filter (where not mv.done and mv.kind = 'upgrade'), 0) as upg_now,
               coalesce(sum(mv.n) filter (where not mv.done and mv.rank = 'f' and mv.kind = 'leave'), 0) as out_f
          from public.airline_pilots ap
          join public.airlines al on al.id = ap.airline_id and al.world_id = p_world and al.status = 'active'
          join public.airline_finance fin on fin.airline_id = ap.airline_id
          left join public.pilot_moves mv on mv.airline_id = ap.airline_id and mv.family = ap.family
         where ap.family = fam.id and ap.need > 0
         group by ap.airline_id, fin.pilot_expats, ap.captains, ap.fos, ap.need, fin.pilot_buffer, fin.pilot_pay
         order by fin.pilot_pay desc, random()
      loop
        v_gap := rec.target - case when rk = 'c' then rec.captains else rec.fos end - rec.pending;
        continue when v_gap <= 0;
        v_take := least(v_gap, floor(v_pool)::int, greatest(0, game.param('pilot_hire_max_qtr')::int - rec.hired_qtr));
        if v_take > 0 then
          insert into public.pilot_moves (airline_id, world_id, family, rank, kind, n, start_day, due_day)
          values (rec.airline_id, p_world, fam.id, rk, 'hire', v_take, p_day, p_day + game.param('pilot_join_days')::int);
          v_pool := v_pool - v_take; v_gap := v_gap - v_take;
        end if;
        if rk = 'c' and v_gap > 0 then
          v_n := least(v_gap, ceil((rec.fos - rec.out_f - rec.upg_now) * game.param('pilot_upgrade_share_qtr'))::int - rec.upg_qtr);
          if v_n > 0 then
            insert into public.pilot_moves (airline_id, world_id, family, rank, kind, n, start_day, due_day)
            values (rec.airline_id, p_world, fam.id, 'c', 'upgrade', v_n, p_day, p_day + game.param('pilot_upgrade_days')::int);
            v_cost := v_n * game.wparam(p_world, 'pilot_upgrade_inr');
            perform game.book(rec.airline_id, p_day, -v_cost, 'training',
                              format('Command training for %s %s first officer%s', v_n, fam.name, case when v_n = 1 then '' else 's' end), -v_cost, true);
            v_gap := v_gap - v_n;
          end if;
          if v_gap > 0 and rec.pilot_expats then
            insert into public.pilot_moves (airline_id, world_id, family, rank, kind, n, start_day, due_day)
            values (rec.airline_id, p_world, fam.id, 'c', 'expat', v_gap, p_day, p_day + game.param('pilot_expat_days')::int);
          end if;
        end if;
      end loop;
      update public.pilot_market set captains = case when rk = 'c' then v_pool else captains end, fos = case when rk = 'f' then v_pool else fos end
       where world_id = p_world and family = fam.id;
    end loop;
  end loop;

  -- cadets start through the quarter at the airline's rate, for its biggest fleet family
  for rec in
    select fin.airline_id, fin.pilot_cadets,
           coalesce((select ap.family from public.airline_pilots ap where ap.airline_id = fin.airline_id
                      order by ap.need desc, ap.family = 'A320' desc limit 1), 'A320') as family
      from public.airline_finance fin
      join public.airlines al on al.id = fin.airline_id and al.world_id = p_world and al.status = 'active'
     where fin.pilot_cadets > 0
  loop
    v_n := floor(p_day * rec.pilot_cadets / 91.0)::int - floor((p_day - 1) * rec.pilot_cadets / 91.0)::int;
    if v_n > 0 then
      insert into public.pilot_moves (airline_id, world_id, family, rank, kind, n, start_day, due_day)
      values (rec.airline_id, p_world, rec.family, 'f', 'cadet', v_n, p_day, p_day + game.param('pilot_cadet_days')::int);
      v_cost := v_n * game.wparam(p_world, 'pilot_cadet_inr');
      perform game.book(rec.airline_id, p_day, -v_cost, 'training', format('Training for %s cadet%s', v_n, case when v_n = 1 then '' else 's' end), -v_cost, true);
    end if;
  end loop;

  -- pilots well above need are let go, with severance; foreign captains go first, local pilots return to the market
  for rec in
    select ap.airline_id, ap.family, ap.captains, ap.fos, ap.expats, ap.need, fin.pilot_buffer, fin.pilot_pay, pm.pay_index,
           pf.pay_c_inr_day, pf.pay_f_inr_day, pf.name, al.is_ai,
           coalesce((select sum(mv.n) from public.pilot_moves mv where mv.airline_id = ap.airline_id and mv.family = ap.family
                      and not mv.done and mv.kind = 'leave' and mv.rank = 'c'), 0) as out_c,
           coalesce((select sum(mv.n) from public.pilot_moves mv where mv.airline_id = ap.airline_id and mv.family = ap.family
                      and not mv.done and mv.rank = 'f' and (mv.kind = 'leave' or mv.kind = 'upgrade')), 0) as out_f
      from public.airline_pilots ap
      join public.airlines al on al.id = ap.airline_id and al.world_id = p_world and al.status = 'active'
      join public.airline_finance fin on fin.airline_id = ap.airline_id
      join public.pilot_market pm on pm.world_id = p_world and pm.family = ap.family
      join public.pilot_families pf on pf.id = ap.family
     where ap.captains + ap.fos > 0
  loop
    v_target := ceil(rec.need * (1 + rec.pilot_buffer) * game.param('pilot_furlough_slack'))::int;
    v_n := rec.captains - rec.out_c - v_target;
    if v_n > 0 then
      v_e := least(v_n, rec.expats);
      v_cost := round(game.param('pilot_severance_days') * rec.pay_index * rec.pay_c_inr_day * game.wparam(p_world, 'pay_mult')
                      * (v_e * game.param('pilot_expat_mult') + (v_n - v_e) * rec.pilot_pay));
      update public.airline_pilots set captains = captains - v_n, expats = expats - v_e where airline_id = rec.airline_id and family = rec.family;
      update public.pilot_market set captains = captains + (v_n - v_e) where world_id = p_world and family = rec.family;
      perform game.book(rec.airline_id, p_day, -v_cost, 'severance', format('%s %s captain%s let go', v_n, rec.name, case when v_n = 1 then '' else 's' end), -v_cost, true);
    end if;
    v_n := rec.fos - rec.out_f - v_target;
    if v_n > 0 then
      v_cost := round(game.param('pilot_severance_days') * rec.pay_index * rec.pay_f_inr_day * game.wparam(p_world, 'pay_mult') * rec.pilot_pay * v_n);
      update public.airline_pilots set fos = fos - v_n where airline_id = rec.airline_id and family = rec.family;
      update public.pilot_market set fos = fos + v_n where world_id = p_world and family = rec.family;
      perform game.book(rec.airline_id, p_day, -v_cost, 'severance', format('%s %s first officer%s let go', v_n, rec.name, case when v_n = 1 then '' else 's' end), -v_cost, true);
    end if;
  end loop;
end $function$;

-- Crew and airport costs at the world's pay and charges (0037).
CREATE OR REPLACE FUNCTION game.ops_rows(p_airline uuid, p_day integer, p_rule text)
 RETURNS TABLE(aircraft_id uuid, wet boolean, age_y numeric, trips integer, km integer, block_h numeric, fh numeric, maint_usd_fh numeric, maint_usd_cycle numeric, fuel_kg numeric, crew_inr_bh numeric, window_h numeric, turn_min numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select ac.id, tm.holding = 'wet', greatest(0, p_day - ac.built_day) / 364.0, ro.weekly_trips, m.km,
         m.km::numeric / t.cruise_kmh + t.block_offset_h, m.km::numeric / t.cruise_kmh + game.param('maint_fh_offset'),
         t.maint_usd_fh, t.maint_usd_cycle,
         (t.fuel_fixed_kg + t.fuel_per_km_kg * m.km) * 0.97 * (1 + game.param('age_fuel_per_year') * greatest(0, p_day - ac.built_day) / 364.0),
         t.pilot_inr_bh * game.wparam((select a.world_id from public.airlines a where a.id = p_airline), 'pay_mult') + game.cabin_crew(p_rule, ac.seats_econ + ac.seats_biz) * game.wparam((select a.world_id from public.airlines a where a.id = p_airline), 'cabin_inr_bh'),
         t.day_window_h, l.min_turn_min
    from public.rotations ro
    join public.aircraft ac on ac.id = ro.aircraft_id
    join public.aircraft_terms tm on tm.aircraft_id = ac.id
    join public.aircraft_types t on t.id = ac.type_id
    join public.routes r on r.id = ro.route_id
    join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
    cross join lateral public.layout_calc(ac.type_id, ac.biz_rows, ac.biz_pitch, ac.econ_pitch, p_rule) l
   where ac.airline_id = p_airline and ac.status in ('active', 'grounded', 'refit', 'delivering')
$function$;

CREATE OR REPLACE FUNCTION game.ferry_cost(p_aircraft uuid, p_from text, p_to text)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select case when p_from = p_to or game.param('ferry_on') < 1 then 0 else round(
           (t.fuel_fixed_kg + t.fuel_per_km_kg * d.km) * 0.8 * w.fuel_inr_kg
           + (d.km / t.cruise_kmh + t.block_offset_h) * (t.pilot_inr_bh * game.wparam(w.id, 'pay_mult') + game.cabin_crew(w.crew_rule, ac.seats_econ + ac.seats_biz) * game.wparam(w.id, 'cabin_inr_bh'))
           + ((d.km / t.cruise_kmh + game.param('maint_fh_offset')) * t.maint_usd_fh + t.maint_usd_cycle) * w.fx_inr_usd
           + (t.landing_inr + t.nav_inr_km * d.km) * game.wparam(w.id, 'charge_mult')) end
    from public.aircraft ac
    join public.aircraft_types t on t.id = ac.type_id
    join public.worlds w on w.id = ac.world_id
    cross join lateral (select game.haversine_km(a.lat::float8, a.lon::float8, b.lat::float8, b.lon::float8)::numeric as km
                          from public.airports a, public.airports b where a.iata = p_from and b.iata = p_to) d
   where ac.id = p_aircraft
$function$;

CREATE OR REPLACE FUNCTION game.wet_rate_usd(p_world uuid, p_type text)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select round(game.param('wet_lease_mult') * (
           (t.lease_usd_month / 30.33
              + (t.pilot_fixed_inr_day * game.wparam(w.id, 'pay_mult') + l.cabin_crew * game.wparam(w.id, 'cabin_fixed_inr_day')) / w.fx_inr_usd)
             / game.param('wet_ref_hours_day')
           + t.maint_usd_fh + t.maint_usd_cycle / 2.0
           + (t.pilot_inr_bh * game.wparam(w.id, 'pay_mult') + l.cabin_crew * game.wparam(w.id, 'cabin_inr_bh')) / w.fx_inr_usd))
  from public.aircraft_types t, public.worlds w, game.std_layout(t.id, 1) s,
       public.layout_calc(t.id, s.biz_rows, s.biz_pitch, s.econ_pitch, w.crew_rule) l
  where t.id = p_type and w.id = p_world
$function$;

CREATE OR REPLACE FUNCTION game.bot_prices(p_world uuid, p_day integer)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  r record;
  v_hi numeric := game.param('bot_lf_high');
  v_lo numeric := game.param('bot_lf_low');
  v_step numeric := game.param('bot_fare_step');
  v_bm numeric := game.param('biz_fare_mult');
  v_net numeric := 1 + game.param('ancillary_share') - game.param('dist_rev_share');
  v_flf numeric := game.param('bot_floor_lf');
  v_floor numeric; v_be numeric; v_e numeric; v_b numeric; v_n int := 0;
begin
  for r in
    with fly as (
      select rt.id, rt.airline_id, al.is_ai, least(rt.origin, rt.dest) as a, greatest(rt.origin, rt.dest) as b, rt.fare_econ
        from public.routes rt join public.airlines al on al.id = rt.airline_id and al.status = 'active'
       where rt.world_id = p_world and rt.status = 'open'
         and exists (select 1 from public.rotations ro where ro.route_id = rt.id))
    select f.id, f.airline_id, f.fare_econ, rt.fare_biz, m.ref_fare, ba.fare_lo, ba.fare_hi, ba.defend_lo,
           exists (select 1 from public.bases bs where bs.airline_id = f.airline_id and bs.iata in (f.a, f.b)) as home,
           rd.lf_e, rd.lf_b, rd.var_day, rd.seats_e_day, rd.pax_b_day, fc.fixed_day,
           (select min(x.fare_econ) from fly x where x.a = f.a and x.b = f.b and x.airline_id <> f.airline_id) as rival,
           (select min(x.fare_econ) from fly x where x.a = f.a and x.b = f.b and not x.is_ai) as player
      from fly f
      join public.routes rt on rt.id = f.id
      join public.airlines al on al.id = f.airline_id
      join public.bot_airlines ba on ba.code = al.code
      join public.markets m on m.a = f.a and m.b = f.b
      left join lateral (select sum(d.pax_econ)::numeric / nullif(sum(d.seats_econ), 0) as lf_e,
                                sum(d.pax_biz)::numeric / nullif(sum(d.seats_biz), 0) as lf_b,
                                avg(d.var_cost_inr) as var_day, avg(d.seats_econ) as seats_e_day, avg(d.pax_biz) as pax_b_day
                           from public.route_daily d where d.route_id = f.id and d.game_day between p_day - 7 and p_day - 1) rd on true
      -- the route's share of fixed costs: each computer-run aircraft flies one route
      left join lateral (select sum(tm.lease_usd_month * w.fx_inr_usd / 30.33 + t.pilot_fixed_inr_day * game.wparam(w.id, 'pay_mult')
                                    + game.cabin_crew(w.crew_rule, x.seats_econ + x.seats_biz) * game.wparam(w.id, 'cabin_fixed_inr_day')
                                    + game.wparam(w.id, 'overhead_seat_inr_day') * (x.seats_econ + x.seats_biz)) as fixed_day
                           from public.rotations ro
                           join public.aircraft x on x.id = ro.aircraft_id
                           join public.aircraft_terms tm on tm.aircraft_id = x.id
                           join public.aircraft_types t on t.id = x.type_id
                           join public.worlds w on w.id = x.world_id
                          where ro.route_id = f.id) fc on true
     where f.is_ai
  loop
    -- break-even economy fare at bot_floor_lf, after business revenue
    v_be := ((r.var_day + r.fixed_day) / v_net - r.pax_b_day * r.fare_biz) / nullif(r.seats_e_day * v_flf, 0);
    v_floor := greatest(case when r.home and r.player < r.fare_econ then r.defend_lo else r.fare_lo end * r.ref_fare,
                        least(r.fare_hi * r.ref_fare, coalesce(v_be, 0)));
    v_e := r.fare_econ;
    if r.lf_e >= v_hi then v_e := v_e * (1 + v_step);
    elsif r.lf_e < v_lo then v_e := v_e * (1 - v_step);
    end if;
    if r.rival < v_e and r.lf_e < v_lo then v_e := r.rival; end if;   -- losing passengers to a cheaper rival: follow it
    v_e := round(least(r.fare_hi * r.ref_fare, greatest(v_floor, v_e)));
    v_b := r.fare_biz;
    if r.lf_b >= v_hi then v_b := v_b * (1 + v_step);
    elsif r.lf_b < v_lo then v_b := v_b * (1 - v_step);
    end if;
    v_b := round(least(r.fare_hi * r.ref_fare * v_bm, greatest(r.fare_lo * r.ref_fare * v_bm, v_b)));
    if v_e <> r.fare_econ or v_b <> r.fare_biz then
      perform public.set_fares(r.airline_id, r.id, v_e::int, v_b::int);
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end $function$;

CREATE OR REPLACE FUNCTION game.day_ops(p_world uuid, p_day integer)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
    cash_interest_year numeric, insurance_year numeric, pay_mult numeric, charge_mult numeric);   -- 0033

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
    select ap.iata, g.slot_base_inr / power(1 - least(g.slot_util_cap, mv.moves / (coalesce(case when game.world_region(p_world) <> 'india' then ap.slot_cap_full end, ap.slot_cap) * rw.slot_scale * rw.demand_scale)), 2) as price
      from mv join public.airports ap on ap.iata = mv.iata
     where ap.slot_cap is not null)
  update pg_temp._rot x set
    fuel_kg = 2 * x.f * (t.fuel_fixed_kg + t.fuel_per_km_kg * x.km)
             * (0.80 + 0.20 * (x.seats_e * p.lf_e + x.seats_b * p.lf_b) / t.ref_seats)
             * (1 + g.age_fuel_per_year * x.age_y) * o.fuel_mult,
    c_crew = case when x.wet then 0 else
               2 * x.f * (x.block_h * (t.pilot_inr_bh * g.pay_mult + x.crew * g.cabin_inr_bh) * o.hour_mult + o.allowance) end,
    c_maint = case when x.wet then 0 else
                2 * x.f * ((x.km::numeric / t.cruise_kmh + g.maint_fh_offset) * t.maint_usd_fh + t.maint_usd_cycle)
                * o.rate * (1 + o.age_k * x.age_y) * o.hour_mult * o.fx end,
    c_airport = 2 * x.f * ((t.landing_inr * case when x.intl then (1 + g.intl_airport_mult) / 2 else 1 end
                           + t.nav_inr_km * x.km) * g.charge_mult + g.handling_inr_pax * (x.seats_e * p.lf_e + x.seats_b * p.lf_b)),
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
             case when rw.pilots then 0 else t.pilot_fixed_inr_day * g.pay_mult end
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
               - (coalesce(fl.rent_usd, 0) + coalesce(rc.maint, 0) / ox.fx + coalesce(fl.int_usd, 0) + coalesce(fl.depr_usd, 0)) * game.wparam(p_world, 'fx_ref_inr_usd')),
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
                            case when rw.pilots then 0 else t.pilot_fixed_inr_day * g.pay_mult end
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
                                          + ap.fos * pf.pay_f_inr_day * pfin.pilot_pay)) * g.pay_mult as pay
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
end $function$;

-- Refusals name amounts in the world's money (0037).
CREATE OR REPLACE FUNCTION game.book(p_airline uuid, p_day integer, p_cash numeric, p_kind text, p_note text, p_pnl numeric DEFAULT 0, p_force boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_cash numeric;
begin
  update public.airline_finance set cash_inr = cash_inr + p_cash
   where airline_id = p_airline and (p_force or p_cash >= 0 or cash_inr >= -p_cash);
  if not found then
    select cash_inr into v_cash from public.airline_finance where airline_id = p_airline;
    raise exception 'Not enough cash: this needs % and you have % in hand. Borrow on Money or free up cash first.',
      game.money_text((select a.world_id from public.airlines a where a.id = p_airline), -p_cash), game.money_text((select a.world_id from public.airlines a where a.id = p_airline), v_cash);
  end if;
  insert into public.transactions (airline_id, game_day, kind, amount_inr, note, pnl_inr)
  values (p_airline, p_day, p_kind, p_cash, p_note, p_pnl);
end $function$;

-- The consultant is told the world's currency: internal amounts x to_local = the world's money (0037).
CREATE OR REPLACE FUNCTION public.consultant_data(p_report uuid, p_tool text, p_args jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      'world_rules', jsonb_build_object('currency', (select rg.currency from public.regions rg where rg.key = game.world_region(w.id)),
          'to_local', (select rg.price_level / rg.unit_inr from public.regions rg where rg.key = game.world_region(w.id)),
          'cancel_notice_days', game.wparam(w.id, 'cancel_notice_days'),
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
end $function$;

-- A world founded outside India takes its region's values (0037).
CREATE OR REPLACE FUNCTION public.create_world(p_name text, p_rules jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  perform game.apply_region(v_id);
  return jsonb_build_object('world_id', v_id, 'invite', v_code);
end $function$;

-- One home region per world (owner's rule, 26 Nov 2026): airlines are founded and open bases in the world's region only (0037).
CREATE OR REPLACE FUNCTION public.found_airline(p_invite text, p_name text, p_code text, p_base text, p_display_name text DEFAULT NULL::text, p_livery jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  if not found or rp.home is distinct from game.world_region(rw.id) then
    raise exception '%', case when game.world_region(rw.id) = 'india' then 'Bases can only be opened at Indian airports'
      else 'Bases can only be opened at airports in ' || (select rg.name from public.regions rg where rg.key = game.world_region(rw.id)) end;
  end if;
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
end $function$;

CREATE OR REPLACE FUNCTION public.open_base(p_airline uuid, p_iata text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  rw public.worlds%rowtype;
  rp public.airports%rowtype;
  v_day int;
  v_cost numeric := game.param('base_open_inr');
begin
  rw := game.actor(p_airline); v_day := rw.game_day + 1;
  select * into rp from public.airports where iata = upper(trim(p_iata));
  if not found or rp.home is distinct from game.world_region(rw.id) then
    raise exception '%', case when game.world_region(rw.id) = 'india' then 'Bases can only be opened at Indian airports'
      else 'Bases can only be opened at airports in ' || (select rg.name from public.regions rg where rg.key = game.world_region(rw.id)) end;
  end if;
  if rp.opens_day > v_day then raise exception '% airport has not opened yet', rp.city; end if;
  if exists (select 1 from public.bases where airline_id = p_airline and iata = rp.iata) then
    raise exception 'You already have a base at %', rp.iata;
  end if;
  perform game.book(p_airline, v_day, -v_cost, 'base', 'Opened a base at ' || rp.city, -v_cost);
  insert into public.bases (airline_id, iata, opened_day) values (p_airline, rp.iata, v_day);
end $function$;

-- The computer-run airlines are India's until each region has its own (step 3; 0037).
CREATE OR REPLACE FUNCTION game.bot_seed(p_world uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  rw public.worlds%rowtype;
  b record; n record; grp record;
  v_day int; v_al uuid; v_route uuid; v_ac uuid; v_built int; v_k int; v_seats numeric; v_count int := 0;
  v_scale numeric; v_min int := game.param('bot_min_weekly')::int;
  v_age numeric := game.param('bot_max_age_years');
  v_term int := game.param('lease_term_days')::int;
begin
  if game.param('bot_plan') = 0 then return game.bot_seed_v1(p_world); end if;
  select * into rw from public.worlds where id = p_world;
  if rw.bot_scale <= 0 or game.world_region(p_world) <> 'india' or exists (select 1 from public.airlines where world_id = p_world and is_ai) then return 0; end if;
  v_day := rw.game_day + 1;
  v_scale := rw.demand_scale * rw.bot_scale;
  for b in select * from public.bot_airlines order by sort loop
    drop table if exists pg_temp._seed;
    create temp table _seed on commit drop as
    select bn.origin, bn.dest, bn.type_id, bn.biz_rows, bn.biz_pitch, bn.econ_pitch,
           round(bn.aircraft * bn.weekly_trips * v_scale)::int as t,
           game.bot_fit(bn.type_id, bn.biz_rows, bn.biz_pitch, bn.econ_pitch, m.km) as fit
      from public.bot_network bn join public.markets m on m.a = least(bn.origin, bn.dest) and m.b = greatest(bn.origin, bn.dest)
     where bn.code = b.code;
    delete from pg_temp._seed where t < v_min;
    continue when not exists (select 1 from pg_temp._seed);
    v_al := null;
    insert into public.airlines (world_id, is_ai, name, code, created_day)
    values (p_world, true, b.name, b.code, v_day)
    on conflict do nothing returning id into v_al;
    continue when v_al is null;
    insert into public.airline_finance (airline_id, cash_inr, credit_limit_inr) values (v_al, 0, game.param('credit_limit_inr'));
    perform game.book(v_al, v_day, game.param('start_cash_inr'), 'equity', 'Founding equity');
    insert into public.bases (airline_id, iata, opened_day) select distinct v_al, origin, v_day from pg_temp._seed;
    for grp in select s.origin, s.type_id, s.biz_rows, coalesce(s.biz_pitch, 0) as bp, max(s.biz_pitch) as biz_pitch, s.econ_pitch,
                      sum(s.t::float8 / s.fit) as need
                 from pg_temp._seed s group by s.origin, s.type_id, s.biz_rows, coalesce(s.biz_pitch, 0), s.econ_pitch loop
      v_k := greatest(1, round(grp.need))::int;
      if grp.need > v_k then
        update pg_temp._seed s set t = floor(s.t * v_k / grp.need)
         where s.origin = grp.origin and s.type_id = grp.type_id and s.biz_rows = grp.biz_rows
           and coalesce(s.biz_pitch, 0) = grp.bp and s.econ_pitch = grp.econ_pitch;
      end if;
      for i in 1..v_k loop
        v_built := v_day - floor(random() * v_age * 364)::int;
        insert into public.aircraft (world_id, type_id, airline_id, reg, built_day, status, available_day, base_iata,
                                     biz_rows, biz_pitch, econ_pitch, seats_biz, seats_econ)
        select p_world, grp.type_id, v_al, game.next_reg(), v_built, 'active', v_day, grp.origin,
               grp.biz_rows, case when grp.biz_rows > 0 then coalesce(grp.biz_pitch, 44) end, grp.econ_pitch, l.seats_biz, l.seats_econ
          from public.layout_calc(grp.type_id, grp.biz_rows, grp.biz_pitch, grp.econ_pitch, rw.crew_rule) l
        returning id into v_ac;
        insert into public.aircraft_terms (aircraft_id, airline_id, holding, lease_usd_month, lease_end_day, deposit_inr, start_day)
        values (v_ac, v_al, 'lease', game.lease_rent_usd(p_world, grp.type_id, v_built, v_day),
                v_day + floor(random() * v_term)::int, 0, v_day);
        v_count := v_count + 1;
      end loop;
    end loop;
    v_seats := 0;
    for n in select s.*, l.seats from pg_temp._seed s
               cross join lateral public.layout_calc(s.type_id, s.biz_rows, s.biz_pitch, s.econ_pitch, rw.crew_rule) l
              where s.t >= v_min order by s.t desc, s.origin, s.dest loop
      v_route := public.open_route(v_al, n.origin, n.dest);
      insert into game.bot_plan (route_id, airline_id, trips, type_id, biz_rows, biz_pitch, econ_pitch, base, since_day)
      values (v_route, v_al, n.t, n.type_id, n.biz_rows, case when n.biz_rows > 0 then coalesce(n.biz_pitch, 44) end, n.econ_pitch,
              n.origin, v_day);
      v_seats := v_seats + n.t * n.seats * 2 / 7.0;
    end loop;
    insert into game.bot_start (airline_id, aircraft)
    values (v_al, (select count(*) from public.aircraft where airline_id = v_al));
    perform game.bot_pack(v_al);
    delete from game.bot_plan where airline_id = v_al and trips < 1;
    perform public.set_marketing(v_al, least(game.param('marketing_max_inr_day'), round(b.mkt_inr_pax * 0.85 * v_seats)));
  end loop;
  insert into public.news (world_id, game_day, kind, body)
  select p_world, v_day, 'world', 'Established airlines in this world: ' || string_agg(al.name, ', ' order by al.name) || '.'
    from public.airlines al where al.world_id = p_world and al.is_ai
  having count(*) > 0;
  return v_count;
end $function$;

-- Places keep the region's demand factor (0037).
CREATE OR REPLACE FUNCTION public.admin_set_places(p_world uuid, p_places integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  update public.worlds set max_airlines = p_places, demand_scale = round(p_places / 50.0 * coalesce((select rg.demand_mult from public.regions rg where rg.key = game.world_region(p_world)), 1), 3)
   where id = p_world;
  -- pilots for the new places join the market at once; aircraft follow through the quarterly lessor refill and delivery slots
  update public.pilot_market pm
     set captains = pm.captains + f.pool_c * greatest(0, p_places - w.max_airlines), fos = pm.fos + f.pool_f * greatest(0, p_places - w.max_airlines)
    from public.pilot_families f where pm.world_id = p_world and f.id = pm.family;
  if w.status <> 'setup' then
    insert into public.news (world_id, game_day, kind, body)
    values (p_world, w.game_day, 'world', format('The world grows to %s places: more travellers, aircraft to lease and order, pilots and airport capacity.', p_places));
  end if;
  return jsonb_build_object('places', p_places, 'demand_scale', round(p_places / 50.0, 3));
end $function$;

-- New aircraft are registered in the world's region's style (0037).
CREATE OR REPLACE FUNCTION game.add_wet(p_airline uuid, p_world uuid, p_type text, p_base text, p_day integer, p_arrive integer, p_starter boolean DEFAULT false, OUT o_id uuid, OUT o_reg text, OUT o_rate numeric)
 RETURNS record
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
  values (p_world, p_type, p_airline, game.next_reg(p_world), p_day - game.param('wet_age_years')::int * 364,
          case when p_arrive <= p_day then 'active' else 'delivering' end, p_arrive, p_base,
          s.biz_rows, s.biz_pitch, s.econ_pitch, l.seats_biz, l.seats_econ)
  returning id, reg into o_id, o_reg;
  insert into public.aircraft_terms (aircraft_id, airline_id, holding, wet_usd_bh, start_day, starter, wet_min_until)
  values (o_id, p_airline, 'wet', o_rate, p_arrive, p_starter,
          case when p_starter then null else p_arrive + game.param('wet_min_weeks')::int * 7 end);
end $function$;

CREATE OR REPLACE FUNCTION game.fill_pool(p_world uuid, p_type text, p_n integer, p_day integer)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_rule text;
  v_age numeric := game.param('pool_max_age_years');
  s record;
  l record;
begin
  select crew_rule into v_rule from public.worlds where id = p_world;
  for i in 1..p_n loop
    select * into s from game.std_layout(p_type, floor(random() * 3)::int);
    select * into l from public.layout_calc(p_type, s.biz_rows, s.biz_pitch, s.econ_pitch, v_rule);
    insert into public.aircraft (world_id, type_id, reg, built_day, status, biz_rows, biz_pitch, econ_pitch, seats_biz, seats_econ)
    values (p_world, p_type, game.next_reg(p_world), p_day - floor(random() * v_age * 364)::int, 'pool',
            s.biz_rows, s.biz_pitch, s.econ_pitch, l.seats_biz, l.seats_econ);
  end loop;
  return greatest(p_n, 0);
end $function$;

CREATE OR REPLACE FUNCTION public.order_aircraft(p_airline uuid, p_type text, p_base text, p_biz_rows integer, p_biz_pitch integer, p_econ_pitch integer, p_pay text DEFAULT 'cash'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  values (rw.id, p_type, p_airline, game.next_reg(rw.id), q.delivery_day, 'delivering', q.delivery_day, v_base, p_biz_rows,
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
end $function$;

revoke all on all functions in schema game from public, anon, authenticated;
