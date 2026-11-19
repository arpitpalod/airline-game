-- Migration 0018: revenue management (spec section 19). Flights go on sale six weeks before they fly and sell day by day:
-- each traveller type books on its own curve, each route has a ladder of fare levels that close as the day comes near,
-- economy sells Saver and Flexi, and each route is run by hand, to a target booking curve or by the optimiser.
-- Overbooking, no-shows and compensation for passengers who cannot board. Worlds with rm = false keep the daily demand
-- of section 4 unchanged (the checks written before this migration run in such worlds).

-- ---------- Game values (G) ----------
insert into public.game_params (key, num, note) values
('rm_horizon', 42, 'a flight goes on sale this many days before it flies'),
('rm_tau_biz', 6, 'booking curve: business travellers book on average this many days ahead (arrivals fall as exp(-days ahead / this))'),
('rm_tau_lei', 16, 'leisure travellers, the same'),
('rm_tau_bud', 24, 'travellers visiting friends and relatives and on a budget, the same'),
('rm_date_sd', 0.12, 'every route date gets its own demand swing, log-normal with this spread, fixed when it goes on sale'),
('rm_flex_val_biz', 0.25, 'what being able to change the ticket is worth to a business traveller, as a share of the reference fare'),
('rm_flex_val_lei', 0.04, 'the same for a leisure traveller'),
('rm_flex_val_bud', 0.02, 'the same for a budget or family-visit traveller'),
('rm_flex_mu', 0.15, 'how sharply travellers split between Saver and Flexi on the difference between what Flexi is worth to them and costs'),
('rm_flex_default', 0.15, 'Flexi price above Saver on a new route, as a share of the reference fare'),
('rm_noshow_biz', 0.06, 'share of business travellers on a Saver ticket who do not turn up (the fare is kept)'),
('rm_noshow_lei', 0.025, 'the same for leisure travellers'),
('rm_noshow_bud', 0.025, 'the same for budget and family-visit travellers'),
('rm_noshow_flex', 0.06, 'Flexi and business-cabin ticket holders miss their flight this much more often, and get their fare back'),
('rm_deny_mult', 2, 'a passenger who cannot board gets the fare back and this many times the fare in compensation'),
('rm_deny_cap_inr', 10000, 'compensation is at most this much a passenger'),
('rm_deny_brand_k', 40, 'brand target falls by this x the share of passengers who could not board an overbooked flight'),
('rm_offload_days', 14, 'cutting seats on a flight more than this many days away refunds the passengers who no longer fit, with no compensation'),
('rm_curve_band', 0.08, 'booking-curve mode moves the fare when bookings are this far ahead of or behind the target curve...'),
('rm_curve_seats', 0.03, '...and at least this share of the seats, so the first few bookings of a flight do not move it'),
('rm_ob_max', 0.15, 'the most a route may overbook, as a share of its seats'),
('rm_mult_min', 0.3, 'cheapest fare level allowed, as a multiple of the route''s base fare'),
('rm_mult_max', 4, 'dearest fare level allowed, the same'),
('rm_city_prob', 0.03, 'chance a day that a city announces an event (a summit, a final, a festival) that brings more travellers for a few days'),
('rm_log_days', 91, 'flown departures are kept this many days'),
-- a new route's selling settings (each route's own copy can then be changed)
('rm_target_lf', 0.85, 'new route: load to aim for'),
('rm_overbook', 0.02, 'new route: overbooking, share of seats'),
('rm_e_mult_1', 0.75, 'new route: economy fare level 1 as a multiple of the base fare'),
('rm_e_mult_2', 0.85, 'level 2'), ('rm_e_mult_3', 0.95, 'level 3'), ('rm_e_mult_4', 1.05, 'level 4'),
('rm_e_mult_5', 1.15, 'level 5'), ('rm_e_mult_6', 1.30, 'level 6'),
('rm_e_close_1', 21, 'new route: economy level 1 stops selling this many days before the flight'),
('rm_e_close_2', 14, 'level 2'), ('rm_e_close_3', 7, 'level 3'), ('rm_e_close_4', 2, 'level 4'), ('rm_e_close_5', 0, 'level 5 (level 6 sells to the end)'),
('rm_e_limit_1', 0.20, 'new route, manual mode: share of seats that may sell at level 1'),
('rm_e_limit_2', 0.40, 'at level 2 or cheaper'), ('rm_e_limit_3', 0.60, 'at level 3 or cheaper'), ('rm_e_limit_4', 0.80, 'at level 4 or cheaper'),
('rm_e_limit_5', 0.95, 'at level 5 or cheaper'),
('rm_b_mult_1', 0.85, 'new route: business fare level 1 as a multiple of the business base fare'), ('rm_b_mult_2', 1, 'level 2'), ('rm_b_mult_3', 1.20, 'level 3'),
('rm_b_close_1', 7, 'new route: business level 1 stops selling this many days before the flight'), ('rm_b_close_2', 2, 'level 2'),
('rm_b_limit_1', 0.40, 'new route, manual mode: share of business seats at level 1'), ('rm_b_limit_2', 0.80, 'at level 2 or cheaper')
on conflict (key) do update set num = excluded.num, note = excluded.note;

-- Demand by day of the week and traveller type (G). Game day 1 is a Monday. Each column averages 1.
create table public.rm_weekday (
  dow int primary key check (dow between 0 and 6),   -- 0 Monday ... 6 Sunday
  biz numeric not null, lei numeric not null, bud numeric not null
);
insert into public.rm_weekday values
(0, 1.20, 0.85, 0.95), (1, 1.10, 0.85, 0.90), (2, 1.05, 0.90, 0.90), (3, 1.10, 0.95, 0.95),
(4, 1.15, 1.20, 1.10), (5, 0.60, 1.20, 1.10), (6, 0.80, 1.05, 1.10);

-- Festivals and holidays (G), on top of the monthly seasons. Day of the year 0 is 1 January; a game year has 364 days,
-- so a month is 30.33 days. A range that ends before it starts runs over the new year.
create table public.rm_festivals (
  id text primary key, name text not null,
  from_doy int not null check (from_doy between 0 and 363), to_doy int not null check (to_doy between 0 and 363),
  scope text not null check (scope in ('all', 'domestic', 'international')),
  biz numeric not null, lei numeric not null, bud numeric not null
);
insert into public.rm_festivals values
('republic', 'Republic Day weekend', 23, 26, 'domestic', 0.8, 1.25, 1.10),
('holi', 'Holi', 69, 73, 'domestic', 0.8, 1.20, 1.35),
('eid', 'Eid holidays', 134, 140, 'international', 0.8, 1.20, 1.50),
('independence', 'Independence Day weekend', 224, 227, 'domestic', 0.8, 1.30, 1.10),
('puja', 'Durga Puja and Dussehra', 280, 285, 'domestic', 0.7, 1.20, 1.35),
('diwali', 'Diwali', 297, 309, 'all', 0.6, 1.30, 1.60),
('yearend', 'Christmas and New Year', 352, 2, 'all', 0.6, 1.50, 1.20);

alter table public.rm_weekday enable row level security;
alter table public.rm_festivals enable row level security;
grant select on public.rm_weekday, public.rm_festivals to authenticated;
create policy read_all on public.rm_weekday for select to authenticated using (true);
create policy read_all on public.rm_festivals for select to authenticated using (true);

alter table public.worlds add column rm boolean not null default true;

-- How each route sells its seats (private). Fare levels are multiples of the route's base fare (routes.fare_econ and
-- fare_biz), so moving the base fare moves the whole ladder.
create table public.route_rm (
  route_id   uuid primary key references public.routes on delete cascade,
  airline_id uuid not null references public.airlines on delete cascade,
  mode       text not null default 'curve' check (mode in ('manual', 'curve', 'optimise')),
  e_mult     numeric[] not null default '{0.75,0.85,0.95,1.05,1.15,1.30}',   -- economy fare levels (new routes: game values rm_e_mult_*)
  e_close    int[] not null default '{21,14,7,2,0,0}',     -- each level sells until this many days before the flight
  e_limit    numeric[] not null default '{0.20,0.40,0.60,0.80,0.95,1}',  -- manual: share of seats that may sell at this level or cheaper
  b_mult     numeric[] not null default '{0.85,1,1.20}',    -- business-cabin levels
  b_close    int[] not null default '{7,2,0}',
  b_limit    numeric[] not null default '{0.40,0.80,1}',
  flex       numeric default 0.15,     -- Flexi price above Saver, share of the reference fare; null: no Flexi
  target_lf  numeric not null default 0.85 check (target_lf between 0.5 and 1.1),   -- booking-curve mode: load to aim for
  pace       int not null default 1 check (pace between 1 and 3),                   -- booking-curve mode: levels moved a day
  outlook    numeric not null default 1 check (outlook between 0.7 and 1.3),        -- optimiser: its demand forecast x this
  overbook   numeric not null default 0.02 check (overbook >= 0)
);
create index route_rm_airline_idx on public.route_rm (airline_id);

