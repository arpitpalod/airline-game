-- Migration 0041 (spec 14.33): gems, connections part 3 of 3 (open item 31).
--
-- What changes:
--  * public.gem_kinds (G, public: the kinds are no secret, where and when are): ten real kinds of hidden demand, each
--    with how often a world draws it, where it can fall, how big and how long, its shape, who it moves (business,
--    leisure, budget) and how often a vague clue reaches the news ahead of it.
--  * game.world_gems (hidden; not readable by the app): each world's own gems at random places and dates, drawn by
--    game.gems_week at every week of selling (lasting ones and yearly seasons at a world's first week of selling, the
--    others about 26 weeks ahead, before their flights go on sale). Running worlds get theirs at their next week.
--  * game.gem_rows, game.gem_market, game.gem_area, game.gem_hints (helpers).
--  * game.sell_week (from 0039): demand on markets a gem touches is multiplied by it, week by week, for nonstops and
--    connections alike. Clues reach the world's news (kind 'gem').
--  * public.route_study (from 0037): a quick study says something unusual is coming on the market in the next six
--    months; a full one says about how much and when (route_studies.gem_note). Either way the airline knows of it.
--  * public.hub_study (from 0040): estimates include the gems of the next 26 weeks, and list them ('gems').
--  * public.consultant_data (from 0037): the overview carries market_hints, a few vague rumours (game.gem_hints, about
--    half of the gems in the next 13 weeks, the same all week); a new playbook version tells the consultant they are
--    possibilities worth a study, not facts.
--  * game.bot_network (from 0040): computer-run airlines sell Top fares on routes touched by a gem they know of (a clue
--    in the news, or their own studies) while it lasts, then go back to their way of selling.

create table public.gem_kinds (
  key        text primary key,
  name       text not null,
  sort       int not null,
  scope      text not null check (scope in ('airport', 'pair', 'country')),
  pick       text not null,                 -- where it can fall (game.gems_week)
  per_year   numeric not null default 0,     -- drawn this often a year per world, about 26 weeks ahead
  at_start   int not null default 0,         -- drawn this many at a world's first week of selling
  mult_lo    numeric not null, mult_hi numeric not null,   -- demand at the peak, times normal
  weeks_lo   int not null, weeks_hi int not null,          -- how long (for a boom city: how long it takes to build)
  shape      text not null check (shape in ('flat', 'rise_fall', 'trapezoid', 'ramp')),
  recurs     boolean not null default false,               -- comes back every year
  drift      int not null default 0,                       -- weeks earlier (-) or later each year
  w_biz numeric not null, w_lei numeric not null, w_bud numeric not null,   -- share of the change each traveller type feels
  clue_share numeric not null default 0,      -- chance a vague clue reaches the news
  clue_weeks int not null default 0,          -- that many weeks before it starts (negative: after)
  clue       text                             -- {area}, {city}, {region}
);
alter table public.gem_kinds enable row level security;
grant select on public.gem_kinds to anon, authenticated;
create policy read_all on public.gem_kinds for select to anon, authenticated using (true);

insert into public.gem_kinds (key, name, sort, scope, pick, per_year, at_start, mult_lo, mult_hi, weeks_lo, weeks_hi, shape, recurs, drift,
                              w_biz, w_lei, w_bud, clue_share, clue_weeks, clue) values
  ('mega_event', 'A mega gathering', 1, 'airport', 'busy', 1.2, 0, 3, 8, 1, 4, 'flat', false, 0, 0.2, 1, 1, 0.6, 6,
   'A huge gathering is expected in {area} in the coming weeks.'),
  ('pilgrim_season', 'A pilgrim season', 2, 'airport', 'tourist', 0, 3, 1.5, 2.5, 3, 8, 'rise_fall', true, -2, 0.1, 1, 1, 0.4, 4,
   'Pilgrims are heading to {area}.'),
  ('viral_place', 'A place gone viral', 3, 'airport', 'small_tourist', 0.8, 0, 1.6, 2.5, 52, 104, 'trapezoid', false, 0, 0, 1, 1.2, 0.7, -8,
   'Social media is full of a holiday town in {area}.'),
  ('visa_open', 'Visas made easy', 4, 'country', 'foreign', 0.4, 0, 1.3, 1.8, 104, 260, 'flat', false, 0, 0.5, 1, 1, 1, 6,
   'Travel to {city} and the rest of its country is getting easier for travellers from {region}: visas are being eased.'),
  ('visa_close', 'Visas made hard', 5, 'country', 'foreign', 0.25, 0, 0.55, 0.8, 52, 156, 'flat', false, 0, 0.6, 1, 1, 1, 4,
   'Visas to {city} and the rest of its country are getting harder for travellers from {region}.'),
  ('boom_city', 'A boom city', 6, 'airport', 'mid_city', 0.3, 0, 1.4, 2.0, 104, 156, 'ramp', false, 0, 1.2, 0.8, 0.8, 0.4, 0,
   'Investment is pouring into a city in {area}.'),
  ('diaspora_pair', 'A diaspora route', 7, 'pair', 'long_pair', 0, 5, 1.6, 3.0, 9999, 9999, 'flat', false, 0, 0.3, 1, 1, 0, 0, null),
  ('medical', 'Medical travel', 8, 'pair', 'medical_pair', 0, 2, 1.3, 1.7, 9999, 9999, 'flat', false, 0, 1, 0.6, 0.4, 0, 0, null),
  ('student_season', 'Students on the move', 9, 'country', 'foreign', 0, 2, 1.3, 1.6, 4, 6, 'rise_fall', true, 0, 0, 0.6, 1.2, 0.3, 3,
   'Students from {region} are heading to {city} and the rest of its country for the new term.'),
  ('wedding_season', 'Wedding season', 10, 'airport', 'tourist', 0, 2, 1.2, 1.5, 8, 14, 'rise_fall', true, 0, 0, 1, 0.5, 0.3, 2,
   'Wedding season is filling hotels in {area}.');

create table game.world_gems (
  id         bigint generated always as identity primary key,
  world_id   uuid not null references public.worlds on delete cascade,
  kind       text not null references public.gem_kinds,
  a          text references public.airports,   -- the airport, or the pair's first airport
  b          text references public.airports,   -- the pair's second airport (a < b)
  country    text,                               -- a country gem's country
  start_week int not null,
  weeks      int not null,
  mult       numeric not null,
  drift      int not null default 0,
  clue_week  int,                                -- the next clue's week (null: none)
  clued      boolean not null default false,     -- a clue has reached the news: every airline knows
  known_by   uuid[] not null default '{}'        -- airlines that found it through their own studies
);
create index world_gems_world_idx on game.world_gems (world_id);

insert into public.game_params (key, num, note) values
  ('gems_on', 1, 'hidden demand (gems): 1 on, 0 off (0041)'),
  ('gem_lead_weeks', 26, 'gems drawn during a world are placed at least this many weeks ahead, before their flights go on sale (0041)'),
  ('gem_hint_share', 0.5, 'the consultant hears of about this share of the gems in the next 13 weeks (0041)'),
  ('gem_study_width', 0.25, 'a full route study''s estimate of a gem is within about this share (0041)');

-- Where an airport lies in its country: the north, south, east, west or centre, as a clue says it (0041).
create or replace function game.gem_area(p_iata text) returns text
language sql stable set search_path = '' as $$
  select format('the %s of %s',
           case when abs(x.lat - c.lat) < 1.5 and abs(x.lon - c.lon) < 1.5 then 'centre'
                when abs(x.lat - c.lat) >= abs(x.lon - c.lon) then case when x.lat > c.lat then 'north' else 'south' end
                else case when x.lon > c.lon then 'east' else 'west' end end,
           coalesce(r.name, x.country))
    from public.airports x
    cross join lateral (select avg(y.lat) as lat, avg(y.lon) as lon from public.airports y
                         where y.home = x.home or (x.home is null and y.country = x.country)) c
    left join public.regions r on r.key = x.home
   where x.iata = p_iata
