// Join with an invite code (creates the account, no email confirmation) or sign in.
import { useState, type FormEvent } from 'react';
import { useLocation } from 'react-router-dom';
import { INVITE_KEY, joinGame, supabase } from '../lib/api';
import { Button, Field, Seg } from '../components/ui';

export function AuthScreen() {
  const urlCode = new URLSearchParams(useLocation().search).get('code');
  const savedCode = urlCode ?? localStorage.getItem(INVITE_KEY) ?? '';
  const [mode, setMode] = useState<'join' | 'signin'>(savedCode ? 'join' : 'signin');
  const [code, setCode] = useState(savedCode);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true); setError(null);
    try {
      if (mode === 'join') {
        await joinGame(email.trim(), password, code.trim());
        localStorage.setItem(INVITE_KEY, code.trim().toLowerCase());
      }
      const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
      if (error) throw new Error(error.message === 'Invalid login credentials' ? 'That email and password do not match.' : error.message);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div style={{ minHeight: '100dvh', display: 'grid', placeItems: 'center', padding: 20 }}>
      <div style={{ width: '100%', maxWidth: 420 }} className="stack-lg">
        <div className="stack" style={{ gap: 8 }}>
          <div className="logo lg">✈</div>
          <h1 style={{ fontSize: 28 }}>Run an airline</h1>
          <p className="muted">Compete with your colleagues for the same passengers, aircraft and airport slots. Five minutes a day is enough.</p>
        </div>
        <form className="card stack" onSubmit={submit}>
          <Seg block value={mode} onChange={(m) => { setMode(m); setError(null); }}
            options={[{ value: 'join', label: 'I have an invite' }, { value: 'signin', label: 'Sign in' }]} />
          {mode === 'join' && (
            <Field label="Invite code" hint="From the link or message you were sent.">
              <input className="input" value={code} onChange={(e) => setCode(e.target.value)} autoCapitalize="none" autoCorrect="off" required />
            </Field>
          )}
          <Field label="Email">
            <input className="input" type="email" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="email" required />
          </Field>
          <Field label="Password" hint={mode === 'join' ? 'At least 8 characters. There is no reset by email, so keep it somewhere safe.' : undefined}>
            <input className="input" type="password" value={password} onChange={(e) => setPassword(e.target.value)} minLength={mode === 'join' ? 8 : undefined}
              autoComplete={mode === 'join' ? 'new-password' : 'current-password'} required />
          </Field>
          {error && <div className="card bad small" role="alert">{error}</div>}
          <Button type="submit" block busy={busy}>{mode === 'join' ? 'Create account' : 'Sign in'}</Button>
        </form>
        <p className="tiny muted" style={{ textAlign: 'center' }}>
          On a phone, add this page to your home screen to use it like an app: in Safari tap Share, then Add to Home Screen.
        </p>
      </div>
    </div>
  );
}