-- One row per route per departure day on sale (private). Figures are each way, like the rest of the engine; seats and
-- bookings are averages over the week's flights, so they can be fractions.
create table public.departures (
  route_id   uuid not null references public.routes on delete cascade,
  dep_day    int not null,
  world_id   uuid not null references public.worlds on delete cascade,
  airline_id uuid not null references public.airlines on delete cascade,
  opened     int not null,                     -- game day it went on sale
  k          float8 not null default 1,       -- this date's demand swing
  cap_e      float8 not null default 0, cap_b float8 not null default 0,   -- seats as scheduled now
  sold_e     float8[] not null default '{0,0,0,0,0,0}',   -- economy seats sold at each level
  sold_b     float8[] not null default '{0,0,0}',
  sav        float8[] not null default '{0,0,0}',   -- economy Saver bookings by traveller type: business, leisure, budget/VFR
  flx        float8[] not null default '{0,0,0}',   -- economy Flexi bookings, the same
  bkb        float8 not null default 0,             -- business-cabin bookings (all business travellers)
  rev_sav    float8 not null default 0, rev_flx float8 not null default 0, rev_b float8 not null default 0,
  lvl_e      int not null default 1, lvl_b int not null default 1,   -- level on sale now; 0 = sold out or no seats
  fare_e     int, fare_b int,                                        -- fares on sale now (Saver)
  turned_e   float8 not null default 0, turned_b float8 not null default 0,   -- travellers turned away: no seats left (spill)
  min_e      int not null default 1 check (min_e between 1 and 6),   -- cheapest level allowed, set by hand for this date
  min_b      int not null default 1 check (min_b between 1 and 3),
  curve      float8[] not null default '{}',     -- bookings (both cabins) by the end of each day on sale: element n + 1 is n days before the flight
  pot        float8[] not null default '{0,0,0}',  -- potential travellers for the whole date by type (for the what-if)
  mkt_s      float8[] not null default '{0,0,0}',  -- the market's sum of exp(U / lambda) by type at the last booking day
  own_x      float8[] not null default '{0,0,0,0}', -- this route's exp(U / lambda): economy by type, then the business cabin
  primary key (route_id, dep_day)
);
create index departures_world_day_idx on public.departures (world_id, dep_day);

create table public.departure_log (    -- private: each departure once flown, kept rm_log_days
  route_id uuid not null references public.routes on delete cascade,
  dep_day  int not null,
  world_id uuid not null references public.worlds on delete cascade,
  airline_id uuid not null references public.airlines on delete cascade,
  opened int not null,
  cap_e float8 not null, cap_b float8 not null,
  sold_e float8[] not null, sold_b float8[] not null, sav float8[] not null, flx float8[] not null, bkb float8 not null,
  pax_e float8 not null, pax_b float8 not null, noshow float8 not null,
  denied float8 not null,      -- could not board an overbooked flight (or one cut at short notice): compensated
  cancelled float8 not null default 0,   -- their flight was cancelled on the day (grounding, no crew): refunded
  turned float8 not null, revenue float8 not null, compensation float8 not null,
  curve float8[] not null,
  primary key (route_id, dep_day)
);
create index departure_log_world_day_idx on public.departure_log (world_id, dep_day);

alter table public.route_rm enable row level security;
alter table public.departures enable row level security;
alter table public.departure_log enable row level security;
grant select on public.route_rm, public.departures, public.departure_log to authenticated;
create policy read_own on public.route_rm for select to authenticated
  using (airline_id in (select id from public.airlines where user_id = (select auth.uid())));
create policy read_own on public.departures for select to authenticated
  using (airline_id in (select id from public.airlines where user_id = (select auth.uid())));
create policy read_own on public.departure_log for select to authenticated
  using (airline_id in (select id from public.airlines where user_id = (select auth.uid())));

alter table public.route_daily add column noshow int not null default 0, add column denied int not null default 0;
alter table public.airline_daily add column denied int not null default 0;

-- Every route gets selling settings when it is first opened; existing routes get them now.
-- Every route gets selling settings when it is first opened, from the game values above; existing routes get them now.
create or replace function game.param_list(p_prefix text, p_n int) returns numeric[]
language sql stable set search_path = '' as $$
  select array_agg(game.param(p_prefix || i) order by i) from generate_series(1, p_n) i
