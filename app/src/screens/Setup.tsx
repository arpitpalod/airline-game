// Found an airline: name, code, first base and colour. Comes with a wet-leased aircraft that flies from day 1.
import { useMemo, useState } from 'react';
import { call, INVITE_KEY, supabase } from '../lib/api';
import { useRefData } from '../lib/data';
import { LIVERY_COLORS } from '../lib/game';
import { inr, num } from '../lib/format';
import { Badge, Button, Field, Icon, Logo } from '../components/ui';

export function SetupScreen({ uid, email, onDone, onCancel }: { uid: string; email: string; onDone: (id: string) => void; onCancel?: () => void }) {
  const ref = useRefData(true).data!;
  const [invite, setInvite] = useState(localStorage.getItem(INVITE_KEY) ?? '');
  const [name, setName] = useState('');
  const [code, setCode] = useState('');
  const [codeTouched, setCodeTouched] = useState(false);
  const [person, setPerson] = useState(email.split('@')[0]);
  const [base, setBase] = useState<string>('');
  const [color, setColor] = useState(LIVERY_COLORS[0]);
  const [q, setQ] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const autoCode = name.split(/\s+/).filter(Boolean).map((w) => w[0]).join('').toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 3)
    || name.replace(/[^A-Za-z0-9]/g, '').slice(0, 3).toUpperCase();
  const effCode = codeTouched ? code : autoCode.length >= 2 ? autoCode : (name.replace(/[^A-Za-z0-9]/g, '').slice(0, 3).toUpperCase());

  const bases = useMemo(() => ref.airports.filter((a) => a.is_india && a.opens_day <= 1)
    .filter((a) => !q || `${a.city} ${a.iata}`.toLowerCase().includes(q.toLowerCase()))
    .sort((a, b) => (b.pax_m ?? 0) - (a.pax_m ?? 0)), [ref.airports, q]);
  const chosen = base ? ref.airport[base] : null;
  const p = ref.param;

  async function found() {
    setBusy(true); setError(null);
    try {
      const id = await call<string>('found_airline', {
        p_invite: invite.trim(), p_name: name.trim(), p_code: effCode, p_base: base, p_display_name: person.trim() || null, p_livery: { color },
      });
      localStorage.removeItem(INVITE_KEY);
      onDone(id);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  const ready = invite.trim() && name.trim().length >= 3 && /^[A-Z0-9]{2,3}$/.test(effCode) && base;
  return (
    <div className="main" style={{ maxWidth: 1100, margin: '0 auto', paddingBottom: 40 }}>
      <div className="page-head">
        <div className="grow">
          <h1>Found your airline</h1>
          <div className="sub">Signed in as {email}. {onCancel ? '' : 'This takes a minute.'}</div>
        </div>
        {onCancel ? <Button kind="secondary" size="sm" onClick={onCancel}>Cancel</Button>
          : <Button kind="ghost" size="sm" onClick={() => supabase.auth.signOut()}>Sign out</Button>}
      </div>
      <div className="split">
        <div className="stack-lg">
          <div className="card stack">
            <Field label="Invite code"><input className="input" value={invite} onChange={(e) => setInvite(e.target.value)} autoCapitalize="none" /></Field>
            <Field label="Airline name" hint="3 to 30 characters. Fictional names only.">
              <input className="input" value={name} onChange={(e) => setName(e.target.value)} maxLength={30} placeholder="e.g. Tarang Air" />
            </Field>
            <div className="grid2">
              <Field label="Code" hint="2 or 3 letters">
                <input className="input" value={effCode} maxLength={3} onChange={(e) => { setCodeTouched(true); setCode(e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, '')); }} />
              </Field>
              <Field label="Your name" hint="Shown on the leaderboard">
                <input className="input" value={person} onChange={(e) => setPerson(e.target.value)} maxLength={40} />
              </Field>
            </div>
            <Field label="Colour">
              <div className="row wrap">
                {LIVERY_COLORS.map((c) => (
                  <button key={c} aria-label={`Colour ${c}`} onClick={() => setColor(c)}
                    style={{ width: 36, height: 36, borderRadius: 10, background: c, border: c === color ? '3px solid var(--ink)' : '3px solid transparent', cursor: 'pointer' }} />
                ))}
              </div>
            </Field>
          </div>

          <div className="card stack">
            <div>
              <h2>First base</h2>
              <p className="small muted" style={{ marginTop: 4 }}>Every route starts at one of your bases. Big airports have more travellers, but also more rivals and pricier slots. You can open more bases later for {inr(p.base_open_inr)} each.</p>
            </div>
            <div className="search">
              <Icon name="search" />
              <input className="input" placeholder="Search city or code" value={q} onChange={(e) => setQ(e.target.value)} />
            </div>
            <div className="card flush" style={{ maxHeight: 360, overflowY: 'auto' }}>
              <div className="list">
                {bases.map((a) => (
                  <div key={a.iata} className={`item link ${a.iata === base ? 'me' : ''}`} onClick={() => setBase(a.iata)} role="button" aria-pressed={a.iata === base}>
                    <div className="num strong" style={{ width: 40 }}>{a.iata}</div>
                    <div className="grow">
                      <div>{a.city}</div>
                      <div className="tiny muted">{num(a.pax_m, 1)} million passengers a year{a.slot_cap ? ' · congested' : ''}</div>
                    </div>
                    {a.runway_class === 1 && <Badge tone="warn">Turboprops only</Badge>}
                    {a.runway_class === 3 && <Badge tone="info">Widebodies</Badge>}
                    {a.iata === base && <Icon name="check" size={18} />}
                  </div>
                ))}
              </div>
            </div>
          </div>
        </div>

        <div className="stack-lg sticky-col">
          <div className="card stack">
            <div className="row">
              <Logo code={effCode || '—'} color={color} lg />
              <div className="grow">
                <h2 style={{ fontSize: 20 }}>{name.trim() || 'Your airline'}</h2>
                <div className="small muted">{chosen ? `Based at ${chosen.city} (${chosen.iata})` : 'Choose a first base'}</div>
              </div>
            </div>
            <div className="divider" />
            <div className="small strong">You start with</div>
            <div className="kv">
              <span>Capital</span><span>{inr(p.start_cash_inr)}</span>
              <span>Credit line</span><span>{inr(p.credit_limit_inr)}</span>
              <span>Aircraft</span><span>{chosen?.runway_class === 1 ? 'ATR 72' : 'A320neo'}, wet-leased</span>
            </div>
            <p className="small muted">The wet-leased aircraft comes with crew and can fly from your first day, but it is the most expensive way to fly. Replace it with a leased aircraft once you know where it earns.</p>
            {error && <div className="card bad small" role="alert">{error}</div>}
            <Button block busy={busy} disabled={!ready} onClick={found}>Found {name.trim() || 'airline'}</Button>
            {!ready && <p className="tiny muted" style={{ textAlign: 'center' }}>Needs an invite code, a name, a code and a base.</p>}
          </div>
          <p className="tiny faint">Account {uid.slice(0, 8)}</p>
        </div>
      </div>
    </div>
  );
}
