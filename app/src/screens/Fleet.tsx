// Fleet: every aircraft, what it does and what it costs. Cards on a phone, a table on a laptop.
import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAircraftDaily, useBases, useFleet, useGame, useMarketsFrom, useRoutes, useTurnDelta, type FleetItem } from '../lib/data';
import { aircraftStats, hoursByAircraft, windowShare } from '../lib/derive';
import { holdingLabel, STATUS_LABEL } from '../lib/game';
import { arrivalWeek, currentWeek, inr, pct, usd } from '../lib/format';
import { Badge, Bar, Button, Empty, Icon, Loading, PageHeader } from '../components/ui';

type Filter = 'all' | 'flying' | 'attention' | 'arriving';

export function costLabel(a: FleetItem) {
  const t = a.terms;
  if (!t) return '–';
  if (a.status === 'delivering' && t.ordered_day != null) return `New order · ${t.finance_loan ? (t.loan_ccy === 'inr' ? 'rupee loan' : 'dollar loan') : t.pay_plan === 'slb' ? 'leaseback' : 'cash'}`;
  if (t.holding === 'wet') return `${usd(t.wet_usd_bh)} a block hour`;
  if (t.holding === 'lease') return `${usd(t.lease_usd_month)} a month`;
  return t.loan_usd ? `Owned · ${usd(t.loan_usd)} loan` : t.loan_inr ? `Owned · ${inr(t.loan_inr)} loan` : 'Owned';
}