$$;
create or replace function game.route_rm_add(p_route uuid, p_airline uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.route_rm (route_id, airline_id, flex, target_lf, overbook, e_mult, e_close, e_limit, b_mult, b_close, b_limit)
  values (p_route, p_airline, game.param('rm_flex_default'), game.param('rm_target_lf'), game.param('rm_overbook'),
          game.param_list('rm_e_mult_', 6), game.param_list('rm_e_close_', 5)::int[] || 0, game.param_list('rm_e_limit_', 5) || 1::numeric,
          game.param_list('rm_b_mult_', 3), game.param_list('rm_b_close_', 2)::int[] || 0, game.param_list('rm_b_limit_', 2) || 1::numeric)
  on conflict (route_id) do nothing
$$;
create or replace function game.route_rm_new() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform game.route_rm_add(new.id, new.airline_id);
  return new;
end $$;
create trigger routes_rm_new after insert on public.routes for each row execute function game.route_rm_new();
select game.route_rm_add(id, airline_id) from public.routes;

-- ---------- Helpers ----------

-- A standard normal number fixed by a text key, so every airline on a market sees the same swing for a date.
create or replace function game.hash_normal(p_key text) returns float8
language sql immutable set search_path = '' as $$
  select sqrt(-2 * ln(((hashtextextended(p_key, 1) & 2147483647) + 0.5) / 2147483648.0))
         * cos(2 * pi() * ((hashtextextended(p_key, 2) & 2147483647) + 0.5) / 2147483648.0)
$$;

-- Booking curve of a traveller type with mean lead tau, over a sale of h days. Day n is n days before the flight (0 = the day).
-- rm_arr: share who book on day n; rm_left: share who book on day n or later (today included); before = 1 - left.
create or replace function game.rm_arr(p_n int, p_tau float8, p_h int) returns float8
language sql immutable as $$
  select exp(-p_n / p_tau) * (1 - exp(-1 / p_tau)) / (1 - exp(-p_h / p_tau))
$$;
create or replace function game.rm_left(p_n int, p_tau float8, p_h int) returns float8
language sql immutable as $$
  select (1 - exp(-(p_n + 1) / p_tau)) / (1 - exp(-p_h / p_tau))
$$;

-- Day of the calendar year (0 = 1 January) of a game day, matching the monthly seasons (season_start_month).
create or replace function game.rm_doy(p_day int) returns int
language sql stable set search_path = '' as $$
  select ((game.param('season_start_month')::int - 1) * 91 / 3 + (p_day - 1)) % 364
$$;

-- exp(U / lambda) for a utility and a price term. These small helpers have no search_path setting so that the planner
-- inlines them (a function with a SET clause is never inlined); they use only built-in functions.
create or replace function game.rm_x(p_u float8, p_lambda float8) returns float8
language sql immutable as $$
  select exp(least(600, p_u / p_lambda))
$$;

-- nested logit share factor (game.nest_k) in double precision
create or replace function game.rm_k(p_s float8, p_lambda float8) returns float8
language sql immutable as $$
  select case when p_s > 0 then power(p_s, p_lambda - 1) / (1 + power(p_s, p_lambda)) else 0 end
$$;

create or replace function game.arr_mul(p_a float8[], p_k float8) returns float8[]
language sql immutable set search_path = '' as $$
  select coalesce(array_agg(v * p_k order by i), p_a) from unnest(p_a) with ordinality u(v, i)
$$;

-- A city announces an event a few weeks ahead: more business or leisure travellers to and from it for a few days.
create or replace function game.rm_city_events(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  v_iata text; v_city text; v_seg text; v_mult numeric; v_start int; v_len int; v_name text;
begin
  if random() >= game.param('rm_city_prob') then return; end if;
  select iata, city into v_iata, v_city from public.airports where is_india and pax_m >= 5 order by random() limit 1;
  if v_iata is null then return; end if;
  v_seg := case when random() < 0.5 then 'biz' else 'lei' end;
  v_name := case when v_seg = 'biz' then (array['a trade fair', 'a technology summit', 'an investors'' conference', 'a medical congress'])[1 + floor(random() * 4)::int]
                 else (array['a cricket final', 'a music festival', 'a big wedding weekend', 'a film festival'])[1 + floor(random() * 4)::int] end;
  v_mult := round((1.3 + 0.5 * random())::numeric, 2);
  v_start := p_day + 14 + floor(random() * 22)::int;
  v_len := 2 + floor(random() * 3)::int;
  insert into public.events (world_id, kind, announced_day, starts_day, ends_day, payload)
  values (p_world, 'city_demand', p_day, v_start, v_start + v_len - 1,
          jsonb_build_object('iata', v_iata, 'seg', v_seg, 'mult', v_mult, 'name', v_name));
  insert into public.news (world_id, game_day, kind, body)
  values (p_world, p_day, 'city_demand',
          format('%s hosts %s on days %s to %s: %s%% more %s travellers to and from %s on those days.', v_city, v_name,
                 v_start, v_start + v_len - 1, round((v_mult - 1) * 100), case when v_seg = 'biz' then 'business' else 'leisure' end, v_city));
end $$;

-- ---------- Booking ----------
-- One day of bookings in world p_world on game day p_day, for departures from p_first to the end of the sale window.
-- p_routes, when given, books only those routes (their rivals on the same markets count in the choice but book
-- nothing): it fills the first weeks of a route going on sale for the first time, as if it had been on sale already,
-- p_span days at a time (the bookings of days p_day to p_day + p_span - 1, stopping before p_first).
-- Needs pg_temp._rot (the day's rotations) from game.day_ops.
create or replace function game.rm_book(p_world uuid, p_day int, p_first int, p_routes uuid[] default null, p_span int default 1) returns void
language plpgsql set search_path = '' set jit = off as $$
declare
  rw public.worlds%rowtype;
  g record;
  v_h int := game.param('rm_horizon')::int;
  v_last int;
begin
  select * into rw from public.worlds where id = p_world;
  select * into g from jsonb_to_record((select jsonb_object_agg(key, num) from public.game_params)) as x(
    seg_biz_a numeric, seg_biz_price numeric, seg_biz_freq numeric, seg_biz_comfort numeric, seg_biz_brand numeric,
    seg_lei_a numeric, seg_lei_price numeric, seg_lei_freq numeric, seg_lei_comfort numeric, seg_lei_brand numeric,
    seg_bud_a numeric, seg_bud_price numeric, seg_bud_freq numeric, seg_bud_comfort numeric, seg_bud_brand numeric,
    biz_fare_mult numeric, nest_lambda numeric, seg_biz_cabin_a numeric, growth_year numeric, season_start_month numeric,
    rm_tau_biz numeric, rm_tau_lei numeric, rm_tau_bud numeric, rm_date_sd numeric,
    rm_flex_val_biz numeric, rm_flex_val_lei numeric, rm_flex_val_bud numeric, rm_flex_mu numeric,
    rm_offload_days numeric, rm_curve_band numeric, rm_curve_seats numeric);
  v_last := p_day + v_h - 1;

  create temp table if not exists _rs (     -- each scheduled route: what it offers
    route_id uuid primary key, airline_id uuid, a text, b text, intl boolean, ref float8,
    n_biz float8, n_lei float8, n_bud float8,
    f float8, f_b float8, cap_e float8, cap_b float8, comf_e float8, comf_b float8, block_h float8, brand float8,
    base_e float8, base_b float8, ad_b float8, ad_l float8, ad_u float8
  ) on commit drop;
  create temp table if not exists _bk (     -- one row per departure on sale on the markets being booked
    route_id uuid, dep_day int, n int, m_lo int, a text, b text, apply boolean, ref float8, base_e float8, base_b float8,
    mode text, flex float8, target_lf float8, pace int, outlook float8,
    e_mult float8[], e_close int[], e_limit float8[], b_mult float8[], b_close int[], b_limit float8[],
    cap_e float8, cap_b float8, book_e float8, book_b float8, sold_e float8[], sold_b float8[], te float8, tb float8,
    lvl_e int, lvl_b int, lo_e int, lo_b int, min_e int, min_b int,
    pot_b float8, pot_l float8, pot_u float8,     -- potential travellers for the date
    nb float8, nl float8, nu float8,              -- of whom book today
    rb float8, rl float8, ru float8,              -- of whom are still to book, today included
    cur_e float8, cur_b float8,                    -- target curve: share of final bookings expected before today
    cb float8, cl float8, cu float8, cbb float8, -- utility without the price term: economy by type, business cabin
    gb float8, gl float8, gu float8,              -- Flexi: gain over Saver in utility for those who prefer it (>= 0)
    qb float8, ql float8, qu float8,              -- share of economy bookings by type that take Flexi
    pe float8, pb float8,                          -- Saver fares on sale
    xb float8, xl float8, xu float8, xbb float8, -- exp(U / lambda): economy by type, business cabin
    sb float8, sl float8, su float8,              -- market sums
    dbe float8, dle float8, due float8, de float8, db float8, we float8, wb float8,   -- demand today: economy by type, total, business cabin, would-be
    be float8, bb float8, room float8, pavg float8 -- booked today: economy, business cabin; manual level room; average economy fare
  ) on commit drop;
  truncate pg_temp._rs, pg_temp._bk;

  insert into pg_temp._rs
  with ax as materialized (
    select q.airline_id, t.d_biz, t.d_lei, t.d_bud
      from (select distinct airline_id from pg_temp._rot) q cross join lateral game.anc_terms(q.airline_id) t),
  s as (
    select route_id, airline_id, a, b, sum(f) as f, coalesce(sum(f) filter (where seats_b > 0), 0) as f_b,
           sum(f * seats_e) as cap_e, sum(f * seats_b) as cap_b,
           sum(f * seats_e * comf_e) / nullif(sum(f * seats_e), 0) as comf_e,
           sum(f * seats_b * comf_b) / nullif(sum(f * seats_b), 0) as comf_b,
           sum(f * block_h) / nullif(sum(f), 0) as block_h
      from pg_temp._rot group by route_id, airline_id, a, b)
  select s.route_id, s.airline_id, s.a, s.b, m.intl, m.ref_fare, m.n_biz, m.n_lei, m.n_bud,
         s.f, s.f_b, s.cap_e, s.cap_b, coalesce(s.comf_e, 0), coalesce(s.comf_b, 0), s.block_h, al.brand,
         r.fare_econ, coalesce(r.fare_biz, round(m.ref_fare * g.biz_fare_mult)), ax.d_biz, ax.d_lei, ax.d_bud
    from s
    join public.routes r on r.id = s.route_id
    join public.airlines al on al.id = s.airline_id
    join public.markets m on m.a = s.a and m.b = s.b
    join ax on ax.airline_id = s.airline_id
   where s.f > 0
     and (p_routes is null or (s.a, s.b) in (select least(r2.origin, r2.dest), greatest(r2.origin, r2.dest)
                                               from public.routes r2 where r2.id = any(p_routes)));

  -- every scheduled route is on sale for every day of the window; seats follow the schedule as it is now
  insert into public.departures (route_id, dep_day, world_id, airline_id, opened, k, cap_e, cap_b, lvl_e, lvl_b, curve)
  select s.route_id, t, p_world, s.airline_id, p_day,
         exp(g.rm_date_sd * game.hash_normal(p_world::text || s.a || s.b || t::text) - g.rm_date_sd * g.rm_date_sd / 2),
         s.cap_e, s.cap_b, 1, 1, array_fill(null::float8, array[v_h])
    from pg_temp._rs s cross join generate_series(greatest(p_day, p_first), v_last) t
   where p_routes is null or s.route_id = any(p_routes)
  on conflict (route_id, dep_day) do update set cap_e = excluded.cap_e, cap_b = excluded.cap_b
   where public.departures.cap_e is distinct from excluded.cap_e or public.departures.cap_b is distinct from excluded.cap_b;

  if p_routes is null then
    -- routes no longer flown keep their bookings but have no seats
    update public.departures d set cap_e = 0, cap_b = 0
     where d.world_id = p_world and d.dep_day >= p_day and (d.cap_e > 0 or d.cap_b > 0)
       and not exists (select 1 from pg_temp._rs s where s.route_id = d.route_id);
    -- seats cut on a flight far enough away: the passengers who no longer fit are refunded, with no compensation
    update public.departures d
       set sold_e = game.arr_mul(d.sold_e, z.ke), sav = game.arr_mul(d.sav, z.ke), flx = game.arr_mul(d.flx, z.ke),
           rev_sav = d.rev_sav * z.ke, rev_flx = d.rev_flx * z.ke,
           sold_b = game.arr_mul(d.sold_b, z.kb), bkb = d.bkb * z.kb, rev_b = d.rev_b * z.kb
      from (select x.route_id, x.dep_day,
                   least(1, x.cap_e * (1 + rm.overbook) / nullif(x.te, 0)) as ke,
                   least(1, x.cap_b * (1 + rm.overbook) / nullif(x.bkb, 0)) as kb
              from (select d2.route_id, d2.dep_day, d2.cap_e, d2.cap_b, d2.bkb,
                           (select sum(v) from unnest(d2.sold_e) v) as te
                      from public.departures d2
                     where d2.world_id = p_world and d2.dep_day > p_day + g.rm_offload_days) x
              join public.route_rm rm on rm.route_id = x.route_id
             where x.te > x.cap_e * (1 + rm.overbook) + 1e-6 or x.bkb > x.cap_b * (1 + rm.overbook) + 1e-6) z
     where d.route_id = z.route_id and d.dep_day = z.dep_day;
  end if;

  -- the departures being booked today, with who wants to fly that day and who books today
  insert into pg_temp._bk (route_id, dep_day, n, m_lo, a, b, apply, ref, base_e, base_b, mode, flex, target_lf, pace, outlook,
                           e_mult, e_close, e_limit, b_mult, b_close, b_limit, cap_e, cap_b, book_e, book_b, sold_e, sold_b,
                           te, tb, lvl_e, lvl_b, min_e, min_b, pot_b, pot_l, pot_u, nb, nl, nu, rb, rl, ru, cur_e, cur_b,
                           cb, cl, cu, cbb, gb, gl, gu, qb, ql, qu)
  with cal as materialized (
    select t, game.rm_doy(t) as doy,
           sf.biz * wd.biz as fb, sf.lei * wd.lei as fl, sf.bud * wd.bud as fu,
           power(1 + g.growth_year, (t - 1) / 364.0) * rw.demand_scale as grow
      from generate_series(greatest(p_day, p_first), v_last) t
      join public.rm_weekday wd on wd.dow = (t - 1) % 7
      join public.season_factors sf
        on sf.month = ((g.season_start_month::int - 1 + (((t - 1) % 364) * 12) / 364) % 12) + 1),
  fest as materialized (   -- festivals by date, for domestic and international markets
    select c.t, i.intl, coalesce(exp(sum(ln(e.biz))), 1) as eb, coalesce(exp(sum(ln(e.lei))), 1) as el,
           coalesce(exp(sum(ln(e.bud))), 1) as eu
      from cal c cross join (values (false), (true)) i(intl)
      left join public.rm_festivals e
        on (e.scope = 'all' or (e.scope = 'international') = i.intl)
       and case when e.from_doy <= e.to_doy then c.doy between e.from_doy and e.to_doy
                else c.doy >= e.from_doy or c.doy <= e.to_doy end
     group by c.t, i.intl),
  city as materialized (   -- events announced by cities
    select c.t, ev.payload ->> 'iata' as iata,
           exp(sum(ln(case when ev.payload ->> 'seg' = 'biz' then (ev.payload ->> 'mult')::numeric else 1 end))) as eb,
           exp(sum(ln(case when ev.payload ->> 'seg' = 'lei' then (ev.payload ->> 'mult')::numeric else 1 end))) as el
      from cal c join public.events ev
        on ev.world_id = p_world and ev.kind = 'city_demand' and c.t between ev.starts_day and ev.ends_day
     group by c.t, ev.payload ->> 'iata')
  select d.route_id, d.dep_day, d.dep_day - p_day, d.dep_day - least(p_day + p_span - 1, greatest(p_day, p_first - 1)),
         s.a, s.b, (p_routes is null or d.route_id = any(p_routes)),
         s.ref, s.base_e, s.base_b, rm.mode, rm.flex, rm.target_lf, rm.pace, rm.outlook,
         rm.e_mult, rm.e_close, rm.e_limit, rm.b_mult, rm.b_close, rm.b_limit,
         d.cap_e, d.cap_b, d.cap_e * (1 + rm.overbook), d.cap_b * (1 + rm.overbook), d.sold_e, d.sold_b,
         (select sum(v) from unnest(d.sold_e) v), (select sum(v) from unnest(d.sold_b) v),
         d.lvl_e, d.lvl_b, d.min_e, d.min_b,
         p.b, p.l, p.u,
         -- who book in this pass: today, or (filling a new route) the days of the span
         p.b * (game.rm_left(d.dep_day - p_day, g.rm_tau_biz, v_h) - game.rm_left(o.m - 1, g.rm_tau_biz, v_h)),
         p.l * (game.rm_left(d.dep_day - p_day, g.rm_tau_lei, v_h) - game.rm_left(o.m - 1, g.rm_tau_lei, v_h)),
         p.u * (game.rm_left(d.dep_day - p_day, g.rm_tau_bud, v_h) - game.rm_left(o.m - 1, g.rm_tau_bud, v_h)),
         p.b * game.rm_left(d.dep_day - p_day, g.rm_tau_biz, v_h), p.l * game.rm_left(d.dep_day - p_day, g.rm_tau_lei, v_h),
         p.u * game.rm_left(d.dep_day - p_day, g.rm_tau_bud, v_h),
         -- the target curve weighs each type's booking curve by its share of the market that day (seasons and weekday only)
         1 - (s.n_biz * c.fb * game.rm_left(d.dep_day - p_day, g.rm_tau_biz, v_h)
              + s.n_lei * c.fl * game.rm_left(d.dep_day - p_day, g.rm_tau_lei, v_h)
              + s.n_bud * c.fu * game.rm_left(d.dep_day - p_day, g.rm_tau_bud, v_h))
             / nullif(s.n_biz * c.fb + s.n_lei * c.fl + s.n_bud * c.fu, 0),
         1 - game.rm_left(d.dep_day - p_day, g.rm_tau_biz, v_h),
         g.seg_biz_a + g.seg_biz_freq * ln(1 + s.f) + g.seg_biz_comfort * s.comf_e * sqrt(s.block_h) + g.seg_biz_brand * (s.brand - 50) / 50,
         g.seg_lei_a + g.seg_lei_freq * ln(1 + s.f) + g.seg_lei_comfort * s.comf_e * sqrt(s.block_h) + g.seg_lei_brand * (s.brand - 50) / 50,
         g.seg_bud_a + g.seg_bud_freq * ln(1 + s.f) + g.seg_bud_comfort * s.comf_e * sqrt(s.block_h) + g.seg_bud_brand * (s.brand - 50) / 50,
         g.seg_biz_a + g.seg_biz_cabin_a + g.seg_biz_freq * ln(1 + s.f_b) + g.seg_biz_comfort * s.comf_b * sqrt(s.block_h)
           + g.seg_biz_brand * (s.brand - 50) / 50,
         coalesce(greatest(0, g.seg_biz_price * (g.rm_flex_val_biz - rm.flex)), 0),
         coalesce(greatest(0, g.seg_lei_price * (g.rm_flex_val_lei - rm.flex)), 0),
         coalesce(greatest(0, g.seg_bud_price * (g.rm_flex_val_bud - rm.flex)), 0),
         coalesce(1 / (1 + exp(-(g.seg_biz_price * (g.rm_flex_val_biz - rm.flex) / g.rm_flex_mu)::float8)), 0),
         coalesce(1 / (1 + exp(-(g.seg_lei_price * (g.rm_flex_val_lei - rm.flex) / g.rm_flex_mu)::float8)), 0),
         coalesce(1 / (1 + exp(-(g.seg_bud_price * (g.rm_flex_val_bud - rm.flex) / g.rm_flex_mu)::float8)), 0)
    from public.departures d
    join pg_temp._rs s on s.route_id = d.route_id
    join public.route_rm rm on rm.route_id = d.route_id
    join cal c on c.t = d.dep_day
    join fest fe on fe.t = d.dep_day and fe.intl = s.intl
    left join city ca on ca.t = d.dep_day and ca.iata = s.a
    left join city cb2 on cb2.t = d.dep_day and cb2.iata = s.b
    cross join lateral (select d.dep_day - least(p_day + p_span - 1, greatest(p_day, p_first - 1)) as m) o
    cross join lateral (select s.n_biz * c.fb * fe.eb * coalesce(ca.eb, 1) * coalesce(cb2.eb, 1) * c.grow * d.k as b,
                               s.n_lei * c.fl * fe.el * coalesce(ca.el, 1) * coalesce(cb2.el, 1) * c.grow * d.k as l,
                               s.n_bud * c.fu * fe.eu * c.grow * d.k as u) p
   where d.world_id = p_world and d.dep_day between greatest(p_day, p_first) and v_last;

  -- Which level is on sale. Fences first: a level sells only until its day; then the date's own floor.
  update pg_temp._bk set
    lo_e = greatest(min_e, coalesce((select min(i) from generate_subscripts(e_close, 1) i where e_close[i] <= n), 6)),
    lo_b = greatest(min_b, coalesce((select min(i) from generate_subscripts(b_close, 1) i where b_close[i] <= n), 3));
  -- Manual: the cheapest open level whose seat limit is not reached. Booking curve: one step (pace) dearer when bookings
  -- run ahead of the target curve, one step cheaper when behind. Optimiser: decided below. Sold out: 0.
  update pg_temp._bk set
    lvl_e = case when cap_e <= 0 or te >= book_e - 1e-6 then 0
                 when mode = 'manual' then coalesce((select min(i) from generate_series(lo_e, 6) i
                                                      where (select sum(v) from unnest(sold_e[1:i]) v) < e_limit[i] * book_e - 1e-6), 6)
                 when mode = 'curve' then least(6, greatest(lo_e,
                        case when lvl_e = 0 then 6
                             when te > target_lf * cap_e * cur_e + greatest(g.rm_curve_band * target_lf * cap_e * cur_e, g.rm_curve_seats * cap_e) then lvl_e + pace
                             when te < target_lf * cap_e * cur_e - greatest(g.rm_curve_band * target_lf * cap_e * cur_e, g.rm_curve_seats * cap_e) then lvl_e - pace
                             else lvl_e end))
                 else greatest(lo_e, least(6, case when lvl_e = 0 then 6 else lvl_e end)) end,
    lvl_b = case when cap_b <= 0 or tb >= book_b - 1e-6 then 0
                 when mode = 'manual' then coalesce((select min(i) from generate_series(lo_b, 3) i
                                                      where (select sum(v) from unnest(sold_b[1:i]) v) < b_limit[i] * book_b - 1e-6), 3)
                 when mode = 'curve' then least(3, greatest(lo_b,
                        case when lvl_b = 0 then 3
                             when tb > target_lf * cap_b * cur_b + greatest(g.rm_curve_band * target_lf * cap_b * cur_b, g.rm_curve_seats * cap_b) then lvl_b + pace
                             when tb < target_lf * cap_b * cur_b - greatest(g.rm_curve_band * target_lf * cap_b * cur_b, g.rm_curve_seats * cap_b) then lvl_b - pace
                             else lvl_b end))
                 else greatest(lo_b, least(3, case when lvl_b = 0 then 3 else lvl_b end)) end;

  update pg_temp._bk set pe = case when lvl_e > 0 then round(base_e * e_mult[lvl_e] / 10) * 10 end,
                         pb = case when lvl_b > 0 then round(base_b * b_mult[lvl_b] / 10) * 10 end;
  -- exp(U / lambda) at the fares on sale; extras change the price travellers see (section 14.6)
  update pg_temp._bk k set
    xb  = case when k.lvl_e > 0 then game.rm_x(k.cb - g.seg_biz_price * (k.pe / k.ref + s.ad_b) + k.gb, g.nest_lambda) else 0 end,
    xl  = case when k.lvl_e > 0 then game.rm_x(k.cl - g.seg_lei_price * (k.pe / k.ref + s.ad_l) + k.gl, g.nest_lambda) else 0 end,
    xu  = case when k.lvl_e > 0 then game.rm_x(k.cu - g.seg_bud_price * (k.pe / k.ref + s.ad_u) + k.gu, g.nest_lambda) else 0 end,
    xbb = case when k.lvl_b > 0 then game.rm_x(k.cbb - g.seg_biz_price * k.pb / (k.ref * g.biz_fare_mult), g.nest_lambda) else 0 end
    from pg_temp._rs s where s.route_id = k.route_id;
  update pg_temp._bk k set sb = z.sb, sl = z.sl, su = z.su
    from (select route_id, dep_day, sum(xb + xbb) over w as sb, sum(xl) over w as sl, sum(xu) over w as su
            from pg_temp._bk window w as (partition by a, b, dep_day)) z
   where z.route_id = k.route_id and z.dep_day = k.dep_day;

  if exists (select 1 from pg_temp._bk where apply and mode = 'optimise') then
  -- Optimiser: the level that earns most from the seats left, if the rest of the sale went at that fare with rivals
  -- where they are now: fare x least(travellers still to come who would choose it x outlook, seats left).
  update pg_temp._bk k set lvl_e = z.i
    from (select distinct on (k2.route_id, k2.dep_day) k2.route_id, k2.dep_day, c.i
            from pg_temp._bk k2 join pg_temp._rs s on s.route_id = k2.route_id
            cross join lateral generate_series(k2.lo_e, 6) c(i)
            cross join lateral (select round(k2.base_e * k2.e_mult[c.i] / 10) * 10 as p) pr
            cross join lateral (select game.rm_x(k2.cb - g.seg_biz_price * (pr.p / k2.ref + s.ad_b) + k2.gb, g.nest_lambda) as xb,
                                       game.rm_x(k2.cl - g.seg_lei_price * (pr.p / k2.ref + s.ad_l) + k2.gl, g.nest_lambda) as xl,
                                       game.rm_x(k2.cu - g.seg_bud_price * (pr.p / k2.ref + s.ad_u) + k2.gu, g.nest_lambda) as xu) x
           where k2.apply and k2.mode = 'optimise' and k2.lvl_e > 0
           order by k2.route_id, k2.dep_day,
                    pr.p * least(k2.outlook * (k2.rb * x.xb * game.rm_k(k2.sb - k2.xb + x.xb, g.nest_lambda)
                                             + k2.rl * x.xl * game.rm_k(k2.sl - k2.xl + x.xl, g.nest_lambda)
                                             + k2.ru * x.xu * game.rm_k(k2.su - k2.xu + x.xu, g.nest_lambda)),
                                 k2.book_e - k2.te) desc, c.i desc) z
   where z.route_id = k.route_id and z.dep_day = k.dep_day;
  update pg_temp._bk k set lvl_b = z.i
    from (select distinct on (k2.route_id, k2.dep_day) k2.route_id, k2.dep_day, c.i
            from pg_temp._bk k2
            cross join lateral generate_series(k2.lo_b, 3) c(i)
            cross join lateral (select round(k2.base_b * k2.b_mult[c.i] / 10) * 10 as p) pr
            cross join lateral (select game.rm_x(k2.cbb - g.seg_biz_price * pr.p / (k2.ref * g.biz_fare_mult), g.nest_lambda) as x) x
           where k2.apply and k2.mode = 'optimise' and k2.lvl_b > 0
           order by k2.route_id, k2.dep_day,
                    pr.p * least(k2.outlook * k2.rb * x.x * game.rm_k(k2.sb - k2.xbb + x.x, g.nest_lambda), k2.book_b - k2.tb) desc, c.i desc) z
   where z.route_id = k.route_id and z.dep_day = k.dep_day;
  update pg_temp._bk k set
    pe  = case when k.lvl_e > 0 then round(k.base_e * k.e_mult[k.lvl_e] / 10) * 10 end,
    pb  = case when k.lvl_b > 0 then round(k.base_b * k.b_mult[k.lvl_b] / 10) * 10 end
   where k.apply and k.mode = 'optimise';
  update pg_temp._bk k set
    xb  = case when k.lvl_e > 0 then game.rm_x(k.cb - g.seg_biz_price * (k.pe / k.ref + s.ad_b) + k.gb, g.nest_lambda) else 0 end,
    xl  = case when k.lvl_e > 0 then game.rm_x(k.cl - g.seg_lei_price * (k.pe / k.ref + s.ad_l) + k.gl, g.nest_lambda) else 0 end,
    xu  = case when k.lvl_e > 0 then game.rm_x(k.cu - g.seg_bud_price * (k.pe / k.ref + s.ad_u) + k.gu, g.nest_lambda) else 0 end,
    xbb = case when k.lvl_b > 0 then game.rm_x(k.cbb - g.seg_biz_price * k.pb / (k.ref * g.biz_fare_mult), g.nest_lambda) else 0 end
    from pg_temp._rs s where s.route_id = k.route_id and k.apply and k.mode = 'optimise';
  update pg_temp._bk k set sb = z.sb, sl = z.sl, su = z.su
    from (select route_id, dep_day, sum(xb + xbb) over w as sb, sum(xl) over w as sl, sum(xu) over w as su
            from pg_temp._bk window w as (partition by a, b, dep_day)) z
   where z.route_id = k.route_id and z.dep_day = k.dep_day;

  end if;

  -- Book. Today's travellers choose among the fares on sale (nested logit, section 4); a route takes at most the seats it
  -- has left (with overbooking); in manual mode the level's seat limit caps it and the rest sell at the next level.
  -- Travellers who wanted a sold-out cabin are turned away (counted at its dearest level; they try the others on later days).
  update pg_temp._bk k set
    dbe = k.nb * k.xb * game.rm_k(k.sb, g.nest_lambda),
    dle = k.nl * k.xl * game.rm_k(k.sl, g.nest_lambda),
    due = k.nu * k.xu * game.rm_k(k.su, g.nest_lambda),
    db  = k.nb * k.xbb * game.rm_k(k.sb, g.nest_lambda),
    -- exp(U / lambda) of a sold-out cabin at its dearest level, kept in we and wb for the next step
    we  = case when k.lvl_e = 0 and k.cap_e > 0 then 1 else 0 end,
    wb  = case when k.lvl_b = 0 and k.cap_b > 0 then 1 else 0 end,
    xb  = case when k.lvl_e = 0 and k.cap_e > 0
               then game.rm_x(k.cb - g.seg_biz_price * (round(k.base_e * k.e_mult[6] / 10) * 10 / k.ref + s.ad_b) + k.gb, g.nest_lambda) else k.xb end,
    xl  = case when k.lvl_e = 0 and k.cap_e > 0
               then game.rm_x(k.cl - g.seg_lei_price * (round(k.base_e * k.e_mult[6] / 10) * 10 / k.ref + s.ad_l) + k.gl, g.nest_lambda) else k.xl end,
    xu  = case when k.lvl_e = 0 and k.cap_e > 0
               then game.rm_x(k.cu - g.seg_bud_price * (round(k.base_e * k.e_mult[6] / 10) * 10 / k.ref + s.ad_u) + k.gu, g.nest_lambda) else k.xu end,
    xbb = case when k.lvl_b = 0 and k.cap_b > 0
               then game.rm_x(k.cbb - g.seg_biz_price * round(k.base_b * k.b_mult[3] / 10) * 10 / (k.ref * g.biz_fare_mult), g.nest_lambda) else k.xbb end
    from pg_temp._rs s
   where k.apply and s.route_id = k.route_id;
  update pg_temp._bk k set
    we = case when k.we = 1 then k.nb * k.xb * game.rm_k(k.sb + k.xb, g.nest_lambda) + k.nl * k.xl * game.rm_k(k.sl + k.xl, g.nest_lambda)
                                 + k.nu * k.xu * game.rm_k(k.su + k.xu, g.nest_lambda) else 0 end,
    wb = case when k.wb = 1 then k.nb * k.xbb * game.rm_k(k.sb + k.xbb, g.nest_lambda) else 0 end,
    xb = case when k.we = 1 then 0 else k.xb end, xl = case when k.we = 1 then 0 else k.xl end,
    xu = case when k.we = 1 then 0 else k.xu end, xbb = case when k.wb = 1 then 0 else k.xbb end
   where k.apply and (k.we = 1 or k.wb = 1);
  update pg_temp._bk set de = dbe + dle + due where apply;
  update pg_temp._bk set be = least(de, greatest(0, book_e - te)), bb = least(db, greatest(0, book_b - tb)),
         room = case when mode = 'manual' and lvl_e between 1 and 5
                     then greatest(0, e_limit[lvl_e] * book_e - (select sum(v) from unnest(sold_e[1:lvl_e]) v)) else 1e12 end
   where apply;
  update pg_temp._bk set
    pavg = case when be > 0 then (least(be, room) * pe
                                  + (be - least(be, room)) * coalesce(round(base_e * e_mult[least(6, lvl_e + 1)] / 10) * 10, pe)) / be
                else pe end
   where apply;

  update public.departures d set
    sold_e = (select array_agg(d.sold_e[i] + case when i = z.lvl_e then least(z.be, z.room) when i = z.lvl_e + 1 then z.be - least(z.be, z.room)
                                                  else 0 end order by i) from generate_series(1, 6) i),
    sold_b = (select array_agg(d.sold_b[i] + case when i = z.lvl_b then z.bb else 0 end order by i) from generate_series(1, 3) i),
    sav = array[d.sav[1] + z.r * z.dbe * (1 - z.qb), d.sav[2] + z.r * z.dle * (1 - z.ql), d.sav[3] + z.r * z.due * (1 - z.qu)],
    flx = array[d.flx[1] + z.r * z.dbe * z.qb, d.flx[2] + z.r * z.dle * z.ql, d.flx[3] + z.r * z.due * z.qu],
    bkb = d.bkb + z.bb,
    rev_sav = d.rev_sav + coalesce(z.r * (z.dbe * (1 - z.qb) + z.dle * (1 - z.ql) + z.due * (1 - z.qu)) * z.pavg, 0),
    rev_flx = d.rev_flx + coalesce(z.r * (z.dbe * z.qb + z.dle * z.ql + z.due * z.qu) * (z.pavg + coalesce(z.flex, 0) * z.ref), 0),
    rev_b = d.rev_b + z.bb * coalesce(z.pb, 0),
    turned_e = d.turned_e + z.de - z.be + z.we, turned_b = d.turned_b + z.db - z.bb + z.wb,
    lvl_e = z.lvl_e, lvl_b = z.lvl_b, fare_e = z.pe, fare_b = z.pb,
    curve = (select array_agg(case when i = z.m_lo + 1 then round((z.te + z.be + z.tb + z.bb)::numeric, 2)::float8 else d.curve[i] end order by i)
               from generate_series(1, greatest(cardinality(d.curve), z.m_lo + 1)) i),
    pot = array[z.pot_b, z.pot_l, z.pot_u],
    mkt_s = array[z.sb, z.sl, z.su], own_x = array[z.xb, z.xl, z.xu, z.xbb]
    from (select k.*, coalesce(k.be / nullif(k.de, 0), 0) as r from pg_temp._bk k where k.apply) z
   where d.route_id = z.route_id and d.dep_day = z.dep_day;
end $$;

-- ---------- Flying ----------
-- Today's departures fly: no-shows, passengers who cannot board (compensation), and the day's results into pg_temp._prod
-- for the rest of game.day_ops. Then each departure moves to the log.
create or replace function game.rm_fly(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' set jit = off as $$
declare
  g record;
begin
  select * into g from jsonb_to_record((select jsonb_object_agg(key, num) from public.game_params)) as x(
    rm_noshow_biz numeric, rm_noshow_lei numeric, rm_noshow_bud numeric, rm_noshow_flex numeric,
    rm_deny_mult numeric, rm_deny_cap_inr numeric, anc_biz_share numeric, biz_fare_mult numeric, rm_log_days numeric);

  create temp table if not exists _fly (
    route_id uuid primary key, airline_id uuid, a text, b text, km int, ref float8, brand float8,
    f float8, f_b float8, ce float8, cb float8, cs_e float8, cs_b float8,
    comf_e float8, comf_b float8, block_h float8, base_e float8, base_b float8,
    an_y float8, an_c float8,
    se float8, sf float8, bk float8, show_e float8, show_b float8, nfx float8,
    rev_sav float8, rev_flx float8, rev_b float8, turned float8,
    af_e float8, af_f float8, af_b float8, down float8, den_e float8, den_b float8,
    pax_e float8, pax_b float8, net_e float8, net_b float8, comp float8, ob_e float8, ob_b float8
  ) on commit drop;
  truncate pg_temp._fly;

  insert into pg_temp._fly (route_id, airline_id, a, b, km, ref, brand, f, f_b, ce, cb, cs_e, cs_b, comf_e, comf_b, block_h, base_e, base_b,
                            an_y, an_c, se, sf, bk, show_e, show_b, nfx, rev_sav, rev_flx, rev_b, turned)
  select d.route_id, d.airline_id, m.a, m.b, m.km, m.ref_fare, al.brand,
         coalesce(c.f, 0), coalesce(c.f_b, 0), coalesce(c.cap_e, 0), coalesce(c.cap_b, 0), d.cap_e, d.cap_b, coalesce(c.comf_e, 0), coalesce(c.comf_b, 0),
         coalesce(c.block_h, m.km / 750.0 + 0.5), r.fare_econ, coalesce(r.fare_biz, round(m.ref_fare * g.biz_fare_mult)),
         ax.yield, ax.cost,
         d.sav[1] + d.sav[2] + d.sav[3], d.flx[1] + d.flx[2] + d.flx[3], d.bkb,
         d.sav[1] * (1 - g.rm_noshow_biz) + d.sav[2] * (1 - g.rm_noshow_lei) + d.sav[3] * (1 - g.rm_noshow_bud)
           + d.flx[1] * (1 - g.rm_noshow_biz - g.rm_noshow_flex) + d.flx[2] * (1 - g.rm_noshow_lei - g.rm_noshow_flex)
           + d.flx[3] * (1 - g.rm_noshow_bud - g.rm_noshow_flex),
         d.bkb * (1 - g.rm_noshow_biz - g.rm_noshow_flex),
         d.flx[1] * (g.rm_noshow_biz + g.rm_noshow_flex) + d.flx[2] * (g.rm_noshow_lei + g.rm_noshow_flex)
           + d.flx[3] * (g.rm_noshow_bud + g.rm_noshow_flex),
         d.rev_sav, d.rev_flx, d.rev_b, d.turned_e + d.turned_b
    from public.departures d
    join public.routes r on r.id = d.route_id
    join public.airlines al on al.id = d.airline_id
    join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
    cross join lateral game.anc_terms(d.airline_id) ax
    left join (select route_id, sum(f) as f, coalesce(sum(f) filter (where seats_b > 0), 0) as f_b,
                      sum(f * seats_e) as cap_e, sum(f * seats_b) as cap_b,
                      sum(f * seats_e * comf_e) / nullif(sum(f * seats_e), 0) as comf_e,
                      sum(f * seats_b * comf_b) / nullif(sum(f * seats_b), 0) as comf_b,
                      sum(f * block_h) / nullif(sum(f), 0) as block_h
                 from pg_temp._rot where flown group by route_id) c on c.route_id = d.route_id
   where d.world_id = p_world and d.dep_day = p_day and al.status = 'active';

  -- Business travellers who cannot fit in the business cabin take free economy seats; the rest, and anyone over the
  -- economy seats, cannot board and get their fare back. Those over the seats scheduled (overbooking, or seats cut at
  -- short notice) also get compensation; those whose flight was cancelled on the day (an aircraft grounded, no crew) are
  -- refunded only: the brand already pays for cancellations (section 10).
  update pg_temp._fly set
    af_e = (rev_sav + rev_flx) / nullif(se + sf, 0), af_f = rev_flx / nullif(sf, 0), af_b = rev_b / nullif(bk, 0),
    down = least(greatest(0, show_b - cb), greatest(0, ce - show_e));
  update pg_temp._fly set
    den_b = greatest(0, show_b - cb) - down,
    den_e = greatest(0, show_e - ce),
    pax_e = least(show_e, ce) + down,
    pax_b = least(show_b, cb);
  update pg_temp._fly set ob_e = least(den_e, greatest(0, show_e - greatest(cs_e, ce))),
                          ob_b = least(den_b, greatest(0, show_b - greatest(cs_b, cb) - down));
  update pg_temp._fly set
    net_e = rev_sav + rev_flx - nfx * coalesce(af_f, 0) - den_e * coalesce(af_e, 0) + down * coalesce(least(af_e, af_b), af_b, 0),
    net_b = rev_b - (bk - show_b) * coalesce(af_b, 0) - (den_b + down) * coalesce(af_b, 0),
    comp = ob_e * least(g.rm_deny_mult * coalesce(af_e, base_e), g.rm_deny_cap_inr)
           + ob_b * least(g.rm_deny_mult * coalesce(af_b, base_b), g.rm_deny_cap_inr);

  insert into pg_temp._prod (route_id, airline_id, a, b, km, f, f_b, cap_e, cap_b, comf_e, comf_b, block_h, fare_e, fare_b, ref,
                             brand, an_y, an_c, pax_e, pax_b, pe, pb, rev, anc, anc_cost, spill, dem_e, dem_b, deny_cost, denied, noshow)
  select route_id, airline_id, a, b, km, f, f_b, ce, cb, comf_e, comf_b, block_h,
         coalesce(2 * net_e / nullif(round(2 * pax_e), 0), base_e), coalesce(2 * net_b / nullif(round(2 * pax_b), 0), base_b),
         ref, brand, an_y, an_c,
         pax_e, pax_b, round(2 * pax_e), round(2 * pax_b), round(2 * (net_e + net_b)),
         round(2 * pax_e) * ref * an_y + 2 * net_b * g.anc_biz_share,
         round(2 * pax_e) * ref * an_c, turned, se + sf + turned, bk,
         2 * comp, round(2 * (ob_e + ob_b)), round(2 * ((se + sf - show_e) + (bk - show_b)))
    from pg_temp._fly;

  insert into public.departure_log (route_id, dep_day, world_id, airline_id, opened, cap_e, cap_b, sold_e, sold_b, sav, flx, bkb,
                                    pax_e, pax_b, noshow, denied, cancelled, turned, revenue, compensation, curve)
  select d.route_id, d.dep_day, d.world_id, d.airline_id, d.opened, f.ce, f.cb, d.sold_e, d.sold_b, d.sav, d.flx, d.bkb,
         round(f.pax_e::numeric, 2), round(f.pax_b::numeric, 2), round(((f.se + f.sf - f.show_e) + (f.bk - f.show_b))::numeric, 2),
         round((f.ob_e + f.ob_b)::numeric, 2), round((f.den_e + f.den_b - f.ob_e - f.ob_b)::numeric, 2),
         round(f.turned::numeric, 2), round(f.net_e + f.net_b), round(f.comp), d.curve
    from public.departures d join pg_temp._fly f on f.route_id = d.route_id
   where d.world_id = p_world and d.dep_day = p_day
  on conflict (route_id, dep_day) do nothing;

  delete from public.departures where world_id = p_world and dep_day <= p_day;
  delete from public.departure_log where world_id = p_world and dep_day <= p_day - g.rm_log_days;
end $$;

-- The day's selling and flying, in place of step 4 of game.day_ops.
create or replace function game.rm_day(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' set jit = off as $$
declare
  v_h int := game.param('rm_horizon')::int;
  v_new uuid[];
begin
  -- a route going on sale for the first time (a new route, or the first day of revenue management in a world) fills its
  -- first six weeks as if it had been on sale: the same booking, run for the days before today a week at a time
  select array_agg(distinct x.route_id) into v_new
    from pg_temp._rot x
   where not exists (select 1 from public.departures d where d.route_id = x.route_id)
     and not exists (select 1 from public.departure_log l where l.route_id = x.route_id and l.dep_day = p_day - 1);
  if v_new is not null then
    for v in p_day - v_h + 1 .. p_day - 1 by 7 loop
      perform game.rm_book(p_world, v, p_day, v_new, 7);
    end loop;
  end if;
  perform game.rm_city_events(p_world, p_day);
  perform game.rm_book(p_world, p_day, p_day, null);
  perform game.rm_fly(p_world, p_day);
end $$;

-- ---------- Player actions ----------

-- Selling settings for one route, or (p_route null) the scalar settings for all the airline's routes.
-- Keys: mode, target_lf, pace, outlook, overbook, flex (null: no Flexi), e_mult, e_close, e_limit, b_mult, b_close, b_limit.
create or replace function public.set_rm(p_airline uuid, p_route uuid, p_settings jsonb) returns int
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  s jsonb := coalesce(p_settings, '{}');
  v_h int := game.param('rm_horizon')::int;
  v_lo numeric := game.param('rm_mult_min'); v_hi numeric := game.param('rm_mult_max');
  v_n int;
  em numeric[]; ec int[]; el numeric[]; bm numeric[]; bc int[]; bl numeric[];
begin
  rw := game.actor(p_airline, false);
  if p_route is not null and not exists (select 1 from public.routes where id = p_route and airline_id = p_airline) then
    raise exception 'That route is not yours';
  end if;
  if p_route is null and (s ?| array['e_mult', 'e_close', 'e_limit', 'b_mult', 'b_close', 'b_limit']) then
    raise exception 'Fare levels are set route by route';
  end if;
  if s ? 'mode' and (s ->> 'mode') not in ('manual', 'curve', 'optimise') then raise exception 'Unknown way of selling'; end if;
  if s ? 'target_lf' and (s ->> 'target_lf')::numeric not between 0.5 and 1.1 then raise exception 'Target load must be between 50%% and 110%%'; end if;
  if s ? 'pace' and (s ->> 'pace')::int not between 1 and 3 then raise exception 'Pace must be 1, 2 or 3 levels a day'; end if;
  if s ? 'outlook' and (s ->> 'outlook')::numeric not between 0.7 and 1.3 then raise exception 'Outlook must be between 0.7 and 1.3'; end if;
  if s ? 'overbook' and (s ->> 'overbook')::numeric not between 0 and game.param('rm_ob_max') then
    raise exception 'Overbooking must be between 0%% and %', round(game.param('rm_ob_max') * 100) || '%';
  end if;
  if s ? 'flex' and jsonb_typeof(s -> 'flex') <> 'null' and (s ->> 'flex')::numeric not between 0.02 and 1 then
    raise exception 'Flexi must cost between 2%% and 100%% of the reference fare more than Saver';
  end if;
  if s ? 'e_mult' then
    em := array(select jsonb_array_elements_text(s -> 'e_mult')::numeric);
    if cardinality(em) <> 6 or exists (select 1 from generate_series(2, 6) i where em[i] <= em[i - 1])
       or em[1] < v_lo or em[6] > v_hi then
      raise exception 'Six economy fare levels, each dearer than the one before, from %x to %x the base fare', v_lo, v_hi;
    end if;
  end if;
  if s ? 'b_mult' then
    bm := array(select jsonb_array_elements_text(s -> 'b_mult')::numeric);
    if cardinality(bm) <> 3 or bm[2] <= bm[1] or bm[3] <= bm[2] or bm[1] < v_lo or bm[3] > v_hi then
      raise exception 'Three business fare levels, each dearer than the one before, from %x to %x the base fare', v_lo, v_hi;
    end if;
  end if;
  if s ? 'e_close' then
    ec := array(select jsonb_array_elements_text(s -> 'e_close')::int);
    if cardinality(ec) <> 6 or ec[6] <> 0 or exists (select 1 from generate_series(2, 6) i where ec[i] > ec[i - 1])
       or ec[1] > v_h or ec[6] < 0 then
      raise exception 'Each economy level must stop selling no earlier than the one before it, and the dearest sells to the last day';
    end if;
  end if;
  if s ? 'b_close' then
    bc := array(select jsonb_array_elements_text(s -> 'b_close')::int);
    if cardinality(bc) <> 3 or bc[3] <> 0 or bc[2] > bc[1] or bc[3] > bc[2] or bc[1] > v_h then
      raise exception 'Each business level must stop selling no earlier than the one before it, and the dearest sells to the last day';
    end if;
  end if;
  if s ? 'e_limit' then
    el := array(select jsonb_array_elements_text(s -> 'e_limit')::numeric);
    if cardinality(el) <> 6 or el[6] <> 1 or el[1] < 0 or exists (select 1 from generate_series(2, 6) i where el[i] < el[i - 1]) then
      raise exception 'Economy seat limits must grow level by level, and the dearest level may sell every seat';
    end if;
  end if;
  if s ? 'b_limit' then
    bl := array(select jsonb_array_elements_text(s -> 'b_limit')::numeric);
    if cardinality(bl) <> 3 or bl[3] <> 1 or bl[1] < 0 or bl[2] < bl[1] then
      raise exception 'Business seat limits must grow level by level, and the dearest level may sell every seat';
    end if;
  end if;

  update public.route_rm rm set
    mode = coalesce(s ->> 'mode', rm.mode),
    target_lf = coalesce((s ->> 'target_lf')::numeric, rm.target_lf),
    pace = coalesce((s ->> 'pace')::int, rm.pace),
    outlook = coalesce((s ->> 'outlook')::numeric, rm.outlook),
    overbook = coalesce((s ->> 'overbook')::numeric, rm.overbook),
    flex = case when s ? 'flex' then (s ->> 'flex')::numeric else rm.flex end,
    e_mult = coalesce(em, rm.e_mult), e_close = coalesce(ec, rm.e_close), e_limit = coalesce(el, rm.e_limit),
    b_mult = coalesce(bm, rm.b_mult), b_close = coalesce(bc, rm.b_close), b_limit = coalesce(bl, rm.b_limit)
   where rm.airline_id = p_airline and (p_route is null or rm.route_id = p_route);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- The cheapest fare level allowed on chosen dates already on sale (1 lets every level sell). Returns the dates changed.
create or replace function public.set_rm_dates(p_airline uuid, p_route uuid, p_from int, p_to int, p_min_e int, p_min_b int default 1)
returns int
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  v_n int;
begin
  rw := game.actor(p_airline);
  if not exists (select 1 from public.routes where id = p_route and airline_id = p_airline) then raise exception 'That route is not yours'; end if;
  if p_min_e not between 1 and 6 or coalesce(p_min_b, 1) not between 1 and 3 then raise exception 'Levels are 1 to 6 in economy, 1 to 3 in business'; end if;
  update public.departures set min_e = p_min_e, min_b = coalesce(p_min_b, 1)
   where route_id = p_route and dep_day between p_from and p_to and dep_day > rw.game_day;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- Fares on sale on a route's market, by airline and date: what any traveller can see. Sold out: null.
create or replace function public.market_fares(p_route uuid)
returns table (airline_id uuid, route_id uuid, dep_day int, fare_e int, fare_b int)
language sql stable security definer set search_path = '' as $$
  select d.airline_id, d.route_id, d.dep_day, case when d.lvl_e > 0 then d.fare_e end, case when d.lvl_b > 0 then d.fare_b end
    from public.routes r0
    join public.routes r on r.world_id = r0.world_id and least(r.origin, r.dest) = least(r0.origin, r0.dest)
                        and greatest(r.origin, r.dest) = greatest(r0.origin, r0.dest)
    join public.departures d on d.route_id = r.id
   where r0.id = p_route
     and (game.is_server() or exists (select 1 from public.airlines a where a.world_id = r0.world_id and a.user_id = auth.uid()))
   order by d.dep_day, d.fare_e
$$;

-- What if: the economy travellers a route would carry on an average departure on sale, at one fare for the whole sale,
-- against rivals' fares on sale now, from p_mult_lo to p_mult_hi times its base fare. Demand is before the seat limit.
create or replace function public.rm_whatif(p_route uuid)
returns table (mult numeric, fare int, demand numeric, pax numeric, revenue numeric)
language plpgsql stable security definer set search_path = '' as $$
declare
  ra public.routes%rowtype;
  v_lambda numeric := game.param('nest_lambda');
  v_b numeric[] := array[game.param('seg_biz_price'), game.param('seg_lei_price'), game.param('seg_bud_price')];
  v_ref numeric;
begin
  select * into ra from public.routes where id = p_route;
  if not found then raise exception 'Route not found'; end if;
  if not game.is_server() and not exists (select 1 from public.airlines where id = ra.airline_id and user_id = auth.uid()) then
    raise exception 'That route is not yours';
  end if;
  select ref_fare into v_ref from public.markets where a = least(ra.origin, ra.dest) and b = greatest(ra.origin, ra.dest);
  return query
  select m.m, (round(ra.fare_econ * m.m / 10) * 10)::int,
         round(avg(z.dem)::numeric, 1), round(avg(least(z.dem, d.cap_e))::numeric, 1),
         round(avg(least(z.dem, d.cap_e))::numeric * round(ra.fare_econ * m.m / 10) * 10)
    from generate_series(0.6, 2.0, 0.1) m(m)
    cross join public.departures d
    cross join lateral (
      select sum(d.pot[i] * x * game.rm_k(d.mkt_s[i] - d.own_x[i] + x, v_lambda)) as dem
        from generate_series(1, 3) i
        cross join lateral (select case when d.own_x[i] > 0 and d.fare_e is not null
                                        then d.own_x[i] * exp((-v_b[i] * (round(ra.fare_econ * m.m / 10) * 10 - d.fare_e) / v_ref / v_lambda)::float8)
                                        else 0::float8 end as x) xx) z
   where d.route_id = p_route and d.cap_e > 0 and d.fare_e is not null
   group by m.m order by m.m;
end $$;

-- ---------- The day engine ----------
-- Redefined from 0017: step 4 runs game.rm_day in worlds with revenue management; compensation for passengers who
-- could not board is booked with distribution and service, and their share lowers the brand target.
create or replace function game.day_ops(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' set jit = off as $$
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
    loan_rate_year numeric, anc_biz_share numeric, slot_ref_seats numeric, rm_deny_brand_k numeric);

  select biz, lei, bud into v_sb, v_sl, v_su from public.season_factors
   where month = ((g.season_start_month::int - 1 + (((p_day - 1) % 364) * 12) / 364) % 12) + 1;
  v_grow := power(1 + g.growth_year, (p_day - 1) / 364.0) * rw.demand_scale;

  create temp table if not exists _rot (   -- one row per aircraft per route
    route_id uuid, airline_id uuid, aircraft_id uuid, type_id text, a text, b text, km int, intl boolean,
    f numeric,                -- round trips a day
    flown boolean, wet boolean, seats_e int, seats_b int, comf_e numeric, comf_b numeric,
    block_h numeric, turn_min numeric, age_y numeric, crew int,
    c_fuel numeric default 0, c_crew numeric default 0, c_maint numeric default 0,
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
    deny_cost numeric default 0, denied numeric default 0, noshow numeric default 0   -- 0018: passengers who could not board (both ways)
  ) on commit drop;
  create temp table if not exists _acx (   -- migration 0017: what holding each aircraft costs today, and the hours it flew
    aircraft_id uuid primary key, airline_id uuid, fixed numeric, bh numeric
  ) on commit drop;
  truncate pg_temp._rot, pg_temp._prod, pg_temp._acx;

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
    join public.airlines al on al.id = r.airline_id and al.status = 'active'
    join public.rotations ro on ro.route_id = r.id
    join public.aircraft ac on ac.id = ro.aircraft_id and ac.airline_id = r.airline_id and ac.status in ('active', 'grounded')
    join public.aircraft_types t on t.id = ac.type_id
    join public.aircraft_terms tm on tm.aircraft_id = ac.id
    join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
   where r.world_id = p_world and r.status = 'open';

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

  -- Step 4: demand. With revenue management (0018) flights sell over six weeks and today's departures fly with what they
  -- sold (game.rm_day fills pg_temp._prod); otherwise the daily demand of section 4.
  if rw.rm then
    perform game.rm_day(p_world, p_day);
  else
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

  update pg_temp._prod
     set spill = greatest(dem_e - cap_e, 0) + greatest(dem_b - cap_b, 0) - dg,
         pe = round(2 * pax_e), pb = round(2 * pax_b), rev = round(2 * pax_e) * fare_e + round(2 * pax_b) * fare_b,
         anc = round(2 * pax_e) * ref * an_y + round(2 * pax_b) * fare_b * g.anc_biz_share,
         anc_cost = round(2 * pax_e) * ref * an_c;

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
    c_fuel = 2 * x.f * (t.fuel_fixed_kg + t.fuel_per_km_kg * x.km)
             * (0.80 + 0.20 * (x.seats_e * p.lf_e + x.seats_b * p.lf_b) / t.ref_seats)
             * (1 + g.age_fuel_per_year * x.age_y) * rw.fuel_inr_kg,
    c_crew = case when x.wet then 0 else 2 * x.f * x.block_h * (t.pilot_inr_bh + x.crew * g.cabin_inr_bh) end,
    c_maint = case when x.wet then 0 else
                2 * x.f * ((x.km::numeric / t.cruise_kmh + g.maint_fh_offset) * t.maint_usd_fh + t.maint_usd_cycle)
                * (1 + g.age_maint_per_year * x.age_y) * rw.fx_inr_usd end,
    c_airport = 2 * x.f * (t.landing_inr * case when x.intl then (1 + g.intl_airport_mult) / 2 else 1 end
                           + t.nav_inr_km * x.km + g.handling_inr_pax * (x.seats_e * p.lf_e + x.seats_b * p.lf_b)),
    c_slots = 2 * x.f * (coalesce(sa.price, 0) + coalesce(sb.price, 0)) * t.ref_seats / g.slot_ref_seats   -- 0016: by aircraft size
  from (select route_id, a, b, coalesce(pax_e / nullif(cap_e, 0), 0) as lf_e, coalesce(pax_b / nullif(cap_b, 0), 0) as lf_b
          from pg_temp._prod) p
  join public.aircraft_types t on true
  left join sp sa on sa.iata = p.a
  left join sp sb on sb.iata = p.b
  where x.flown and p.route_id = x.route_id and t.id = x.type_id;

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
   where ac.world_id = p_world and ac.status in ('active', 'grounded', 'refit');

  insert into public.route_daily (route_id, game_day, airline_id, flights, seats_econ, seats_biz, pax_econ, pax_biz,
                                  spill, revenue_inr, var_cost_inr, aircraft_cost_inr, noshow, denied)
  select p.route_id, p_day, p.airline_id, 2 * p.f, round(2 * p.cap_e), round(2 * p.cap_b), p.pe, p.pb, round(2 * p.spill),
         round(p.rev + p.anc),
         round(c.var + g.dist_rev_share * p.rev + g.service_inr_pax * (p.pe + p.pb) + p.anc_cost + p.deny_cost),
         round(c.acx), round(p.noshow), round(p.denied)
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
                          + s.all_ * (g.dist_rev_share * p.rev + g.service_inr_pax * (p.pe + p.pb) + p.anc_cost + p.deny_cost)) as cost
                 from pg_temp._rot x
                 join pg_temp._prod p on p.route_id = x.route_id
                 cross join lateral (select coalesce(x.f * x.seats_e / nullif(p.cap_e, 0), 0) as e,
                                            coalesce(x.f * x.seats_b / nullif(p.cap_b, 0), 0) as b,
                                            coalesce(x.f * (x.seats_e + x.seats_b) / nullif(p.cap_e + p.cap_b, 0), 0) as all_) s
                where x.flown group by x.aircraft_id) z on z.aircraft_id = a.aircraft_id
   where a.airline_id is not null;

  insert into public.airline_daily (airline_id, game_day, pax, ask, rpk, rev_ticket, rev_anc, c_fuel, c_crew, c_maint,
    c_airport, c_rent, c_slots, c_dist, c_marketing, c_overhead, c_interest, c_other, c_depr, flights, cancelled, loan_repaid, denied)
  select al.id, p_day, coalesce(pr.pax, 0), coalesce(pr.ask, 0), coalesce(pr.rpk, 0),
         coalesce(pr.rev, 0), round(coalesce(pr.anc, 0)),
         round(coalesce(rc.fuel, 0)), round(coalesce(rc.crew, 0) + coalesce(fl.crew_fixed, 0) + coalesce(sal.pay, 0)), round(coalesce(rc.maint, 0)),
         round(coalesce(rc.airport, 0)), round(coalesce(fl.rent, 0)), round(coalesce(rc.slots, 0)),
         round(coalesce(g.dist_rev_share * pr.rev + g.service_inr_pax * pr.pax + pr.anc_cost + pr.deny_cost, 0)), al.marketing_inr_day,
         round(g.overhead_fixed_inr_day + g.overhead_aircraft_inr_day * coalesce(fl.n, 0) + g.overhead_seat_inr_day * coalesce(fl.seats, 0)
               + g.base_fixed_inr_day * (select count(*) from public.bases bs where bs.airline_id = al.id)),
         round(fin.debt_inr * g.interest_year / 364 + coalesce(fl.loan_int, 0)), coalesce(tx.other, 0), round(coalesce(fl.depr, 0)),
         coalesce(rc.flights, 0), coalesce(rc.cancelled, 0), round(coalesce(fl.loan_prin, 0)), round(coalesce(pr.denied, 0))
    from public.airlines al
    join public.airline_finance fin on fin.airline_id = al.id
    left join (select airline_id, sum(pe + pb) as pax, sum(2 * (cap_e + cap_b) * km) as ask,
                      sum((pe + pb) * km) as rpk, sum(rev) as rev, sum(anc) as anc, sum(anc_cost) as anc_cost,
                      sum(deny_cost) as deny_cost, sum(denied) as denied
                 from pg_temp._prod group by airline_id) pr on pr.airline_id = al.id
    left join (select airline_id, sum(c_fuel) as fuel, sum(c_crew) as crew, sum(c_maint) as maint,
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
   where al.world_id = p_world and al.status = 'active';

  update public.airline_finance fin
     set cash_inr = fin.cash_inr + d.rev_ticket + d.rev_anc - (d.c_fuel + d.c_crew + d.c_maint + d.c_airport + d.c_rent
                    + d.c_slots + d.c_dist + d.c_marketing + d.c_overhead + d.c_interest + d.loan_repaid)
    from public.airline_daily d join public.airlines al on al.id = d.airline_id
   where d.airline_id = fin.airline_id and d.game_day = p_day and al.world_id = p_world;

  update public.aircraft_terms tm set loan_usd = tm.loan_usd - least(tm.loan_usd, tm.loan_pay_usd_day)
    from public.aircraft ac join public.airlines al on al.id = ac.airline_id and al.status = 'active'
   where ac.id = tm.aircraft_id and ac.world_id = p_world and ac.status in ('active', 'grounded', 'refit')
     and tm.holding = 'owned' and tm.loan_usd > 0;

  -- punctuality: tight schedules run late. Brand drifts toward a target built from punctuality,
  -- cancellations, cabin comfort and marketing per passenger.
  update public.airlines al set otp = round((1 - g.otp_smooth) * al.otp + g.otp_smooth * s.otp, 4)
    from (select u.airline_id, sum(u.fl * (g.otp_base - g.otp_util_k * greatest(0, u.util - 0.85) / 0.15)) / sum(u.fl) as otp
            from (select x.airline_id, x.aircraft_id, sum(2 * x.f) as fl,
                         sum(2 * x.f * (x.block_h + x.turn_min / 60)) / max(t.day_window_h) as util
                    from pg_temp._rot x join public.aircraft_types t on t.id = x.type_id
                   where x.flown group by x.airline_id, x.aircraft_id) u
           group by u.airline_id) s
   where al.id = s.airline_id;

  update public.airlines al
     set brand = round(least(100, greatest(0, al.brand + g.brand_drift * (
           50 + g.brand_otp_k * (al.otp - g.brand_otp_ref)
              - g.brand_cancel_k * coalesce(d.cancelled / nullif(d.flights + d.cancelled, 0), 0)
              - coalesce(g.rm_deny_brand_k, 0) * coalesce(d.denied::numeric / nullif(d.pax + d.denied, 0), 0)
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

revoke all on function game.day_ops(uuid, int), game.rm_day(uuid, int), game.rm_book(uuid, int, int, uuid[], int), game.rm_fly(uuid, int),
  game.rm_city_events(uuid, int), game.route_rm_new(), game.route_rm_add(uuid, uuid), game.param_list(text, int) from public, anon, authenticated;
revoke all on function public.set_rm(uuid, uuid, jsonb), public.set_rm_dates(uuid, uuid, int, int, int, int),
  public.market_fares(uuid), public.rm_whatif(uuid) from public, anon;
grant execute on function public.set_rm(uuid, uuid, jsonb), public.set_rm_dates(uuid, uuid, int, int, int, int),
  public.market_fares(uuid), public.rm_whatif(uuid) to authenticated, service_role;
