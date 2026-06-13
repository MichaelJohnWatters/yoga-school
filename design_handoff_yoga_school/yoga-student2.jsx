// yoga-student2.jsx — Profile (Overview + Wallet), class booking sheet,
// notifications feed (+ empty). Same token system as round 1.

function YProfileHeader({ seg = 'overview' }) {
  return (
    <div style={{ padding: '70px 20px 0' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
        <YAvatar name="Maya Rowe" size={56} tone="accent"></YAvatar>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 21, fontWeight: 800, letterSpacing: -0.4 }}>Maya Rowe</div>
          <div style={{ fontSize: 13, color: 'var(--muted)', fontWeight: 500 }}>Member since March 2026</div>
        </div>
        <div style={{ width: 38, height: 38, borderRadius: '50%', border: '1px solid var(--border-strong)', display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'var(--muted)' }}>
          <YIcon d="M4 20l4-1L19 8l-3-3L5 16l-1 4zM14 6l3 3" size={16}></YIcon>
        </div>
      </div>
      <div style={{ display: 'flex', background: 'var(--surface-2)', borderRadius: 'var(--r-chip)', padding: 3, marginTop: 16 }}>
        {['Overview', 'Wallet'].map((t) => {
          const on = t.toLowerCase() === seg;
          return (
            <div key={t} style={{
              flex: 1, textAlign: 'center', padding: '8px 0', borderRadius: 'var(--r-chip)',
              fontSize: 13.5, fontWeight: 700,
              background: on ? 'var(--surface)' : 'transparent',
              color: on ? 'var(--text)' : 'var(--muted)',
              boxShadow: on ? 'var(--shadow)' : 'none',
              border: on ? '1px solid var(--border)' : '1px solid transparent',
            }}>{t}</div>
          );
        })}
      </div>
    </div>
  );
}

// Attendance: numbers + a small weekly bar chart (12 weeks)
function YProfileScreen({ vars }) {
  const bars = [1, 2, 1, 3, 2, 2, 4, 3, 2, 3, 4, 3];
  return (
    <YScreen vars={vars} tab="profile">
      <YProfileHeader seg="overview"></YProfileHeader>
      <div style={{ padding: '18px 20px 0' }}>
        <div style={{ background: 'var(--surface)', borderRadius: 'var(--r-card)', border: '1px solid var(--border)', padding: '16px 16px 14px' }}>
          <div style={{ display: 'flex' }}>
            {[['9', 'this month'], ['3 wks', 'streak'], ['24', 'all time']].map(([n, l], i) => (
              <div key={l} style={{ flex: 1, textAlign: 'center', borderLeft: i ? '1px solid var(--border)' : 'none' }}>
                <div style={{ fontSize: 22, fontWeight: 800, letterSpacing: -0.5 }}>{n}</div>
                <div style={{ fontSize: 11.5, fontWeight: 600, color: 'var(--muted)' }}>{l}</div>
              </div>
            ))}
          </div>
          <div style={{ display: 'flex', alignItems: 'flex-end', gap: 5, height: 44, marginTop: 16 }}>
            {bars.map((b, i) => (
              <div key={i} style={{
                flex: 1, height: b * 10 + 4, borderRadius: 4,
                background: i === bars.length - 1 ? 'var(--primary)' : 'var(--primary-soft)',
              }}></div>
            ))}
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 10.5, fontWeight: 600, color: 'var(--muted)', marginTop: 6 }}>
            <span>12 weeks ago</span><span>classes / week</span><span>now</span>
          </div>
        </div>
      </div>

      {/* Active passes lead; history sits below, muted */}
      <div style={{ padding: '18px 20px 0' }}>
        <YSectionHead title="Active passes"></YSectionHead>
        <div style={{ background: 'var(--primary-soft)', borderRadius: 'var(--r-card)', padding: 16 }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
            <div style={{ fontSize: 15.5, fontWeight: 800, letterSpacing: -0.2 }}>5-Class Pack</div>
            <YChip kind="accent">All yoga</YChip>
          </div>
          <div style={{ display: 'flex', gap: 5, margin: '12px 0 8px' }}>
            {[1, 1, 1, 0, 0].map((f, i) => (
              <div key={i} style={{ flex: 1, height: 7, borderRadius: 4, background: f ? 'var(--primary)' : 'var(--surface)', border: f ? 'none' : '1px solid var(--border-strong)' }}></div>
            ))}
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12.5, fontWeight: 600, color: 'var(--muted)' }}>
            <span><b style={{ color: 'var(--text)' }}>3 of 5</b> credits left</span>
            <span>Expires 12 Aug</span>
          </div>
        </div>
      </div>
      <div style={{ padding: '16px 20px 0' }}>
        <YSectionHead title="History"></YSectionHead>
        <div style={{ background: 'var(--surface)', borderRadius: 'var(--r-card)', border: '1px solid var(--border)', overflow: 'hidden' }}>
          {[
            ['Intro Month', 'Mar – Apr 2026', 'Expired'],
            ['Single Class', 'Used 2 Mar 2026', 'Depleted'],
          ].map(([n, m, s], i) => (
            <div key={n} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '11px 14px', borderTop: i ? '1px solid var(--border)' : 'none', opacity: 0.75 }}>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 13.5, fontWeight: 700, color: 'var(--muted)' }}>{n}</div>
                <div style={{ fontSize: 11.5, fontWeight: 500, color: 'var(--muted)', marginTop: 1 }}>{m}</div>
              </div>
              <YChip kind="full">{s}</YChip>
            </div>
          ))}
        </div>
      </div>
    </YScreen>
  );
}

