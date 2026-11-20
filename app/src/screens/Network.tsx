// Network: map of bases and routes, the route list, and opening bases and routes.
import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { call } from '../lib/api';
import { useBases, useGame, useMarketsFrom, useRouteDaily, useRoutes } from '../lib/data';
import { lfTone, routeStat } from '../lib/derive';
import { marketTotal, pairKey } from '../lib/game';
import { inr, num, pct, weekOf } from '../lib/format';
import type { Market } from '../lib/types';
import { WorldMap } from '../components/WorldMap';
import { useAction } from '../components/toast';
import { Badge, Bar, Button, Empty, Field, Icon, Loading, PageHeader, Seg, Sheet } from '../components/ui';
import { StudyCard } from '../components/Study';

export function Network() {
  const { ref, world, airline } = useGame();
  const bases = useBases();
  const net = useRoutes();
  const rd = useRouteDaily();
  const baseIatas = (bases.data ?? []).map((b) => b.iata);
  const markets = useMarketsFrom(baseIatas);
  const [sel, setSel] = useState<string | null>(null);
  const [opening, setOpening] = useState<{ base?: string; dest?: string } | null>(null);
  const nav = useNavigate();
  const routes = net.data?.routes ?? [];
  const rots = net.data?.rotations ?? [];
  const from7 = world.game_day - 6;

  const stats = useMemo(() => Object.fromEntries(routes.map((r) => [r.id, routeStat(rd.data ?? [], r.id, from7)])), [routes, rd.data, from7]);
  const mapRoutes = routes.map((r) => ({ key: r.id, a: r.origin, b: r.dest, tone: lfTone(stats[r.id]?.lf ?? null) }));
  const visibleAirports = ref.airports.filter((a) => a.opens_day <= world.game_day + 91);

  return (
    <div className="stack-lg">
      <PageHeader title="Network" sub={`${routes.length} ${routes.length === 1 ? 'route' : 'routes'} from ${baseIatas.length} ${baseIatas.length === 1 ? 'base' : 'bases'}`}
        actions={<><Button size="sm" kind="secondary" onClick={() => nav('/extras')}>Extras</Button><Button size="sm" onClick={() => setOpening({})}><Icon name="plus" />Open route</Button></>} />
      <div className="split">
        <div className="stack">
          <div className="phone-only"><WorldMap airports={visibleAirports} bases={baseIatas} routes={mapRoutes} selected={sel} onSelect={setSel} height={300} /></div>
          <div className="desk-only"><WorldMap airports={visibleAirports} bases={baseIatas} routes={mapRoutes} selected={sel} onSelect={setSel} height={600} /></div>
          <p className="tiny muted">Tap an airport to open a base or a route there.</p>
        </div>
        <div className="stack">
          <div className="card flush">
            <div className="card-title" style={{ padding: '14px 16px 0' }}><h2>Your routes</h2><span className="small muted">last 7 days</span></div>
            {net.isLoading ? <div style={{ padding: 16 }}><Loading /></div> : routes.length === 0 ? (
              <Empty title="No routes yet" action={<Button onClick={() => setOpening({})}>Open your first route</Button>}>
                A route links one of your bases to another airport. Then you put aircraft on it.
              </Empty>
            ) : (
              <div className="list">
                {routes.map((r) => {
                  const s = stats[r.id];
                  const m = markets.data?.[pairKey(r.origin, r.dest)];
                  const weekly = rots.filter((x) => x.route_id === r.id).reduce((a, x) => a + x.weekly_trips, 0);
                  return (
                    <div key={r.id} className="item link" onClick={() => nav(`/route/${r.id}`)}>
                      <div className="grow">
                        <div className="row between">
                          <span className="strong">{ref.airport[r.origin]?.city} – {ref.airport[r.dest]?.city}</span>
                          <span className="num strong">{s?.lf != null ? pct(s.lf) : '–'}</span>
                        </div>
                        <div className="row between tiny muted" style={{ margin: '2px 0 6px' }}>
                          <span>{r.origin}–{r.dest} · {weekly ? `${weekly} round trips a week` : 'no aircraft yet'}</span>
                          <span>{inr(r.fare_econ)}{m ? ` · ${(r.fare_econ / m.ref_fare).toFixed(2)}× ref` : ''}</span>
                        </div>
                        <Bar value={s?.lf ?? 0} warn={(s?.lf ?? 1) < 0.7} />
                      </div>
                      <Icon name="right" />
                    </div>
                  );
                })}
              </div>
            )}
          </div>
          <div className="card">
            <div className="card-title"><h2>Bases</h2></div>
            <div className="row wrap">
              {baseIatas.map((b) => <Badge key={b} tone="accent">{ref.airport[b]?.city} ({b})</Badge>)}
            </div>
            <p className="small muted" style={{ marginTop: 10 }}>Aircraft live at a base and every route starts at one. Another base costs {inr(ref.param.base_open_inr)} to open plus {inr(ref.param.base_fixed_inr_day * 7)} a week. Tap an Indian airport on the map to open one.</p>
          </div>
        </div>
      </div>
      {sel && <AirportSheet iata={sel} onClose={() => setSel(null)} bases={baseIatas} markets={markets.data}
        flying={new Set(routes.map((r) => pairKey(r.origin, r.dest)))} onRoute={(base, dest) => { setSel(null); setOpening({ base, dest }); }} />}
      {opening && <OpenRouteSheet initial={opening} bases={baseIatas} markets={markets.data} onClose={() => setOpening(null)}
        flying={new Set(routes.map((r) => pairKey(r.origin, r.dest)))} airlineId={airline.id} />}
    </div>
  );
}

