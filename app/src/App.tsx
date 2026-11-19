import type { Session } from '@supabase/supabase-js';
import { useQueryClient } from '@tanstack/react-query';
import { useEffect, useMemo, useRef, useState } from 'react';
import { Navigate, Route, Routes, useLocation } from 'react-router-dom';
import { INVITE_KEY, supabase } from './lib/api';
import { GameContext, useMyAirlines, useProfile, useRefData, useWorldRow, type Game } from './lib/data';
import { Shell } from './components/Shell';
import { ErrorBoundary } from './components/ErrorBoundary';
import { Button, ErrorBox } from './components/ui';
import { AuthScreen } from './screens/Auth';
import { SetupScreen } from './screens/Setup';
import { Home } from './screens/Home';
import { Network } from './screens/Network';
import { RouteDetail } from './screens/RouteDetail';
import { Selling } from './screens/Selling';
import { Fleet } from './screens/Fleet';
import { AircraftDetail } from './screens/AircraftDetail';
import { Configurator } from './screens/Configurator';
import { Market } from './screens/Market';
import { Money } from './screens/Money';
import { Ranks } from './screens/Ranks';
import { Admin } from './screens/Admin';
import { Extras } from './screens/Extras';

const PICK_KEY = 'airline-game-airline';

export function App() {
  const [session, setSession] = useState<Session | null | undefined>(undefined);
  const loc = useLocation();
  const [invite, setInvite] = useState<string | null>(() => localStorage.getItem(INVITE_KEY));

  // An invite link (#/join?code=...) is remembered until an airline is founded with it or the player cancels.
  useEffect(() => {
    const code = new URLSearchParams(loc.search).get('code');
    if (code) { localStorage.setItem(INVITE_KEY, code.trim().toLowerCase()); setInvite(code.trim().toLowerCase()); }
  }, [loc.search]);
  const clearInvite = () => { localStorage.removeItem(INVITE_KEY); setInvite(null); };

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSession(data.session));
    const { data } = supabase.auth.onAuthStateChange((_e, s) => setSession(s));
    return () => data.subscription.unsubscribe();
  }, []);

  if (session === undefined) return <Splash />;
  if (!session) return <AuthScreen />;
  return <SignedIn session={session} invite={invite} clearInvite={clearInvite} />;
}

function Splash() {
  return (
    <div style={{ minHeight: '100dvh', display: 'grid', placeItems: 'center' }}>
      <div className="logo lg" aria-label="Loading">✈</div>
    </div>
  );
}

function SignedIn({ session, invite, clearInvite }: { session: Session; invite: string | null; clearInvite: () => void }) {
  const uid = session.user.id;
  const mine = useMyAirlines(uid);
  const profile = useProfile(uid);
  const ref = useRefData(true);
  const [picked, setPicked] = useState<string | null>(() => localStorage.getItem(PICK_KEY));
  const [founding, setFounding] = useState(false);

  const airlines = mine.data ?? [];
  const airline = airlines.find((a) => a.id === picked) ?? airlines[airlines.length - 1];
  const world = useWorldRow(airline?.world_id);

  if (mine.isLoading || ref.isLoading) return <Splash />;
  if (mine.error || ref.error) return <div className="main"><ErrorBox error={mine.error || ref.error} retry={() => { mine.refetch(); ref.refetch(); }} /></div>;
  // A pending invite means the player wants an airline in another world: show setup even if they already have one.
  if (!airline || founding || invite) {
    return <SetupScreen uid={uid} email={session.user.email ?? ''}
      onDone={(id) => { localStorage.setItem(PICK_KEY, id); setPicked(id); setFounding(false); clearInvite(); mine.refetch(); }}
      onCancel={airline ? () => { setFounding(false); clearInvite(); } : undefined} />;
  }
  if (!world.data) return world.error ? <div className="main"><ErrorBox error={world.error} retry={() => world.refetch()} /></div> : <Splash />;

  return (
    <GameProvider game={{
      uid, email: session.user.email ?? '', airline, world: world.data, ref: ref.data!, profile: profile.data ?? null, myAirlines: airlines,
      switchAirline: (id) => { if (id === 'new') { setFounding(true); return; } localStorage.setItem(PICK_KEY, id); setPicked(id); },
    }} />
  );
}

function GameProvider({ game }: { game: Game }) {
  const qc = useQueryClient();
  const loc = useLocation();
  const lastDay = useRef(game.world.game_day);
  // A new game day means new results everywhere.
  useEffect(() => {
    if (game.world.game_day !== lastDay.current) {
      lastDay.current = game.world.game_day;
      qc.invalidateQueries({ predicate: (q) => q.queryKey[0] === 'a' || q.queryKey[0] === 'w' });
    }
  }, [game.world.game_day, qc]);
  const value = useMemo(() => game, [game]);
  return (
    <GameContext.Provider value={value}>
      <Shell>
        <ErrorBoundary key={loc.pathname}>
        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/network" element={<Network />} />
          <Route path="/route/:id" element={<RouteDetail />} />
          <Route path="/route/:id/sell" element={<Selling />} />
          <Route path="/fleet" element={<Fleet />} />
          <Route path="/aircraft/:id" element={<AircraftDetail />} />
          <Route path="/configure/:type" element={<Configurator />} />
          <Route path="/market" element={<Market />} />
          <Route path="/money" element={<Money />} />
          <Route path="/ranks" element={<Ranks />} />
          <Route path="/admin" element={<Admin />} />
          <Route path="/extras" element={<Extras />} />
          <Route path="/join" element={<Navigate to="/" replace />} />
          <Route path="*" element={<NotFound />} />
        </Routes>
        </ErrorBoundary>
      </Shell>
    </GameContext.Provider>
  );
}

function NotFound() {
  return <div className="card"><p>That page does not exist.</p><div style={{ marginTop: 12 }}><Button onClick={() => (location.hash = '#/')}>Go home</Button></div></div>;
}

