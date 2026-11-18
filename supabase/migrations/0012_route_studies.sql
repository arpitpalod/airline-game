-- Route studies (owner request, 19 Nov 2026; spec section 18): pay to learn what the market on a city pair is doing,
-- as a range rather than an exact figure. A quick study is cheap and wide, a full one dear and narrow, and each
-- estimate carries its own error, so a study can be off. What it reports is not otherwise visible: how many
-- travellers fly the route with all airlines, how many are turned away, and how full the airlines are; for a
-- route nobody flies, how many would fly with one airline at the reference fare. Adds only.

insert into public.game_params (key, num, note) values
('study_quick_inr', 500000, 'cost of a quick route study'),
('study_full_inr', 4000000, 'cost of a full route study'),
('study_quick_width', 0.35, 'a quick study reports its estimate plus or minus this share'),
('study_full_width', 0.12, 'a full study reports its estimate plus or minus this share'),
('study_valid_days', 91, 'days a study is shown as current in the app')
on conflict (key) do update set num = excluded.num, note = excluded.note;

create table public.route_studies (
  id          bigint generated always as identity primary key,
  airline_id  uuid not null references public.airlines on delete cascade,
  world_id    uuid not null references public.worlds on delete cascade,
  a           text not null references public.airports,
  b           text not null references public.airports,
  game_day    int not null,
  depth       text not null check (depth in ('quick', 'full')),
  carriers    int not null,       -- airlines flying the city pair when the study was made
  flying_lo   int, flying_hi int, -- travellers a day, each way, with all airlines, over the last 28 days
  turned_lo   int, turned_hi int, -- travellers a day, each way, who found no seat
  lf_lo       numeric, lf_hi numeric,          -- share of seats filled, all airlines
  untapped_lo int, untapped_hi int,            -- nobody flies it: travellers a day, each way, who would fly at the
                                               -- reference fare with one airline flying twice a day
  biz_share   numeric, lei_share numeric, bud_share numeric,  -- traveller mix (full study)
  next_qtr    numeric                          -- demand a quarter ahead against now, as a ratio (full study)
);
create index route_studies_airline_idx on public.route_studies (airline_id, a, b);

alter table public.route_studies enable row level security;
grant select on public.route_studies to authenticated;
create policy read_own on public.route_studies for select to authenticated
  using (airline_id in (select id from public.airlines where user_id = (select auth.uid())));

-- Season factor for a game day and segment mix (game day 1 is the first day of season_start_month).
create or replace function game.season_mix(p_day int, p_biz numeric, p_lei numeric, p_bud numeric) returns numeric
language sql stable set search_path = '' as $$
  select (p_biz * f.biz + p_lei * f.lei + p_bud * f.bud) / nullif(p_biz + p_lei + p_bud, 0)
    from public.season_factors f
   where f.month = ((game.param('season_start_month')::int - 1 + (((p_day - 1) % 364) * 12) / 364) % 12) + 1
$$;

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
    v_grow := power(1 + game.param('growth_year'), (v_day - 1) / 364.0) * rw.demand_scale;
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
                        * power(1 + game.param('growth_year'), 91 / 364.0), 2);
  end if;

  insert into public.route_studies (airline_id, world_id, a, b, game_day, depth, carriers, flying_lo, flying_hi, turned_lo, turned_hi,
                                    lf_lo, lf_hi, untapped_lo, untapped_hi, biz_share, lei_share, bud_share, next_qtr)
  values (s.airline_id, s.world_id, s.a, s.b, s.game_day, s.depth, s.carriers, s.flying_lo, s.flying_hi, s.turned_lo, s.turned_hi,
          s.lf_lo, s.lf_hi, s.untapped_lo, s.untapped_hi, s.biz_share, s.lei_share, s.bud_share, s.next_qtr)
  returning id into s.id;
  return to_jsonb(s);
end $$;

revoke all on function game.season_mix(int, numeric, numeric, numeric) from public, anon, authenticated;
revoke all on function public.route_study(uuid, text, text, text) from public, anon;
grant execute on function public.route_study(uuid, text, text, text) to authenticated, service_role;
