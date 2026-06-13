// yoga-home.jsx — Home screen (+ first-run empty state).
// Order per direction: slim promo on top, upcoming bookings lead the body.

const YH_PAD = '0 20px';

function YHomeHeader({ greeting, sub }) {
  return (
    <div style={{ padding: '70px 20px 0' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <YLogo></YLogo>
          <div style={{ fontSize: 13, fontWeight: 700, letterSpacing: 1.6, textTransform: 'uppercase', color: 'var(--muted)' }}>Studio 52</div>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <div style={{ position: 'relative', width: 38, height: 38, borderRadius: '50%', border: '1px solid var(--border-strong)', display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'var(--text)' }}>
            <YIcon d="M12 3a6 6 0 016 6c0 5 2 6 2 6H4s2-1 2-6a6 6 0 016-6zM10 20a2.2 2.2 0 004 0" size={19}></YIcon>
            <div style={{ position: 'absolute', top: 7, right: 8, width: 7, height: 7, borderRadius: '50%', background: 'var(--accent)' }}></div>
          </div>
          <YAvatar name="Maya Rowe" size={38} tone="accent"></YAvatar>
        </div>
      </div>
      <div style={{ marginTop: 18, fontSize: 26, fontWeight: 800, letterSpacing: -0.5, lineHeight: 1.15 }}>{greeting}</div>
      <div style={{ marginTop: 3, fontSize: 14, color: 'var(--muted)', fontWeight: 500 }}>{sub}</div>
    </div>
  );
}

function YPromoBanner() {
  return (
    <div style={{ padding: YH_PAD, marginTop: 16 }}>
      <div style={{
        display: 'flex', alignItems: 'center', gap: 10, background: 'var(--accent-soft)',
        borderRadius: 'var(--r-card)', padding: '10px 14px', color: 'var(--text)',
      }}>
        <span style={{ color: 'var(--accent)', display: 'flex' }}>
          <YIcon d="M20 12l-8 8-9-9V4h7l10 8zM7.5 7.5h.01" size={17}></YIcon>
        </span>
        <div style={{ flex: 1, fontSize: 13.5, fontWeight: 600, lineHeight: 1.3 }}>
          Summer offer — 20% off Unlimited Monthly until 21 June
        </div>
        <span style={{ color: 'var(--muted)', display: 'flex' }}>
          <YIcon d="M9 5l7 7-7 7" size={14}></YIcon>
        </span>
      </div>
    </div>
  );
}

function YDateTile({ dow, day }) {
  return (
    <div style={{
      width: 52, height: 56, borderRadius: 12, background: 'var(--primary-soft)',
      display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center',
      color: 'var(--primary-strong)', flexShrink: 0,
    }}>
      <div style={{ fontSize: 10.5, fontWeight: 800, letterSpacing: 1.2 }}>{dow}</div>
      <div style={{ fontSize: 21, fontWeight: 800, lineHeight: 1.05 }}>{day}</div>
    </div>
  );
}

function YHomeScreen({ vars }) {
  return (
    <YScreen vars={vars} tab="home">
      <YHomeHeader greeting="Good morning, Maya" sub="Thursday 11 June"></YHomeHeader>
      <YPromoBanner></YPromoBanner>

      {/* Upcoming bookings — the clear anchor of Home */}
      <div style={{ padding: YH_PAD, marginTop: 20 }}>
        <YSectionHead title="Upcoming" action="All bookings"></YSectionHead>
        <div style={{ background: 'var(--surface)', borderRadius: 'var(--r-card)', boxShadow: 'var(--shadow)', border: '1px solid var(--border)', padding: 14, display: 'flex', gap: 12, alignItems: 'center' }}>
          <YDateTile dow="FRI" day="12"></YDateTile>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 16.5, fontWeight: 700, letterSpacing: -0.2 }}>Vinyasa Flow</div>
            <div style={{ fontSize: 13, color: 'var(--muted)', fontWeight: 500, marginTop: 2 }}>7:30 – 8:30 · Room 1</div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginTop: 7 }}>
              <YAvatar name="Asha Patel" size={20}></YAvatar>
              <span style={{ fontSize: 12.5, fontWeight: 600, color: 'var(--muted)' }}>Asha Patel</span>
            </div>
          </div>
          <YChip kind="booked"><YCheck></YCheck>Booked</YChip>
        </div>
        <div style={{ background: 'var(--surface)', borderRadius: 'var(--r-card)', border: '1px solid var(--border)', padding: '11px 14px', display: 'flex', gap: 12, alignItems: 'center', marginTop: 8 }}>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 14.5, fontWeight: 700 }}>Reformer Pilates</div>
            <div style={{ fontSize: 12.5, color: 'var(--muted)', fontWeight: 500, marginTop: 1 }}>Sat 13 · 9:00 · Jonas Meyer</div>
          </div>
          <YChip kind="booked"><YCheck></YCheck>Booked</YChip>
        </div>
      </div>

      {/* This week — quick path into Book */}
      <div style={{ padding: YH_PAD, marginTop: 18 }}>
        <YSectionHead title="This week at the studio" action="Full schedule"></YSectionHead>
        <div style={{ background: 'var(--surface)', borderRadius: 'var(--r-card)', border: '1px solid var(--border)', overflow: 'hidden' }}>
          {[
            { name: 'Yin & Restore', meta: 'Today · 19:00 · Mara Kovac' },
            { name: 'Power Vinyasa', meta: 'Fri · 17:45 · Asha Patel' },
          ].map((c, i) => (
            <div key={c.name} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '11px 14px', borderTop: i ? '1px solid var(--border)' : 'none' }}>
              <YAvatar name={c.meta.split('· ')[2]} size={34}></YAvatar>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 14.5, fontWeight: 700 }}>{c.name}</div>
                <div style={{ fontSize: 12.5, color: 'var(--muted)', fontWeight: 500, marginTop: 1 }}>{c.meta}</div>
              </div>
              <YButton variant="soft" small>Book</YButton>
            </div>
          ))}
        </div>
      </div>

      {/* Milestones — deliberately quiet (cosmetic, per spec) */}
      <div style={{ padding: YH_PAD, marginTop: 14 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 14px', borderRadius: 'var(--r-card)', border: '1px dashed var(--border-strong)', color: 'var(--muted)' }}>
          <span style={{ color: 'var(--accent)', display: 'flex' }}>
            <YIcon d="M12 3l2.2 5.4L20 9l-4.4 3.9L17 19l-5-3.2L7 19l1.4-6.1L4 9l5.8-.6z" size={16}></YIcon>
          </span>
          <div style={{ flex: 1, fontSize: 12.5, fontWeight: 600 }}>24 classes · 3-week streak</div>
          <YIcon d="M9 5l7 7-7 7" size={12}></YIcon>
        </div>
      </div>
    </YScreen>
  );
}

