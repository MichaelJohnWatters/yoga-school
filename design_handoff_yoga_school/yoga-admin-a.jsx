// yoga-admin-a.jsx — Dashboard, Schedule, Product Builder (single form + live preview)

function KDashboard({ vars }) {
  const classes = [
    ['7:30', 'Vinyasa Flow', 'Asha Patel', 93, '13 / 14', 'Done', 'neutral'],
    ['9:00', 'Reformer Pilates', 'Jonas Meyer', 83, '10 / 12', 'In progress', 'accent'],
    ['12:15', 'Yin & Restore', 'Mara Kovac', 100, '16 / 16', 'Full · 3 waiting', 'full'],
    ['17:45', 'Power Vinyasa', 'Asha Patel', 50, '7 / 14', 'Open', 'booked'],
    ['19:00', 'Candlelit Slow Flow', 'Mara Kovac', 38, '6 / 16', 'Open', 'booked'],
  ];
  return (
    <KShell vars={vars} active="dashboard" title="Good morning, Priya" sub="Thursday 11 June · 5 classes today"
      actions={<YButton small>+ New class</YButton>}>
      {/* unmarked attendance nudge */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, background: 'var(--accent-soft)', borderRadius: 'var(--r-card)', padding: '11px 16px', marginBottom: 16 }}>
        <span style={{ color: 'var(--accent)', display: 'flex' }}><YIcon d="M12 9v4M12 16.5h.01M10.3 4.2L2.8 17a2 2 0 001.7 3h15a2 2 0 001.7-3L13.7 4.2a2 2 0 00-3.4 0z" size={16}></YIcon></span>
        <div style={{ flex: 1, fontSize: 13, fontWeight: 600 }}>2 classes from yesterday still have unmarked attendance</div>
        <div style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--accent)' }}>Review →</div>
      </div>
      <div style={{ display: 'flex', gap: 14, marginBottom: 16 }}>
        <KStat label="Occupancy today" value="78%" sub="52 of 72 spots booked"></KStat>
        <KStat label="Revenue today" value="£312" sub="£272 card · £40 cash"></KStat>
        <KStat label="New bookings" value="46" sub="9 via waitlist"></KStat>
      </div>
      <KCard title="Today's classes" action="Open schedule">
        <KRow cols="64px 1.4fr 1fr 1.6fr 130px 70px" head>
          <span>Time</span><span>Class</span><span>Instructor</span><span>Occupancy</span><span>Status</span><span></span>
        </KRow>
        {classes.map(([t, n, who, pct, cap, st, tone], i) => (
          <KRow key={t} cols="64px 1.4fr 1fr 1.6fr 130px 70px" last={i === classes.length - 1}>
            <span style={{ fontWeight: 800, fontVariantNumeric: 'tabular-nums' }}>{t}</span>
            <span style={{ fontWeight: 700 }}>{n}</span>
            <span style={{ display: 'flex', alignItems: 'center', gap: 7, color: 'var(--muted)' }}><YAvatar name={who} size={22}></YAvatar>{who}</span>
            <KMeter pct={pct} label={cap}></KMeter>
            <span><YChip kind={tone}>{st}</YChip></span>
            <span style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--primary)' }}>Roster</span>
          </KRow>
        ))}
      </KCard>
    </KShell>
  );
}

// ——— Schedule: calm week grid ———
function KBlock({ name, time, who, room, kind = 'primary' }) {
  return (
    <div style={{
      borderRadius: 10, padding: '7px 9px', marginBottom: 6,
      background: kind === 'accent' ? 'var(--accent-soft)' : 'var(--primary-soft)',
      borderLeft: '3px solid ' + (kind === 'accent' ? 'var(--accent)' : 'var(--primary)'),
    }}>
      <div style={{ fontSize: 11.5, fontWeight: 800, lineHeight: 1.25 }}>{name}</div>
      <div style={{ fontSize: 10.5, fontWeight: 600, color: 'var(--muted)', marginTop: 1 }}>{time} · {who}{room ? ' · ' + room : ''}</div>
    </div>
  );
}