const level = (x: number) => (x < 0.3 ? 'Low' : x < 0.6 ? 'Medium' : 'High');

function AirportSheet({ iata, onClose, bases, markets, flying, onRoute }: {
  iata: string; onClose: () => void; bases: string[]; markets?: Record<string, Market>; flying: Set<string>; onRoute: (base: string, dest: string) => void;
}) {
  const { ref, world, airline } = useGame();
  const a = ref.airport[iata];
  const { run, busy } = useAction();
  const isBase = bases.includes(iata);
  const fromBases = bases.filter((b) => b !== iata && markets?.[pairKey(b, iata)] && !flying.has(pairKey(b, iata)));
  const opensLater = a.opens_day > world.game_day + 1;
  return (
    <Sheet title={`${a.city} (${a.iata})`} onClose={onClose}>
      <div className="stack">
        <div className="row wrap">
          <Badge>{a.is_india ? 'India' : a.country}</Badge>
          <Badge tone={a.runway_class === 1 ? 'warn' : 'neutral'}>{['', 'Turboprops only', 'Up to A321', 'Any aircraft'][a.runway_class]}</Badge>
          {a.slot_cap && <Badge tone="warn">Congested: slots cost more</Badge>}
          {isBase && <Badge tone="accent">Your base</Badge>}
          {opensLater && <Badge tone="info">Opens in week {weekOf(a.opens_day)}</Badge>}
        </div>
        <div className="kv">
          {a.is_india ? <><span>Passengers a year</span><span>{num(a.pax_m, 1)} million</span></>
            : <><span>Traffic with India</span><span>{a.mass! >= 6 ? 'Very large' : a.mass! >= 2 ? 'Large' : a.mass! >= 0.8 ? 'Medium' : 'Small'}</span></>}
          <span>Business travel</span><span>{level(a.biz_idx)}</span>
          <span>Tourism</span><span>{level(a.tour_idx)}</span>
        </div>
        {fromBases.map((b) => {
          const m = markets![pairKey(b, iata)];
          return (
            <Button key={b} block onClick={() => onRoute(b, iata)}>Open route from {b} · {num(m.km)} km</Button>
          );
        })}
        {!isBase && a.is_india && !opensLater && (
          <Button block kind="secondary" busy={busy === 'base'}
            onClick={() => run('base', () => call('open_base', { p_airline: airline.id, p_iata: iata }), `${a.city} is now a base`).then((r) => r !== undefined && onClose())}>
            Open a base here · {inr(ref.param.base_open_inr)}
          </Button>
        )}
        {!a.is_india && fromBases.length === 0 && !bases.some((b) => flying.has(pairKey(b, iata))) && (
          <p className="small muted">No market links this airport with your bases. Foreign airports can only be reached from an Indian base.</p>
        )}
      </div>
    </Sheet>
  );
}