// First-run Home — no bookings, no passes. Warm but brief; points to Book & Buy.
function YHomeEmptyScreen({ vars }) {
  return (
    <YScreen vars={vars} tab="home">
      <YHomeHeader greeting="Welcome, Maya" sub="Glad you're here"></YHomeHeader>
      <YPromoBanner></YPromoBanner>
      <div style={{ padding: YH_PAD, marginTop: 20 }}>
        <div style={{ background: 'var(--surface)', borderRadius: 'var(--r-card)', border: '1px solid var(--border)', boxShadow: 'var(--shadow)', padding: '28px 20px', textAlign: 'center' }}>
          <div style={{ width: 58, height: 58, borderRadius: '50%', background: 'var(--primary-soft)', color: 'var(--primary-strong)', display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto 14px' }}>
            <YIcon d="M8 2v4M16 2v4M3 9h18M5 4h14a2 2 0 012 2v14a2 2 0 01-2 2H5a2 2 0 01-2-2V6a2 2 0 012-2z" size={24}></YIcon>
          </div>
          <div style={{ fontSize: 18, fontWeight: 800, letterSpacing: -0.3 }}>Your week is wide open</div>
          <div style={{ fontSize: 13.5, color: 'var(--muted)', fontWeight: 500, marginTop: 5, lineHeight: 1.45 }}>
            Browse the schedule and book your first class — we'll keep your spot here.
          </div>
          <div style={{ display: 'flex', gap: 8, justifyContent: 'center', marginTop: 18 }}>
            <YButton>Browse classes</YButton>
            <YButton variant="outline">See passes</YButton>
          </div>
        </div>
      </div>
      <div style={{ padding: YH_PAD, marginTop: 14 }}>
        <div style={{ display: 'flex', gap: 10, alignItems: 'center', padding: '12px 14px', borderRadius: 'var(--r-card)', background: 'var(--surface-2)' }}>
          <span style={{ color: 'var(--muted)', display: 'flex' }}>
            <YIcon d="M12 8v5l3 2M12 21a9 9 0 110-18 9 9 0 010 18z" size={17}></YIcon>
          </span>
          <div style={{ fontSize: 12.5, color: 'var(--muted)', fontWeight: 600, lineHeight: 1.4 }}>
            New here? Most students start with Yin & Restore or Beginners' Vinyasa.
          </div>
        </div>
      </div>
    </YScreen>
  );
}

Object.assign(window, { YHomeScreen, YHomeEmptyScreen, YHomeHeader, YPromoBanner, YDateTile });
