// Join with an invite code or sign in (spec 14.4 and 14.21). Joining checks the invite code, then signs up with
// Supabase Auth, which emails a 6-digit code to confirm the address; the code is typed here, so the player never
// leaves the app (a link in the email would open the phone's browser, not the installed app). A forgotten password
// is reset the same way: a 6-digit code by email, then a new password.
import { useEffect, useState, type FormEvent } from 'react';
import { useLocation } from 'react-router-dom';
import { INVITE_KEY, checkInvite, supabase } from '../lib/api';
import { Button, Field, Seg } from '../components/ui';

type Step = 'form' | 'confirm' | 'forgot' | 'recover';

// Supabase's messages, in the game's words where they are likely.
function plain(msg: string) {
  if (/rate limit/i.test(msg)) return 'Too many emails were sent just now. Try again in a few minutes.';
  if (/only request this after (\d+) seconds/i.test(msg)) return `Wait ${msg.match(/after (\d+) seconds/i)![1]} seconds before asking for another code.`;
  if (/expired|invalid/i.test(msg) && /token|otp|code/i.test(msg)) return 'That code is wrong or has expired. Check the latest email, or ask for a new code.';
  if (msg === 'Invalid login credentials') return 'That email and password do not match.';
  if (/password should be at least/i.test(msg)) return 'Password must be at least 8 characters.';
  return msg;
}