$$;

-- Every gem-week in weeks p_w0 to p_w1 of a world, with its demand at that week (times normal) (0041).
create or replace function game.gem_rows(p_world uuid, p_w0 int, p_w1 int)
returns table (id bigint, kind text, scope text, a text, b text, country text, week int, m float8, w_biz float8, w_lei float8, w_bud float8)
language sql stable set search_path = '' as $$
  select g.id, g.kind, k.scope, g.a, g.b, g.country, w.week,
         (1 + (g.mult - 1) * case k.shape
            when 'flat' then 1
            when 'rise_fall' then sin(pi() * (w.week - o.s + 0.5) / g.weeks)
            when 'trapezoid' then least(1, 3 * (w.week - o.s + 0.5) / g.weeks, 3 * (1 - (w.week - o.s + 0.5) / g.weeks))
            else least(1, (w.week - o.s + 1)::float8 / g.weeks) end)::float8,
         k.w_biz::float8, k.w_lei::float8, k.w_bud::float8
    from game.world_gems g
    join public.gem_kinds k on k.key = g.kind
    cross join lateral generate_series(0, case when k.recurs then 30 else 0 end) y(yr)
    cross join lateral (select g.start_week + y.yr * (52 + g.drift) as s) o
    cross join lateral generate_series(greatest(p_w0, o.s), least(p_w1, case when k.shape = 'ramp' then p_w1 else o.s + g.weeks - 1 end)) w(week)
   where g.world_id = p_world and o.s <= p_w1 and game.param('gems_on') > 0
$$;

-- The gem-weeks of one market (0041): by airport, by the pair, or by country (a country and the world's home region).
create or replace function game.gem_market(p_world uuid, p_a text, p_b text, p_w0 int, p_w1 int)
returns table (id bigint, kind text, week int, m float8, fb float8, fl float8, fu float8)
language sql stable set search_path = '' as $$
  select r.id, r.kind, r.week, r.m,
         greatest(0.2, 1 + (r.m - 1) * r.w_biz), greatest(0.2, 1 + (r.m - 1) * r.w_lei), greatest(0.2, 1 + (r.m - 1) * r.w_bud)
    from game.gem_rows(p_world, p_w0, p_w1) r
    join public.airports pa on pa.iata = least(p_a, p_b)
    join public.airports pb on pb.iata = greatest(p_a, p_b)
   where (r.scope = 'airport' and r.a in (pa.iata, pb.iata))
      or (r.scope = 'pair' and r.a = pa.iata and r.b = pb.iata)
      or (r.scope = 'country' and ((pa.country = r.country and pb.home = game.world_region(p_world))
                                or (pb.country = r.country and pa.home = game.world_region(p_world))))
$$;

-- Each world's gems (0041), at every week of selling: draws (lasting ones and yearly seasons at the first week, the
-- rest about gem_lead_weeks ahead), and clues to the news.
create or replace function game.gems_week(p_world uuid, p_week int) returns void
language plpgsql set search_path = '' as $$
declare
  k record; v_reg text := game.world_region(p_world); v_n int; v_start int; v_a text; v_b text; v_c text; i int;
  v_first boolean; g record; v_txt text;
begin
  if game.param('gems_on') <= 0 then return; end if;
  v_first := not exists (select 1 from game.world_gems x where x.world_id = p_world);
  for k in select * from public.gem_kinds order by sort loop
    v_n := case when v_first then k.at_start else 0 end
           + case when k.per_year > 0 and random() < k.per_year / 52 then 1 else 0 end;
    for i in 1..v_n loop
      v_a := null; v_b := null; v_c := null;
      if k.pick = 'busy' then
        select iata into v_a from public.airports where home = v_reg and coalesce(pax_m, 0) >= 0.5
         order by power(random(), 1.0 / (coalesce(tour_idx, 0.3) + 0.3)) desc limit 1;   -- weighted draws
      elsif k.pick = 'tourist' then
        select iata into v_a from public.airports where home = v_reg and coalesce(tour_idx, 0) >= 0.4 order by power(random(), 1.0 / tour_idx) desc limit 1;
      elsif k.pick = 'small_tourist' then
        select iata into v_a from public.airports where home = v_reg and coalesce(tour_idx, 0) >= 0.6 and coalesce(pax_m, 0) < 6
         order by random() limit 1;
      elsif k.pick = 'mid_city' then
        select iata into v_a from public.airports where home = v_reg and pax_m between 1 and 15 and coalesce(biz_idx, 0) >= 0.2
         order by random() limit 1;
      elsif k.pick = 'foreign' then
        select f.country into v_c from (
          select y.country, sum(m.n_biz + m.n_lei + m.n_bud) as n
            from public.markets m
            join public.airports x on x.iata in (m.a, m.b) and x.home = v_reg
            join public.airports y on y.iata in (m.a, m.b) and y.home is distinct from v_reg
           group by y.country) f
         order by power(random(), 1.0 / greatest(sqrt(f.n), 1e-6)) desc limit 1;
      elsif k.pick in ('long_pair', 'medical_pair') then
        select m.a, m.b into v_a, v_b
          from public.markets m
          join public.airports pa on pa.iata = m.a
          join public.airports pb on pb.iata = m.b
         where (coalesce(pa.home, '') = v_reg) <> (coalesce(pb.home, '') = v_reg)
           and case when k.pick = 'long_pair' then m.km >= 2500
                    else m.km between 800 and 5000 and greatest(case when pa.home = v_reg then pa.pax_m else 0 end,
                                                                case when pb.home = v_reg then pb.pax_m else 0 end) >= 10 end
           and (pa.home = v_reg or pb.home = v_reg)
           and not exists (select 1 from game.world_gems x where x.world_id = p_world and x.a = m.a and x.b = m.b)
         order by power(random(), 1.0 / greatest(sqrt(m.n_biz + m.n_lei + m.n_bud), 1e-6)) desc limit 1;
      end if;
      continue when v_a is null and v_c is null;
      v_start := case when k.weeks_lo >= 9999 then 1
                      when v_first and k.recurs then p_week + floor(random() * 52)::int
                      else p_week + game.param('gem_lead_weeks')::int + floor(random() * 13)::int end;
      insert into game.world_gems (world_id, kind, a, b, country, start_week, weeks, mult, drift, clue_week)
      values (p_world, k.key, v_a, v_b, v_c, v_start,
              k.weeks_lo + floor(random() * (k.weeks_hi - k.weeks_lo + 1))::int,
              round((k.mult_lo + random() * (k.mult_hi - k.mult_lo))::numeric, 2), k.drift,
              case when k.clue is not null and random() < k.clue_share then v_start - k.clue_weeks end);
    end loop;
  end loop;

  -- clues: vague, to the whole world; a yearly season's next clue a year (and its drift) later
  for g in select x.*, gk.clue, gk.recurs from game.world_gems x join public.gem_kinds gk on gk.key = x.kind
            where x.world_id = p_world and x.clue_week is not null and x.clue_week <= p_week loop
    v_txt := replace(replace(replace(g.clue, '{area}', coalesce(game.gem_area(g.a), 'the region')),
               '{city}', coalesce((select ap.city from public.airports ap where ap.country = g.country order by ap.pax_m desc nulls last limit 1), g.country, 'abroad')),
               '{region}', coalesce((select r.name from public.regions r where r.key = v_reg), 'here'));
    if g.clue_week > p_week - 4 then   -- a clue more than four weeks late is not worth printing
      insert into public.news (world_id, game_day, kind, body) values (p_world, (p_week - 1) * 7 + 1, 'gem', v_txt);
    end if;
    update game.world_gems set clued = true,
           clue_week = case when g.recurs then g.clue_week + 52 + g.drift end
     where id = g.id;
  end loop;
end $$;

