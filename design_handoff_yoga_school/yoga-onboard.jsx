// yoga-onboard.jsx — splash (default + studio image variant), sign-in, student check-in code.

// ——— Splash: standard = themed, logo-forward. Studio may upload an optional
// splash image in Settings; when present it becomes a full-bleed backdrop.
function YSplashScreen({ vars, withImage = false }) {
  return (
    <div style={{
      ...vars, position: 'absolute', inset: 0, background: 'var(--bg)',
      fontFamily: '"Hanken Grotesk", system-ui, sans-serif',
      display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center',
      overflow: 'hidden',
    }}>
      {withImage && (
        <React.Fragment>
          {/* studio-uploaded splash image (placeholder) */}
          <div style={{
            position: 'absolute', inset: 0,
            background: 'linear-gradient(160deg, var(--primary-strong), var(--primary) 55%, var(--accent))',
            opacity: 0.92,
          }}></div>
          <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'flex-start', justifyContent: 'center', paddingTop: 110 }}>
            <span style={{ fontSize: 11, fontWeight: 700, letterSpacing: 1, color: 'rgba(255,255,255,0.55)', border: '1px dashed rgba(255,255,255,0.4)', borderRadius: 999, padding: '5px 12px' }}>
              STUDIO SPLASH IMAGE · SET IN SETTINGS
            </span>
          </div>
        </React.Fragment>
      )}
      <div style={{ position: 'relative', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 18 }}>
        <div style={{
          width: 84, height: 84, borderRadius: 26,
          background: withImage ? 'rgba(255,255,255,0.97)' : 'var(--primary)',
          color: withImage ? 'var(--primary)' : 'var(--on-primary)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          fontWeight: 800, fontSize: 36, letterSpacing: -1,
          boxShadow: '0 8px 30px rgba(0,0,0,0.18)',
        }}>52</div>
        <div style={{ textAlign: 'center' }}>
          <div style={{ fontSize: 24, fontWeight: 800, letterSpacing: -0.4, color: withImage ? '#FFFFFF' : 'var(--text)' }}>Studio 52</div>
          <div style={{ fontSize: 13.5, fontWeight: 500, marginTop: 5, color: withImage ? 'rgba(255,255,255,0.75)' : 'var(--muted)' }}>Glad you're here</div>
        </div>
      </div>
      <div style={{ position: 'absolute', bottom: 64, left: 0, right: 0, display: 'flex', justifyContent: 'center' }}>
        <div style={{ width: 28, height: 4, borderRadius: 4, background: withImage ? 'rgba(255,255,255,0.4)' : 'var(--border-strong)' }}></div>
      </div>
    </div>
  );
}

// ——— Sign in ———
function YAuthField({ label, value, muted }) {
  return (
    <div style={{ border: '1px solid var(--border-strong)', borderRadius: 14, padding: '13px 16px', background: 'var(--surface)' }}>
      <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--muted)', letterSpacing: 0.4 }}>{label}</div>
      <div style={{ fontSize: 15, fontWeight: 600, marginTop: 3, color: muted ? 'var(--muted)' : 'var(--text)' }}>{value}</div>
    </div>
  );
}

