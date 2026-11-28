// The hub and route study (migration 0040): every route out of one airport with its own and connecting travellers,
// the top connecting markets through it, the connections to expect now and with a suggested set of routes.
import { useState } from 'react';
import { call } from '../lib/api';
import { useGame, useHubStudies, type HubStudy } from '../lib/data';
import { inr, num } from '../lib/format';
import { ShortNote, useShort } from './Cash';
import { useAction } from './toast';
import { Badge, Button } from './ui';

function Findings({ s }: { s: HubStudy }) {
  const { ref } = useGame();
  const r = s.result;
  const [all, setAll] = useState(false);
  const name = (x: string) => ref.airport[x]?.city ?? x;
  const spokes = all ? r.spokes : r.spokes.slice(0, 12);
  return (
    <div className="stack">
      <div className="kv small">
        <span>Connecting a week, your routes here now</span><span>{num(r.now.conn_wk)} ({r.now.spokes} {r.now.spokes === 1 ? 'route' : 'routes'})</span>
        <span>With the suggested {r.suggested.spokes.length} routes</span><span>{num(r.suggested.conn_wk)}</span>
        <span>Other airlines flying from here</span><span>{r.rivals.flying}, of which {r.rivals.connecting} sell connections</span>
      </div>
      <table className="table">
        <thead><tr><th>Route</th><th className="r">Own a week</th><th className="r">Connecting</th><th className="r">Airlines</th></tr></thead>
        <tbody>
          {spokes.map((x) => (
            <tr key={x.x} className={x.yours ? 'me' : ''}>
              <td>{name(x.x)} {x.suggested && <Badge tone="accent">suggested</Badge>}{x.yours && !x.network && <Badge tone="warn">nonstop only</Badge>}</td>
              <td className="r num">{num(x.own_wk)}</td><td className="r num">{num(x.conn_wk)}</td><td className="r num">{x.carriers}</td>
            </tr>
          ))}
        </tbody>
      </table>
      {r.spokes.length > 12 && <Button size="sm" kind="secondary" onClick={() => setAll(!all)}>{all ? 'Show the best 12' : `Show all ${r.spokes.length}`}</Button>}
      <h3>Top connecting markets through {name(r.hub)}</h3>
      <table className="table">
        <thead><tr><th>Market</th><th className="r">A week</th><th className="r">Detour</th><th className="r">Nonstops</th></tr></thead>
        <tbody>
          {r.markets.map((m) => (
            <tr key={m.a + m.b}>
              <td>{name(m.a)} – {name(m.b)}</td><td className="r num">{num(m.conn_wk)}</td>
              <td className="r num">{m.detour > 1.005 ? `+${Math.round((m.detour - 1) * 100)}%` : '–'}</td>
              <td className="r num">{m.nonstops}{m.outside ? ' + airlines abroad' : ''}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="tiny muted">Travellers a week each way. Own: with you alone flying the route twice a day at the reference fare. Connecting: daily connections at {Math.round(Number(ref.param.hub_study_conn_pct) * 100)}% of the two routes' reference fares, if every route here sold network-based, against today's nonstops. Each figure is within about ±{Math.round(r.width * 100)}% and carries its own error; rivals' moves change them.</p>
    </div>
  );
}

/** Hub and route study for one airport (0040). */
export function HubStudyCard({ iata, flat }: { iata: string; flat?: boolean }) {
  const { ref, world, airline } = useGame();
  const studies = useHubStudies();
  const { run, busy } = useAction();
  const last = (studies.data ?? []).find((s) => s.hub === iata);
  const age = last ? world.game_day + 1 - last.game_day : null;
  const cost = Number(ref.param.hub_study_inr);
  const short = useShort(cost);
  return (
    <div className={flat ? 'stack' : 'card stack'}>
      <div className="card-title" style={{ marginBottom: 0 }}>
        <h2>Hub and route study</h2>
        {last && <Badge tone={age! <= 91 ? 'info' : 'warn'}>{age! < 7 ? 'this week' : `${Math.floor(age! / 7)} ${age! < 14 ? 'week' : 'weeks'} old`}</Badge>}
      </div>
      {last ? <Findings s={last} />
        : <p className="small muted">Every route out of {ref.airport[iata]?.city ?? iata}: its own travellers and the connecting travellers it could carry through here, the best connecting markets, and the connections to expect with your routes now and with a suggested set.</p>}
      <Button size="sm" kind="secondary" busy={busy === 'hub'} disabled={short > 0}
        onClick={() => run('hub', () => call('hub_study', { p_airline: airline.id, p_hub: iata }), 'Study done. The findings are below.')}>
        {last ? 'Study again' : 'Study this hub'} · {inr(cost)}</Button>
      <ShortNote cost={cost} />
    </div>
  );
}
