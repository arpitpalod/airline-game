// One aircraft: terms, cabin, how busy it is, its routes, and what you can do with it.
import { useMemo, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { call } from '../lib/api';
import { seatCapOf, useAircraftDaily, useBases, useFleet, useGame, useMarketsFrom, useQuote, useRoutes, useSeatRoom, useTurnDelta } from '../lib/data';
import { aircraftStats, demandWeek, hoursByAircraft } from '../lib/derive';
import { ageYears, cabinRange, cannotFly, holdingLabel, maxWeekly, pairKey, STATUS_LABEL, weekHours } from '../lib/game';
import { arrivalWeek, inr, num, pct, plural, usd, weekOf } from '../lib/format';
import { useAction } from '../components/toast';
import { Badge, Bar, Button, Empty, Field, Loading, PageHeader, Sheet, Stepper } from '../components/ui';

export function AircraftDetail() {
  const { id } = useParams();
  const { ref, world, airline } = useGame();
  const turnDelta = useTurnDelta();
  const fleet = useFleet();
  const net = useRoutes();
  const bases = useBases();
  const markets = useMarketsFrom((bases.data ?? []).map((b) => b.iata));
  const { run, busy } = useAction();
  const nav = useNavigate();
  const [sheet, setSheet] = useState<'route' | 'base' | 'return' | null>(null);
  const hours = useMemo(() => (fleet.data && net.data ? hoursByAircraft(fleet.data, net.data.routes, net.data.rotations, markets.data, ref, turnDelta) : {}),
    [fleet.data, net.data, markets.data, ref, turnDelta]);

  if (fleet.isLoading) return <Loading h={300} />;
  const ac = fleet.data?.find((a) => a.id === id);
  if (!ac) return <Empty title="This aircraft is no longer in your fleet" action={<Button onClick={() => nav('/fleet')}>Back to fleet</Button>} />;
  const t = ref.type[ac.type_id];
  const terms = ac.terms;
  const used = hours[ac.id] ?? 0;
  const rots = (net.data?.rotations ?? []).filter((r) => r.aircraft_id === ac.id);
  const routes = net.data?.routes ?? [];
  const seats = ac.seats_econ + ac.seats_biz;
  const returnLabel = terms?.holding === 'owned' ? 'Sell this aircraft' : terms?.holding === 'wet' ? 'End the wet lease' : 'Return to the lessor';

  return (
    <div className="stack-lg">
      <PageHeader back="/fleet" title={ac.reg} sub={`${t.name} · based at ${ref.airport[ac.base_iata ?? '']?.city ?? '—'}`} />
      <div className="row wrap">
        <Badge tone={ac.status === 'active' ? 'good' : ac.status === 'grounded' ? 'warn' : 'info'}>{STATUS_LABEL[ac.status]}{ac.status !== 'active' ? ` until week ${arrivalWeek(ac.available_day)}` : ''}</Badge>
        <Badge tone={terms?.holding === 'wet' ? 'warn' : 'neutral'}>{holdingLabel(ac)}</Badge>
        <Badge>{num(ageYears(ac, world.game_day), 1)} years old</Badge>
      </div>

      <div className="split">
        <div className="stack-lg">
          <div className="card stack">
            <div className="card-title" style={{ marginBottom: 0 }}><h2>How busy</h2><span className="small muted">{num(used, 1)} of {num(weekHours(t))} hours a week</span></div>
            <Bar value={used / weekHours(t)} warn={used / weekHours(t) > 0.85} />
            <p className="small muted">{used === 0 ? 'Idle aircraft still cost rent, crew and overheads every week.' : used / weekHours(t) > 0.85 ? 'Flying this much leaves little slack, so delays build up and punctuality suffers.' : `${pct(used / weekHours(t))} of its flying day is planned.`}</p>
          </div>
          <AircraftMoney id={ac.id} holding={terms?.holding} />
          <div className="card flush">
            <div className="card-title" style={{ padding: '14px 16px 0' }}><h2>Routes</h2><Button size="sm" kind="ghost" onClick={() => setSheet('route')}>Add to a route</Button></div>
            {rots.length === 0 ? <Empty title="Not flying any route">Add it to a route that starts or ends at {ac.base_iata}.</Empty> : (
              <div className="list">
                {rots.map((ro) => {
                  const r = routes.find((x) => x.id === ro.route_id);
                  return r ? (
                    <Link key={ro.route_id} to={`/route/${r.id}`} className="item link" style={{ color: 'inherit' }}>
                      <div className="grow"><div className="strong">{ref.airport[r.origin]?.city} – {ref.airport[r.dest]?.city}</div><div className="tiny muted">{r.origin}–{r.dest}</div></div>
                      <span className="num">{ro.weekly_trips} a week</span>
                    </Link>
                  ) : null;
                })}
              </div>
            )}
          </div>
        </div>

        <div className="stack-lg">
          <div className="card stack">
            <h2>Cabin</h2>
            <div className="kv">
              <span>Seats</span><span>{ac.seats_biz ? `${ac.seats_biz} business + ` : ''}{ac.seats_econ} economy</span>
              {ac.biz_rows > 0 && <><span>Business</span><span>{ac.biz_rows} rows at {ac.biz_pitch ?? 44} in</span></>}
              <span>Economy pitch</span><span>{ac.econ_pitch} in</span>
              <span>Range with this cabin</span><span>{num(cabinRange(t, seats))} km</span>
              <span>Cabin crew</span><span>{Math.ceil(seats / 50)}</span>
            </div>
            {terms?.holding !== 'wet' && (ac.status === 'active' || ac.status === 'grounded') && (
              <Button kind="secondary" onClick={() => nav(`/configure/${ac.type_id}?aircraft=${ac.id}`)}>Change cabin</Button>
            )}
          </div>
          <div className="card stack">
            <h2>Terms</h2>
            <div className="kv">
              {terms?.holding === 'lease' && <>
                <span>Rent</span><span>{usd(terms.lease_usd_month)} a month</span>
                <span>Lease ends</span><span>{terms.lease_end_day != null ? `week ${weekOf(terms.lease_end_day)}` : '–'}</span>
                <span>Deposit held</span><span>{inr(terms.deposit_inr)}</span>
              </>}
              {terms?.holding === 'wet' && <>
                <span>Rate</span><span>{usd(terms.wet_usd_bh)} a block hour</span>
                <span>Minimum</span><span>{ref.param.wet_min_hours_day} hours a day</span>
                <span>Runs at least</span><span>{terms.wet_min_until && terms.wet_min_until > world.game_day + 1
                  ? `until week ${weekOf(terms.wet_min_until)}: ending sooner pays the minimum hours left` : terms.starter ? 'no minimum: your starting aircraft' : 'its minimum has passed: end it any week'}</span>
                <span>Includes</span><span>crew and maintenance</span>
              </>}
              {terms?.holding === 'owned' && <>
                <span>Bought for</span><span>{usd(terms.price_usd)}</span>
                {terms.loan_usd ? <><span>Loan left</span><span>{usd(terms.loan_usd)}</span><span>Repaid a week</span><span>{usd((terms.loan_pay_usd_day ?? 0) * 7)}</span></> : null}
                {terms.loan_inr ? <><span>Rupee loan left</span><span>{inr(terms.loan_inr)}</span><span>Repaid a week</span><span>{inr((terms.loan_pay_inr_day ?? 0) * 7)}</span></> : null}
                {ac.status === 'delivering' && <><span>Paying with</span><span>{terms.finance_loan ? (terms.loan_ccy === 'inr' ? 'a rupee loan' : 'a dollar loan') : terms.pay_plan === 'slb' ? 'sale and leaseback' : 'cash'}</span></>}
              </>}
            </div>
          </div>
          <div className="card stack">
            <h2>Options</h2>
            <Button kind="secondary" onClick={() => setSheet('base')}>Move to another base</Button>
            <Button kind="danger" onClick={() => setSheet('return')}>{returnLabel}</Button>
          </div>
        </div>
      </div>

      {sheet === 'route' && <AddToRoute acId={ac.id} onClose={() => setSheet(null)} used={used} markets={markets.data} />}
      {sheet === 'base' && <MoveBase acId={ac.id} current={ac.base_iata} hasRoutes={rots.length > 0} onClose={() => setSheet(null)} />}
      {sheet === 'return' && (
        <Sheet title={returnLabel} onClose={() => setSheet(null)}>
          <div className="stack">
            <p className="small">
              {(terms?.holding === 'lease' || terms?.holding === 'wet') && <ReturnCost acId={ac.id} holding={terms.holding} delivering={ac.status === 'delivering'} />}
              {terms?.holding === 'owned' && `It sells at ${pct(ref.param.sale_discount)} of its book value${terms.loan_usd || terms.loan_inr ? ', and the rest of its loan is repaid from the proceeds' : ''}. It goes to the lessor pool.`}
              {' '}Its routes lose this aircraft at once.
            </p>
            <Button kind="danger-solid" block busy={busy === 'ret'} onClick={() => run('ret', () => call<{ cash_inr: number; pnl_inr: number }>('return_aircraft', { p_airline: airline.id, p_aircraft: ac.id }),
              (r) => terms?.holding === 'wet' ? `${ac.reg}'s wet lease has ended.` : `${ac.reg} is gone. Cash ${inr(r.cash_inr, { sign: true })}, profit effect ${inr(r.pnl_inr, { sign: true })}.`).then((r) => { if (r) nav('/fleet'); })}>
              {returnLabel}{terms?.holding === 'lease' || terms?.holding === 'wet' ? <ReturnPrice acId={ac.id} /> : null}
            </Button>
          </div>
        </Sheet>
      )}
    </div>
  );
}

/** The cash an aircraft's return moves, for its button: what is paid, or what comes back. */
function ReturnPrice({ acId }: { acId: string }) {
  const x = useQuote<{ fee_inr: number | null; cash_inr: number; gone?: boolean }>('return', acId).data;
  if (!x || x.gone || x.fee_inr == null) return null;
  return <>{x.cash_inr < 0 ? ` · pay ${inr(-x.cash_inr)}` : x.cash_inr > 0 ? ` · ${inr(x.cash_inr)} back` : ' · nothing to pay'}</>;
}

// 0033: what giving it back costs, before it is given back
function ReturnCost({ acId, holding, delivering }: { acId: string; holding: 'lease' | 'wet'; delivering: boolean }) {
  const q = useQuote<{ fee_inr: number | null; cash_inr: number; deposit_inr?: number; months?: number; gone?: boolean }>('return', acId);
  const x = q.data;
  if (!x) return <span className="muted">Working out the cost… </span>;
  if (x.gone) return null;
  if (holding === 'wet') {
    return <>{x.fee_inr ? `A wet lease runs at least 13 weeks from its arrival: ending it now pays the minimum hours left, ${inr(x.fee_inr)}.` : 'The wet lease ends from this week. Nothing more is owed.'} </>;
  }
  if (delivering) return <>It has not arrived: the deposit of {inr(x.deposit_inr ?? 0)} is lost. </>;
  return <>The rent for the rest of the lease is owed, up to {x.months} months: {inr(x.fee_inr ?? 0)}, taken from your deposit of {inr(x.deposit_inr ?? 0)}{x.cash_inr >= 0 ? `, so ${inr(x.cash_inr)} comes back` : `, so ${inr(-x.cash_inr)} more is paid`}. The aircraft goes back to the lessor pool, where a rival can lease it. </>;
}

function AddToRoute({ acId, onClose, used, markets }: { acId: string; onClose: () => void; used: number; markets?: Record<string, import('../lib/types').Market> }) {
  const { ref, airline, world } = useGame();
  const turnDelta = useTurnDelta();
  const fleet = useFleet();
  const net = useRoutes();
  const { run, busy } = useAction();
  const ac = fleet.data!.find((a) => a.id === acId)!;
  const t = ref.type[ac.type_id];
  const taken = new Set((net.data?.rotations ?? []).filter((r) => r.aircraft_id === acId).map((r) => r.route_id));
  const options = (net.data?.routes ?? []).filter((r) => !taken.has(r.id) && ac.base_iata && [r.origin, r.dest].includes(ac.base_iata));
  // routes it cannot fly (a runway too short, or beyond its range) show why, and cannot be picked
  // and routes abroad take only the seats still free between India and that country
  const seatRoom = useSeatRoom();
  const seats = ac.seats_econ + ac.seats_biz;
  const cannot = (o: { origin: string; dest: string }) =>
    cannotFly(t, seats, [ref.airport[o.origin], ref.airport[o.dest]], markets?.[pairKey(o.origin, o.dest)]?.km ?? 0);
  const capOf = (o: { origin: string; dest: string }) => seatCapOf(ref, seatRoom.data, [o.origin, o.dest]);
  const blocked = (o: { origin: string; dest: string }) => {
    const c = capOf(o);
    return cannot(o) ?? (c && c.cap(seats) === 0 ? { badge: 'Seats', why: `Seats to ${c.name} are full in this world` } : null);
  };
  const [pick, setPick] = useState<string | null>(options.find((o) => !blocked(o))?.id ?? null);
  const r = options.find((x) => x.id === pick);
  const km = r ? markets?.[pairKey(r.origin, r.dest)]?.km ?? 0 : 0;
  const rc = r ? capOf(r) : null;
  const max = r && !blocked(r) ? Math.min(maxWeekly(t, ac, km, used, turnDelta), rc ? rc.cap(seats) : 84) : 0;
  const [trips, setTrips] = useState<number | null>(null);
  // start from what the market can fill, less the seats the airline already flies there
  const want = r ? demandWeek(markets?.[pairKey(r.origin, r.dest)], world.demand_scale) ?? 0 : 0;
  const mineSeats = r ? (net.data?.rotations ?? []).filter((x) => x.route_id === r.id).reduce((s, x) => {
    const o = fleet.data!.find((a) => a.id === x.aircraft_id);
    return s + x.weekly_trips * ((o?.seats_econ ?? 0) + (o?.seats_biz ?? 0));
  }, 0) : 0;
  const fits = Math.max(1, Math.ceil(Math.max(0, want - mineSeats) / (seats * 0.85)));
  const tv = trips ?? Math.min(max, 14, fits);
  return (
    <Sheet title={`Add ${ac.reg} to a route`} onClose={onClose}>
      <div className="stack">
        {options.length === 0 ? <div className="card warn small">You have no other open route from {ac.base_iata}. Open one on the Network screen.</div> : (
          <>
            <div className="card flush"><div className="list">
              {options.map((o) => {
                const no = blocked(o);
                return (
                  <div key={o.id} className={`item ${no ? 'off' : 'link'} ${o.id === pick ? 'me' : ''}`} aria-disabled={!!no}
                    onClick={() => { if (!no) { setPick(o.id); setTrips(null); } }}>
                    <div className="grow">
                      <div>{ref.airport[o.origin]?.city} – {ref.airport[o.dest]?.city}</div>
                      {no && <div className="small bad-ink">{no.why}</div>}
                    </div>
                    {no ? <Badge tone="bad">{no.badge}</Badge> : <span className="tiny muted">{num(markets?.[pairKey(o.origin, o.dest)]?.km)} km</span>}
                  </div>
                );
              })}
            </div></div>
            {r && (max === 0 ? <div className="card warn small">No free hours left for this route. Take it off another route first.</div> : (
              <Field label={`Round trips a week (up to ${max})`}>
                <Stepper label="round trips a week" value={tv} min={1} max={max} onChange={setTrips} format={(x) => `${x} a week`} />
                <div className={`hint ${tv * seats + mineSeats > 2.5 * Math.max(1, want) ? 'bad-ink' : ''}`}>About {num(want)} travellers a week each way want this route, with every airline{mineSeats ? `; you already fly ${num(mineSeats)} seats` : ''}. {plural(tv, 'round trip')} is {num(tv * seats)} seats each way.</div>
              </Field>
            ))}
            <Button block disabled={!r || max === 0} busy={busy === 'add'} onClick={() => run('add', () => call('set_rotation', {
              p_airline: airline.id, p_aircraft: ac.id, p_route: r!.id, p_weekly_trips: tv,
            }), `${ac.reg} will fly ${tv} round trips a week`).then((x) => x !== undefined && onClose())}>Add</Button>
          </>
        )}
      </div>
    </Sheet>
  );
}

function MoveBase({ acId, current, hasRoutes, onClose }: { acId: string; current: string | null; hasRoutes: boolean; onClose: () => void }) {
  const { ref, airline } = useGame();
  const bases = useBases();
  const { run, busy } = useAction();
  const options = (bases.data ?? []).filter((b) => b.iata !== current);
  const [pick, setPick] = useState(options[0]?.iata ?? '');
  return (
    <Sheet title="Move to another base" onClose={onClose}>
      <div className="stack">
        {hasRoutes && <div className="card warn small">Take this aircraft off its routes first.</div>}
        {options.length === 0 ? <div className="card info small">You have only one base. Open another on the Network screen.</div> : (
          <>
            <Field label="New base">
              <select className="input" value={pick} onChange={(e) => setPick(e.target.value)}>
                {options.map((b) => <option key={b.iata} value={b.iata}>{ref.airport[b.iata]?.city} ({b.iata})</option>)}
              </select>
            </Field>
            <FerryCost acId={acId} to={pick} />
            <Button block disabled={hasRoutes || !pick} busy={busy === 'move'} onClick={() => run('move', () => call('rebase_aircraft', {
              p_airline: airline.id, p_aircraft: acId, p_base: pick,
            }), `Moved to ${pick}`).then((x) => x !== undefined && onClose())}>Move</Button>
          </>
        )}
      </div>
    </Sheet>
  );
}

// 0033: one empty flight to the new base
function FerryCost({ acId, to }: { acId: string; to: string }) {
  const q = useQuote<{ cost_inr: number; gone?: boolean }>('ferry', acId, to, !!to);
  if (!to || !q.data || q.data.gone) return null;
  return <p className="small muted">{q.data.cost_inr > 0 ? `It flies there empty: fuel, crew, maintenance and fees, about ${inr(q.data.cost_inr)}.` : 'It is still on its way, so it is delivered there at no cost.'}</p>;
}

// Last week: the revenue an aircraft earned and the costs that belong to it. Pilot salaries, head office and
// marketing are left out: they are not split by aircraft.
function AircraftMoney({ id, holding }: { id: string; holding?: string }) {
  const { world } = useGame();
  const ad = useAircraftDaily();
  const s = ad.data ? aircraftStats(ad.data, world.game_day - 6)[id] : undefined;
  const per = (x: number) => (s && s.days ? (x * 7) / s.days : 0);
  const holdLabel = holding === 'wet' ? 'Wet-lease charge' : holding === 'owned' ? 'Ownership (depreciation, loan interest)' : 'Rent';
  return (
    <div className="card stack">
      <div className="card-title" style={{ marginBottom: 0 }}><h2>Money</h2><span className="small muted">last week</span></div>
      {!s ? <p className="small muted">Figures appear after its first week in service.</p> : (
        <>
          <div className="kv">
            <span>Revenue (fares and extras)</span><span>{inr(per(s.revenue))}</span>
            <span>Flying costs</span><span>−{inr(per(s.flying))}</span>
            <span>{holdLabel}{holding === 'wet' ? '' : ', cabin crew base pay'}</span><span>−{inr(per(s.holding))}</span>
            <span className="strong">Result</span><span className={`strong ${s.result >= 0 ? 'good' : 'bad'}`}>{inr(per(s.result), { sign: true })}</span>
          </div>
          <p className="tiny muted">Flying costs are fuel, flying pay, maintenance, airport charges, slots, and its share of sales and service. Pilot salaries, head office and marketing are not split by aircraft.</p>
        </>
      )}
    </div>
  );
}