function YWalletScreen({ vars }) {
  return (
    <YScreen vars={vars} tab="profile">
      <YProfileHeader seg="wallet"></YProfileHeader>
      <div style={{ padding: '18px 20px 0' }}>
        <YSectionHead title="Payment methods" action="Add"></YSectionHead>
        <div style={{ background: 'var(--surface)', borderRadius: 'var(--r-card)', border: '1px solid var(--border)', padding: '13px 14px', display: 'flex', alignItems: 'center', gap: 12 }}>
          <div style={{ width: 42, height: 28, borderRadius: 6, background: 'var(--text)', color: 'var(--bg)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 10, fontWeight: 800, letterSpacing: 0.5 }}>VISA</div>
          <div style={{ flex: 1, fontSize: 14, fontWeight: 700 }}>···· 4242</div>
          <YChip kind="neutral">Default</YChip>
        </div>
      </div>
      <div style={{ padding: '18px 20px 0' }}>
        <YSectionHead title="Purchase history"></YSectionHead>
        <div style={{ background: 'var(--surface)', borderRadius: 'var(--r-card)', border: '1px solid var(--border)', overflow: 'hidden' }}>
          {[
            ['5-Class Pack', '14 May 2026 · Card', '£60'],
            ['Intro Month', '2 Mar 2026 · Cash, at the desk', '£49'],
            ['Single Class', '1 Mar 2026 · Card', '£14'],
          ].map(([n, m, p], i) => (
            <div key={n} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '12px 14px', borderTop: i ? '1px solid var(--border)' : 'none' }}>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 14, fontWeight: 700 }}>{n}</div>
                <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--muted)', marginTop: 1 }}>{m}</div>
              </div>
              <div style={{ fontSize: 14.5, fontWeight: 800, fontVariantNumeric: 'tabular-nums' }}>{p}</div>
            </div>
          ))}
        </div>
        <div style={{ fontSize: 11.5, fontWeight: 500, color: 'var(--muted)', marginTop: 10, lineHeight: 1.5 }}>
          Receipts are emailed after every purchase. Cash purchases are recorded by the studio.
        </div>
      </div>
    </YScreen>
  );
}

// ——— Class detail / booking sheet over Book ———
function YSheetRow({ children, style = {} }) {
  return <div style={{ display: 'flex', alignItems: 'center', gap: 10, ...style }}>{children}</div>;
}