function OpenRouteSheet({ initial, bases, markets, onClose, flying, airlineId }: {
  initial: { base?: string; dest?: string }; bases: string[]; markets?: Record<string, Market>; onClose: () => void; flying: Set<string>; airlineId: string;
}) {
  const { ref, world } = useGame();
  const [base, setBase] = useState(initial.base ?? bases[0]);
  const [dest, setDest] = useState<string | null>(initial.dest ?? null);
  const [q, setQ] = useState('');
  const [scope, setScope] = useState<'india' | 'intl'>('india');
  const { run, busy } = useAction();
  const nav = useNavigate();

  const options = useMemo(() => Object.values(markets ?? {})
    .filter((m) => m.a === base || m.b === base)
    .map((m) => ({ m, other: m.a === base ? m.b : m.a }))
    .filter(({ other }) => ref.airport[other] && ref.airport[other].opens_day <= world.game_day + 1)
    .filter(({ m }) => (scope === 'intl') === m.intl)
    .filter(({ other }) => !q || `${ref.airport[other].city} ${other}`.toLowerCase().includes(q.toLowerCase()))
    .sort((x, y) => marketTotal(y.m) - marketTotal(x.m)), [markets, base, q, scope, ref.airport, world.game_day]);

  const m = dest ? markets?.[pairKey(base, dest)] : undefined;
  const [fare, setFare] = useState<number | null>(null);
  const fareVal = fare ?? m?.ref_fare ?? 0;

  if (!markets) return <Sheet title="Open a route" onClose={onClose}><Loading /></Sheet>;
  return (
    <Sheet title={dest && m ? `${ref.airport[base].city} – ${ref.airport[dest].city}` : 'Open a route'} onClose={onClose} wide>
      {dest && m ? (
        <div className="stack">
          <div className="kv">
            <span>Distance</span><span>{num(m.km)} km{m.intl ? ' · international' : ''}</span>
            <span>Potential travellers a week, each way</span><span>about {num(marketTotal(m) * world.demand_scale * 7)}</span>
            <span>Of whom on business</span><span>{pct(m.n_biz / marketTotal(m))}</span>
            <span>Reference fare</span><span>{inr(m.ref_fare)}</span>
          </div>
          {ref.airport[dest].runway_class === 1 && <div className="card warn small">{ref.airport[dest].city} takes turboprops only: only an ATR 72 can fly this route.</div>}
          {flying.has(pairKey(base, dest)) && <div className="card warn small">You already fly this route.</div>}
          <StudyCard a={base} b={dest} />
          <Field label="Economy fare" hint="Start near the reference fare. You can change it any time; it counts for the week being played.">
            <div className="row">
              <input className="input num" type="number" inputMode="numeric" step={100} value={fareVal} onChange={(e) => setFare(Number(e.target.value))} style={{ maxWidth: 180 }} />
              <span className="small muted">{m.ref_fare ? `${(fareVal / m.ref_fare).toFixed(2)}× reference` : ''}</span>
            </div>
          </Field>
          <div className="row">
            <Button kind="secondary" onClick={() => setDest(null)}>Back</Button>
            <div className="grow" />
            <Button busy={busy === 'open'} onClick={async () => {
              const id = await run('open', () => call<string>('open_route', { p_airline: airlineId, p_origin: base, p_dest: dest, p_fare_econ: Math.round(fareVal), p_fare_biz: null }), 'Route opened. Now put an aircraft on it.');
              if (id) { onClose(); nav(`/route/${id}?assign=1`); }
            }}>Open route</Button>
          </div>
        </div>
      ) : (
        <div className="stack">
          {bases.length > 1 && (
            <Field label="From">
              <select className="input" value={base} onChange={(e) => setBase(e.target.value)}>
                {bases.map((b) => <option key={b} value={b}>{ref.airport[b].city} ({b})</option>)}
              </select>
            </Field>
          )}
          <div className="row">
            <Seg value={scope} onChange={setScope} options={[{ value: 'india', label: 'Domestic' }, { value: 'intl', label: 'International' }]} />
          </div>
          <div className="search"><Icon name="search" /><input className="input" placeholder="Search city or code" value={q} onChange={(e) => setQ(e.target.value)} /></div>
          <p className="tiny muted">Sorted by potential travellers. Busy routes earn more but draw more rivals.</p>
          <div className="card flush" style={{ maxHeight: '50dvh', overflowY: 'auto' }}>
            <div className="list">
              {options.map(({ m: mk, other }) => (
                <div key={other} className="item link" onClick={() => { setDest(other); setFare(null); }}>
                  <div className="num strong" style={{ width: 40 }}>{other}</div>
                  <div className="grow">
                    <div>{ref.airport[other].city}{flying.has(pairKey(base, other)) && <span className="tiny muted"> · flying</span>}</div>
                    <div className="tiny muted">{num(mk.km)} km · about {num(marketTotal(mk) * world.demand_scale * 7)} a week · {inr(mk.ref_fare)}</div>
                  </div>
                  {ref.airport[other].runway_class === 1 && <Badge tone="warn">ATR only</Badge>}
                  <Icon name="right" />
                </div>
              ))}
              {options.length === 0 && <div className="item small muted">No destinations match.</div>}
            </div>
          </div>
        </div>
      )}
    </Sheet>
  );
}
