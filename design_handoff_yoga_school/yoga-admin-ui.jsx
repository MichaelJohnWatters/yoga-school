// yoga-admin-ui.jsx — manager console shell + calm/spacious desktop primitives.
// Same semantic tokens as the student app; desktop density, generous air.

const K_NAV = [
  ['dashboard', 'Dashboard', 'M4 13h7V4H4v9zm9 7h7v-9h-7v9zm0-16v4h7V4h-7zM4 20h7v-4H4v4z'],
  ['schedule', 'Schedule', 'M8 2v4M16 2v4M3 9h18M5 4h14a2 2 0 012 2v14a2 2 0 01-2 2H5a2 2 0 01-2-2V6a2 2 0 012-2z'],
  ['products', 'Products', 'M20 12l-8 8-9-9V4h7l10 8zM7.5 7.5h.01'],
  ['students', 'Students', 'M12 12a4 4 0 100-8 4 4 0 000 8zM4 21c1.2-3.5 4.3-5 8-5s6.8 1.5 8 5'],
  ['roster', 'Roster', 'M9 11l3 3 8-8M21 12v6a2 2 0 01-2 2H5a2 2 0 01-2-2V6a2 2 0 012-2h11'],
  ['reports', 'Reports', 'M4 20V10M10 20V4M16 20v-7M21 20H3'],
  ['settings', 'Settings', 'M12 15a3 3 0 100-6 3 3 0 000 6zM19 12a7 7 0 00-.1-1.2l2-1.5-2-3.5-2.4 1a7 7 0 00-2-1.2L14 3h-4l-.5 2.6a7 7 0 00-2 1.2l-2.4-1-2 3.5 2 1.5A7 7 0 005 12a7 7 0 00.1 1.2l-2 1.5 2 3.5 2.4-1a7 7 0 002 1.2L10 21h4l.5-2.6a7 7 0 002-1.2l2.4 1 2-3.5-2-1.5c.07-.4.1-.8.1-1.2z'],
];

function KShell({ vars, active, title, sub, actions, children }) {
  return (
    <div style={{
      ...vars, display: 'flex', width: '100%', height: '100%', boxSizing: 'border-box',
      background: 'var(--bg)', fontFamily: '"Hanken Grotesk", system-ui, sans-serif',
      WebkitFontSmoothing: 'antialiased', overflow: 'hidden', textAlign: 'left',
    }}>
      {/* sidebar */}
      <div style={{ width: 208, flexShrink: 0, borderRight: '1px solid var(--border)', background: 'var(--surface)', display: 'flex', flexDirection: 'column', padding: '20px 12px' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '0 10px 18px' }}>
          <YLogo size={30}></YLogo>
          <div>
            <div style={{ fontSize: 13.5, fontWeight: 800, letterSpacing: -0.2 }}>Studio 52</div>
            <div style={{ fontSize: 10.5, fontWeight: 600, color: 'var(--muted)', letterSpacing: 0.6 }}>MANAGER</div>
          </div>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
          {K_NAV.map(([key, label, d]) => {
            const on = key === active;
            return (
              <div key={key} style={{
                display: 'flex', alignItems: 'center', gap: 10, padding: '9px 10px', borderRadius: 10,
                background: on ? 'var(--primary-soft)' : 'transparent',
                color: on ? 'var(--primary-strong)' : 'var(--muted)',
                fontSize: 13.5, fontWeight: on ? 700 : 600,
              }}>
                <YIcon d={d} size={17}></YIcon>{label}
              </div>
            );
          })}
        </div>
        <div style={{ marginTop: 'auto', display: 'flex', alignItems: 'center', gap: 9, padding: '10px 10px 0', borderTop: '1px solid var(--border)' }}>
          <YAvatar name="Priya Shah" size={30}></YAvatar>
          <div>
            <div style={{ fontSize: 12.5, fontWeight: 700 }}>Priya Shah</div>
            <div style={{ fontSize: 11, fontWeight: 500, color: 'var(--muted)' }}>Owner</div>
          </div>
        </div>
      </div>
      {/* content */}
      <div style={{ flex: 1, minWidth: 0, padding: '26px 30px', overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
        <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', marginBottom: 20 }}>
          <div>
            <div style={{ fontSize: 23, fontWeight: 800, letterSpacing: -0.5 }}>{title}</div>
            {sub && <div style={{ fontSize: 13.5, fontWeight: 500, color: 'var(--muted)', marginTop: 3 }}>{sub}</div>}
          </div>
          {actions && <div style={{ display: 'flex', gap: 8 }}>{actions}</div>}
        </div>
        <div style={{ flex: 1, minHeight: 0 }}>{children}</div>
      </div>
    </div>
  );
}

function KCard({ title, action, children, pad = 18, style = {} }) {
  return (
    <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 'var(--r-card)', padding: pad, boxSizing: 'border-box', ...style }}>
      {(title || action) && (
        <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 14 }}>
          <div style={{ fontSize: 14.5, fontWeight: 800, letterSpacing: -0.2 }}>{title}</div>
          {action && <div style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--primary)' }}>{action}</div>}
        </div>
      )}
      {children}
    </div>
  );
}