export function AuthScreen({ setHold }: { setHold?: (v: boolean) => void }) {
  const urlCode = new URLSearchParams(useLocation().search).get('code');
  const savedCode = urlCode ?? localStorage.getItem(INVITE_KEY) ?? '';
  const [mode, setMode] = useState<'join' | 'signin'>(savedCode ? 'join' : 'signin');
  const [step, setStep] = useState<Step>('form');
  const [code, setCode] = useState(savedCode);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [otp, setOtp] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [wait, setWait] = useState(0);   // seconds before another code can be sent
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [stuck, setStuck] = useState(false);   // signed in by the code, but the new password was not saved
  const mail = email.trim();

  useEffect(() => {
    if (wait <= 0) return;
    const t = setTimeout(() => setWait(wait - 1), 1000);
    return () => clearTimeout(t);
  }, [wait]);

  async function run(fn: () => Promise<void>) {
    setBusy(true); setError(null);
    try { await fn(); } catch (err) { setError(plain((err as Error).message)); } finally { setBusy(false); }
  }
  const go = (s: Step) => { setStep(s); setError(null); setOtp(''); };

  const submit = (e: FormEvent) => { e.preventDefault(); run(async () => {
    if (mode === 'signin') {
      const { error } = await supabase.auth.signInWithPassword({ email: mail, password });
      if (!error) return;
      if (/not confirmed/i.test(error.message)) {   // signed up but never typed the code: send a fresh one
        const r = await supabase.auth.resend({ type: 'signup', email: mail });
        if (r.error) throw r.error;
        setWait(60); go('confirm');
        return;
      }
      throw error;
    }
    localStorage.setItem(INVITE_KEY, code.trim().toLowerCase());
    await checkInvite(code.trim());
    const { data, error } = await supabase.auth.signUp({ email: mail, password });
    if (error) throw error;
    if (data.session) return;   // email confirmation is off: signed in already
    if (data.user && (data.user.identities?.length ?? 0) === 0) {
      // Already a player: sign in instead and keep the invite, so the next screen founds an airline in that world.
      const r = await supabase.auth.signInWithPassword({ email: mail, password });
      if (r.error) throw new Error('You already have an account with this email, and that password does not match it. Use Sign in, or Forgot password.');
      return;
    }
    setWait(60); go('confirm');
  }); };

  const confirm = (e: FormEvent) => { e.preventDefault(); run(async () => {
    const { error } = await supabase.auth.verifyOtp({ email: mail, token: otp.replace(/\D/g, ''), type: 'email' });
    if (error) throw error;
  }); };

  const resend = () => run(async () => {
    const { error } = step === 'confirm'
      ? await supabase.auth.resend({ type: 'signup', email: mail })
      : await supabase.auth.resetPasswordForEmail(mail);
    if (error) throw error;
    setWait(60);
  });

  const sendReset = (e: FormEvent) => { e.preventDefault(); run(async () => {
    const { error } = await supabase.auth.resetPasswordForEmail(mail);
    if (error) throw error;
    setWait(60); go('recover');
  }); };

  const recover = (e: FormEvent) => { e.preventDefault(); run(async () => {
    if (newPassword.length < 8) throw new Error('Password must be at least 8 characters.');
    setHold?.(true);
    const v = await supabase.auth.verifyOtp({ email: mail, token: otp.replace(/\D/g, ''), type: 'recovery' });
    if (v.error) { setHold?.(false); throw v.error; }
    const u = await supabase.auth.updateUser({ password: newPassword });
    if (u.error) { setStuck(true); throw new Error(`The code was right, but the new password was not saved: ${plain(u.error.message)}`); }
    setHold?.(false);
  }); };

  const resendLine = (
    <div className="row" style={{ justifyContent: 'space-between', gap: 12 }}>
      <button type="button" className="link-btn" disabled={wait > 0 || busy} onClick={resend}>
        {wait > 0 ? `Send again in ${Math.floor(wait / 60)}:${String(wait % 60).padStart(2, '0')}` : 'Send the code again'}</button>
      <button type="button" className="link-btn" onClick={() => go(step === 'confirm' ? 'form' : 'forgot')}>Wrong email? Change it</button>
    </div>
  );
  const codeField = (
    <Field label="6-digit code">
      <input className="input" value={otp} onChange={(e) => setOtp(e.target.value)} inputMode="numeric" autoComplete="one-time-code"
        maxLength={12} required style={{ fontSize: 22, letterSpacing: 6, textAlign: 'center' }} />
    </Field>
  );

  return (
    <div style={{ minHeight: '100dvh', display: 'grid', placeItems: 'center', padding: 20 }}>
      <div style={{ width: '100%', maxWidth: 420 }} className="stack-lg">
        <div className="stack" style={{ gap: 8 }}>
          <div className="logo lg">✈</div>
          <h1 style={{ fontSize: 28 }}>Run an airline</h1>
          <p className="muted">Compete with your colleagues for the same passengers, aircraft and airport slots. Five minutes a day is enough.</p>
        </div>

        {step === 'form' && (
          <form className="card stack" onSubmit={submit}>
            <Seg block value={mode} onChange={(m) => { setMode(m); setError(null); }}
              options={[{ value: 'join', label: 'I have an invite' }, { value: 'signin', label: 'Sign in' }]} />
            {mode === 'join' && (
              <Field label="Invite code" hint="From the link or message you were sent.">
                <input className="input" value={code} onChange={(e) => setCode(e.target.value)} autoCapitalize="none" autoCorrect="off" required />
              </Field>
            )}
            <Field label="Email" hint={mode === 'join' ? 'We email you a code to confirm it.' : undefined}>
              <input className="input" type="email" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="email" required />
            </Field>
            <Field label="Password" hint={mode === 'join' ? 'At least 8 characters.' : undefined}>
              <input className="input" type="password" value={password} onChange={(e) => setPassword(e.target.value)} minLength={mode === 'join' ? 8 : undefined}
                autoComplete={mode === 'join' ? 'new-password' : 'current-password'} required />
            </Field>
            {error && <div className="card bad small" role="alert">{error}</div>}
            <Button type="submit" block busy={busy}>{mode === 'join' ? 'Create account' : 'Sign in'}</Button>
            {mode === 'signin' && <button type="button" className="link-btn" onClick={() => go('forgot')}>Forgot password?</button>}
          </form>
        )}

        {step === 'confirm' && (
          <form className="card stack" onSubmit={confirm}>
            <h2>Check your email</h2>
            <p className="small">We sent a 6-digit code to <strong>{mail}</strong>. Type it here; no need to leave the app.</p>
            {codeField}
            {error && <div className="card bad small" role="alert">{error}</div>}
            <Button type="submit" block busy={busy}>Confirm</Button>
            {resendLine}
            <p className="tiny muted">The code works for one hour. Not there? Check spam.</p>
          </form>
        )}

        {step === 'forgot' && (
          <form className="card stack" onSubmit={sendReset}>
            <h2>Forgot password</h2>
            <Field label="Email" hint="Your account's email. We send a 6-digit code to it.">
              <input className="input" type="email" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="email" required />
            </Field>
            {error && <div className="card bad small" role="alert">{error}</div>}
            <Button type="submit" block busy={busy}>Send me a code</Button>
            <button type="button" className="link-btn" onClick={() => { setMode('signin'); go('form'); }}>Back to sign in</button>
          </form>
        )}

        {step === 'recover' && (
          <form className="card stack" onSubmit={recover}>
            <h2>New password</h2>
            <p className="small">If an account uses <strong>{mail}</strong>, a 6-digit code is on its way.</p>
            {codeField}
            <Field label="New password" hint="At least 8 characters.">
              <input className="input" type="password" value={newPassword} onChange={(e) => setNewPassword(e.target.value)} minLength={8}
                autoComplete="new-password" required />
            </Field>
            {error && <div className="card bad small" role="alert">{error}</div>}
            {stuck
              ? <Button type="button" block onClick={() => { setStuck(false); setHold?.(false); }}>Continue with the old password</Button>
              : <Button type="submit" block busy={busy}>Save and sign in</Button>}
            {resendLine}
          </form>
        )}

        <p className="tiny muted" style={{ textAlign: 'center' }}>
          On a phone, add this page to your home screen to use it like an app: in Safari tap Share, then Add to Home Screen.
        </p>
      </div>
    </div>
  );
}