function KSchedule({ vars }) {
  const days = [
    ['Mon 8', [['Vinyasa Flow', '7:30', 'Asha'], ['Reformer', '9:00', 'Jonas', 'accent'], ['Power Vinyasa', '17:45', 'Asha']]],
    ['Tue 9', [['Reformer', '9:00', 'Jonas', 'accent'], ['Yin & Restore', '12:15', 'Mara'], ['Slow Flow', '19:00', 'Mara']]],
    ['Wed 10', [['Vinyasa Flow', '7:30', 'Asha'], ['Beginners wk 3/6', '18:00', 'Mara', 'accent']]],
    ['Thu 11', [['Vinyasa Flow', '7:30', 'Asha'], ['Reformer', '9:00', 'Jonas', 'accent'], ['Yin & Restore', '12:15', 'Mara'], ['Power Vinyasa', '17:45', 'Asha'], ['Candlelit Flow', '19:00', 'Mara']]],
    ['Fri 12', [['Vinyasa Flow', '7:30', 'Asha'], ['Power Vinyasa', '17:45', 'Asha']]],
    ['Sat 13', [['Reformer', '9:00', 'Jonas', 'accent'], ['Community Flow', '10:30', 'Asha']]],
    ['Sun 14', []],
  ];
  return (
    <KShell vars={vars} active="schedule" title="Schedule" sub="8 – 14 June · 17 classes across 3 rooms"
      actions={<React.Fragment><div style={{ width: 150 }}><KSeg options={['Week', 'Day']} value="Week"></KSeg></div><YButton variant="outline" small>Today</YButton><YButton small>+ New class</YButton></React.Fragment>}>
      <KCard pad={14} style={{ height: '100%', boxSizing: 'border-box' }}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(7, 1fr)', gap: 10, height: '100%' }}>
          {days.map(([d, blocks], i) => (
            <div key={d} style={{ borderLeft: i ? '1px solid var(--border)' : 'none', paddingLeft: i ? 10 : 0, minWidth: 0 }}>
              <div style={{ fontSize: 11.5, fontWeight: 800, letterSpacing: 0.5, textTransform: 'uppercase', color: i === 3 ? 'var(--primary)' : 'var(--muted)', marginBottom: 10 }}>{d}</div>
              {blocks.map(([n, t, w, k]) => <KBlock key={n + t} name={n} time={t} who={w} room={k === 'accent' ? 'R2' : 'R1'} kind={k}></KBlock>)}
              {!blocks.length && <div style={{ fontSize: 11.5, fontWeight: 600, color: 'var(--muted)', opacity: 0.6, marginTop: 4 }}>No classes — rest day</div>}
            </div>
          ))}
        </div>
      </KCard>
    </KShell>
  );
}

// ——— Product Builder: single form, live student-card preview ———
function KProductBuilder({ vars }) {
  return (
    <KShell vars={vars} active="products" title="Edit product" sub="Products / 5-Class Pack"
      actions={<React.Fragment><YButton variant="outline" small>Archive</YButton><YButton small>Save changes</YButton></React.Fragment>}>
      <div style={{ display: 'grid', gridTemplateColumns: '1.5fr 1fr', gap: 16, alignItems: 'start' }}>
        <KCard pad={22}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 18 }}>
            <KField label="Name"><KInput value="5-Class Pack"></KInput></KField>
            <KField label="Price"><KInput value="60.00" suffix="GBP"></KInput></KField>
            <KField label="Billing"><KSeg options={['One-time', 'Recurring']} value="One-time"></KSeg></KField>
            <KField label="Pass kind" hint="Credit packs count down; unlimited checks only the validity window.">
              <KSeg options={['Credits', 'Unlimited']} value="Credits"></KSeg>
            </KField>
            <KField label="Credits"><KInput value="5" w={120}></KInput></KField>
            <KField label="Valid for" hint="From purchase date. Leave empty for no expiry."><KInput value="90" suffix="days" w={150}></KInput></KField>
          </div>
          <div style={{ marginTop: 20 }}>
            <KField label="Eligible class types">
              <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                <KCheckChip label="Vinyasa" on></KCheckChip>
                <KCheckChip label="Yin" on></KCheckChip>
                <KCheckChip label="Power" on></KCheckChip>
                <KCheckChip label="Reformer"></KCheckChip>
                <KCheckChip label="Beginners' Course"></KCheckChip>
              </div>
            </KField>
          </div>
          <div style={{ marginTop: 20, padding: '12px 14px', borderRadius: 12, background: 'var(--surface-2)', fontSize: 12.5, fontWeight: 600, color: 'var(--muted)', lineHeight: 1.5 }}>
            Changes apply to <b style={{ color: 'var(--text)' }}>future purchases only</b> — passes already sold keep the terms they were bought with.
          </div>
        </KCard>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          <KCard title="Student sees" pad={18}>
            <div style={{ borderRadius: 'var(--r-card)', background: 'var(--surface)', border: '1px solid var(--border)', padding: '14px 16px', display: 'flex', alignItems: 'center', gap: 12 }}>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 15, fontWeight: 800, letterSpacing: -0.2 }}>5-Class Pack</div>
                <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--muted)', marginTop: 3 }}>5 credits · valid 90 days</div>
              </div>
              <span style={{ fontSize: 11, fontWeight: 700, padding: '3px 9px', borderRadius: 999, background: 'var(--surface-2)', color: 'var(--muted)' }}>All yoga</span>
              <div style={{ fontSize: 18, fontWeight: 800, letterSpacing: -0.4 }}>£60</div>
            </div>
            <div style={{ fontSize: 12.5, fontWeight: 600, color: 'var(--muted)', marginTop: 12, lineHeight: 1.55 }}>
              In plain terms: 5 classes of Vinyasa, Yin or Power, used within 90 days of purchase. Not valid for Reformer.
            </div>
          </KCard>
          <KCard title="In use" pad={18}>
            <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--muted)', lineHeight: 1.6 }}>
              <b style={{ color: 'var(--text)' }}>31 active passes</b> were bought from this product.<br></br>£1,860 revenue · last sale 2 hours ago.
            </div>
          </KCard>
        </div>
      </div>
    </KShell>
  );
}