function KStat({ label, value, sub, tone }) {
  return (
    <KCard style={{ flex: 1 }}>
      <div style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--muted)', letterSpacing: 0.2 }}>{label}</div>
      <div style={{ fontSize: 28, fontWeight: 800, letterSpacing: -0.7, marginTop: 6, color: tone === 'accent' ? 'var(--accent)' : 'var(--text)' }}>{value}</div>
      {sub && <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--muted)', marginTop: 4 }}>{sub}</div>}
    </KCard>
  );
}

// grid table: cols = CSS grid-template-columns string
function KRow({ cols, children, head = false, last = false }) {
  return (
    <div style={{
      display: 'grid', gridTemplateColumns: cols, gap: 12, alignItems: 'center',
      padding: head ? '0 4px 10px' : '12px 4px',
      borderBottom: last ? 'none' : '1px solid var(--border)',
      fontSize: head ? 11.5 : 13.5, fontWeight: head ? 700 : 600,
      color: head ? 'var(--muted)' : 'var(--text)',
      letterSpacing: head ? 0.6 : 0, textTransform: head ? 'uppercase' : 'none',
    }}>{children}</div>
  );
}

function KMeter({ pct, label }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
      <div style={{ flex: 1, height: 6, borderRadius: 4, background: 'var(--surface-2)', overflow: 'hidden' }}>
        <div style={{ width: pct + '%', height: '100%', borderRadius: 4, background: pct >= 100 ? 'var(--accent)' : 'var(--primary)' }}></div>
      </div>
      <span style={{ fontSize: 12, fontWeight: 700, color: 'var(--muted)', whiteSpace: 'nowrap', fontVariantNumeric: 'tabular-nums' }}>{label}</span>
    </div>
  );
}

// ——— form primitives ———
function KField({ label, children, hint }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
      <div style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--muted)' }}>{label}</div>
      {children}
      {hint && <div style={{ fontSize: 11.5, fontWeight: 500, color: 'var(--muted)' }}>{hint}</div>}
    </div>
  );
}

function KInput({ value, suffix, w }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, border: '1px solid var(--border-strong)', borderRadius: 10, padding: '9px 12px', background: 'var(--surface)', width: w, boxSizing: 'border-box' }}>
      <span style={{ flex: 1, fontSize: 13.5, fontWeight: 600 }}>{value}</span>
      {suffix && <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--muted)' }}>{suffix}</span>}
    </div>
  );
}

function KSeg({ options, value }) {
  return (
    <div style={{ display: 'flex', background: 'var(--surface-2)', borderRadius: 10, padding: 3, gap: 2 }}>
      {options.map((o) => {
        const on = o === value;
        return (
          <div key={o} style={{
            flex: 1, textAlign: 'center', padding: '7px 12px', borderRadius: 8, fontSize: 12.5, fontWeight: 700,
            background: on ? 'var(--surface)' : 'transparent',
            color: on ? 'var(--text)' : 'var(--muted)',
            border: on ? '1px solid var(--border)' : '1px solid transparent',
            whiteSpace: 'nowrap',
          }}>{o}</div>
        );
      })}
    </div>
  );
}

function KToggle({ on }) {
  return (
    <div style={{ width: 40, height: 24, borderRadius: 999, flexShrink: 0, background: on ? 'var(--primary)' : 'var(--surface-2)', border: on ? '1px solid transparent' : '1px solid var(--border-strong)', position: 'relative' }}>
      <div style={{ position: 'absolute', top: 2, left: on ? 18 : 2, width: 18, height: 18, borderRadius: '50%', background: '#fff', boxShadow: '0 1px 3px rgba(0,0,0,0.25)' }}></div>
    </div>
  );
}

function KCheckChip({ label, on }) {
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 6, padding: '6px 12px', borderRadius: 999,
      fontSize: 12.5, fontWeight: 700,
      background: on ? 'var(--primary-soft)' : 'var(--surface)',
      color: on ? 'var(--primary-strong)' : 'var(--muted)',
      border: on ? '1px solid transparent' : '1px solid var(--border-strong)',
    }}>{on && <YCheck size={10}></YCheck>}{label}</span>
  );
}

Object.assign(window, { KShell, KCard, KStat, KRow, KMeter, KField, KInput, KSeg, KToggle, KCheckChip });