export function Fleet() {
  const { ref, world } = useGame();
  const turnDelta = useTurnDelta();
  const fleet = useFleet();
  const net = useRoutes();
  const bases = useBases();
  const markets = useMarketsFrom((bases.data ?? []).map((b) => b.iata));
  const [filter, setFilter] = useState<Filter>('all');
  const nav = useNavigate();
  const fl = fleet.data ?? [];
  const rots = net.data?.rotations ?? [];
  const routes = net.data?.routes ?? [];
  const hours = useMemo(() => (net.data ? hoursByAircraft(fl, routes, rots, markets.data, ref, turnDelta) : {}), [fl, routes, rots, markets.data, ref, net.data, turnDelta]);
  const ad = useAircraftDaily();
  const money = useMemo(() => aircraftStats(ad.data ?? [], world.game_day - 6), [ad.data, world.game_day]);
  // last week's result: revenue less flying costs and what holding the aircraft costs
  const result = (a: FleetItem) => {
    const s = money[a.id];
    if (!s || !s.days) return <span className="muted">–</span>;
    const r = (s.result * 7) / s.days;
    return <span className={`num ${r >= 0 ? 'good' : 'bad'}`}>{inr(r, { sign: true })}</span>;
  };
  const flying = new Set(rots.map((r) => r.aircraft_id));
  const needs = (a: FleetItem) => a.status === 'grounded' || (a.status === 'active' && !flying.has(a.id));
  const groups: Record<Filter, FleetItem[]> = {
    all: fl,
    flying: fl.filter((a) => a.status === 'active' && flying.has(a.id)),
    attention: fl.filter(needs),
    arriving: fl.filter((a) => a.status === 'delivering'),
  };
  const shown = groups[filter];
  const routeNames = (a: FleetItem) => rots.filter((r) => r.aircraft_id === a.id)
    .map((r) => routes.find((x) => x.id === r.route_id)).filter(Boolean).map((r) => `${r!.origin}–${r!.dest}`);

  const status = (a: FleetItem) => {
    if (a.status === 'delivering') return <Badge tone="info">Arrives week {arrivalWeek(a.available_day)}</Badge>;
    if (a.status === 'grounded') return <Badge tone="warn">Grounded to week {arrivalWeek(a.available_day)}</Badge>;
    if (a.status === 'refit') return <Badge tone="info">Refit to week {arrivalWeek(a.available_day)}</Badge>;
    if (a.status === 'active' && !flying.has(a.id)) return <Badge tone="warn">Not flying</Badge>;
    return <Badge tone="good">{STATUS_LABEL[a.status]}</Badge>;
  };

  return (
    <div className="stack-lg">
      <PageHeader title="Fleet" back="/ops" sub={`${fl.length} aircraft · week ${currentWeek(world)}`}
        actions={<Button size="sm" onClick={() => nav('/market')}><Icon name="plus" />Get aircraft</Button>} />
      <div className="chips" role="tablist">
        {([['all', 'All'], ['flying', 'Flying'], ['attention', 'Needs attention'], ['arriving', 'Arriving']] as [Filter, string][]).map(([k, l]) => (
          <button key={k} className={`chip ${filter === k ? 'on' : ''}`} onClick={() => setFilter(k)}>{l} {groups[k].length}</button>
        ))}
      </div>
      {fleet.isLoading ? <Loading h={200} /> : shown.length === 0 ? (
        <div className="card"><Empty title={filter === 'all' ? 'No aircraft' : 'Nothing here'}>{filter === 'all' ? 'Lease, order or wet-lease an aircraft to start flying.' : ''}</Empty></div>
      ) : (
        <>
          <div className="stack phone-only">
            {shown.map((a) => {
              const t = ref.type[a.type_id];
              const use = windowShare(a, hours[a.id] ?? 0, ref);
              const names = routeNames(a);
              return (
                <div key={a.id} className="card link" onClick={() => nav(`/aircraft/${a.id}`)}>
                  <div className="row between">
                    <div>
                      <div className="strong">{a.reg}</div>
                      <div className="tiny muted">{t.name} · {a.base_iata} · {a.seats_biz ? `${a.seats_biz}J ` : ''}{a.seats_econ}Y</div>
                    </div>
                    {status(a)}
                  </div>
                  <div className="small" style={{ margin: '10px 0 6px' }}>{names.length ? names.join(', ') : <span className="muted">No routes</span>}</div>
                  <div className="row"><div className="grow"><Bar value={use} warn={use > 0.85} /></div><span className="tiny muted nowrap">{pct(use)} of its day</span></div>
                  <div className="row between tiny muted" style={{ marginTop: 8 }}>
                    <span>{holdingLabel(a)}</span><span>{costLabel(a)}</span>
                  </div>
                  {money[a.id] && <div className="row between small" style={{ marginTop: 6 }}><span className="muted">Result last week</span>{result(a)}</div>}
                </div>
              );
            })}
          </div>
          <div className="card flush desk-only">
            <table className="table">
              <thead><tr><th>Aircraft</th><th>Type</th><th>Base</th><th className="r">Seats</th><th>Routes</th><th>Use of day</th><th>Holding</th><th className="r">Result last week</th><th>Status</th></tr></thead>
              <tbody>
                {shown.map((a) => {
                  const use = windowShare(a, hours[a.id] ?? 0, ref);
                  return (
                    <tr key={a.id} className="link" onClick={() => nav(`/aircraft/${a.id}`)}>
                      <td className="strong">{a.reg}</td>
                      <td>{ref.type[a.type_id].name}</td>
                      <td>{a.base_iata}</td>
                      <td className="r">{a.seats_biz ? `${a.seats_biz} + ` : ''}{a.seats_econ}</td>
                      <td className="small">{routeNames(a).join(', ') || <span className="muted">–</span>}</td>
                      <td style={{ minWidth: 130 }}><div className="row"><div className="grow"><Bar value={use} warn={use > 0.85} /></div><span className="tiny muted">{pct(use)}</span></div></td>
                      <td className="small">{holdingLabel(a)}<div className="tiny muted">{costLabel(a)}</div></td>
                      <td className="r small">{result(a)}</td>
                      <td>{status(a)}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </>
      )}
      <p className="small muted">An aircraft can fly {ref.type.A20N?.day_window_h ?? 17} hours a day (more for long-range types). Above 85% of that, flights start running late. Result last week is its revenue less its flying costs and rent or ownership, before pilot salaries, head office and marketing.</p>
    </div>
  );
}