Object.assign(window, { KDashboard, KSchedule, KScheduleDay, KProductBuilder });

// ——— Schedule · Day view: vertical time axis × room lanes ———
// This is where overlaps live: 9:00 in Room 1 and Room 2 sit side-by-side.
const KDAY_START = 7, KDAY_END = 20, KDAY_H = 46; // px per hour

function KDayBlock({ name, who, from, to, kind = 'primary', full }) {
  const top = (from - KDAY_START) * KDAY_H;
  const height = (to - from) * KDAY_H - 5;
  const fmt = (h) => `${Math.floor(h)}:${String(Math.round((h % 1) * 60)).padStart(2, '0')}`;
  return (
    <div style={{
      position: 'absolute', left: 4, right: 4, top, height, boxSizing: 'border-box',
      borderRadius: 10, padding: '6px 9px', overflow: 'hidden',
      background: kind === 'accent' ? 'var(--accent-soft)' : 'var(--primary-soft)',
      borderLeft: '3px solid ' + (kind === 'accent' ? 'var(--accent)' : 'var(--primary)'),
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
        <span style={{ fontSize: 11.5, fontWeight: 800, lineHeight: 1.2, flex: 1, minWidth: 0 }}>{name}</span>
        {full && <span style={{ fontSize: 9.5, fontWeight: 800, color: 'var(--muted)', border: '1px solid var(--border-strong)', borderRadius: 999, padding: '1px 6px', whiteSpace: 'nowrap' }}>FULL</span>}
      </div>
      <div style={{ fontSize: 10.5, fontWeight: 600, color: 'var(--muted)', marginTop: 1 }}>{fmt(from)} – {fmt(to)} · {who}</div>
    </div>
  );
}

function KScheduleDay({ vars }) {
  const rooms = [
    ['Room 1', [
      ['Vinyasa Flow', 'Asha', 7.5, 8.5],
      ['Yin & Restore', 'Mara', 12.25, 13.5, 'primary', true],
      ['Power Vinyasa', 'Asha', 17.75, 18.75],
      ['Candlelit Flow', 'Mara', 19, 20],
    ]],
    ['Room 2 · Reformer', [
      ['Reformer Pilates', 'Jonas', 9, 9.83, 'accent'],
      ['Reformer Pilates', 'Jonas', 10, 10.83, 'accent'],
      ['Reformer Private', 'Jonas', 16, 17, 'accent'],
    ]],
    ['Garden Studio', [
      ['Beginners\u2019 Course · wk 3/6', 'Mara', 18, 19],
    ]],
  ];
  const hours = [];
  for (let h = KDAY_START; h <= KDAY_END; h++) hours.push(h);
  return (
    <KShell vars={vars} active="schedule" title="Schedule" sub="Thursday 11 June · 8 classes · 3 rooms"
      actions={<React.Fragment><div style={{ width: 150 }}><KSeg options={['Week', 'Day']} value="Day"></KSeg></div><YButton variant="outline" small>Today</YButton><YButton small>+ New class</YButton></React.Fragment>}>
      <KCard pad={14} style={{ height: '100%', boxSizing: 'border-box', overflow: 'hidden' }}>
        {/* room headers */}
        <div style={{ display: 'grid', gridTemplateColumns: '52px repeat(3, 1fr)', gap: 0, marginBottom: 8 }}>
          <span></span>
          {rooms.map(([r]) => (
            <div key={r} style={{ fontSize: 11.5, fontWeight: 800, letterSpacing: 0.5, textTransform: 'uppercase', color: 'var(--muted)', padding: '0 8px' }}>{r}</div>
          ))}
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '52px repeat(3, 1fr)', position: 'relative' }}>
          {/* time gutter */}
          <div style={{ position: 'relative', height: (KDAY_END - KDAY_START) * KDAY_H }}>
            {hours.map((h) => (
              <div key={h} style={{ position: 'absolute', top: (h - KDAY_START) * KDAY_H - 7, fontSize: 10.5, fontWeight: 700, color: 'var(--muted)', fontVariantNumeric: 'tabular-nums' }}>{h}:00</div>
            ))}
          </div>
          {/* lanes */}
          {rooms.map(([r, blocks], i) => (
            <div key={r} style={{ position: 'relative', height: (KDAY_END - KDAY_START) * KDAY_H, borderLeft: '1px solid var(--border)' }}>
              {hours.map((h) => (
                <div key={h} style={{ position: 'absolute', left: 0, right: 0, top: (h - KDAY_START) * KDAY_H, height: 1, background: 'var(--border)', opacity: 0.55 }}></div>
              ))}
              {blocks.map(([n, w, f, t, k, full]) => <KDayBlock key={n + f} name={n} who={w} from={f} to={t} kind={k} full={full}></KDayBlock>)}
            </div>
          ))}
        </div>
      </KCard>
    </KShell>
  );
}
