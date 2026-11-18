-- Pilots (owner request, 19 Nov 2026; spec section 14.8). Pilots become a scarce resource with lead times, as in India in
-- 2025: each fleet family needs captains and first officers for the hours it flies; an airline short of crew cancels
-- flights. Pilots come from a world market (28 days), command upgrades (91 days), cadets (364 days) or, if the airline
-- allows it, foreign captains at a premium. They resign more when paid below the market or below a rival, and serve a
-- notice period (captains 364 days, first officers 182). Every scarce number scales with the world's places (principle 7).
-- Also: admin_set_places ties a world's places and demand together. Adds and updates only.

insert into public.game_params (key, num, note) values
('pilot_bh_day', 2.4, 'block hours one pilot flies a day on average under the duty-time rules'),
('pilot_reserve', 0.15, 'extra pilots needed for leave, training and sickness'),
('pilot_aug_bh', 8, 'flights longer than this many block hours carry an extra pilot'),
('pilot_aug_mult', 1.5, 'pilots per flight deck seat on those flights'),
('pilot_plan_util', 0.7, 'share of its daily flying window an aircraft with no flights yet is assumed to fly, when planning crews'),
('pilot_plan_days', 63, 'aircraft arriving within this many days count when hiring'),
('pilot_join_days', 28, 'days for a pilot hired from the market to join'),
('pilot_hire_max_qtr', 60, 'most pilots of one rank and fleet family an airline can hire from the market in any 91 days'),
('pilot_expat_mult', 1.8, 'pay of a foreign captain against the market rate'),
('pilot_expat_days', 56, 'days for a foreign captain to join'),
('pilot_upgrade_days', 91, 'command training, first officer to captain'),
('pilot_upgrade_inr', 1000000, 'cost of one command upgrade'),
('pilot_upgrade_share_qtr', 0.10, 'most first officers an airline can put into command training in any 91 days, as a share (at least one)'),
('pilot_cadet_days', 364, 'days from cadet to first officer'),
('pilot_cadet_inr', 3000000, 'cost of training one cadet'),
('pilot_cadets_max_qtr', 60, 'most cadets an airline can start a quarter'),
('pilot_notice_c', 364, 'notice a captain serves before leaving'),
('pilot_notice_f', 182, 'notice a first officer serves before leaving'),
('pilot_quit_year', 0.05, 'share of pilots who resign in a year at market pay'),
('pilot_quit_pay_k', 5, 'resignations scale by exp(-k x (pay level - 1))'),
('pilot_quit_poach_k', 4, 'and by exp(k x (best rival pay level - own)) when a rival pays more'),
('pilot_quit_stretch', 1.5, 'resignations multiply by this while an airline has fewer pilots than it needs'),
('pilot_quit_trouble', 2, 'and by this while its cash is below zero'),
('pilot_pool_start_mult', 2.5, 'pilots in the market at world start, against the target'),
('pilot_pool_in_qtr', 0.25, 'newly qualified pilots entering the market each quarter, as a share of the target'),
('pilot_pool_out_qtr', 0.25, 'pilots leaving the market each quarter (abroad, other work), as a share of the pool'),
('pilot_pay_k', 0.6, 'market pay rises by k x shortage^2, shortage = 1 - captains in the market / target'),
('pilot_pay_smooth', 0.03, 'share of the gap market pay closes each day'),
('pilot_pay_min', 0.8, 'lowest pay level an airline can set, against the market'),
('pilot_pay_max', 1.5, 'highest pay level'),
('pilot_buffer_max', 0.4, 'most spare pilots an airline can keep, as a share of need'),
('pilot_furlough_slack', 1.25, 'pilots above need x (1 + spare) x this are let go'),
('pilot_severance_days', 91, 'days of pay owed to each pilot let go'),
('event_duty_prob_day', 0.0011, 'chance a day that the regulator tightens duty-time rules (at most once a season)'),
('event_duty_mult', 0.9, 'hours a pilot may fly after the change, against before'),
('event_duty_notice', 91, 'days between the announcement and the change')
on conflict (key) do update set num = excluded.num, note = excluded.note;