function YClassSheetScreen({ vars }) {
  return (
    <div style={{ position: 'absolute', inset: 0 }}>
      <YBookScreen vars={vars}></YBookScreen>
      <div style={{ position: 'absolute', inset: 0, background: 'rgba(15,10,5,0.4)', backdropFilter: 'blur(2px)' }}></div>
      <div style={{
        ...vars, position: 'absolute', left: 0, right: 0, bottom: 0,
        background: 'var(--surface)', borderRadius: '24px 24px 0 0', padding: '10px 20px 40px',
        fontFamily: '"Hanken Grotesk", system-ui, sans-serif', color: 'var(--text)',
        boxShadow: '0 -12px 40px rgba(0,0,0,0.25)',
      }}>
        <div style={{ width: 38, height: 4, borderRadius: 4, background: 'var(--border-strong)', margin: '0 auto 16px' }}></div>
        <YSheetRow>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 19, fontWeight: 800, letterSpacing: -0.4 }}>Reformer Pilates</div>
            <div style={{ fontSize: 13, fontWeight: 500, color: 'var(--muted)', marginTop: 3 }}>Thu 11 June · 9:00 – 9:50 · Room 2</div>
          </div>
          <YChip kind="accent">2 spots left</YChip>
        </YSheetRow>
        <YSheetRow style={{ marginTop: 12 }}>
          <YAvatar name="Jonas Meyer" size={30}></YAvatar>
          <div style={{ fontSize: 13.5, fontWeight: 600, color: 'var(--muted)' }}>with Jonas Meyer · 10 of 12 booked</div>
        </YSheetRow>

        <div style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--muted)', margin: '18px 0 8px', letterSpacing: 0.3 }}>PAY WITH</div>
        <div style={{ border: '1.5px solid var(--primary)', background: 'var(--primary-soft)', borderRadius: 'var(--r-card)', padding: '12px 14px', display: 'flex', alignItems: 'center', gap: 10 }}>
          <div style={{ width: 18, height: 18, borderRadius: '50%', border: '5px solid var(--primary)', background: 'var(--surface)' }}></div>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 14, fontWeight: 700 }}>Reformer 5-Pack</div>
            <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--muted)' }}>3 credits left · expires 12 Aug</div>
          </div>
          <div style={{ fontSize: 13, fontWeight: 800 }}>1 credit</div>
        </div>
        <div style={{ borderRadius: 'var(--r-card)', border: '1px solid var(--border)', padding: '11px 14px', display: 'flex', alignItems: 'center', gap: 10, marginTop: 8 }}>
          <div style={{ width: 18, height: 18, borderRadius: '50%', border: '1.5px solid var(--border-strong)' }}></div>
          <div style={{ flex: 1, fontSize: 14, fontWeight: 700, color: 'var(--muted)' }}>Buy a new pass…</div>
          <YIcon d="M9 5l7 7-7 7" size={13}></YIcon>
        </div>

        <YSheetRow style={{ marginTop: 14, justifyContent: 'space-between' }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>Bring a guest <span style={{ color: 'var(--muted)', fontWeight: 600 }}>(+1, uses a 2nd credit)</span></div>
          <div style={{ width: 44, height: 26, borderRadius: 999, background: 'var(--surface-2)', border: '1px solid var(--border-strong)', position: 'relative' }}>
            <div style={{ position: 'absolute', top: 2, left: 2, width: 20, height: 20, borderRadius: '50%', background: 'var(--surface)', boxShadow: 'var(--shadow)', border: '1px solid var(--border)' }}></div>
          </div>
        </YSheetRow>
        <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--muted)', marginTop: 12, lineHeight: 1.45 }}>
          Free cancellation until Wed 21:00. After that, your credit is used.
        </div>
        <YButton style={{ width: '100%', boxSizing: 'border-box', marginTop: 14 }}>Book this class</YButton>
      </div>
    </div>
  );
}