function YAuthScreen({ vars }) {
  return (
    <div style={{
      ...vars, position: 'absolute', inset: 0, background: 'var(--bg)',
      fontFamily: '"Hanken Grotesk", system-ui, sans-serif', overflow: 'hidden',
    }}>
      <div style={{ padding: '92px 24px 0' }}>
        <YLogo size={52}></YLogo>
        <div style={{ fontSize: 27, fontWeight: 800, letterSpacing: -0.6, marginTop: 22 }}>Welcome to Studio 52</div>
        <div style={{ fontSize: 14.5, fontWeight: 500, color: 'var(--muted)', marginTop: 5, lineHeight: 1.45 }}>
          Sign in to book classes and manage your passes.
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10, marginTop: 28 }}>
          <YAuthField label="EMAIL" value="maya@rowe.co"></YAuthField>
          <YAuthField label="PASSWORD" value="••••••••••" ></YAuthField>
        </div>
        <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--primary)', marginTop: 12, textAlign: 'right' }}>Forgot password?</div>
        <YButton style={{ width: '100%', boxSizing: 'border-box', marginTop: 18 }}>Sign in</YButton>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, margin: '20px 0' }}>
          <div style={{ flex: 1, height: 1, background: 'var(--border)' }}></div>
          <span style={{ fontSize: 11.5, fontWeight: 700, color: 'var(--muted)', letterSpacing: 0.3 }}>OR</span>
          <div style={{ flex: 1, height: 1, background: 'var(--border)' }}></div>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <div style={{ height: 48, borderRadius: 999, background: '#000', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 7, fontSize: 14.5, fontWeight: 600 }}>
            <svg width="13" height="16" viewBox="0 0 14 17" fill="currentColor"><path d="M11.6 9c0-2 1.6-2.9 1.7-3-1-1.4-2.4-1.6-2.9-1.6-1.2-.1-2.4.7-3 .7-.6 0-1.6-.7-2.6-.7C3.4 4.5 2.2 5.2 1.5 6.3c-1.4 2.4-.4 6 1 8 .7 1 1.5 2 2.5 2 1 0 1.4-.6 2.6-.6 1.2 0 1.5.6 2.6.6s1.8-1 2.4-2c.8-1.1 1.1-2.2 1.1-2.3 0 0-2.1-.8-2.1-3zM9.6 3.1c.5-.7.9-1.6.8-2.6-.8 0-1.8.6-2.3 1.2-.5.6-1 1.6-.8 2.5.9.1 1.8-.4 2.3-1.1z"></path></svg>
            Continue with Apple
          </div>
          <div style={{ height: 48, borderRadius: 999, background: '#fff', color: '#3c4043', border: '1px solid #dadce0', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 7, fontSize: 14.5, fontWeight: 600 }}>
            <span style={{ fontWeight: 800, background: 'linear-gradient(90deg,#4285F4,#EA4335,#FBBC05,#34A853)', WebkitBackgroundClip: 'text', backgroundClip: 'text', color: 'transparent' }}>G</span>
            Continue with Google
          </div>
        </div>
        <div style={{ textAlign: 'center', fontSize: 13, fontWeight: 600, color: 'var(--muted)', marginTop: 22 }}>
          New to the studio? <span style={{ color: 'var(--primary)', fontWeight: 700 }}>Create an account</span>
        </div>
      </div>
    </div>
  );
}

// ——— Check-in: the screen behind Book's barcode button ———
// Deterministic pseudo-QR placeholder (real one = student check-in token).
function YQrPlaceholder({ size = 196 }) {
  const n = 17, cell = size / n;
  const cells = [];
  for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) {
    const corner = (x < 5 && y < 5) || (x > n - 6 && y < 5) || (x < 5 && y > n - 6);
    if (corner) {
      const lx = x < 5 ? x : x - (n - 5), ly = y < 5 ? y : y - (n - 5);
      if (lx === 0 || lx === 4 || ly === 0 || ly === 4 || (lx === 2 && ly === 2)) cells.push([x, y]);
    } else if (((x * 7 + y * 13 + (x * y) % 5) % 3) === 0) cells.push([x, y]);
  }
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} aria-label="Check-in code">
      {cells.map(([x, y], i) => (
        <rect key={i} x={x * cell} y={y * cell} width={cell * 0.92} height={cell * 0.92} rx={cell * 0.18} fill="#1A1611"></rect>
      ))}
    </svg>
  );
}

function YCheckinScreen({ vars }) {
  return (
    <YScreen vars={vars} tab="book">
      <div style={{ padding: '70px 20px 0', display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ width: 36, height: 36, borderRadius: '50%', border: '1px solid var(--border-strong)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <YIcon d="M15 5l-7 7 7 7" size={15}></YIcon>
        </div>
        <div style={{ fontSize: 22, fontWeight: 800, letterSpacing: -0.4 }}>Check in</div>
      </div>
      <div style={{ padding: '24px 28px 0', textAlign: 'center' }}>
        <div style={{ background: '#FFFFFF', borderRadius: 24, padding: '26px 26px 22px', boxShadow: 'var(--shadow)', border: '1px solid var(--border)' }}>
          <YQrPlaceholder></YQrPlaceholder>
          <div style={{ fontSize: 17, fontWeight: 800, letterSpacing: 2.5, color: '#1A1611', marginTop: 14, fontVariantNumeric: 'tabular-nums' }}>M52·7341</div>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, marginTop: 18 }}>
          <YAvatar name="Maya Rowe" size={26} tone="accent"></YAvatar>
          <span style={{ fontSize: 14.5, fontWeight: 700 }}>Maya Rowe</span>
        </div>
        <div style={{ display: 'flex', justifyContent: 'center', marginTop: 10 }}>
          <YChip kind="booked"><YCheck></YCheck>Booked · Yin & Restore 12:15</YChip>
        </div>
        <div style={{ fontSize: 12.5, fontWeight: 500, color: 'var(--muted)', marginTop: 16, lineHeight: 1.5 }}>
          Show this at the front desk scanner.<br></br>Screen brightness raised automatically.
        </div>
      </div>
    </YScreen>
  );
}

Object.assign(window, { YSplashScreen, YAuthScreen, YCheckinScreen, YQrPlaceholder });