create table public.pilot_families (       -- reference: pilots fly one family; every number (G)
  id            text primary key,
  name          text not null,
  sort          int not null,
  pay_c_inr_day numeric not null,           -- captain's pay a day at a market pay index of 1
  pay_f_inr_day numeric not null,           -- first officer's
  pool_c        numeric not null,           -- captains in the world market at its target, per airline place
  pool_f        numeric not null            -- first officers
);
insert into public.pilot_families values
('ATR',  'ATR 72',      1, 15300,  7000,  4,  6),
('A320', 'A320 family', 2, 19800,  9000, 20, 30),
('A350', 'A350',        3, 26100, 11900,  3,  4);

alter table public.aircraft_types add column pilot_family text references public.pilot_families;
update public.aircraft_types set pilot_family = case id when 'AT76' then 'ATR' when 'A359' then 'A350' else 'A320' end;

alter table public.worlds add column pilots boolean not null default true;   -- false: the flat pilot cost per aircraft of 0004

alter table public.airline_finance
  add column pilot_pay numeric not null default 1,         -- pay level against the market
  add column pilot_buffer numeric not null default 0.1,    -- spare pilots to keep, share of need
  add column pilot_cadets int not null default 0,          -- cadets to start a quarter
  add column pilot_expats boolean not null default false;  -- hire foreign captains when the market runs short

create table public.airline_pilots (       -- private: pilots on strength by fleet family
  airline_id uuid not null references public.airlines on delete cascade,
  family     text not null references public.pilot_families,
  captains   int not null default 0,       -- including foreign captains and anyone serving notice
  fos        int not null default 0,       -- first officers
  expats     int not null default 0,       -- foreign captains (part of captains)
  need       int not null default 0,       -- per rank, for aircraft flying or arriving soon, with reserve
  primary key (airline_id, family)
);

create table public.pilot_moves (          -- private: pilots joining or leaving later
  id         bigint generated always as identity primary key,
  airline_id uuid not null references public.airlines on delete cascade,
  world_id   uuid not null references public.worlds on delete cascade,
  family     text not null references public.pilot_families,
  rank       text not null check (rank in ('c', 'f')),
  kind       text not null check (kind in ('hire', 'expat', 'cadet', 'upgrade', 'leave', 'release')),
  n          int not null check (n > 0),
  start_day  int not null,
  due_day    int not null,
  done       boolean not null default false
);
create index pilot_moves_due_idx on public.pilot_moves (world_id, done, due_day);
create index pilot_moves_airline_idx on public.pilot_moves (airline_id, family);

create table public.pilot_market (         -- public: pilots looking for work in a world, and the market pay
  world_id  uuid not null references public.worlds on delete cascade,
  family    text not null references public.pilot_families,
  captains  numeric not null,
  fos       numeric not null,
  pay_index numeric not null default 1,
  primary key (world_id, family)
);

alter table public.pilot_families enable row level security;
alter table public.pilot_market enable row level security;
alter table public.airline_pilots enable row level security;
alter table public.pilot_moves enable row level security;
grant select on public.pilot_families, public.pilot_market, public.airline_pilots, public.pilot_moves to authenticated;
create policy read_all on public.pilot_families for select to authenticated using (true);
create policy read_all on public.pilot_market for select to authenticated using (true);
create policy read_own on public.airline_pilots for select to authenticated
  using (airline_id in (select id from public.airlines where user_id = (select auth.uid())));
create policy read_own on public.pilot_moves for select to authenticated
  using (airline_id in (select id from public.airlines where user_id = (select auth.uid())));

-- Hours one pilot may fly a day on a game day, after any tightening of the duty-time rules that has started by then.
create or replace function game.pilot_bh(p_world uuid, p_day int) returns numeric
language sql stable set search_path = '' as $$
  select game.param('pilot_bh_day') * coalesce(exp(sum(ln((e.payload ->> 'mult')::numeric))), 1)
    from public.events e where e.world_id = p_world and e.kind = 'duty_rules' and e.starts_day <= p_day
$$;