// ——— Notifications feed + empty ———
function YNotifHeader() {
  return (
    <div style={{ padding: '70px 20px 0', display: 'flex', alignItems: 'center', gap: 12 }}>
      <div style={{ width: 36, height: 36, borderRadius: '50%', border: '1px solid var(--border-strong)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <YIcon d="M15 5l-7 7 7 7" size={15}></YIcon>
      </div>
      <div style={{ fontSize: 22, fontWeight: 800, letterSpacing: -0.4 }}>Notifications</div>
    </div>
  );
}

function YNotifScreen({ vars }) {
  const items = [
    { icon: 'M12 3a6 6 0 016 6c0 5 2 6 2 6H4s2-1 2-6a6 6 0 016-6z', tone: 'accent', unread: true, title: 'A spot opened up', body: 'Yin & Restore, today 12:15 — claim your place by 11:15.', time: '9:42', cta: 'Claim spot' },
    { icon: 'M2 6.5L4.8 9.2 10 3.5', tone: 'primary', unread: true, title: 'Booking confirmed', body: 'Vinyasa Flow · Fri 12 June, 7:30 with Asha Patel.', time: 'Yesterday' },
    { icon: 'M12 8v5l3 2', tone: 'muted', title: 'Class cancelled — credit returned', body: 'Power Vinyasa on Mon 8 June was cancelled. 1 credit is back on your 5-Class Pack.', time: 'Mon' },
  ];
  return (
    <YScreen vars={vars} tab="more">
      <YNotifHeader></YNotifHeader>
      <div style={{ padding: '16px 20px 0', display: 'flex', flexDirection: 'column', gap: 8 }}>
        {items.map((n) => (
          <div key={n.title} style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 'var(--r-card)', padding: '13px 14px', display: 'flex', gap: 12 }}>
            <div style={{
              width: 34, height: 34, borderRadius: '50%', flexShrink: 0,
              background: n.tone === 'accent' ? 'var(--accent-soft)' : n.tone === 'primary' ? 'var(--primary-soft)' : 'var(--surface-2)',
              color: n.tone === 'accent' ? 'var(--accent)' : n.tone === 'primary' ? 'var(--primary-strong)' : 'var(--muted)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
            }}>
              <YIcon d={n.icon} size={15}></YIcon>
            </div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                <span style={{ fontSize: 14, fontWeight: 700, flex: 1 }}>{n.title}</span>
                <span style={{ fontSize: 11.5, fontWeight: 600, color: 'var(--muted)' }}>{n.time}</span>
                {n.unread && <span style={{ width: 7, height: 7, borderRadius: '50%', background: 'var(--accent)' }}></span>}
              </div>
              <div style={{ fontSize: 12.5, fontWeight: 500, color: 'var(--muted)', marginTop: 3, lineHeight: 1.45 }}>{n.body}</div>
              {n.cta && <div style={{ marginTop: 9 }}><YButton variant="primary" small>{n.cta}</YButton></div>}
            </div>
          </div>
        ))}
      </div>
    </YScreen>
  );
}

function YNotifEmptyScreen({ vars }) {
  return (
    <YScreen vars={vars} tab="more">
      <YNotifHeader></YNotifHeader>
      <div style={{ padding: '70px 36px 0', textAlign: 'center' }}>
        <div style={{ width: 58, height: 58, borderRadius: '50%', background: 'var(--surface-2)', color: 'var(--muted)', display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto 14px' }}>
          <YIcon d="M12 3a6 6 0 016 6c0 5 2 6 2 6H4s2-1 2-6a6 6 0 016-6zM10 20a2.2 2.2 0 004 0" size={24}></YIcon>
        </div>
        <div style={{ fontSize: 17, fontWeight: 800, letterSpacing: -0.3 }}>All quiet for now</div>
        <div style={{ fontSize: 13.5, color: 'var(--muted)', fontWeight: 500, marginTop: 5, lineHeight: 1.45 }}>
          Booking confirmations, waitlist updates and class changes will land here.
        </div>
      </div>
    </YScreen>
  );
}

Object.assign(window, { YProfileScreen, YWalletScreen, YClassSheetScreen, YNotifScreen, YNotifEmptyScreen });