-- The consultant's rumours (0041): about gem_hint_share of the gems in the next 13 weeks, vaguely, the same all week.
-- A gem already under way is 'now'; one coming is 'around week N', give or take a couple of weeks.
create or replace function game.gem_hints(p_world uuid, p_airline uuid, p_week int) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('kind', q.name,
           'where', case q.scope
                      when 'pair' then (select game.gem_area(x.iata) from public.airports x where x.iata in (q.a, q.b) and x.home = game.world_region(p_world) limit 1)
                                       || ' and ' || (select x.city from public.airports x where x.iata in (q.a, q.b) and x.home is distinct from game.world_region(p_world) limit 1)
                      when 'country' then (select ap.city from public.airports ap where ap.country = q.country order by ap.pax_m desc nulls last limit 1) || ' and its country'
                      else game.gem_area(q.a) end,
           'when', case when q.week <= p_week then 'now'
                        else 'around week ' || (q.week + round(4 * (game.hash_normal(p_airline::text || q.id || p_week) / 3))::int) end)
           order by q.week), '[]'::jsonb)
    from (select r.id, k.name, r.scope, min(r.week) as week, max(r.a) as a, max(r.b) as b, max(r.country) as country
            from game.gem_rows(p_world, p_week, p_week + 12) r
            join public.gem_kinds k on k.key = r.kind
           where abs(r.m - 1) > 0.1
           group by r.id, k.name, r.scope) q
   where (game.hash_normal('hint' || p_airline::text || q.id || p_week) + 4) / 8 < game.param('gem_hint_share')
$$;

