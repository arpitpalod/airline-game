import { createContext, useCallback, useContext, useState, type ReactNode } from 'react';
import { useInvalidate } from '../lib/data';

type Toast = { id: number; text: string; kind: 'ok' | 'error' };
const Ctx = createContext<(text: string, kind?: 'ok' | 'error') => void>(() => {});

export function ToastProvider({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<Toast[]>([]);
  const push = useCallback((text: string, kind: 'ok' | 'error' = 'ok') => {
    const id = Date.now() + Math.random();
    setItems((x) => [...x.slice(-2), { id, text, kind }]);
    setTimeout(() => setItems((x) => x.filter((t) => t.id !== id)), kind === 'error' ? 6500 : 3500);
  }, []);
  return (
    <Ctx.Provider value={push}>
      {children}
      <div className="toasts" role="status" aria-live="polite">
        {items.map((t) => <div key={t.id} className={`toast ${t.kind === 'error' ? 'error' : ''}`}>{t.text}</div>)}
      </div>
    </Ctx.Provider>
  );
}

export const useToast = () => useContext(Ctx);

/** Runs a player action: shows the server's message on failure, refreshes the airline's data on success. */
export function useAction() {
  const toast = useToast();
  const invalidate = useInvalidate();
  const [busy, setBusy] = useState<string | null>(null);
  async function run<T>(key: string, fn: () => Promise<T>, ok?: string | ((r: T) => string)): Promise<T | undefined> {
    setBusy(key);
    try {
      const r = await fn();
      await invalidate();
      if (ok) toast(typeof ok === 'function' ? ok(r) : ok);
      return r;
    } catch (e) {
      toast((e as Error).message, 'error');
      return undefined;
    } finally {
      setBusy(null);
    }
  }
  return { run, busy };
}
