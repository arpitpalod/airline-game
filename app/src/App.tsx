import type { Session } from '@supabase/supabase-js';
import { useQueryClient } from '@tanstack/react-query';
import { useEffect, useMemo, useRef, useState } from 'react';
import { Navigate, Route, Routes, useLocation, useNavigate } from 'react-router-dom';
import { INVITE_KEY, supabase } from './lib/api';
import { GameContext, useMyAirlines, useProfile, useRefData, useWorldParams, useWorldRow, type Game } from './lib/data';
import { Shell } from './components/Shell';
import { ErrorBoundary } from './components/ErrorBoundary';
import { Button, ErrorBox } from './components/ui';
import { AuthScreen } from './screens/Auth';
import { SetupScreen } from './screens/Setup';
import { Home } from './screens/Home';
import { Network } from './screens/Network';
import { RouteDetail } from './screens/RouteDetail';
import { Fleet } from './screens/Fleet';
import { AircraftDetail } from './screens/AircraftDetail';
import { Configurator } from './screens/Configurator';
import { Market } from './screens/Market';
import { Money } from './screens/Money';
import { Ranks } from './screens/Ranks';
import { Admin } from './screens/Admin';
import { Extras } from './screens/Extras';
import { Insights } from './screens/Insights';
import { Ops, OpsDollar, OpsFuel, OpsMaint, OpsStyle } from './screens/Ops';
import { NewWorld, Worlds } from './screens/Worlds';

const PICK_KEY = 'airline-game-airline';
const JOIN_WORLD_KEY = 'airline-game-invite-world';   // the world an invite is for, when the app knows it (0027)

export function App() {
  const [session, setSession] = useState<Session | null | undefined>(undefined);
  // While a password is being reset the code signs the player in before the new password is saved: stay on the
  // sign-in screen until it is (spec 14.21).
  const [hold, setHold] = useState(false);
  const loc = useLocation();
  const [invite, setInvite] = useState<string | null>(() => localStorage.getItem(INVITE_KEY));

  // An invite link (#/join?code=...) is remembered until an airline is founded with it or the player cancels.
  useEffect(() => {
    const code = new URLSearchParams(loc.search).get('code');
    if (code) { localStorage.setItem(INVITE_KEY, code.trim().toLowerCase()); setInvite(code.trim().toLowerCase()); }
  }, [loc.search]);
  const clearInvite = () => { localStorage.removeItem(INVITE_KEY); localStorage.removeItem(JOIN_WORLD_KEY); setInvite(null); };
  // Join a world from the Worlds screen, or one just founded: the code is known, and so is the world.
  const startJoin = (code: string, worldId?: string) => {
    localStorage.setItem(INVITE_KEY, code);
    if (worldId) localStorage.setItem(JOIN_WORLD_KEY, worldId); else localStorage.removeItem(JOIN_WORLD_KEY);
    setInvite(code);
  };

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSession(data.session));
    const { data } = supabase.auth.onAuthStateChange((_e, s) => setSession(s));
    return () => data.subscription.unsubscribe();
  }, []);

  if (session === undefined) return <Splash />;
  if (!session || hold) return <AuthScreen setHold={setHold} />;
  return <SignedIn session={session} invite={invite} clearInvite={clearInvite} startJoin={startJoin} />;
}

function Splash() {
  return (
    <div style={{ minHeight: '100dvh', display: 'grid', placeItems: 'center' }}>
      <div className="logo lg" aria-label="Loading">✈</div>
    </div>
  );
}

function SignedIn({ session, invite, clearInvite, startJoin }: {
  session: Session; invite: string | null; clearInvite: () => void; startJoin: (code: string, worldId?: string) => void;
}) {
  const uid = session.user.id;
  const mine = useMyAirlines(uid);
  const profile = useProfile(uid);
  const ref = useRefData(true);
  const [picked, setPicked] = useState<string | null>(() => localStorage.getItem(PICK_KEY));
  const [founding, setFounding] = useState(false);
  const nav = useNavigate();

  const airlines = mine.data ?? [];
  const airline = airlines.find((a) => a.id === picked) ?? airlines[airlines.length - 1];
  const world = useWorldRow(airline?.world_id);
  // A world's own rules (its money, banks and growth) lie over the game's values everywhere in the app (0027).
  const wparams = useWorldParams(airline?.world_id);
  const gameRef = useMemo(() => (ref.data && wparams.data ? { ...ref.data, param: { ...ref.data.param, ...wparams.data } } : ref.data),
    [ref.data, wparams.data]);

  if (mine.isLoading || ref.isLoading) return <Splash />;
  if (mine.error || ref.error) return <div className="main"><ErrorBox error={mine.error || ref.error} retry={() => { mine.refetch(); ref.refetch(); }} /></div>;
  // A pending invite means the player wants an airline in another world: show setup even if they already have one.
  if (!airline || founding || invite) {
    return <SetupScreen uid={uid} email={session.user.email ?? ''} worldId={invite ? localStorage.getItem(JOIN_WORLD_KEY) ?? undefined : undefined}
      onDone={(id) => { localStorage.setItem(PICK_KEY, id); setPicked(id); setFounding(false); clearInvite(); mine.refetch(); nav('/'); }}
      onCancel={airline ? () => { setFounding(false); clearInvite(); } : undefined} />;
  }
  if (!world.data || wparams.isLoading) return world.error ? <div className="main"><ErrorBox error={world.error} retry={() => world.refetch()} /></div> : <Splash />;

  return (
    <GameProvider game={{
      uid, email: session.user.email ?? '', airline, world: world.data, ref: gameRef!, profile: profile.data ?? null, myAirlines: airlines,
      switchAirline: (id) => { if (id === 'new') { setFounding(true); return; } localStorage.setItem(PICK_KEY, id); setPicked(id); },
      startJoin,
    }} />
  );
}

function GameProvider({ game }: { game: Game }) {
  const qc = useQueryClient();
  const loc = useLocation();
  const lastDay = useRef(game.world.game_day);
  // A new game week means new results everywhere.
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
          <Route path="/ops" element={<Ops />} />
          <Route path="/ops/fuel" element={<OpsFuel />} />
          <Route path="/ops/dollars" element={<OpsDollar />} />
          <Route path="/ops/maintenance" element={<OpsMaint />} />
          <Route path="/ops/style" element={<OpsStyle />} />
          <Route path="/fleet" element={<Fleet />} />
          <Route path="/aircraft/:id" element={<AircraftDetail />} />
          <Route path="/configure/:type" element={<Configurator />} />
          <Route path="/market" element={<Market />} />
          <Route path="/money" element={<Money />} />
          <Route path="/ranks" element={<Ranks />} />
          <Route path="/admin" element={<Admin />} />
          <Route path="/worlds" element={<Worlds />} />
          <Route path="/worlds/new" element={<NewWorld />} />
          <Route path="/extras" element={<Extras />} />
          <Route path="/insights" element={<Insights />} />
          <Route path="/practice" element={<Insights />} />
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

