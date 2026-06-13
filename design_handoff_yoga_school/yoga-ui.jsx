// yoga-ui.jsx — shared primitives for the Studio 52 student app screens.
// All colors come from the semantic token vars set by yogaVars().

const YUI_FONT = '"Hanken Grotesk", system-ui, sans-serif';

// Initials avatar — placeholder for instructor/user photos (real photos later).
function YAvatar({ name, size = 32, tone = 'primary' }) {
  const initials = name.split(' ').map((w) => w[0]).join('').slice(0, 2);
  return (
    <div aria-label={name} style={{
      width: size, height: size, borderRadius: '50%', flexShrink: 0,
      background: tone === 'accent' ? 'var(--accent-soft)' : 'var(--primary-soft)',
      color: tone === 'accent' ? 'var(--accent)' : 'var(--primary-strong)',
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      fontSize: Math.round(size * 0.36), fontWeight: 700, letterSpacing: 0.3,
      border: '1px solid var(--border)',
    }}>{initials}</div>
  );
}

// State chip: booked / full / left / waitlist / generic
function YChip({ kind = 'neutral', children }) {
  const looks = {
    booked:  { background: 'var(--primary-soft)', color: 'var(--primary-strong)', border: '1px solid transparent' },
    full:    { background: 'transparent', color: 'var(--muted)', border: '1px solid var(--border-strong)' },
    accent:  { background: 'var(--accent-soft)', color: 'var(--accent)', border: '1px solid transparent' },
    neutral: { background: 'var(--surface-2)', color: 'var(--muted)', border: '1px solid transparent' },
  };
  return (
    <span style={{
      ...looks[kind], borderRadius: 'var(--r-chip)', padding: '4px 10px',
      fontSize: 12, fontWeight: 600, whiteSpace: 'nowrap',
      display: 'inline-flex', alignItems: 'center', gap: 5,
    }}>{children}</span>
  );
}

function YCheck({ size = 11 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 12 12" fill="none">
      <path d="M2 6.5L4.8 9.2 10 3.5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"></path>
    </svg>
  );
}

function YButton({ children, variant = 'primary', small = false, style = {} }) {
  const looks = {
    primary: { background: 'var(--primary)', color: 'var(--on-primary)', border: '1px solid transparent' },
    soft:    { background: 'var(--primary-soft)', color: 'var(--primary-strong)', border: '1px solid transparent' },
    outline: { background: 'transparent', color: 'var(--text)', border: '1px solid var(--border-strong)' },
  };
  return (
    <div style={{
      ...looks[variant], borderRadius: 'var(--r-chip)', cursor: 'pointer',
      padding: small ? '7px 14px' : '13px 20px',
      fontSize: small ? 13 : 15, fontWeight: 700, textAlign: 'center',
      display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 6,
      ...style,
    }}>{children}</div>
  );
}

function YSectionHead({ title, action }) {
  return (
    <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', margin: '0 0 10px' }}>
      <div style={{ fontSize: 17, fontWeight: 700, letterSpacing: -0.2 }}>{title}</div>
      {action && <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--primary)' }}>{action}</div>}
    </div>
  );
}

// ---- tab bar icons (fixed iconography per spec) ---------------------------
function YIcon({ d, filled = false, size = 23 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill={filled ? 'currentColor' : 'none'}
      stroke="currentColor" strokeWidth={filled ? 0 : 1.8} strokeLinecap="round" strokeLinejoin="round">
      <path d={d}></path>
    </svg>
  );
}
const Y_ICONS = {
  home: 'M3 10.5L12 3l9 7.5V21h-6v-6h-6v6H3z',
  book: 'M8 2v4M16 2v4M3 9h18M5 4h14a2 2 0 012 2v14a2 2 0 01-2 2H5a2 2 0 01-2-2V6a2 2 0 012-2z',
  buy: 'M6 8h12l1.5 13h-15L6 8zM9 8a3 3 0 016 0',
  profile: 'M12 12a4 4 0 100-8 4 4 0 000 8zM4 21c1.2-3.5 4.3-5 8-5s6.8 1.5 8 5',
  more: 'M5 13a1 1 0 110-2 1 1 0 010 2zM12 13a1 1 0 110-2 1 1 0 010 2zM19 13a1 1 0 110-2 1 1 0 010 2z',
};

// NOTE: spec decides tab bar = Book/Buy/Profile/More, but Home is a primary
// screen — assumed Home is the leading 5th tab. Flagged for confirmation.
function YTabBar({ active = 'home' }) {
  const tabs = [
    { key: 'home', label: 'Home' }, { key: 'book', label: 'Book' },
    { key: 'buy', label: 'Buy' }, { key: 'profile', label: 'Profile' },
    { key: 'more', label: 'More' },
  ];
  return (
    <div style={{
      display: 'flex', borderTop: '1px solid var(--border)',
      background: 'var(--surface)', padding: '8px 8px 26px',
    }}>
      {tabs.map((t) => {
        const on = t.key === active;
        return (
          <div key={t.key} style={{
            flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 3,
            color: on ? 'var(--primary)' : 'var(--muted)', paddingTop: 4, minHeight: 44,
          }}>
            <YIcon d={Y_ICONS[t.key]} filled={t.key === 'more'}></YIcon>
            <span style={{ fontSize: 10.5, fontWeight: on ? 700 : 600 }}>{t.label}</span>
          </div>
        );
      })}
    </div>
  );
}

// Screen shell: themed background + content + tab bar pinned to bottom.
function YScreen({ children, tab, vars }) {
  return (
    <div style={{
      ...vars, position: 'absolute', inset: 0, background: 'var(--bg)',
      display: 'flex', flexDirection: 'column', fontFamily: YUI_FONT,
      WebkitFontSmoothing: 'antialiased', overflow: 'hidden',
    }}>
      <div style={{ flex: 1, overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>{children}</div>
      {tab && <YTabBar active={tab}></YTabBar>}
    </div>
  );
}

// Studio logo placeholder — square monogram tile (studio uploads real logo).
function YLogo({ size = 34 }) {
  return (
    <div style={{
      width: size, height: size, borderRadius: size * 0.3, background: 'var(--primary)',
      color: 'var(--on-primary)', display: 'flex', alignItems: 'center', justifyContent: 'center',
      fontWeight: 800, fontSize: size * 0.44, letterSpacing: -0.5, flexShrink: 0,
    }}>52</div>
  );
}

Object.assign(window, { YAvatar, YChip, YCheck, YButton, YSectionHead, YIcon, Y_ICONS, YTabBar, YScreen, YLogo });