-- Block hours a day each airline's dry fleet needs crews for, by family: aircraft in service plus those arriving within
-- p_horizon days. An aircraft with flights counts what it flies (long flights count extra pilots); one without is planned
-- at pilot_plan_util of its daily flying window. Wet-leased aircraft bring their own crew.
create or replace function game.pilot_need(p_world uuid, p_day int, p_horizon int)
returns table (airline_id uuid, family text, bh numeric)
language sql stable set search_path = '' as $$
  select ac.airline_id, t.pilot_family, sum(coalesce(s.bh, t.day_window_h * game.param('pilot_plan_util')))
    from public.aircraft ac
    join public.aircraft_terms tm on tm.aircraft_id = ac.id and tm.holding <> 'wet'
    join public.aircraft_types t on t.id = ac.type_id
    left join (select ro.aircraft_id,
                      sum(2 * ro.weekly_trips / 7.0 * b.h * case when b.h > game.param('pilot_aug_bh') then game.param('pilot_aug_mult') else 1 end) as bh
                 from public.rotations ro
                 join public.routes r on r.id = ro.route_id and r.status = 'open' and r.world_id = p_world
                 join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
                 join public.aircraft x on x.id = ro.aircraft_id
                 join public.aircraft_types t2 on t2.id = x.type_id
                 cross join lateral (select m.km::numeric / t2.cruise_kmh + t2.block_offset_h as h) b
                group by ro.aircraft_id) s on s.aircraft_id = ac.id
   where ac.world_id = p_world and ac.airline_id is not null
     and (ac.status in ('active', 'grounded', 'refit') or (ac.status = 'delivering' and ac.available_day <= p_day + p_horizon))
   group by ac.airline_id, t.pilot_family
$$;

create or replace function game.pilot_market_init(p_world uuid) returns void
language sql set search_path = '' as $$
  insert into public.pilot_market (world_id, family, captains, fos)
  select w.id, f.id, round(f.pool_c * w.max_airlines * game.param('pilot_pool_start_mult')),
         round(f.pool_f * w.max_airlines * game.param('pilot_pool_start_mult'))
    from public.worlds w cross join public.pilot_families f
   where w.id = p_world
  on conflict (world_id, family) do nothing
$$;

