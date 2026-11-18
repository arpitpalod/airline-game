// One layout that changes with screen size: bottom tabs on a phone, a sidebar on a laptop.
import { useEffect, useState, type ReactNode } from 'react';
import { NavLink, useLocation } from 'react-router-dom';
import { supabase } from '../lib/api';
import { useGame } from '../lib/data';
import { clock } from '../lib/game';
import { dayLabel, realSpan } from '../lib/format';
import { Icon, Logo } from './ui';

const TABS = [
  { to: '/', label: 'Home', icon: 'home' },
  { to: '/network', label: 'Network', icon: 'network' },
  { to: '/fleet', label: 'Fleet', icon: 'plane' },
  { to: '/money', label: 'Money', icon: 'money' },
  { to: '/ranks', label: 'Ranks', icon: 'trophy' },
];

export function Shell({ children }: { children: ReactNode }) {
  const { airline, world, profile, myAirlines, switchAirline } = useGame();
  const loc = useLocation();
  useEffect(() => { window.scrollTo(0, 0); }, [loc.pathname]);
  const side = [...TABS.slice(0, 3), { to: '/market', label: 'Get aircraft', icon: 'market' }, { to: '/pilots', label: 'Pilots', icon: 'pilot' }, ...TABS.slice(3),
    ...(profile?.is_admin ? [{ to: '/admin', label: 'Admin', icon: 'shield' }] : [])];
  // Market and aircraft pages belong to the Fleet tab, route pages to Network.
  const tabActive = (to: string) => {
    const p = loc.pathname;
    if (to === '/') return p === '/';
    if (to === '/fleet') return p.startsWith('/fleet') || p.startsWith('/aircraft') || p.startsWith('/market') || p.startsWith('/configure') || p.startsWith('/pilots');
    if (to === '/network') return p.startsWith('/network') || p.startsWith('/route') || p.startsWith('/extras');
    if (to === '/ranks') return p.startsWith('/ranks') || p.startsWith('/admin');
    return p.startsWith(to);
  };
  const sideActive = (to: string) => {
    const p = loc.pathname;
    if (to === '/market') return p.startsWith('/market');
    if (to === '/pilots') return p.startsWith('/pilots');
    if (to === '/fleet') return p.startsWith('/fleet') || p.startsWith('/aircraft') || p.startsWith('/configure');
    if (to === '/ranks') return p.startsWith('/ranks');
    if (to === '/admin') return p.startsWith('/admin');
    return tabActive(to);
  };
  const color = airline.livery?.color;
  return (
    <div className="frame">
      <aside className="sidebar">
        <div className="side-brand">
          <Logo code={airline.code} color={color} />
          <div className="grow">
            <div className="strong" style={{ lineHeight: 1.2 }}>{airline.name}</div>
            <div className="tiny muted">{world.name}</div>
          </div>
        </div>
        <nav className="side-nav">
          {side.map((t) => (
            <NavLink key={t.to} to={t.to} className={() => (sideActive(t.to) ? 'active' : '')}>
              <Icon name={t.icon} />{t.label}
            </NavLink>
          ))}
        </nav>
        <div className="side-foot">
          <WorldClock />
          {myAirlines.length > 0 && (
            <select className="input" style={{ height: 36, fontSize: 13, marginTop: 10 }} value={airline.id}
              onChange={(e) => switchAirline(e.target.value)} aria-label="Switch airline">
              {myAirlines.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
              <option value="new">Join another world…</option>
            </select>
          )}
          <button className="btn ghost sm" style={{ marginTop: 8, paddingLeft: 0 }} onClick={() => supabase.auth.signOut()}>
            <Icon name="out" />Sign out
          </button>
        </div>
      </aside>
      <main className="main">
        <WorldBanner />
        {children}
      </main>
      <nav className="tabbar" aria-label="Main">
        {TABS.map((t) => (
          <NavLink key={t.to} to={t.to} className={() => (tabActive(t.to) ? 'active' : '')}>
            <Icon name={t.icon} />{t.label}
          </NavLink>
        ))}
      </nav>
    </div>
  );
}

export function WorldClock() {
  const { world } = useGame();
  const [, tick] = useState(0);
  useEffect(() => { const i = setInterval(() => tick((x) => x + 1), 30_000); return () => clearInterval(i); }, []);
  const c = clock(world);
  return (
    <div>
      <div className="strong" style={{ color: 'var(--ink)' }}>{dayLabel(Math.max(world.game_day, 1))}</div>
      <div className="tiny">
        {world.status === 'running' && c.nextInSec != null && `Next results in about ${realSpan(c.nextInSec / 86400 * world.speed, world.speed)}`}
        {world.status === 'setup' && 'World not started yet'}
        {world.status === 'paused' && 'Paused'}
        {world.status === 'ended' && 'Season over'}
      </div>
    </div>
  );
}

function WorldBanner() {
  const { world } = useGame();
  if (world.status === 'running') return null;
  const text = world.status === 'setup'
    ? 'The world has not started yet. Look around and plan; actions open when it starts. Your wet-leased aircraft will fly from day 1.'
    : world.status === 'paused' ? 'The world is paused. Results and actions resume when it restarts.' : 'This season is over.';
  return <div className="card info small" style={{ marginBottom: 16 }}>{text}</div>;
}
