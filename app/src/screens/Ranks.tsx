// Leaderboard (players only; computer-run airlines are not ranked), side boards, world events and news.
import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { rows, supabase } from '../lib/api';
import { useEvents, useGame, useNews, useQuarterlies, useWorldAirlines } from '../lib/data';
import { inr, num, pct, weekOf } from '../lib/format';
import type { Profile } from '../lib/types';
import { Badge, Loading, Logo, PageHeader, Seg } from '../components/ui';

const EVENT_TEXT: Record<string, string> = {
  fuel_shock: 'Fuel price shock', fx_swing: 'Rupee weakens', engine_grounding: 'Engine problem grounds part of a fleet', airport_opening: 'New airport opens', duty_rules: 'Stricter pilot duty-time rules',
  airport_closed: 'Airport closed', airspace_closed: 'Airspace west of India closed', fare_cap: 'Fares capped',
};

export function Ranks() {
  const { airline, world, ref } = useGame();
  const airlines = useWorldAirlines();
  const quarters = useQuarterlies();
  const news = useNews(40);
  const events = useEvents();
  const [board, setBoard] = useState<'score' | 'lf' | 'otp' | 'margin'>('score');
  const players = (airlines.data ?? []).filter((a) => !a.is_ai);
  const profiles = useQuery({
    queryKey: ['w', world.id, 'profiles', players.length], enabled: players.length > 0,
    queryFn: () => rows<Profile>(supabase.from('profiles').select('user_id,display_name,is_admin').in('user_id', players.map((p) => p.user_id!).filter(Boolean))),
  });
  const who = (uid: string | null) => profiles.data?.find((p) => p.user_id === uid)?.display_name;
  const latestQ = Math.max(0, ...(quarters.data ?? []).map((x) => x.quarter));
  const rep = (quarters.data ?? []).filter((x) => x.quarter === latestQ && players.some((p) => p.id === x.airline_id));
  const val = (x: (typeof rep)[number]) => board === 'score' ? x.score ?? 0 : board === 'lf' ? x.load_factor ?? 0 : board === 'otp' ? x.otp ?? 0 : x.revenue ? x.op_profit / x.revenue : -1;
  const sorted = [...rep].sort((a, b) => board === 'score' ? (a.rank ?? 999) - (b.rank ?? 999) : val(b) - val(a));

  return (
    <div className="stack-lg">
      <PageHeader title="Leaderboard" sub={`${players.length} ${players.length === 1 ? "player" : "players"} in ${world.name}`} />
      <div className="split">
        <div className="stack">
          <Seg value={board} onChange={setBoard} options={[
            { value: 'score', label: 'Score' }, { value: 'margin', label: 'Margin' }, { value: 'lf', label: 'Load' }, { value: 'otp', label: 'On time' },
          ]} />
          <div className="card flush">
            {quarters.isLoading || airlines.isLoading ? <div style={{ padding: 16 }}><Loading /></div> : latestQ === 0 ? (
              <>
                <p className="small muted" style={{ padding: '14px 16px 4px' }}>Ranks are published at the end of each quarter of flying, the first at the end of week {(world.prelaunch_weeks ?? 0) + 13}. Score is net worth plus {num(ref.param.score_profit_mult ?? 5)} times the last four quarters' profit after interest and tax{(ref.param.restart_score_mult ?? 0) > 0 ? `, less ${inr((ref.param.restart_score_mult ?? 1) * (ref.param.start_cash_inr ?? 0))} for each time the airline went into administration` : ''}.</p>
                <div className="list">
                  {players.map((p) => (
                    <div key={p.id} className={`item ${p.id === airline.id ? 'me' : ''}`}>
                      <Logo code={p.code} color={p.livery?.color} />
                      <div className="grow"><div className="strong">{p.name}</div><div className="tiny muted">{who(p.user_id) ?? ''} · joined week {weekOf(Math.max(p.created_day, 1))}</div></div>
                      {p.administrations > 0 && <Badge tone="bad">{p.administrations}× administration</Badge>}
                    </div>
                  ))}
                </div>
              </>
            ) : (
              <table className="table">
                <thead><tr><th>#</th><th>Airline</th><th className="r">{board === 'score' ? 'Score' : board === 'margin' ? 'Margin' : board === 'lf' ? 'Seats sold' : 'On time'}</th><th className="r desk-only">Profit</th><th className="r desk-only">Passengers</th></tr></thead>
                <tbody>
                  {sorted.map((x, i) => {
                    const a = players.find((p) => p.id === x.airline_id)!;
                    return (
                      <tr key={x.airline_id} className={x.airline_id === airline.id ? 'me' : ''}>
                        <td className="num">{board === 'score' ? x.rank ?? i + 1 : i + 1}</td>
                        <td><div className="row"><Logo code={a.code} color={a.livery?.color} /><div><div className="strong">{a.name}</div><div className="tiny muted">{who(a.user_id)}{a.administrations ? ` · ${a.administrations}× administration` : ''}</div></div></div></td>
                        <td className="r num strong">{board === 'score' ? inr(x.score) : board === 'margin' ? (x.revenue ? pct(x.op_profit / x.revenue) : '–') : pct(board === 'lf' ? x.load_factor : x.otp)}</td>
                        <td className="r desk-only">{inr(x.net_profit, { sign: true })}</td>
                        <td className="r desk-only">{num(x.pax)}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            )}
          </div>
          {latestQ > 0 && <p className="tiny muted">Quarter {latestQ}. Computer-run airlines are not ranked.</p>}
        </div>
        <div className="stack-lg">
          {(events.data ?? []).length > 0 && (
            <div className="card flush">
              <div className="card-title" style={{ padding: '14px 16px 0' }}><h2>World events</h2></div>
              <div className="list">
                {events.data!.map((e) => (
                  <div key={e.id} className="item small">
                    <span className="grow">{EVENT_TEXT[e.kind] ?? e.kind}{e.kind === 'airport_opening' && e.payload?.city ? `: ${e.payload.city as string}` : ''}{(e.kind === 'airport_closed' || e.kind === 'fare_cap') && e.payload?.airport ? `: ${e.payload.airport as string}` : ''}</span>
                    <span className="tiny muted">week {weekOf(e.starts_day)}{e.ends_day && weekOf(e.ends_day) !== weekOf(e.starts_day) ? `–${weekOf(e.ends_day)}` : ''}</span>
                  </div>
                ))}
              </div>
            </div>
          )}
          <div className="card flush">
            <div className="card-title" style={{ padding: '14px 16px 0' }}><h2>News</h2></div>
            <div className="list">
              {(news.data ?? []).map((n) => (
                <div key={n.id} className="item small" style={{ alignItems: 'flex-start' }}>
                  <span className="faint num" style={{ width: 58, flexShrink: 0 }}>Wk {weekOf(Math.max(n.game_day, 1))}</span>
                  <span className="grow">{n.body}</span>
                </div>
              ))}
              {news.data?.length === 0 && <div className="item small muted">No news yet.</div>}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
