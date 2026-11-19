import { cloneElement, isValidElement, useEffect, useId, type ReactElement, type ReactNode } from 'react';
import { useNavigate } from 'react-router-dom';

const P: Record<string, ReactNode> = {
  home: <path d="M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z" />,
  network: <><circle cx="5" cy="18" r="2" /><circle cx="19" cy="6" r="2" /><circle cx="17" cy="18" r="2" /><path d="M6.5 16.5 17.5 7.5M7 18h8M18.5 8l-1 8" /></>,
  plane: <path d="M10.5 21 12 18l1.5 3M12 3c.8 0 1.5.7 1.5 1.5V9l7.5 4.5V16l-7.5-2.5V18H10.5v-4.5L3 16v-2.5L10.5 9V4.5C10.5 3.7 11.2 3 12 3z" />,
  money: <><rect x="3" y="6" width="18" height="13" rx="2" /><path d="M3 10h18M16 15h2" /></>,
  trophy: <><path d="M8 4h8v5a4 4 0 0 1-8 0zM8 6H4.5a3 3 0 0 0 3.5 4M16 6h3.5a3 3 0 0 1-3.5 4M12 13v4M8 21h8M9.5 17h5" /></>,
  market: <><path d="M4 9h16l-1 11H5zM8 9V7a4 4 0 0 1 8 0v2" /></>,
  shield: <path d="M12 3 4.5 6v5.5c0 4.5 3.2 8 7.5 9.5 4.3-1.5 7.5-5 7.5-9.5V6z" />,
  right: <path d="m9 6 6 6-6 6" />,
  left: <path d="m15 6-6 6 6 6" />,
  x: <path d="M6 6l12 12M18 6 6 18" />,
  plus: <path d="M12 5v14M5 12h14" />,
  search: <><circle cx="11" cy="11" r="6.5" /><path d="m20 20-4-4" /></>,
  alert: <><path d="M12 4 2.5 20h19z" /><path d="M12 10v4M12 17h.01" /></>,
  check: <path d="m5 12.5 4.5 4.5L19 7.5" />,
  out: <path d="M15 4h4a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1h-4M10 16l4-4-4-4M14 12H4" />,
  news: <><rect x="4" y="4" width="16" height="16" rx="2" /><path d="M8 9h8M8 13h8M8 17h5" /></>,
  seat: <path d="M7 4v9a2 2 0 0 0 2 2h7l2 5M7 13h9M6 20h4" />,
  more: <><circle cx="5" cy="12" r="1.4" /><circle cx="12" cy="12" r="1.4" /><circle cx="19" cy="12" r="1.4" /></>,
  refresh: <path d="M20 11a8 8 0 1 0-2.3 5.7M20 5v6h-6" />,
  pilot: <><circle cx="12" cy="10" r="3.5" /><path d="M5 21c1.2-3.5 4-5 7-5s5.8 1.5 7 5M7 6.5 12 4l5 2.5" /></>,
};

export function Icon({ name, size = 20 }: { name: keyof typeof P | string; size?: number }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round"
      width={size} height={size} aria-hidden="true">
      {P[name]}
    </svg>
  );
}

export function Button({ children, kind = 'primary', size, block, busy, disabled, onClick, type = 'button', title }: {
  children: ReactNode; kind?: 'primary' | 'secondary' | 'ghost' | 'danger' | 'danger-solid'; size?: 'sm';
  block?: boolean; busy?: boolean; disabled?: boolean; onClick?: () => void; type?: 'button' | 'submit'; title?: string;
}) {
  const cls = ['btn', kind !== 'primary' && kind, size, block && 'block'].filter(Boolean).join(' ');
  return (
    <button type={type} className={cls} disabled={disabled || busy} onClick={onClick} title={title}>
      {busy ? <span className="spinner" /> : children}
    </button>
  );
}

export function Badge({ tone = 'neutral', children }: { tone?: 'neutral' | 'good' | 'warn' | 'info' | 'bad' | 'accent'; children: ReactNode }) {
  return <span className={`badge ${tone}`}>{children}</span>;
}

export function PageHeader({ title, sub, back, actions }: { title: ReactNode; sub?: ReactNode; back?: string | true; actions?: ReactNode }) {
  const nav = useNavigate();
  return (
    <div className="page-head">
      {back && (
        <button className="back" aria-label="Back" onClick={() => (back === true ? nav(-1) : nav(back))}>
          <Icon name="left" />
        </button>
      )}
      <div className="grow">
        <h1>{title}</h1>
        {sub && <div className="sub">{sub}</div>}
      </div>
      {actions && <div className="row">{actions}</div>}
    </div>
  );
}

