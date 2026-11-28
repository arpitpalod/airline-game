// One route: how full it is, its fares against rivals, and which aircraft fly it how often.
import { useMemo, useState } from 'react';
import { useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { call } from '../lib/api';
import { useBases, useEvents, useFleet, useGame, useMarketsFrom, useQuote, useRivals, useRouteDaily, useRoutes, useSeatCap, useSeatRoom, useTurnDelta, type FleetItem } from '../lib/data';
import { cancelRule, demandWeek, hoursByAircraft, routeStat, unitEcon } from '../lib/derive';
import { cannotFly, maxWeekly, minTurn, pairKey, STATUS_LABEL, tripHours, weekHours } from '../lib/game';
import { inr, num, pct, plural, unit, weekOf } from '../lib/format';
import { LoadChart } from '../components/charts';
import { StudyCard } from '../components/Study';
import { LastFlights, MarketMoves, NetworkCard, RouteAudit, SeatsOnSale, StrategyCard } from '../components/Selling';
import { useAction } from '../components/toast';
import { Badge, Button, Empty, Kpi, Loading, PageHeader, Sheet, Stepper } from '../components/ui';

export function RouteDetail() {
  const { id } = useParams();
  const [sp, setSp] = useSearchParams();
  const { ref, world, airline } = useGame();
  const turnDelta = useTurnDelta();
  const net = useRoutes();
  const fleet = useFleet();
  const bases = useBases();
  const rd = useRouteDaily();
  const route = net.data?.routes.find((r) => r.id === id);
  const markets = useMarketsFrom([...(bases.data ?? []).map((b) => b.iata), ...(route ? [route.origin, route.dest] : [])]);
  const rivals = useRivals(route ? [route.origin, route.dest] : []);
  const { run, busy } = useAction();
  const nav = useNavigate();
  const [fareE, setFareE] = useState<number | null>(null);
  const [fareB, setFareB] = useState<number | null>(null);
  const [closing, setClosing] = useState(false);
  const assigning = sp.get('assign') === '1';

  const m = route ? markets.data?.[pairKey(route.origin, route.dest)] : undefined;
  const rots = (net.data?.rotations ?? []).filter((r) => r.route_id === id);
  const fl = fleet.data ?? [];
  const hours = useMemo(() => (net.data && fleet.data ? hoursByAircraft(fleet.data, net.data.routes, net.data.rotations, markets.data, ref, turnDelta) : {}),
    [net.data, fleet.data, markets.data, ref, turnDelta]);

  if (net.isLoading || fleet.isLoading) return <Loading h={300} />;
  if (!route) return <Empty title="This route is closed" action={<Button onClick={() => nav('/network')}>Back to network</Button>} />;

  const A = ref.airport[route.origin], B = ref.airport[route.dest];
  const s7 = routeStat(rd.data ?? [], route.id, world.game_day - 6);
  const series = Array.from(new Set((rd.data ?? []).filter((d) => d.route_id === route.id).map((d) => weekOf(d.game_day)))).sort((a, b) => a - b)
    .map((w) => { const st = routeStat((rd.data ?? []).filter((d) => weekOf(d.game_day) === w), route.id, 0); return { day: w, lf: st.lf }; });
  const perWeek = (x: number) => (s7.days ? (x * 7) / s7.days : 0);
  const fe = fareE ?? route.fare_econ, fb = fareB ?? route.fare_biz ?? 0;
  const bizMult = ref.param.biz_fare_mult ?? 3.5;
  const dirty = fe !== route.fare_econ || (route.fare_biz != null && fb !== route.fare_biz);
  const minF = Math.ceil((m?.ref_fare ?? 0) * ref.param.fare_min_mult), maxF = Math.floor((m?.ref_fare ?? 1e6) * ref.param.fare_max_mult);
  const hasBiz = rots.some((r) => (fl.find((a) => a.id === r.aircraft_id)?.seats_biz ?? 0) > 0);

  const comp = (rivals.data?.[pairKey(route.origin, route.dest)] ?? []).filter((x) => x.weekly > 0 || x.route.airline_id === airline.id);
  const totalSeats = comp.reduce((a, x) => a + x.seatsWeek, 0);

  return (
    <div className="stack-lg">
      <PageHeader back="/network" title={`${A.city} – ${B.city}`}
        sub={`${route.origin}–${route.dest} · ${m ? `${num(m.km)} km` : ''}${m?.intl ? ' · international' : ''} · opened week ${weekOf(route.opened_day)}`} />
      <div className="grid4-d">
        <Kpi label="Seats sold, last week" value={s7.lf != null ? pct(s7.lf) : '–'} note={s7.lf == null ? 'No flights yet' : s7.lf >= 0.95 ? (world.selling ? 'Full: try Top fares' : 'Full: room to raise the fare') : s7.lf < 0.6 ? 'Many empty seats' : 'Healthy is 80 to 88%'} />
        <Kpi label="Passengers a week" value={num(perWeek(s7.pax))} note={`${num(perWeek(s7.spill))} turned away`} />
        <Kpi label="Revenue a week" value={inr(perWeek(s7.revenue))} />
        <Kpi label="Flight profit a week" value={inr(perWeek(s7.revenue - s7.varCost), { sign: true })} tone={s7.revenue - s7.varCost >= 0 ? 'good' : 'bad'}
          note="Before rent and head office" />
      </div>
      {s7.lf != null && m && (() => {
        const u = unitEcon(s7, m.km);
        if (!u) return null;
        const be = u.beLf;
        return (
          <div className="grid4-d">
            <Kpi label="RASK" value={unit(u.rask, 2)} note="Revenue per seat-km, fares and extras" />
            <Kpi label="CASK" value={unit(u.cask, 2)} tone={u.cask <= u.rask ? 'good' : 'bad'} note="Flying costs and aircraft rent per seat-km" />
            <Kpi label="Break-even load" value={be != null ? pct(be) : '–'} tone={be != null && s7.lf! >= be ? 'good' : 'bad'}
              note={be == null ? '' : be > 1 ? 'Even full, today\'s fares don\'t cover the costs' : `Needed to cover costs at today's fares. You fly ${pct(s7.lf!)}.`} />
          </div>
        );
      })()}

      <div className="split">
        <div className="stack-lg">
          {world.selling && <SeatsOnSale route={route} />}
          {world.selling && <LastFlights route={route} />}
          <div className="card">
            <div className="card-title"><h2>How full, last 4 weeks</h2></div>
            <LoadChart points={series} />
          </div>
          <div className="card flush">
            <div className="card-title" style={{ padding: '14px 16px 0' }}><h2>Competition</h2><span className="small muted">public fares and schedules</span></div>
            {world.selling && <MarketMoves route={route} airlines={comp.filter((x) => x.weekly > 0).length} />}
            <div className="scroll-x">
              <table className="table">
                <thead><tr><th>Airline</th><th className="r">Economy</th><th className="r">Trips a week</th><th className="r">Seat share</th></tr></thead>
                <tbody>
                  {comp.sort((a, b) => a.route.fare_econ - b.route.fare_econ).map((x) => (
                    <tr key={x.route.id} className={x.route.airline_id === airline.id ? 'me' : ''}>
                      <td>{x.route.airline_id === airline.id ? <strong>You</strong> : x.airline?.name ?? '—'}{x.airline?.is_ai && <div className="tiny muted">computer-run</div>}</td>
                      <td className="r">{inr(x.route.fare_econ)}</td>
                      <td className="r">{x.weekly}</td>
                      <td className="r">{totalSeats ? pct(x.seatsWeek / totalSeats) : '–'}</td>
                    </tr>
                  ))}
                  {comp.length === 0 && <tr><td colSpan={4} className="muted small">Loading…</td></tr>}
                </tbody>
              </table>
            </div>
            {comp.filter((x) => x.route.airline_id !== airline.id).length === 0 && rivals.data &&
              <p className="small muted" style={{ padding: '0 16px 14px' }}>Nobody else flies this route yet.</p>}
          </div>
        </div>

        <div className="stack-lg">
          {world.selling && m && <RouteAudit route={route} km={m.km} intl={m.intl} refFare={m.ref_fare} airlines={comp.filter((x) => x.weekly > 0).length} />}
          {world.selling && <NetworkCard route={route} />}
          {world.selling ? <StrategyCard route={route} /> : (
          <div className="card stack">
            <div className="card-title" style={{ marginBottom: 0 }}><h2>Fares</h2></div>
            <div className="field">
              <label>Economy · {m ? `${(fe / m.ref_fare).toFixed(2)}× reference ${inr(m.ref_fare)}` : ''}</label>
              <Stepper label="economy fare" value={fe} step={100} min={minF} max={maxF} onChange={setFareE} format={(v) => inr(v)} />
            </div>
            {route.fare_biz != null && (
              <div className="field">
                <label>Business · {m ? `${(fb / (m.ref_fare * bizMult)).toFixed(2)}× reference ${inr(Math.round(m.ref_fare * bizMult))}` : ''}{!hasBiz && ' · no business seats on this route yet'}</label>
                <Stepper label="business fare" value={fb} step={500} min={minF} max={maxF * 4} onChange={setFareB} format={(v) => inr(v)} />
              </div>
            )}
            <p className="tiny muted">A higher fare earns more per seat but sells fewer. Change it a little at a time and watch the next few weeks. New fares count for the week being played.</p>
            <Button block disabled={!dirty} busy={busy === 'fares'} onClick={() => run('fares', () => call('set_fares', {
              p_airline: airline.id, p_route: route.id, p_fare_econ: fe, p_fare_biz: route.fare_biz != null ? fb : null,
            }), 'Fares saved. They count from this week.').then(() => { setFareE(null); setFareB(null); })}>Save fares</Button>
          </div>
          )}
          <RouteShocks a={route.origin} b={route.dest} intl={!!m?.intl} refFare={m?.ref_fare ?? 0} />
          {m?.intl && <SeatsAbroad a={route.origin} b={route.dest} />}
          <div className="card flush">
            <div className="card-title" style={{ padding: '14px 16px 0' }}>
              <h2>Aircraft on this route</h2>
              <Button size="sm" kind="ghost" onClick={() => setSp({ assign: '1' })}>Add</Button>
            </div>
            {rots.length === 0 ? (
              <Empty title="No aircraft yet" action={<Button onClick={() => setSp({ assign: '1' })}>Put an aircraft on it</Button>}>
                A route earns nothing until an aircraft flies it.
              </Empty>
            ) : (
              <div className="list">
                {rots.map((ro) => {
                  const ac = fl.find((a) => a.id === ro.aircraft_id);
                  return ac && m ? <RotationRow key={ro.aircraft_id} ac={ac} trips={ro.weekly_trips} km={m.km} used={(hours[ac.id] ?? 0)} routeId={route.id} ends={[route.origin, route.dest]} /> : null;
                })}
              </div>
            )}
            {rots.length > 0 && m && world.selling && <p className="tiny muted" style={{ padding: '0 16px 14px' }}>{cancelRule(ref.param, m.km, route.fare_econ, inr)}</p>}
          </div>
          <StudyCard a={route.origin} b={route.dest} />
          <Button kind="danger" onClick={() => setClosing(true)}>Close this route</Button>
        </div>
      </div>

      {assigning && m && (
        <AssignSheet routeId={route.id} ends={[route.origin, route.dest]} km={m.km} want={demandWeek(m, world.demand_scale) ?? 0} mine={rots.reduce((s, ro) => s + ro.weekly_trips * ((fl.find((a) => a.id === ro.aircraft_id)?.seats_econ ?? 0) + (fl.find((a) => a.id === ro.aircraft_id)?.seats_biz ?? 0)), 0)} fleet={fl} hours={hours}
          already={new Set(rots.map((r) => r.aircraft_id))} onClose={() => setSp({})} />
      )}
      {closing && (
        <Sheet title="Close this route?" onClose={() => setClosing(false)}>
          <div className="stack">
            <p className="small">Its aircraft stop flying it from this week and become free for other routes. You can open it again later{ref.param.route_launch_inr ? `, for a new launch of ${inr(ref.param.route_launch_inr)}` : ''}.</p>
            {world.selling && <CloseCost routeId={route.id} />}
            <Button kind="danger-solid" block busy={busy === 'close'} onClick={() => run('close', () => call('close_route', { p_airline: airline.id, p_route: route.id }), 'Route closed').then((r) => {
              if (r !== undefined) nav('/network');
            })}>Close route{world.selling ? <ClosePrice routeId={route.id} /> : null}</Button>
          </div>
        </Sheet>
      )}
    </div>
  );
}

/** The compensation closing pays now, for its button. */
function ClosePrice({ routeId }: { routeId: string }) {
  const x = useQuote<{ refund_inr: number; comp_inr: number }>('close_route', routeId).data;
  return x && x.comp_inr > 0 ? <>{` · ${inr(x.comp_inr)} compensation`}</> : null;
}

// 0033: what closing costs now: tickets sold are refunded, and flights within the region's notice pay compensation
function CloseCost({ routeId }: { routeId: string }) {
  const q = useQuote<{ refund_inr: number; comp_inr: number; notice_days: number }>('close_route', routeId);
  const x = q.data;
  if (!x) return <p className="small muted">Working out the refunds…</p>;
  return (
    <div className="kv small">
      <span>Tickets sold, refunded</span><span>{inr(x.refund_inr)}</span>
      <span>Compensation{x.notice_days ? ` (flights within ${x.notice_days === 1 ? 'a day' : `${x.notice_days} days`})` : ''}</span><span className={x.comp_inr > 0 ? 'bad-ink' : ''}>{x.comp_inr > 0 ? `−${inr(x.comp_inr)}` : 'none'}</span>
    </div>
  );
}

function RotationRow({ ac, trips, km, used, routeId, ends }: { ac: FleetItem; trips: number; km: number; used: number; routeId: string; ends: string[] }) {
  const { ref, airline } = useGame();
  const turnDelta = useTurnDelta();
  const seatCap = useSeatCap(ends);
  const t = ref.type[ac.type_id];
  const trip = tripHours(t, km, minTurn(t, ac.seats_econ + ac.seats_biz, turnDelta));
  const byHours = Math.min(84, Math.floor((weekHours(t) - (used - trips * trip) + 1e-9) / trip));
  const max = seatCap ? Math.min(byHours, seatCap.cap(ac.seats_econ + ac.seats_biz, trips)) : byHours;
  const [v, setV] = useState(trips);
  const { run, busy } = useAction();
  const nav = useNavigate();
  return (
    <div className="item" style={{ flexWrap: 'wrap' }}>
      <div className="grow" style={{ minWidth: 150, cursor: 'pointer' }} onClick={() => nav(`/aircraft/${ac.id}`)}>
        <div className="strong">{ac.reg} <span className="muted" style={{ fontWeight: 400 }}>· {t.name}</span></div>
        <div className="tiny muted">{ac.seats_biz ? `${ac.seats_biz} business + ` : ''}{ac.seats_econ} economy · {STATUS_LABEL[ac.status]} · up to {max} a week{max < byHours ? ` (seats to ${seatCap!.name} are full)` : ''}</div>
      </div>
      <div className="row">
        <div style={{ width: 150 }}><Stepper label="round trips a week" value={v} min={0} max={max} onChange={setV} format={(x) => `${x}/wk`} /></div>
        <Button size="sm" disabled={v === trips} busy={busy === 'rot'} onClick={() => run('rot', () => call('set_rotation', {
          p_airline: airline.id, p_aircraft: ac.id, p_route: routeId, p_weekly_trips: v,
        }), v === 0 ? `${ac.reg} taken off this route` : `${ac.reg} now flies ${v} round trips a week`)}>Save</Button>
      </div>
    </div>
  );
}

function AssignSheet({ routeId, ends, km, want, mine, fleet, hours, already, onClose }: {
  routeId: string; ends: string[]; km: number; want: number; mine: number; fleet: FleetItem[]; hours: Record<string, number>; already: Set<string>; onClose: () => void;
}) {
  const { ref, airline } = useGame();
  const turnDelta = useTurnDelta();
  const { run, busy } = useAction();
  // each aircraft's room on this route: round trips a week that fit its free hours, or none where it cannot fly the route
  // (a runway too short at either end, or beyond its range), shown before it is chosen rather than refused after
  const blocked = (a: FleetItem) => cannotFly(ref.type[a.type_id], a.seats_econ + a.seats_biz, ends.map((x) => ref.airport[x]), km);
  const seatCap = useSeatCap(ends);
  const byHours = (a: FleetItem) => (blocked(a) ? 0 : maxWeekly(ref.type[a.type_id], a, km, hours[a.id] ?? 0, turnDelta));
  const roomOf = (a: FleetItem) => (seatCap ? Math.min(byHours(a), seatCap.cap(a.seats_econ + a.seats_biz)) : byHours(a));
  const seatsShort = (a: FleetItem) => !blocked(a) && roomOf(a) < byHours(a);
  const candidates = fleet.filter((a) => !already.has(a.id) && a.base_iata && ends.includes(a.base_iata) && ['active', 'delivering', 'grounded', 'refit'].includes(a.status))
    .sort((x, y) => Number(roomOf(y) > 0) - Number(roomOf(x) > 0));
  const others = fleet.filter((a) => !already.has(a.id) && !(a.base_iata && ends.includes(a.base_iata)) && a.status !== 'returned');
  const [pick, setPick] = useState<string | null>(candidates.find((a) => roomOf(a) > 0)?.id ?? null);
  const ac = candidates.find((a) => a.id === pick);
  const t = ac ? ref.type[ac.type_id] : null;
  const max = ac ? roomOf(ac) : 0;
  const noFlyer = candidates.length > 0 && candidates.every((a) => blocked(a));
  const shortEnd = ends.map((x) => ref.airport[x]).find((ap) => ap?.runway_class === 1);
  const [trips, setTrips] = useState<number | null>(null);
  // start from what the market can fill (QA: 14 round trips put 1,008 seats on a route about 30 travellers a week want)
  const seatsAc = ac ? ac.seats_econ + ac.seats_biz : 1;
  const fits = Math.max(1, Math.ceil(Math.max(0, want - mine) / (seatsAc * 0.85)));
  const tv = trips ?? Math.min(max, 14, fits);
  return (
    <Sheet title="Put an aircraft on this route" onClose={onClose}>
      <div className="stack">
        {candidates.length === 0 ? (
          <div className="card warn small">
            None of your aircraft is based at {ends.join(' or ')}. {others.length ? 'Move one there from its page in Fleet, or get a new one.' : 'Get an aircraft first.'}
          </div>
        ) : (
          <>
            <div className="card flush">
              <div className="list">
                {candidates.map((a) => {
                  const tt = ref.type[a.type_id];
                  const free = Math.max(0, weekHours(tt) - (hours[a.id] ?? 0));
                  const room = roomOf(a);
                  const no = blocked(a);
                  return (
                    <div key={a.id} className={`item ${room > 0 ? 'link' : 'off'} ${a.id === pick ? 'me' : ''}`} aria-disabled={room === 0}
                      onClick={() => { if (room > 0) { setPick(a.id); setTrips(null); } }}>
                      <div className="grow">
                        <div className="strong">{a.reg} · {tt.name}</div>
                        <div className="tiny muted">{a.seats_econ + a.seats_biz} seats · {STATUS_LABEL[a.status]} · {num(free)} of {num(weekHours(tt))} hours a week free</div>
                        <div className={`small ${room > 0 ? '' : 'bad-ink'}`} style={{ marginTop: 2 }}>
                          {no ? no.why
                            : room > 0 ? `Room for ${plural(room, 'round trip')} a week here${seatsShort(a) ? `: the seats left to ${seatCap!.name} (${num(seatCap!.free)} a week)` : ''}`
                              : seatsShort(a) ? `No room: only ${num(seatCap!.free)} seats a week to ${seatCap!.name} are free in this world`
                                : 'No room: not enough free hours for one round trip here'}
                        </div>
                      </div>
                      <div className="stack" style={{ gap: 4, alignItems: 'flex-end' }}>
                        {room === 0 && <Badge tone="bad">{no ? no.badge : seatsShort(a) ? 'Seats' : 'Full'}</Badge>}
                        {a.terms?.holding === 'wet' && <Badge tone="warn">Wet lease</Badge>}
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>
            {noFlyer && <div className="card warn small">None of these aircraft can fly this route.{shortEnd ? ` ${shortEnd.city} takes turboprops only: lease or order an ATR 72 in Get aircraft.` : ''}</div>}
            {ac && t && (
              max === 0 ? <div className="card warn small">{seatsShort(ac) ? `Seats to ${seatCap!.name} are full in this world.` : `${ac.reg} has no free hours left. Take it off another route first.`}</div>
                  : (
                    <div className="field">
                      <label>Round trips a week (up to {max})</label>
                      <Stepper label="round trips a week" value={tv} min={1} max={max} onChange={setTrips} format={(x) => `${x} a week · ${(x / 7).toFixed(1)} a day`} />
                      <div className={`hint ${tv * seatsAc + mine > 2.5 * Math.max(1, want) ? 'bad-ink' : ''}`}>About {num(want)} travellers a week each way want this route, with every airline{mine ? `; you already fly ${num(mine)} seats` : ''}. {plural(tv, 'round trip')} is {num(tv * seatsAc)} seats each way.</div>
                      <div className="hint">One round trip takes {tripHours(t, km, minTurn(t, ac.seats_econ + ac.seats_biz, turnDelta)).toFixed(1)} hours including turnarounds. Flying an aircraft above 85% of its day costs punctuality.</div>
                    </div>
                  )
            )}
            <Button block disabled={!ac || max === 0} busy={busy === 'assign'} onClick={() => run('assign', () => call('set_rotation', {
              p_airline: airline.id, p_aircraft: ac!.id, p_route: routeId, p_weekly_trips: tv,
            }), `${ac!.reg} will fly ${tv} round trips a week`).then((r) => r !== undefined && onClose())}>Assign</Button>
          </>
        )}
      </div>
    </Sheet>
  );
}

/** Shocks in force on this route (0028): a closed airport, a fare cap, the airspace west of India. */
function RouteShocks({ a, b, intl, refFare }: { a: string; b: string; intl: boolean; refFare: number }) {
  const { world, ref } = useGame();
  const ev = useEvents();
  const now = world.game_day + 1;
  const live = (ev.data ?? []).filter((e) => e.starts_day <= now && (e.ends_day ?? now) >= now);
  const lines: string[] = [];
  for (const e of live) {
    const ap = e.payload?.airport as string | undefined;
    const city = ap ? ref.airport[ap]?.city ?? ap : '';
    const until = `until week ${weekOf(e.ends_day ?? now)}`;
    if (e.kind === 'airport_closed' && ap && [a, b].includes(ap)) lines.push(`${city} airport is closed ${until}: every flight on this route is cancelled and its travellers refunded.`);
    if (e.kind === 'fare_cap' && ap && [a, b].includes(ap) && !intl)
      lines.push(`The government caps economy fares to and from ${city} at ${inr(Math.floor((Number(e.payload?.mult ?? 1.5) * refFare) / 10) * 10)} ${until}: every way of selling sells at most at the cap.`);
    if (e.kind === 'airspace_closed' && intl) {
      const ind = [a, b].map((x) => ref.airport[x]).find((x) => x?.is_india);
      const far = [a, b].map((x) => ref.airport[x]).find((x) => x && !x.is_india);
      if (ind && far && ind.lat >= Number(e.payload?.lat_min ?? ref.param.airspace_lat_min ?? 23) && ['GULF', 'EUR', 'NAM', 'CIS', 'AFR'].includes(far.region))
        lines.push(`The airspace west of India is closed ${until}: this route flies round it, longer and dearer, and aircraft that can no longer reach are cancelled.`);
    }
  }
  if (!lines.length) return null;
  return <div className="card warn stack small">{lines.map((l) => <div key={l}>{l}</div>)}</div>;
}

/** Seats between India and the country at the far end, in this world (0028). */
function SeatsAbroad({ a, b }: { a: string; b: string }) {
  const { ref } = useGame();
  const room = useSeatRoom();
  const far = [a, b].map((x) => ref.airport[x]).find((x) => x && !x.is_india);
  const r = far ? room.data?.find((x) => x.country === far.country) : undefined;
  if (!r) return null;
  const others = Math.max(0, r.used - r.mine), free = Math.max(0, r.limit - r.used);
  const w = (n: number) => `${Math.min(100, (100 * n) / Math.max(r.limit, r.used, 1))}%`;
  return (
    <div className="card stack">
      <div className="card-title" style={{ marginBottom: 0 }}><h2>Seats India–{r.name.replace(/^the /, '')}</h2><span className="small muted">each way, a week</span></div>
      <div style={{ display: 'flex', height: 12, borderRadius: 6, overflow: 'hidden', background: 'var(--bg)' }}
        aria-label={`You hold ${num(r.mine)}, other airlines ${num(others)}, free ${num(free)} of ${num(r.limit)}`}>
        <div style={{ width: w(r.mine), background: 'var(--accent)' }} />
        <div style={{ width: w(others), background: 'var(--line-strong)' }} />
      </div>
      <div className="kv">
        <span>Airlines in this world may fly</span><span>{num(r.limit)}</span>
        <span>You fly</span><span>{num(r.mine)}</span>
        <span>Other airlines here</span><span>{num(others)}</span>
        <span>Free</span><span className={free === 0 ? 'bad' : ''}>{num(free)}</span>
      </div>
      <p className="tiny muted">India agrees a weekly limit with {r.name}; this world's share grows with its places. Foreign airlines fly their own seats on top and carry the travellers this world's airlines cannot seat. Free seats go to whoever puts an aircraft on them first; seats you stop flying go back at once.</p>
    </div>
  );
}
