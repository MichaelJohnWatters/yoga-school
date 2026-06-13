// yoga-book.jsx — Book screen: Classes/Enrollments tabs, dotted day-strip,
// class rows (time · type · instructor+photo · booking state). Plus empty day.

const YB_DAYS = [
  { d: 'M', n: 8 }, { d: 'T', n: 9 }, { d: 'W', n: 10 },
  { d: 'T', n: 11, sel: true }, { d: 'F', n: 12 }, { d: 'S', n: 13 }, { d: 'S', n: 14 },
];

function YBookHeader({ tab = 'classes' }) {
  return (
    <div style={{ padding: '70px 20px 0' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div style={{ fontSize: 28, fontWeight: 800, letterSpacing: -0.6 }}>Book</div>
        {/* check-in code shortcut */}
        <div style={{ width: 38, height: 38, borderRadius: '50%', border: '1px solid var(--border-strong)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <YIcon d="M4 5v14M8 5v14M11 5v14M15 5v14M19 5v14" size={17}></YIcon>
        </div>
      </div>
      <div style={{ display: 'flex', background: 'var(--surface-2)', borderRadius: 'var(--r-chip)', padding: 3, marginTop: 14 }}>
        {['Classes', 'Enrollments'].map((t) => {
          const on = t.toLowerCase() === tab;
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

function YDayStrip({ emptySel = false }) {
  return (
    <div style={{ padding: '0 20px' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', margin: '16px 0 8px' }}>
        <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--muted)', letterSpacing: 0.4 }}>JUNE 2026</div>
        <div style={{ display: 'flex', gap: 14, color: 'var(--muted)' }}>
          <YIcon d="M15 5l-7 7 7 7" size={14}></YIcon>
          <YIcon d="M9 5l7 7-7 7" size={14}></YIcon>
        </div>
      </div>
      <div style={{ display: 'flex', gap: 6 }}>
        {YB_DAYS.map((day, i) => {
          const sel = !!day.sel;
          const hasClasses = emptySel ? (i !== 3 && i !== 6) : i !== 6;
          return (
            <div key={i} style={{
              flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 3,
              padding: '9px 0 7px', borderRadius: 14, minHeight: 44,
              background: sel ? 'var(--primary)' : 'var(--surface)',
              color: sel ? 'var(--on-primary)' : 'var(--text)',
              border: sel ? '1px solid transparent' : '1px solid var(--border)',
            }}>
              <div style={{ fontSize: 10.5, fontWeight: 700, opacity: sel ? 0.8 : 0.55 }}>{day.d}</div>
              <div style={{ fontSize: 16, fontWeight: 800 }}>{day.n}</div>
              <div style={{
                width: 4, height: 4, borderRadius: '50%',
                background: hasClasses ? (sel ? 'var(--on-primary)' : 'var(--primary)') : 'transparent',
              }}></div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function YClassRow({ time, dur, name, who, state, hint }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12, padding: '13px 14px',
      background: 'var(--surface)', borderRadius: 'var(--r-card)', border: '1px solid var(--border)',
    }}>
      <div style={{ width: 48, flexShrink: 0 }}>
        <div style={{ fontSize: 16, fontWeight: 800, letterSpacing: -0.3, fontVariantNumeric: 'tabular-nums' }}>{time}</div>
        <div style={{ fontSize: 11.5, color: 'var(--muted)', fontWeight: 600 }}>{dur}</div>
      </div>
      <div style={{ width: 1, alignSelf: 'stretch', background: 'var(--border)' }}></div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 15, fontWeight: 700, letterSpacing: -0.2 }}>{name}</div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginTop: 4 }}>
          <YAvatar name={who} size={20}></YAvatar>
          <span style={{ fontSize: 12.5, fontWeight: 600, color: 'var(--muted)' }}>{who}</span>
        </div>
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 5 }}>
        {state}
        {hint && <div style={{ fontSize: 11.5, fontWeight: 600, color: 'var(--muted)' }}>{hint}</div>}
      </div>
    </div>
  );
}

function YBookScreen({ vars }) {
  return (
    <YScreen vars={vars} tab="book">
      <YBookHeader></YBookHeader>
      <YDayStrip></YDayStrip>
      <div style={{ padding: '14px 20px 0', display: 'flex', flexDirection: 'column', gap: 8 }}>
        <YClassRow time="7:30" dur="60 min" name="Vinyasa Flow" who="Asha Patel"
          state={<YChip kind="booked"><YCheck></YCheck>Booked</YChip>}></YClassRow>
        <YClassRow time="9:00" dur="50 min" name="Reformer Pilates" who="Jonas Meyer"
          state={<YButton variant="primary" small>Book</YButton>} hint="2 spots left"></YClassRow>
        <YClassRow time="12:15" dur="75 min" name="Yin & Restore" who="Mara Kovac"
          state={<YChip kind="full">Full · 3 waiting</YChip>}
          hint={<span style={{ color: 'var(--primary)', fontWeight: 700 }}>Join waitlist</span>}></YClassRow>
        <YClassRow time="17:45" dur="60 min" name="Power Vinyasa" who="Asha Patel"
          state={<YButton variant="primary" small>Book</YButton>}></YClassRow>
        <YClassRow time="19:00" dur="60 min" name="Candlelit Slow Flow" who="Mara Kovac"
          state={<YButton variant="primary" small>Book</YButton>}></YClassRow>
      </div>
    </YScreen>
  );
}

// A day with nothing scheduled — warm, brief, with a way forward.
function YBookEmptyScreen({ vars }) {
  return (
    <YScreen vars={vars} tab="book">
      <YBookHeader></YBookHeader>
      <YDayStrip emptySel></YDayStrip>
      <div style={{ padding: '40px 20px 0', textAlign: 'center' }}>
        <div style={{ width: 58, height: 58, borderRadius: '50%', background: 'var(--surface-2)', color: 'var(--muted)', display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto 14px' }}>
          <YIcon d="M12 8v5l3 2M12 21a9 9 0 110-18 9 9 0 010 18z" size={24}></YIcon>
        </div>
        <div style={{ fontSize: 17, fontWeight: 800, letterSpacing: -0.3 }}>A rest day at the studio</div>
        <div style={{ fontSize: 13.5, color: 'var(--muted)', fontWeight: 500, marginTop: 5, lineHeight: 1.45 }}>
          No classes scheduled for Thursday 11.
        </div>
        <div style={{ marginTop: 16, display: 'flex', justifyContent: 'center' }}>
          <YButton variant="soft" small>Next classes · Fri 12 →</YButton>
        </div>
      </div>
    </YScreen>
  );
}

Object.assign(window, { YBookScreen, YBookEmptyScreen, YBookHeader, YDayStrip, YClassRow });