-- Crews for airlines already flying when pilots start: the computer-run airlines on their first day, and every airline of a
-- world that was running before migration 0013. They get their need plus 10%, outside the market, like their aircraft.
create or replace function game.pilot_seed(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare v_pbh numeric := game.pilot_bh(p_world, p_day); v_res numeric := game.param('pilot_reserve');
begin
  if not (select pilots from public.worlds where id = p_world) then return; end if;
  perform game.pilot_market_init(p_world);
  insert into public.airline_pilots (airline_id, family, captains, fos, need)
  select n.airline_id, n.family, ceil(x.need * 1.1), ceil(x.need * 1.1), x.need
    from game.pilot_need(p_world, p_day, game.param('pilot_plan_days')::int) n
    cross join lateral (select ceil(n.bh / v_pbh * (1 + v_res))::int as need) x
  on conflict (airline_id, family) do update
    set captains = greatest(public.airline_pilots.captains, excluded.captains),
        fos = greatest(public.airline_pilots.fos, excluded.fos), need = excluded.need;
  update public.airline_finance fin set pilot_expats = true
    from public.airlines al where al.id = fin.airline_id and al.world_id = p_world and al.is_ai;
end $$;

-- One day of pilots, run before the day's flying: duty-rule events, joiners and leavers, the market, need, resignations,
-- hiring (best payers first), cadets and letting surplus pilots go.
create or replace function game.day_pilots(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
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
    values (p_world, 'duty_rules', p_day, p_day + game.param('event_duty_notice')::int, null,
            jsonb_build_object('mult', game.param('event_duty_mult')));
    insert into public.news (world_id, game_day, kind, body)
    values (p_world, p_day, 'event', format('The regulator tightens pilot duty-time rules from day %s: each pilot may fly about %s%% fewer hours. Airlines without spare pilots will cancel flights.',
            p_day + game.param('event_duty_notice')::int, round((1 - game.param('event_duty_mult')) * 100)));
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
                  || ' resigned. They keep flying until day ' || (p_day + game.param('pilot_notice_' || rk)::int) || ', then leave.'
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
            v_cost := v_n * game.param('pilot_upgrade_inr');
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
      v_cost := v_n * game.param('pilot_cadet_inr');
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
      v_cost := round(game.param('pilot_severance_days') * rec.pay_index * rec.pay_c_inr_day
                      * (v_e * game.param('pilot_expat_mult') + (v_n - v_e) * rec.pilot_pay));
      update public.airline_pilots set captains = captains - v_n, expats = expats - v_e where airline_id = rec.airline_id and family = rec.family;
      update public.pilot_market set captains = captains + (v_n - v_e) where world_id = p_world and family = rec.family;
      perform game.book(rec.airline_id, p_day, -v_cost, 'severance', format('%s %s captain%s let go', v_n, rec.name, case when v_n = 1 then '' else 's' end), -v_cost, true);
    end if;
    v_n := rec.fos - rec.out_f - v_target;
    if v_n > 0 then
      v_cost := round(game.param('pilot_severance_days') * rec.pay_index * rec.pay_f_inr_day * rec.pilot_pay * v_n);
      update public.airline_pilots set fos = fos - v_n where airline_id = rec.airline_id and family = rec.family;
      update public.pilot_market set fos = fos + v_n where world_id = p_world and family = rec.family;
      perform game.book(rec.airline_id, p_day, -v_cost, 'severance', format('%s %s first officer%s let go', v_n, rec.name, case when v_n = 1 then '' else 's' end), -v_cost, true);
    end if;
  end loop;
end $$;

create or replace function public.set_pilot_policy(p_airline uuid, p_pay numeric, p_buffer numeric, p_cadets int, p_expats boolean)
returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform game.actor(p_airline, false);
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

-- Principle 7: a world's places set its demand (demand_scale = places / 50) and, through max_airlines, its lessor pool,
-- delivery slots, pilot market and airport capacity. Any change before the start; only up once it is running.
create or replace function public.admin_set_places(p_world uuid, p_places int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare w public.worlds; v_players int;
begin
  perform game.require_admin();
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

-- day_ops from 0011, plus crew shortages and pilot salaries (when the world has pilots)
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
    loan_rate_year numeric, anc_biz_share numeric);

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
    an_y numeric, an_c numeric, anc numeric, anc_cost numeric  -- extras: revenue and cost per economy passenger (reference fares), totals
  ) on commit drop;
  truncate pg_temp._rot, pg_temp._prod;

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

  -- Step 5: costs per flight. Slots at congested airports are priced by how full the airport is;
  -- a world scaled down in demand has proportionally fewer slots.
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
    c_slots = 2 * x.f * (coalesce(sa.price, 0) + coalesce(sb.price, 0))
  from (select route_id, a, b, coalesce(pax_e / nullif(cap_e, 0), 0) as lf_e, coalesce(pax_b / nullif(cap_b, 0), 0) as lf_b
          from pg_temp._prod) p
  join public.aircraft_types t on true
  left join sp sa on sa.iata = p.a
  left join sp sb on sb.iata = p.b
  where x.flown and p.route_id = x.route_id and t.id = x.type_id;

  -- Step 6: results
  insert into public.route_daily (route_id, game_day, airline_id, flights, seats_econ, seats_biz, pax_econ, pax_biz,
                                  spill, revenue_inr, var_cost_inr)
  select p.route_id, p_day, p.airline_id, 2 * p.f, round(2 * p.cap_e), round(2 * p.cap_b), p.pe, p.pb, round(2 * p.spill),
         round(p.rev + p.anc),
         round(c.var + g.dist_rev_share * p.rev + g.service_inr_pax * (p.pe + p.pb) + p.anc_cost)
    from pg_temp._prod p
    join (select route_id, sum(c_fuel + c_crew + c_maint + c_airport + c_slots) as var
            from pg_temp._rot where flown group by route_id) c on c.route_id = p.route_id;

  insert into public.airline_daily (airline_id, game_day, pax, ask, rpk, rev_ticket, rev_anc, c_fuel, c_crew, c_maint,
    c_airport, c_rent, c_slots, c_dist, c_marketing, c_overhead, c_interest, c_other, c_depr, flights, cancelled, loan_repaid)
  select al.id, p_day, coalesce(pr.pax, 0), coalesce(pr.ask, 0), coalesce(pr.rpk, 0),
         coalesce(pr.rev, 0), round(coalesce(pr.anc, 0)),
         round(coalesce(rc.fuel, 0)), round(coalesce(rc.crew, 0) + coalesce(fl.crew_fixed, 0) + coalesce(sal.pay, 0)), round(coalesce(rc.maint, 0)),
         round(coalesce(rc.airport, 0)), round(coalesce(fl.rent, 0)), round(coalesce(rc.slots, 0)),
         round(coalesce(g.dist_rev_share * pr.rev + g.service_inr_pax * pr.pax + pr.anc_cost, 0)), al.marketing_inr_day,
         round(g.overhead_fixed_inr_day + g.overhead_aircraft_inr_day * coalesce(fl.n, 0) + g.overhead_seat_inr_day * coalesce(fl.seats, 0)
               + g.base_fixed_inr_day * (select count(*) from public.bases bs where bs.airline_id = al.id)),
         round(fin.debt_inr * g.interest_year / 364 + coalesce(fl.loan_int, 0)), coalesce(tx.other, 0), round(coalesce(fl.depr, 0)),
         coalesce(rc.flights, 0), coalesce(rc.cancelled, 0), round(coalesce(fl.loan_prin, 0))
    from public.airlines al
    join public.airline_finance fin on fin.airline_id = al.id
    left join (select airline_id, sum(pe + pb) as pax, sum(2 * (cap_e + cap_b) * km) as ask,
                      sum((pe + pb) * km) as rpk, sum(rev) as rev, sum(anc) as anc, sum(anc_cost) as anc_cost
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
              + g.brand_comfort_k * (coalesce(c.comf, g.brand_comfort_ref) - g.brand_comfort_ref)
              + g.brand_mkt_max * (1 - exp(-al.marketing_inr_day / (g.brand_mkt_inr_pax * greatest(d.pax, g.brand_mkt_min_pax))))
           - al.brand))), 2)
    from public.airline_daily d
    left join (select airline_id, sum(cap_e * comf_e) / nullif(sum(cap_e), 0) as comf from pg_temp._prod group by airline_id) c
           on c.airline_id = d.airline_id
   where d.airline_id = al.id and d.game_day = p_day and al.world_id = p_world and al.status = 'active';

  delete from public.route_daily rd using public.airlines al
   where al.id = rd.airline_id and al.world_id = p_world and rd.game_day <= p_day - g.route_keep_days::int;