-- Selling (from 0039), with gems (0041).
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
    cancel_notice_days float8, denied_fare_mult float8,   -- 0033
    conn_stop_biz float8, conn_stop_lei float8, conn_stop_bud float8, conn_detour_biz float8, conn_detour_lei float8,
    conn_detour_bud float8, conn_calc_detour float8, outside_on float8, outside_freq float8, outside_fare float8,
    outside_comfort float8, outside_brand float8, outside_nonstop_km float8, conn_recapture float8, conn_min_leg_km float8);   -- 0039
  perform game.gems_week(p_world, v_w);     -- 0041: the world's gems: draws and clues
  perform game.bot_network(p_world, v_w);   -- 0039: computer-run airlines' network selling, before the fares

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
         p.network as nw, p.conn_pct::float8 as cpct, p.conn_share::float8 as cshare, x.bk_cx::float8 as sold_cx, m.km::float8 as km,   -- 0039
         m.n_biz::float8 as nb, m.n_lei::float8 as nl, m.n_bud::float8 as nu,
         -- the market's own (hidden) no-show factor, and the no-show share the engine expects in economy from the traveller mix
         mf.v as mf,
         (m.n_biz * g.noshow_biz + m.n_lei * g.noshow_lei + m.n_bud * g.noshow_bud) / nullif(m.n_biz + m.n_lei + m.n_bud, 0) * mf.v as ns,
         0::float8 as pe, 0::float8 as pb, 0::float8 as room_e, 0::float8 as room_b,
         0::float8 as xb_e, 0::float8 as xb_b, 0::float8 as xl, 0::float8 as xu,
         0::float8 as got_be, 0::float8 as got_l, 0::float8 as got_u, 0::float8 as got_b, 0::float8 as lost,
         1::float8 as fac, 0::float8 as dg, 0::float8 as disp   -- 0039
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

  -- 0039: a flight week opens for sale on its market when no airline had it on sale before (a new market, or the
  -- world's first week): travellers who would have booked earlier book now
  drop table if exists pg_temp._op;
  create temp table _op on commit drop as
  select route_id, week, min(listed) over (partition by a, b, week) = v_w as opening from pg_temp._sell;

  -- 0039: connections. An airline's two routes through one airport, both selling network-based, make a connection in
  -- the market between their other ends for the same flight week, when that market exists. Its fare is each route's
  -- share (conn_pct) of that route's own fare that week, cabin by cabin, and each route keeps its part. Travellers
  -- weigh it like a nonstop less a stop and a detour (conn_stop_*, conn_detour_*: shares of the market's reference
  -- fare, G); its frequency is the lower of the two. Connections take at most conn_share of a route's seats. The engine
  -- leaves out detours beyond conn_calc_detour times the direct distance: they sell next to nothing. Each of the two
  -- routes is at least conn_min_leg_km long.
  drop table if exists pg_temp._cn;
  create temp table _cn on commit drop as
  with legs as (
    select s.route_id, s.airline_id, s.week, s.n, s.f, s.ce, s.cb, s.bh, s.brand, s.adb, s.adl, s.adu, s.pu, s.km,
           s.cpct * s.pe as pc, case when s.sb > 0 then s.cpct * s.pb end as pcb,
           least(s.room_e, greatest(0, s.cshare * s.se * (1 + s.ob * s.ns) - s.sold_cx)) > 0.5 as ok_e,
           s.sb > 0 and s.room_b > 0.5 as ok_b,
           h.hub, case when s.a = h.hub then s.b else s.a end as far
      from pg_temp._sell s cross join lateral (values (s.a), (s.b)) h(hub)
     where s.nw and s.km >= g.conn_min_leg_km)   -- a hop to the next airport in the same city connects nobody
  select l1.airline_id, l1.week, l1.n, l1.route_id as r1, l2.route_id as r2, l1.hub,
         m.a, m.b, m.intl, m.km::float8 as km, m.ref_fare::float8 as ref,
         m.n_biz::float8 as nb, m.n_lei::float8 as nl, m.n_bud::float8 as nu,
         (l1.km + l2.km) / m.km as det,
         least(l1.f, l2.f) as f, least(l1.ce, l2.ce) as ce, least(l1.cb, l2.cb) as cb, greatest(l1.bh, l2.bh) as bh,
         l1.brand, (l1.adb + l2.adb) / 2 as adb, (l1.adl + l2.adl) / 2 as adl, (l1.adu + l2.adu) / 2 as adu,
         greatest(l1.pu, l2.pu) as pu,
         l1.pc as pe1, l2.pc as pe2, l1.pcb as pb1, l2.pcb as pb2,
         l1.ok_e and l2.ok_e as ok_e, l1.ok_b and l2.ok_b as ok_b,
         o1.opening and o2.opening as opening,
         0::float8 as xb_e, 0::float8 as xb_b, 0::float8 as xl, 0::float8 as xu
    from legs l1
    join legs l2 on l2.airline_id = l1.airline_id and l2.week = l1.week and l2.hub = l1.hub and l1.far < l2.far
    join public.markets m on m.a = l1.far and m.b = l2.far
    join pg_temp._op o1 on o1.route_id = l1.route_id and o1.week = l1.week
    join pg_temp._op o2 on o2.route_id = l2.route_id and o2.week = l2.week
   where (l1.ok_e and l2.ok_e or l1.ok_b and l2.ok_b)
     and l1.km + l2.km <= g.conn_calc_detour * m.km;
  update pg_temp._cn set
    xb_e = case when ok_e then game.sell_x(g.seg_biz_a - g.seg_biz_price * ((pe1 + pe2) / ref + adb + g.conn_stop_biz + g.conn_detour_biz * (det - 1))
             + g.seg_biz_freq * ln(1 + f) + g.seg_biz_comfort * ce * sqrt(bh) + g.seg_biz_brand * (brand - 50) / 50 + pu, g.nest_lambda) else 0 end,
    xb_b = case when ok_b then game.sell_x(g.seg_biz_a + g.seg_biz_cabin_a - g.seg_biz_price * ((pb1 + pb2) / (ref * g.biz_fare_mult) + g.conn_stop_biz
             + g.conn_detour_biz * (det - 1)) + g.seg_biz_freq * ln(1 + f) + g.seg_biz_comfort * cb * sqrt(bh) + g.seg_biz_brand * (brand - 50) / 50 + pu,
             g.nest_lambda) else 0 end,
    xl   = case when ok_e then game.sell_x(g.seg_lei_a - g.seg_lei_price * ((pe1 + pe2) / ref + adl + g.conn_stop_lei + g.conn_detour_lei * (det - 1))
             + g.seg_lei_freq * ln(1 + f) + g.seg_lei_comfort * ce * sqrt(bh) + g.seg_lei_brand * (brand - 50) / 50 + pu, g.nest_lambda) else 0 end,
    xu   = case when ok_e then game.sell_x(g.seg_bud_a - g.seg_bud_price * ((pe1 + pe2) / ref + adu + g.conn_stop_bud + g.conn_detour_bud * (det - 1))
             + g.seg_bud_freq * ln(1 + f) + g.seg_bud_comfort * ce * sqrt(bh) + g.seg_bud_brand * (brand - 50) / 50 + pu, g.nest_lambda) else 0 end;

  -- 0039: airlines outside the world. On a market with neither end in the world's home region, travellers also have
  -- the real airlines that fly it (outside_*, G): the reference fare, outside_freq flights a day, one stop beyond
  -- outside_nonstop_km. They have every seat they need, and their passengers are not counted.
  drop table if exists pg_temp._ox;
  create temp table _ox on commit drop as
  select q.a, q.b, q.week, q.n, q.intl, q.nb, q.nl, q.nu, q.opening,
         game.sell_x(g.seg_biz_a - g.seg_biz_price * (o.fare + case when q.km > g.outside_nonstop_km then g.conn_stop_biz else 0 end)
           + g.seg_biz_freq * ln(1 + g.outside_freq) + g.seg_biz_comfort * g.outside_comfort * sqrt(o.bh) + g.seg_biz_brand * (g.outside_brand - 50) / 50, g.nest_lambda) as xb,
         game.sell_x(g.seg_lei_a - g.seg_lei_price * (o.fare + case when q.km > g.outside_nonstop_km then g.conn_stop_lei else 0 end)
           + g.seg_lei_freq * ln(1 + g.outside_freq) + g.seg_lei_comfort * g.outside_comfort * sqrt(o.bh) + g.seg_lei_brand * (g.outside_brand - 50) / 50, g.nest_lambda) as xl,
         game.sell_x(g.seg_bud_a - g.seg_bud_price * (o.fare + case when q.km > g.outside_nonstop_km then g.conn_stop_bud else 0 end)
           + g.seg_bud_freq * ln(1 + g.outside_freq) + g.seg_bud_comfort * g.outside_comfort * sqrt(o.bh) + g.seg_bud_brand * (g.outside_brand - 50) / 50, g.nest_lambda) as xu
    from (select a, b, week, n, intl, nb, nl, nu, km, bool_and(opening) as opening from pg_temp._cn
           group by a, b, week, n, intl, nb, nl, nu, km) q
    join public.airports pa on pa.iata = q.a
    join public.airports pb on pb.iata = q.b
    cross join lateral (select coalesce(rw.fare_index, 1)::float8 * g.outside_fare as fare, q.km / 830 + 0.6 as bh) o
   where g.outside_on > 0
     and pa.home is distinct from game.world_region(p_world) and pb.home is distinct from game.world_region(p_world);

  -- festivals and events (G): each day of a flight week inside an event adds a seventh of the event's extra demand
  drop table if exists pg_temp._ev;
  create temp table _ev on commit drop as
  select q.a, q.b, q.week,
         (1 + sum(e.biz - 1) / 7.0)::float8 as fb, (1 + sum(e.lei - 1) / 7.0)::float8 as fl, (1 + sum(e.bud - 1) / 7.0)::float8 as fu
    from (select a, b, week, intl from pg_temp._sell union select a, b, week, intl from pg_temp._cn) q   -- 0039: and connections' markets
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

  -- 0041: gems, the world's hidden demand: each flight week of a market a gem touches is multiplied by it
  drop table if exists pg_temp._gm;
  create temp table _gm on commit drop as
  select q.a, q.b, r.week,
         exp(sum(ln(greatest(0.2, 1 + (r.m - 1) * r.w_biz)))) as fb, exp(sum(ln(greatest(0.2, 1 + (r.m - 1) * r.w_lei)))) as fl,
         exp(sum(ln(greatest(0.2, 1 + (r.m - 1) * r.w_bud)))) as fu
    from (select a, b from pg_temp._sell union select a, b from pg_temp._cn) q
    join public.airports pa on pa.iata = q.a
    join public.airports pb on pb.iata = q.b
    join game.gem_rows(p_world, v_w, v_w + v_h - 1) r
      on (r.scope = 'airport' and r.a in (q.a, q.b)) or (r.scope = 'pair' and r.a = q.a and r.b = q.b)
      or (r.scope = 'country' and ((pa.country = r.country and pb.home = game.world_region(p_world))
                                or (pb.country = r.country and pa.home = game.world_region(p_world))))
   group by q.a, q.b, r.week;

  -- travellers who decide this week on each market and flight week: the week's demand (7 days, season of its middle day,
  -- growth, a swing fixed per market and week) times the share of each type who book n weeks ahead (when the week first
  -- opens on its market, everyone who would have booked by then). 0039: market by market, with every choice in it
  -- (nonstops, connections, airlines outside the world) in one nest
  drop table if exists pg_temp._mkt;
  create temp table _mkt on commit drop as
  with u as (
    select z.a, z.b, z.week, z.n, z.intl, z.nb, z.nl, z.nu, o.opening, z.xb_e + z.xb_b as xb, z.xl, z.xu
      from pg_temp._sell z join pg_temp._op o on o.route_id = z.route_id and o.week = z.week
    union all
    select a, b, week, n, intl, nb, nl, nu, opening, xb_e + xb_b, xl, xu from pg_temp._cn
    union all
    select a, b, week, n, intl, nb, nl, nu, opening, xb, xl, xu from pg_temp._ox),
  mk as (
    select a, b, week, n, intl, nb, nl, nu, bool_and(opening) as opening, sum(xb) as xb, sum(xl) as xl, sum(xu) as xu
      from u group by a, b, week, n, intl, nb, nl, nu),
  wk as (
    select w, (w - 1) * 7 + 4 as mid,
           power(1 + g.growth_year, ((w - 1) * 7 + 3) / 364.0) * rw.demand_scale as grow,
           power(1 + coalesce(g.growth_year_intl, g.growth_year), ((w - 1) * 7 + 3) / 364.0) * rw.demand_scale as grow_i
      from generate_series(v_w, v_w + v_h - 1) w),
  sf as (
    select wk.w, wk.grow, wk.grow_i, s.biz, s.lei, s.bud from wk join public.season_factors s
      on s.month = ((g.season_start_month::int - 1 + (((wk.mid - 1) % 364) * 12) / 364) % 12) + 1)
  select mk.a, mk.b, mk.week,
         7 * mk.nb * sf.biz * coalesce(ev.fb, 1) * coalesce(gm.fb, 1) * k.v * case when mk.opening then c.pre_b + c.arr_b else c.arr_b end as ab,
         7 * mk.nl * sf.lei * coalesce(ev.fl, 1) * coalesce(gm.fl, 1) * k.v * case when mk.opening then c.pre_l + c.arr_l else c.arr_l end as al_,
         7 * mk.nu * sf.bud * coalesce(ev.fu, 1) * coalesce(gm.fu, 1) * k.v * case when mk.opening then c.pre_u + c.arr_u else c.arr_u end as au,
         game.sell_k(mk.xb, g.nest_lambda) as kb, game.sell_k(mk.xl, g.nest_lambda) as kl, game.sell_k(mk.xu, g.nest_lambda) as ku
    from mk
    join sf on sf.w = mk.week
    join pg_temp._curve c on c.n = mk.n
    left join pg_temp._ev ev on ev.a = mk.a and ev.b = mk.b and ev.week = mk.week
    left join pg_temp._gm gm on gm.a = mk.a and gm.b = mk.b and gm.week = mk.week   -- 0041
    cross join lateral (select case when mk.intl then sf.grow_i else sf.grow end * exp(g.demand_noise_sd / sqrt(7) * game.hash_normal(p_world::text || mk.a || mk.b || mk.week)
                                             - g.demand_noise_sd ^ 2 / 14) as v) k;

  -- what each nonstop and each connection is asked for
  drop table if exists pg_temp._dem;
  create temp table _dem on commit drop as
  select z.route_id, z.week, k.ab * z.xb_e * k.kb as d_be, k.ab * z.xb_b * k.kb as d_bb, k.al_ * z.xl * k.kl as d_l, k.au * z.xu * k.ku as d_u
    from pg_temp._sell z join pg_temp._mkt k on k.a = z.a and k.b = z.b and k.week = z.week;
  drop table if exists pg_temp._cd;
  create temp table _cd on commit drop as
  select c.r1, c.r2, c.week, c.a, c.b, c.pe1, c.pe2, c.pb1, c.pb2, c.xb_e, c.xl, c.xu,
         k.ab * c.xb_e * k.kb as dbe, k.ab * c.xb_b * k.kb as dbb, k.al_ * c.xl * k.kl as dl, k.au * c.xu * k.ku as du,
         0::float8 as fe, 0::float8 as fb
    from pg_temp._cn c join pg_temp._mkt k on k.a = c.a and k.b = c.b and k.week = c.week;

  -- 0039: seats. Each route's seats go to its own travellers and its connections in proportion; connections first within
  -- conn_share of the seats. A connection gets what both its routes can give it; its own travellers then get the rest.
  drop table if exists pg_temp._lg;
  create temp table _lg on commit drop as
  with cl as (
    select v.r as route_id, d.week, sum(d.dbe + d.dl + d.du) as ce_d, sum(d.dbb) as cb_d
      from pg_temp._cd d cross join lateral (values (d.r1), (d.r2)) v(r) group by v.r, d.week)
  select z.route_id, z.week, z.room_e, z.room_b,
         greatest(0, z.cshare * z.se * (1 + z.ob * z.ns) - z.sold_cx) as croom,
         d.d_be, d.d_bb, d.d_l, d.d_u,
         g.biz_downgrade_share * greatest(d.d_bb - z.room_b, 0) as dg0,
         coalesce(cl.ce_d, 0) as ce_d, coalesce(cl.cb_d, 0) as cb_d,
         1::float8 as fce, 1::float8 as fcb, 0::float8 as a_e, 0::float8 as a_b
    from pg_temp._sell z
    join pg_temp._dem d on d.route_id = z.route_id and d.week = z.week
    left join cl on cl.route_id = z.route_id and cl.week = z.week;
  update pg_temp._lg l set
    fce = case when ce_d > 0 then least(1, croom / ce_d) * least(1, room_e / nullif(d_be + dg0 + d_l + d_u + ce_d * least(1, croom / ce_d), 0)) else 1 end,
    fcb = case when cb_d > 0 then least(1, room_b / nullif(d_bb + cb_d, 0)) else 1 end;
  update pg_temp._cd d set fe = least(l1.fce, l2.fce), fb = least(l1.fcb, l2.fcb)
    from pg_temp._lg l1, pg_temp._lg l2
   where l1.route_id = d.r1 and l1.week = d.week and l2.route_id = d.r2 and l2.week = d.week;
  update pg_temp._lg l set a_e = x.ae, a_b = x.abz
    from (select v.r, d.week, sum((d.dbe + d.dl + d.du) * d.fe) as ae, sum(d.dbb * d.fb) as abz
            from pg_temp._cd d cross join lateral (values (d.r1), (d.r2)) v(r) group by v.r, d.week) x
   where x.r = l.route_id and x.week = l.week;

  -- business cabin first (after its connections); part of its overflow takes economy on the same airline
  with bz as (
    select l.route_id, l.week, l.d_be, l.d_l, l.d_u, l.d_bb, l.a_e,
           least(l.d_bb, greatest(0, l.room_b - l.a_b)) as got_b,
           g.biz_downgrade_share * greatest(l.d_bb - least(l.d_bb, greatest(0, l.room_b - l.a_b)), 0) as dg,
           greatest(0, l.room_e - l.a_e) as re
      from pg_temp._lg l)
  update pg_temp._sell z
     set got_b = bz.got_b,
         got_be = (bz.d_be + bz.dg) * e.fac, got_l = bz.d_l * e.fac, got_u = bz.d_u * e.fac,
         lost = (bz.d_bb - bz.got_b - bz.dg) + (bz.d_be + bz.dg + bz.d_l + bz.d_u) * (1 - e.fac),
         fac = e.fac, dg = bz.dg,
         disp = case when bz.a_e > 0 and bz.d_be + bz.dg + bz.d_l + bz.d_u > bz.re
                     then least(bz.d_be + bz.dg + bz.d_l + bz.d_u - bz.re, bz.a_e) else 0 end
    from bz cross join lateral (select case when bz.d_be + bz.dg + bz.d_l + bz.d_u > bz.re
                                            then bz.re / (bz.d_be + bz.dg + bz.d_l + bz.d_u) else 1 end as fac) e
   where bz.route_id = z.route_id and bz.week = z.week;

  -- 0039: travellers turned away by a full nonstop choose again among the connections on their market (and the airlines
  -- outside the world), in the seats the connections' routes still have
  drop table if exists pg_temp._rc;
  create temp table _rc on commit drop as
  with lost as (
    select z.a, z.b, z.week, sum((d.d_be + z.dg) * (1 - z.fac)) as lbe, sum(d.d_l * (1 - z.fac)) as ll, sum(d.d_u * (1 - z.fac)) as lu
      from pg_temp._sell z join pg_temp._dem d on d.route_id = z.route_id and d.week = z.week
     where z.fac < 0.999
     group by z.a, z.b, z.week),
  sx as (
    select d.a, d.b, d.week, sum(d.xb_e) as sb, sum(d.xl) as sl, sum(d.xu) as su from pg_temp._cd d group by d.a, d.b, d.week),
  so as (
    select s.a, s.b, s.week, s.sb + coalesce(o.xb, 0) as sb, s.sl + coalesce(o.xl, 0) as sl, s.su + coalesce(o.xu, 0) as su
      from sx s left join pg_temp._ox o on o.a = s.a and o.b = s.b and o.week = s.week)
  select d.r1, d.r2, d.week,
         lo.lbe * d.xb_e * game.sell_k(so.sb, g.nest_lambda) as rbe, lo.ll * d.xl * game.sell_k(so.sl, g.nest_lambda) as rl,
         lo.lu * d.xu * game.sell_k(so.su, g.nest_lambda) as ru, 0::float8 as fr
    from pg_temp._cd d
    join lost lo on lo.a = d.a and lo.b = d.b and lo.week = d.week
    join so on so.a = d.a and so.b = d.b and so.week = d.week
   where g.conn_recapture > 0;
  with left_ as (
    select l.route_id, l.week,
           greatest(0, least(l.room_e - l.a_e - z.got_be - z.got_l - z.got_u, l.croom - l.a_e)) as lo
      from pg_temp._lg l join pg_temp._sell z on z.route_id = l.route_id and z.week = l.week),
  need as (
    select v.r, r.week, sum(r.rbe + r.rl + r.ru) as nd from pg_temp._rc r cross join lateral (values (r.r1), (r.r2)) v(r) group by v.r, r.week),
  f as (
    select n.r, n.week, case when n.nd > 0 then least(1, lf.lo / n.nd) else 1 end as f
      from need n join left_ lf on lf.route_id = n.r and lf.week = n.week)
  update pg_temp._rc r set fr = least(f1.f, f2.f)
    from f f1, f f2 where f1.r = r.r1 and f1.week = r.week and f2.r = r.r2 and f2.week = r.week;

  -- what each route carries for connections this week: travellers by type, its part of their fares, and the locals its
  -- connections left without a seat
  drop table if exists pg_temp._cl;
  create temp table _cl on commit drop as
  with t as (
    select d.r1 as route_id, d.week, d.dbe * d.fe as cbe, d.dl * d.fe as cl, d.du * d.fe as cu, d.dbb * d.fb as cb, d.pe1 as pe, d.pb1 as pb from pg_temp._cd d
    union all
    select d.r2, d.week, d.dbe * d.fe, d.dl * d.fe, d.du * d.fe, d.dbb * d.fb, d.pe2, d.pb2 from pg_temp._cd d
    union all
    select r.r1, r.week, r.rbe * r.fr, r.rl * r.fr, r.ru * r.fr, 0, d.pe1, null from pg_temp._rc r join pg_temp._cd d on d.r1 = r.r1 and d.r2 = r.r2 and d.week = r.week
    union all
    select r.r2, r.week, r.rbe * r.fr, r.rl * r.fr, r.ru * r.fr, 0, d.pe2, null from pg_temp._rc r join pg_temp._cd d on d.r1 = r.r1 and d.r2 = r.r2 and d.week = r.week)
  select route_id, week, sum(cbe) as cbe, sum(cl) as cl, sum(cu) as cu, sum(cb) as cb,
         sum((cbe + cl + cu) * pe) as rev_e, sum(cb * coalesce(pb, 0)) as rev_b
    from t group by route_id, week;

  update public.route_weeks x
     set price_e = z.pe, price_b = case when z.sb > 0 then z.pb end, adj_e = z.adj_e, adj_b = z.adj_b, strategy = z.strategy,
         bk_be = x.bk_be + z.got_be + coalesce(c.cbe, 0), bk_l = x.bk_l + z.got_l + coalesce(c.cl, 0),
         bk_u = x.bk_u + z.got_u + coalesce(c.cu, 0), bk_b = x.bk_b + z.got_b + coalesce(c.cb, 0),
         rev_e = x.rev_e + ((z.got_be + z.got_l + z.got_u) * z.pe + coalesce(c.rev_e, 0)) * z.fxm,
         rev_b = x.rev_b + (z.got_b * z.pb + coalesce(c.rev_b, 0)) * z.fxm,
         sold_wk = z.got_be + z.got_l + z.got_u + z.got_b + coalesce(c.cbe + c.cl + c.cu + c.cb, 0), spill = x.spill + z.lost,
         bk_cx = x.bk_cx + coalesce(c.cbe + c.cl + c.cu, 0), bk_cxb = x.bk_cxb + coalesce(c.cb, 0),
         rev_cx = x.rev_cx + coalesce(c.rev_e + c.rev_b, 0) * z.fxm, disp = x.disp + z.disp
    from pg_temp._sell z left join pg_temp._cl c on c.route_id = z.route_id and c.week = z.week
   where x.route_id = z.route_id and x.week = z.week;
  -- weeks with no seats on sale this week sold nothing
  update public.route_weeks x set sold_wk = 0
   where x.world_id = p_world and x.week >= v_w and x.flown_e is null and x.sold_wk <> 0
     and not exists (select 1 from pg_temp._sell z where z.route_id = x.route_id and z.week = x.week);
  insert into pg_temp._money (airline_id, sales)
  select z.airline_id, 2 * sum((((z.got_be + z.got_l + z.got_u) * z.pe + z.got_b * z.pb) + coalesce(c.rev_e + c.rev_b, 0)) * z.fxm)
    from pg_temp._sell z left join pg_temp._cl c on c.route_id = z.route_id and c.week = z.week
   group by z.airline_id;

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

