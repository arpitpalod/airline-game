// Tells an open app that a newer version has been published (version.json differs from the build it runs), so a tab
// left open for days does not keep running old code. Checks every five minutes and whenever the app comes back to the front.
import { useEffect, useState } from 'react';

async function latestBuild(): Promise<string | null> {
  try {
    const r = await fetch(`${import.meta.env.BASE_URL}version.json?t=${Date.now()}`, { cache: 'no-store' });
    return r.ok ? ((await r.json()) as { build?: string }).build ?? null : null;
  } catch {
    return null;   // offline: try again later
  }
}

/** Gets the new service worker in (it takes over at once) before reloading, so the reload serves the new files. */
async function update() {
  try {
    const reg = await navigator.serviceWorker?.getRegistration();
    if (reg) {
      await reg.update();
      if (reg.installing || reg.waiting) {
        await new Promise<void>((done) => {
          const t = setTimeout(done, 4000);
          navigator.serviceWorker.addEventListener('controllerchange', () => { clearTimeout(t); done(); }, { once: true });
        });
      }
    }
  } catch { /* reload anyway */ }
  location.reload();
}

export function UpdateBanner() {
  const [ready, setReady] = useState(false);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (import.meta.env.DEV) return;
    let live = true;
    const check = async () => { const b = await latestBuild(); if (live && b && b !== __BUILD__) setReady(true); };
    const onFront = () => { if (document.visibilityState === 'visible') void check(); };
    void check();
    const id = setInterval(check, 5 * 60_000);
    document.addEventListener('visibilitychange', onFront);
    window.addEventListener('focus', onFront);
    return () => { live = false; clearInterval(id); document.removeEventListener('visibilitychange', onFront); window.removeEventListener('focus', onFront); };
  }, []);
  if (!ready) return null;
  return (
    <div className="update-banner" role="status">
      <span>A new version of the game is ready.</span>
      <button type="button" disabled={busy} onClick={() => { setBusy(true); void update(); }}>{busy ? 'Updating…' : 'Update now'}</button>
    </div>
  );
}
