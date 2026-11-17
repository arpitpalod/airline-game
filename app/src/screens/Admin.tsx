// Admin: invite link, start, pause and resume. Only for profiles marked is_admin; the server checks this again.
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { call } from '../lib/api';
import { useGame, useWorldAirlines } from '../lib/data';
import { clock } from '../lib/game';
import { dayLabel, num, realSpan } from '../lib/format';
import { useToast } from '../components/toast';
import { Badge, Button, Empty, Kpi, PageHeader, Sheet } from '../components/ui';

export function Admin() {
  const { profile, world } = useGame();
  const airlines = useWorldAirlines();
  const toast = useToast();
  const qc = useQueryClient();
  const [confirm, setConfirm] = useState<'start' | 'pause' | 'resume' | null>(null);
  const [busy, setBusy] = useState(false);
  const invite = useQuery({ queryKey: ['admin', world.id, 'invite'], enabled: !!profile?.is_admin, queryFn: () => call<string>('admin_world_invite', { p_world: world.id }) });

  if (!profile?.is_admin) return <Empty title="Admins only" />;
  const players = (airlines.data ?? []).filter((a) => !a.is_ai);
  const link = invite.data ? `${location.origin}${location.pathname}#/join?code=${invite.data}` : '';
  const c = clock(world);

  async function act(fn: string, ok: string) {
    setBusy(true);
    try {
      await call(fn, { p_world: world.id });
      toast(ok);
      await qc.invalidateQueries({ queryKey: ['world', world.id] });
      setConfirm(null);
    } catch (e) { toast((e as Error).message, 'error'); } finally { setBusy(false); }
  }

  return (
    <div className="stack-lg">
      <PageHeader title="Admin" sub={world.name} />
      <div className="grid4-d">
        <Kpi label="Status" value={world.status} note={world.status === 'running' ? `${num(world.speed)}× speed` : ''} />
        <Kpi label="Game day" value={world.game_day} note={dayLabel(Math.max(1, world.game_day))} />
        <Kpi label="Players" value={`${players.length} / ${world.max_airlines}`} />
        <Kpi label="Demand scale" value={num(world.demand_scale, 2)} note="about players / 50" />
      </div>
      <div className="split-even">
        <div className="card stack">
          <h2>Invite colleagues</h2>
          <p className="small muted">Anyone with this link can create an account and found an airline in {world.name}.</p>
          {invite.error ? <div className="card bad small">{(invite.error as Error).message}</div> : (
            <div className="card tight num small" style={{ wordBreak: 'break-all' }}>{link || 'Loading…'}</div>
          )}
          <div className="row">
            <Button disabled={!link} onClick={async () => { await navigator.clipboard.writeText(link); toast('Invite link copied'); }}>Copy link</Button>
            {'share' in navigator && <Button kind="secondary" disabled={!link} onClick={() => navigator.share({ title: 'Join my airline game', text: `Run an airline against us. Invite code ${invite.data}.`, url: link }).catch(() => {})}>Share</Button>}
          </div>
          {invite.data && <p className="tiny muted">Invite code: <span className="num strong">{invite.data}</span></p>}
        </div>
        <div className="card stack">
          <h2>Clock</h2>
          {world.status === 'setup' && <>
            <p className="small muted">Starting fills the lessor pool and starts the clock: one game day every {realSpan(1, world.speed)}. The computer-run airlines are set up on day 1. Check the demand scale first: it can't change after the start.</p>
            <Button onClick={() => setConfirm('start')}>Start the world</Button>
          </>}
          {world.status === 'running' && <>
            <p className="small muted">Running. Next day due in about {c.nextInSec != null ? realSpan(c.nextInSec / 86400 * world.speed, world.speed) : '–'}.</p>
            <Button kind="secondary" onClick={() => setConfirm('pause')}>Pause</Button>
          </>}
          {world.status === 'paused' && <Button onClick={() => setConfirm('resume')}>Resume</Button>}
          {world.status === 'ended' && <Badge>Season over</Badge>}
        </div>
      </div>
      {confirm && (
        <Sheet title={confirm === 'start' ? 'Start the world?' : confirm === 'pause' ? 'Pause the world?' : 'Resume the world?'} onClose={() => setConfirm(null)}>
          <div className="stack">
            <p className="small">{confirm === 'start' ? `${players.length} players have joined. Players can still join after the start.` : confirm === 'pause' ? 'No game days are processed while paused, and players cannot act.' : 'Game days start again from where they stopped.'}</p>
            <Button block busy={busy} onClick={() => act(confirm === 'start' ? 'admin_start_world' : confirm === 'pause' ? 'admin_pause_world' : 'admin_resume_world',
              confirm === 'start' ? 'The world has started' : confirm === 'pause' ? 'Paused' : 'Resumed')}>
              {confirm === 'start' ? 'Start' : confirm === 'pause' ? 'Pause' : 'Resume'}
            </Button>
          </div>
        </Sheet>
      )}
    </div>
  );
}