-- The route study (from 0037), with gems (0041).
alter table public.route_studies add column gem_note text;
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
  v_g1 int; v_g2 int; v_gmax float8; v_gmin float8; v_gids bigint[]; v_gpk float8;   -- 0041
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

  -- 0041: gems on the market in the next 26 weeks: a quick study notices something, a full one sizes it; either way the
  -- airline now knows of it
  select min(x.week), max(x.week), max(x.m), min(x.m), array_agg(distinct x.id) into v_g1, v_g2, v_gmax, v_gmin, v_gids
    from game.gem_market(rw.id, m.a, m.b, game.week_of(v_day), game.week_of(v_day) + 25) x where abs(x.m - 1) > 0.05;
  if v_gids is not null then
    v_gpk := case when v_gmax - 1 >= 1 - v_gmin then v_gmax else v_gmin end;
    s.gem_note := case when p_depth = 'quick' then 'Something unusual is coming on this market in the next six months.'
      else format('Unusual demand ahead: about %s%s%% at its peak, between weeks %s and %s.', case when v_gpk >= 1 then '+' else '-' end,
                  round(abs(v_gpk - 1) * 100 * greatest(0.3, 1 + game.param('gem_study_width') / 2 * game.rand_normal())), v_g1, v_g2) end;
    update game.world_gems set known_by = array_append(known_by, p_airline) where id = any (v_gids) and not p_airline = any (known_by);
  end if;

  insert into public.route_studies (airline_id, world_id, a, b, game_day, depth, carriers, flying_lo, flying_hi, turned_lo, turned_hi,
                                    lf_lo, lf_hi, untapped_lo, untapped_hi, biz_share, lei_share, bud_share, next_qtr, gem_note)
  values (s.airline_id, s.world_id, s.a, s.b, s.game_day, s.depth, s.carriers, s.flying_lo, s.flying_hi, s.turned_lo, s.turned_hi,
          s.lf_lo, s.lf_hi, s.untapped_lo, s.untapped_hi, s.biz_share, s.lei_share, s.bud_share, s.next_qtr, s.gem_note)
  returning id into s.id;
  return to_jsonb(s);