export function Kpi({ label, value, note, tone }: { label: string; value: ReactNode; note?: ReactNode; tone?: 'good' | 'bad' }) {
  return (
    <div className="card tight kpi">
      <div className="label">{label}</div>
      <div className={`value ${tone ?? ''}`}>{value}</div>
      {note && <div className="note">{note}</div>}
    </div>
  );
}

export function Stepper({ value, onChange, step = 1, min = -Infinity, max = Infinity, format, label, disabled }: {
  value: number; onChange: (v: number) => void; step?: number; min?: number; max?: number; format?: (v: number) => ReactNode; label?: string; disabled?: boolean;
}) {
  const clamp = (v: number) => Math.min(max, Math.max(min, v));
  return (
    <div className="stepper" role="group" aria-label={label} style={disabled ? { opacity: 0.45 } : undefined}>
      <button aria-label={`Less ${label ?? ''}`} disabled={disabled || value <= min} onClick={() => onChange(clamp(value - step))}>−</button>
      <div className="val" aria-live="polite">{format ? format(value) : value}</div>
      <button aria-label={`More ${label ?? ''}`} disabled={disabled || value >= max} onClick={() => onChange(clamp(value + step))}>+</button>
    </div>
  );
}

export function Seg<T extends string>({ value, options, onChange, block }: {
  value: T; options: { value: T; label: ReactNode }[]; onChange: (v: T) => void; block?: boolean;
}) {
  return (
    <div className={`seg ${block ? 'block' : ''}`} role="tablist">
      {options.map((o) => (
        <button key={o.value} role="tab" aria-selected={o.value === value} className={o.value === value ? 'on' : ''} onClick={() => onChange(o.value)}>
          {o.label}
        </button>
      ))}
    </div>
  );
}

export function Sheet({ title, onClose, children, wide }: { title: ReactNode; onClose: () => void; children: ReactNode; wide?: boolean }) {
  useEffect(() => {
    const k = (e: KeyboardEvent) => e.key === 'Escape' && onClose();
    window.addEventListener('keydown', k);
    document.body.style.overflow = 'hidden';
    return () => { window.removeEventListener('keydown', k); document.body.style.overflow = ''; };
  }, [onClose]);
  return (
    <div className="scrim" onClick={onClose}>
      <div className={`sheet ${wide ? 'wide' : ''}`} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()}>
        <div className="grab" />
        <div className="sheet-head">
          <h2>{title}</h2>
          <button className="x" aria-label="Close" onClick={onClose}><Icon name="x" /></button>
        </div>
        {children}
      </div>
    </div>
  );
}

export function Field({ label, hint, children }: { label: string; hint?: ReactNode; children: ReactNode }) {
  const id = useId();
  // A single input or select gets an id so the label names it (screen readers, tests).
  const control = isValidElement(children) && typeof children.type === 'string' && ['input', 'select', 'textarea'].includes(children.type);
  return (
    <div className="field">
      <label htmlFor={control ? id : undefined}>{label}</label>
      {control ? cloneElement(children as ReactElement<{ id?: string }>, { id }) : children}
      {hint && <div className="hint">{hint}</div>}
    </div>
  );
}

export function Empty({ title, children, action }: { title: string; children?: ReactNode; action?: ReactNode }) {
  return (
    <div className="empty">
      <h3>{title}</h3>
      {children && <p className="small">{children}</p>}
      {action && <div style={{ marginTop: 14 }}>{action}</div>}
    </div>
  );
}

export function Loading({ h = 120 }: { h?: number }) {
  return <div className="skeleton" style={{ height: h }} aria-label="Loading" />;
}

export function ErrorBox({ error, retry }: { error: unknown; retry?: () => void }) {
  return (
    <div className="card bad row">
      <div className="grow small">{(error as Error)?.message ?? 'Something went wrong'}</div>
      {retry && <Button kind="secondary" size="sm" onClick={retry}>Try again</Button>}
    </div>
  );
}

export function Logo({ code, color, lg }: { code: string; color?: string; lg?: boolean }) {
  return <div className={`logo ${lg ? 'lg' : ''}`} style={{ background: color || 'var(--accent)' }}>{code}</div>;
}

export function Bar({ value, warn }: { value: number; warn?: boolean }) {
  return <div className={`bar ${warn ? 'warn' : ''}`}><div style={{ width: `${Math.max(0, Math.min(1, value)) * 100}%` }} /></div>;
}