end $$;

-- administer from 0005, plus letting every pilot go
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
         credit_limit_inr = round(game.param('credit_limit_inr') * game.param('restart_credit_share'))
   where airline_id = p_airline;
  update public.airlines
     set administrations = administrations + 1, brand = greatest(0, brand - game.param('restart_brand_hit')), marketing_inr_day = 0
   where id = p_airline;
  insert into public.news (world_id, game_day, airline_id, kind, body)
  select p_world, p_day, p_airline, 'administration', name || ' has gone into administration and restarts with reduced capital.'
    from public.airlines where id = p_airline;
end $$;

-- run_day from 0007, plus crews for the computer-run airlines on day 1 and the daily pilot step
create or replace function game.run_day(p_world uuid) returns int
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  v_day int;
begin
  perform pg_advisory_xact_lock(hashtextextended('day:' || p_world, 0));
  select * into rw from public.worlds where id = p_world for update;
  if not found or rw.status <> 'running' or rw.game_day >= rw.season_days then return null; end if;
  v_day := rw.game_day + 1;
  if rw.game_day = 0 then perform game.bot_seed(p_world); perform game.pilot_seed(p_world, v_day); end if;
  perform game.day_world(p_world, v_day);
  perform game.day_fleet(p_world, v_day);
  perform game.bot_prices(p_world, v_day);
  perform game.day_pilots(p_world, v_day);
  perform game.day_ops(p_world, v_day);
  if v_day % 91 = 0 then
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

-- Every world's places now match its demand (both worlds: demand_scale 0.5, so 25 places; was 50, which sized the lessor
-- pool, delivery slots and pilot market for twice the players the demand was set for).
update public.worlds set max_airlines = greatest(2, round(demand_scale * 50)::int) where max_airlines <> greatest(2, round(demand_scale * 50)::int);

-- Worlds already running get their pilot market and crews for every airline now.
do $$ declare w record; begin
  for w in select id, game_day from public.worlds where status in ('running', 'paused') and pilots loop
    perform game.pilot_seed(w.id, w.game_day + 1);
  end loop;
end $$;

revoke all on function game.pilot_bh(uuid, int), game.pilot_need(uuid, int, int), game.pilot_market_init(uuid),
  game.pilot_seed(uuid, int), game.day_pilots(uuid, int), game.day_ops(uuid, int), game.administer(uuid, uuid, int),
  game.run_day(uuid) from public, anon, authenticated;
revoke all on function public.set_pilot_policy(uuid, numeric, numeric, int, boolean), public.admin_set_places(uuid, int) from public, anon;
grant execute on function public.set_pilot_policy(uuid, numeric, numeric, int, boolean), public.admin_set_places(uuid, int) to authenticated, service_role;