end $function$;

-- The hub and route study (from 0040), with gems (0041).
create or replace function public.hub_study(p_airline uuid, p_hub text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  v_hub text := upper(p_hub);
  v_day int; v_cost numeric; v_w numeric; v_grow numeric; v_grow_i numeric; v_fi numeric; v_region text;
  v_sb numeric; v_sl numeric; v_su numeric; v_lam float8 := game.param('nest_lambda');
  v_res jsonb; v_sug text[]; v_w0 int;
begin
  rw := game.actor(p_airline); v_day := rw.game_day + 1; v_region := game.world_region(rw.id); v_w0 := game.week_of(v_day);
  if not exists (select 1 from public.airports where iata = v_hub and v_region = any (seen_in)) then
    raise exception 'There is no airport % in this world', p_hub;
  end if;
  v_cost := game.param('hub_study_inr');
  v_w := game.param('hub_study_width');
  perform game.book(p_airline, v_day, -v_cost, 'study', format('Hub and route study, %s', v_hub), -v_cost);

  v_grow := power(1 + game.wparam(rw.id, 'growth_year'), (v_day - 1) / 364.0) * rw.demand_scale;
  v_grow_i := power(1 + game.wparam(rw.id, 'growth_year_intl'), (v_day - 1) / 364.0) * rw.demand_scale;
  v_fi := coalesce(rw.fare_index, 1);
  select f.biz, f.lei, f.bud into v_sb, v_sl, v_su from public.season_factors f
   where f.month = ((game.param('season_start_month')::int - 1 + (((v_day - 1) % 364) * 12) / 364) % 12) + 1;

  -- every route out of the hub with a market of its own, to an airport this world shows
  drop table if exists pg_temp._hs;
  create temp table _hs on commit drop as
  select case when m.a = v_hub then m.b else m.a end as x, m.km::float8 as km, m.ref_fare::float8 as ref, m.intl,
         m.n_biz::float8 * v_sb * coalesce(gg.gb, 1) as nb, m.n_lei::float8 * v_sl * coalesce(gg.gl, 1) as nl,
         m.n_bud::float8 * v_su * coalesce(gg.gu, 1) as nu,   -- 0041: with the next 26 weeks' gems
         case when m.intl then v_grow_i else v_grow end as gr,
         0::float8 as loc, 0::float8 as con
    from public.markets m
    join public.airports ap on ap.iata = case when m.a = v_hub then m.b else m.a end
    left join lateral (select 1 + sum(gx.fb - 1) / 26 as gb, 1 + sum(gx.fl - 1) / 26 as gl, 1 + sum(gx.fu - 1) / 26 as gu
                         from game.gem_market(rw.id, m.a, m.b, v_w0, v_w0 + 25) gx) gg on true
   where v_hub in (m.a, m.b) and v_region = any (ap.seen_in);
  -- its own travellers a week each way: one airline, two round trips a day, reference fare (as the route study)
  update pg_temp._hs set loc = 7 * gr * (
      nb * exp(u.b) / (1 + exp(u.b)) + nl * exp(u.l) / (1 + exp(u.l)) + nu * exp(u.u) / (1 + exp(u.u)))
    from (select x as xx,
                 game.param('seg_biz_a') - game.wparam(rw.id, 'seg_biz_price') * v_fi + game.param('seg_biz_freq') * ln(3)
                   + game.param('seg_biz_comfort') * (1 / 6.0) * sqrt(km / 830 + 0.7) as b,
                 game.param('seg_lei_a') - game.wparam(rw.id, 'seg_lei_price') * v_fi + game.param('seg_lei_freq') * ln(3)
                   + game.param('seg_lei_comfort') * (1 / 6.0) * sqrt(km / 830 + 0.7) as l,
                 game.param('seg_bud_a') - game.wparam(rw.id, 'seg_bud_price') * v_fi + game.param('seg_bud_freq') * ln(3)
                   + game.param('seg_bud_comfort') * (1 / 6.0) * sqrt(km / 830 + 0.7) as u
            from pg_temp._hs) u
   where u.xx = x;

  -- the markets between two of them that a connection through the hub could serve: daily connections at
  -- hub_study_conn_pct of the two reference fares, against the world's nonstops on the market and the airlines outside it
  drop table if exists pg_temp._hp;
  create temp table _hp on commit drop as
  with nst as (
    select least(r.origin, r.dest) as a, greatest(r.origin, r.dest) as b, sum(ro.weekly_trips)::float8 / 7 as f,
           count(distinct r.airline_id) as n
      from public.routes r join public.rotations ro on ro.route_id = r.id
     where r.world_id = rw.id and r.status = 'open'
     group by 1, 2)
  select s1.x as a, s2.x as b, mk.km::float8 as km, (s1.km + s2.km) / mk.km as det,
         game.param('hub_study_conn_pct') * (s1.ref + s2.ref) / mk.ref_fare as pf,
         coalesce(nst.f, 0) as nf, coalesce(nst.n, 0) as nn,
         pa.home is distinct from v_region and pb.home is distinct from v_region and game.param('outside_on') > 0 as outside,
         mk.n_biz::float8 * v_sb * coalesce(gg.gb, 1) as nb, mk.n_lei::float8 * v_sl * coalesce(gg.gl, 1) as nl,
         mk.n_bud::float8 * v_su * coalesce(gg.gu, 1) as nu,
         case when mk.intl then v_grow_i else v_grow end as gr, 0::float8 as wk
    from pg_temp._hs s1
    join pg_temp._hs s2 on s1.x < s2.x
    join public.markets mk on mk.a = s1.x and mk.b = s2.x
    join public.airports pa on pa.iata = mk.a
    join public.airports pb on pb.iata = mk.b
    left join nst on nst.a = mk.a and nst.b = mk.b
    left join lateral (select 1 + sum(gx.fb - 1) / 26 as gb, 1 + sum(gx.fl - 1) / 26 as gl, 1 + sum(gx.fu - 1) / 26 as gu
                         from game.gem_market(rw.id, mk.a, mk.b, v_w0, v_w0 + 25) gx) gg on true
   where s1.km + s2.km <= game.param('conn_calc_detour') * mk.km
     and s1.km >= game.param('conn_min_leg_km') and s2.km >= game.param('conn_min_leg_km');
  -- travellers a week each way, the three types summed
  update pg_temp._hp p set wk = 7 * p.gr * t.v
    from (select q.a as qa, q.b as qb, sum(case s.seg when 'biz' then q.nb when 'lei' then q.nl else q.nu end
                   * game.sell_x(c.u, v_lam) * game.sell_k(game.sell_x(c.u, v_lam)
                     + case when q.nf > 0 then game.sell_x(n.u, v_lam) else 0 end
                     + case when q.outside then game.sell_x(o.u, v_lam) else 0 end, v_lam)) as v
            from pg_temp._hp q
           cross join (values ('biz'), ('lei'), ('bud')) s(seg)
           cross join lateral (select game.param('seg_' || s.seg || '_a') - game.wparam(rw.id, 'seg_' || s.seg || '_price')
                                        * (q.pf + game.param('conn_stop_' || s.seg) + game.param('conn_detour_' || s.seg) * (q.det - 1))
                                      + game.param('seg_' || s.seg || '_freq') * ln(2) as u) c
           cross join lateral (select game.param('seg_' || s.seg || '_a') - game.wparam(rw.id, 'seg_' || s.seg || '_price') * v_fi
                                      + game.param('seg_' || s.seg || '_freq') * ln(1 + q.nf) as u) n
           cross join lateral (select game.param('seg_' || s.seg || '_a') - game.wparam(rw.id, 'seg_' || s.seg || '_price')
                                        * (v_fi * game.param('outside_fare') + case when q.km > game.param('outside_nonstop_km') then game.param('conn_stop_' || s.seg) else 0 end)
                                      + game.param('seg_' || s.seg || '_freq') * ln(1 + game.param('outside_freq'))
                                      + game.param('seg_' || s.seg || '_brand') * (game.param('outside_brand') - 50) / 50 as u) o
           group by q.a, q.b) t
   where t.qa = p.a and t.qb = p.b;
  update pg_temp._hs s set con = coalesce((select sum(p.wk) from pg_temp._hp p where s.x in (p.a, p.b)), 0);

  -- the suggested network: the best hub_study_spokes routes by own and connecting travellers
  select array_agg(x order by loc + con desc) into v_sug
    from (select x, loc, con from pg_temp._hs order by loc + con desc limit game.param('hub_study_spokes')::int) q;

  -- each figure gets its own error
  with mine as (
    select case when r.origin = v_hub then r.dest else r.origin end as x, pl.network
      from public.routes r join public.route_plans pl on pl.route_id = r.id
     where r.airline_id = p_airline and r.status = 'open' and v_hub in (r.origin, r.dest)),
  fly as (
    select case when r.origin = v_hub then r.dest else r.origin end as x, count(distinct r.airline_id) as n
      from public.routes r where r.world_id = rw.id and r.status = 'open' and v_hub in (r.origin, r.dest)
       and exists (select 1 from public.rotations ro where ro.route_id = r.id)
     group by 1),
  e as (select x, greatest(0.3, 1 + v_w / 2 * game.rand_normal()) as e1, greatest(0.3, 1 + v_w / 2 * game.rand_normal()) as e2 from pg_temp._hs)
  select jsonb_build_object(
    'hub', v_hub, 'game_day', v_day, 'cost_inr', v_cost, 'width', v_w,
    'spokes', (select coalesce(jsonb_agg(jsonb_build_object(
                  'x', s.x, 'km', round(s.km), 'intl', s.intl, 'own_wk', round(s.loc * e.e1), 'conn_wk', round(s.con * e.e2),
                  'carriers', coalesce(f.n, 0), 'yours', mi.x is not null, 'network', coalesce(mi.network, false),
                  'suggested', s.x = any (v_sug)) order by s.loc + s.con desc), '[]'::jsonb)
                 from (select * from pg_temp._hs order by loc + con desc limit game.param('hub_study_list')::int) s
                 join e on e.x = s.x
                 left join fly f on f.x = s.x
                 left join mine mi on mi.x = s.x),
    'markets', (select coalesce(jsonb_agg(jsonb_build_object(
                  'a', p.a, 'b', p.b, 'conn_wk', round(p.wk * greatest(0.3, 1 + v_w / 2 * game.rand_normal())),
                  'detour', round(p.det::numeric, 2), 'nonstops', p.nn, 'outside', p.outside) order by p.wk desc), '[]'::jsonb)
                 from (select * from pg_temp._hp order by wk desc limit game.param('hub_study_markets')::int) p),
    'now', (select jsonb_build_object('spokes', count(*),
                     'conn_wk', round(coalesce((select sum(p.wk) from pg_temp._hp p
                                                 where p.a in (select x from mine) and p.b in (select x from mine)), 0)
                                      * greatest(0.3, 1 + v_w / 2 * game.rand_normal())))
              from mine),
    'suggested', jsonb_build_object('spokes', to_jsonb(v_sug),
                   'conn_wk', round(coalesce((select sum(p.wk) from pg_temp._hp p where p.a = any (v_sug) and p.b = any (v_sug)), 0)
                                    * greatest(0.3, 1 + v_w / 2 * game.rand_normal()))),
    -- 0041: the gems at the hub and on its routes in the next 26 weeks
    'gems', (select coalesce(jsonb_agg(jsonb_build_object('kind', q.name, 'at', q.at, 'from_week', q.w1, 'to_week', q.w2) order by q.w1), '[]'::jsonb)
               from (select k.name, coalesce(case when gr.scope = 'pair' then gr.a || '-' || gr.b end, gr.a) as at, min(gr.week) as w1, max(gr.week) as w2
                       from game.gem_rows(rw.id, v_w0, v_w0 + 25) gr join public.gem_kinds k on k.key = gr.kind
                      where abs(gr.m - 1) > 0.05
                        and ((gr.scope = 'airport' and (gr.a = v_hub or gr.a in (select x from pg_temp._hs order by loc + con desc limit game.param('hub_study_list')::int)))
                          or (gr.scope = 'pair' and v_hub in (gr.a, gr.b)))
                      group by k.name, gr.scope, gr.a, gr.b) q),
    'rivals', jsonb_build_object(
      'flying', (select count(distinct r.airline_id) from public.routes r
                  where r.world_id = rw.id and r.status = 'open' and r.airline_id <> p_airline and v_hub in (r.origin, r.dest)),
      'connecting', (select count(distinct r.airline_id) from public.routes r join public.route_plans pl on pl.route_id = r.id
                      where r.world_id = rw.id and r.status = 'open' and r.airline_id <> p_airline and v_hub in (r.origin, r.dest)
                        and pl.network)))
    into v_res;

  update game.world_gems g set known_by = array_append(g.known_by, p_airline)
   where g.world_id = rw.id and not p_airline = any (g.known_by)
     and g.id in (select gr.id from game.gem_rows(rw.id, v_w0, v_w0 + 25) gr
                   where abs(gr.m - 1) > 0.05
                     and ((gr.scope = 'airport' and (gr.a = v_hub or gr.a in (select x from pg_temp._hs order by loc + con desc limit game.param('hub_study_list')::int)))
                       or (gr.scope = 'pair' and v_hub in (gr.a, gr.b))));
  insert into public.hub_studies (airline_id, world_id, hub, game_day, cost_inr, result)
  values (p_airline, rw.id, v_hub, v_day, v_cost, v_res);
  return v_res;
end $$;

-- The consultant's look-ups (from 0037), with rumours of gems (0041).
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
      'rupee_per_dollar', round(w.fx_inr_usd, 2), 'fuel_inr_kg', round(w.fuel_inr_kg, 1),
      'market_hints', game.gem_hints(w.id, v_a, game.week_of(v_d + 1)))   -- 0041: rumours of gems
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

insert into public.consultant_playbook (version, model, body)
select p.version + 1, p.model, p.body || E'\n\nThe overview may carry market_hints: rumours of unusual demand coming in the next weeks (a big gathering, a pilgrim or wedding season, a place gone viral, visas eased or tightened, a boom city, students on the move). They are vague and can be wrong or late. Mention one only as a possibility worth a route or hub study, never as a fact, and never promise a number.'
  from public.consultant_playbook p where p.active order by p.version desc limit 1;

-- Computer-run airlines' network selling (from 0040), selling into the gems they know of (0041).
alter table public.route_plans add column gem_prev text, add column gem_until int;
create or replace function game.bot_network(p_world uuid, p_week int) returns void
language plpgsql set search_path = '' as $$
declare
  r record;
begin
  -- routes not yet set: network-based from the start, at the moderate setting
  for r in select p.route_id, p.airline_id from public.route_plans p
             join public.routes rt on rt.id = p.route_id and rt.world_id = p_world and rt.status = 'open'
             join public.airlines al on al.id = rt.airline_id and al.is_ai and al.status = 'active'
            where p.net_day is null loop
    perform public.set_network(r.airline_id, r.route_id, true, game.param('bot_net_pct')::numeric, game.param('bot_net_share')::numeric);
  end loop;
  -- 0041: Top fares on routes touched by a gem they know of (a clue in the news, or their own studies), this week or
  -- the next three; when it is over, back to their own way of selling
  update public.route_plans pl set strategy = pl.gem_prev, gem_prev = null, gem_until = null
    from public.routes rt
   where rt.id = pl.route_id and rt.world_id = p_world and pl.gem_until is not null and pl.gem_until < p_week;
  update public.route_plans pl set gem_prev = coalesce(pl.gem_prev, pl.strategy), strategy = 'top', gem_until = x.until
    from (select rt.id, max(gx.week) as until
            from public.routes rt
            join public.airlines al on al.id = rt.airline_id and al.is_ai and al.status = 'active'
           cross join lateral game.gem_market(p_world, rt.origin, rt.dest, p_week, p_week + 3) gx
            join game.world_gems wg on wg.id = gx.id
           where rt.world_id = p_world and rt.status = 'open' and gx.m > 1.1 and (wg.clued or rt.airline_id = any (wg.known_by))
           group by rt.id) x
   where pl.route_id = x.id;
  perform game.bot_hub(p_world, p_week);   -- 0040: once a year, a hub study and the best route it suggests
  if p_week % 13 <> 0 then return; end if;
  -- every 13 weeks, each route's last 13 flown weeks: when the locals its connections turned away were worth more than
  -- bot_net_disp_ratio of what the connections paid it, fewer seats for connections at a higher share of the fare; when
  -- the route flew under bot_net_lf_low full, more seats at a lower share
  for r in select p.route_id, p.airline_id, p.conn_pct, p.conn_share, sum(w.rev_cx) as rcx,
                  sum(w.disp * w.rev_e / nullif(w.bk_be + w.bk_l + w.bk_u, 0)) as dv,
                  sum(coalesce(w.flown_e, 0) + coalesce(w.flown_b, 0)) / nullif(sum(w.seats_e + w.seats_b), 0) as lf
             from public.route_plans p
             join public.routes rt on rt.id = p.route_id and rt.world_id = p_world and rt.status = 'open'
             join public.airlines al on al.id = rt.airline_id and al.is_ai and al.status = 'active'
             join public.route_weeks w on w.route_id = p.route_id and w.flown_e is not null and w.week > p_week - 14
            where p.network
            group by p.route_id, p.airline_id, p.conn_pct, p.conn_share loop
    if coalesce(r.dv, 0) > game.param('bot_net_disp_ratio') * coalesce(r.rcx, 0) and r.conn_share > 0.05 then
      perform public.set_network(r.airline_id, r.route_id, true, least(game.param('conn_pct_max')::numeric, r.conn_pct + 0.05),
                                 greatest(0, r.conn_share - 0.1));
    elsif r.lf < game.param('bot_net_lf_low') and r.conn_share < game.param('bot_net_share_max') then
      perform public.set_network(r.airline_id, r.route_id, true, greatest(game.param('conn_pct_min')::numeric, r.conn_pct - 0.05),
                                 least(game.param('bot_net_share_max')::numeric, r.conn_share + 0.1));
    end if;
  end loop;
end $$;
