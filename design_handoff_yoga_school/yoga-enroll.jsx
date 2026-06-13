// yoga-enroll.jsx — Enrollments: pay once → booked into every session of a series.
// Student: Book › Enrollments tab + enroll sheet. Manager: series roster grid.

const YENROLL_COURSES = [
  {
    name: "Beginners' Course", sessions: 6, day: 'Wednesdays 18:00', range: '17 Jun – 22 Jul',
    who: 'Mara Kovac', price: '£60', spots: '3 of 10 left', state: 'open',
  },
  {
    name: 'Reformer Foundations', sessions: 4, day: 'Saturdays 11:30', range: '20 Jun – 11 Jul',
    who: 'Jonas Meyer', price: '£68', spots: 'Full · 2 waiting', state: 'full',
  },
  {
    name: 'Mindful Mornings', sessions: 6, day: 'Mondays 7:00', range: '1 Jun – 6 Jul',
    who: 'Asha Patel', price: '£54', state: 'enrolled', progress: 'Session 2 of 6 · next Mon 15',
  },
];

function YCourseCard({ c }) {
  const enrolled = c.state === 'enrolled';
  return (
    <div style={{
      background: enrolled ? 'var(--primary-soft)' : 'var(--surface)',
      border: enrolled ? '1px solid transparent' : '1px solid var(--border)',
      borderRadius: 'var(--r-card)', padding: '15px 16px',
    }}>
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 12 }}>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 15.5, fontWeight: 800, letterSpacing: -0.2 }}>{c.name}</div>
          <div style={{ fontSize: 12.5, fontWeight: 600, color: 'var(--muted)', marginTop: 3 }}>
            {c.sessions} sessions · {c.day} · {c.range}
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginTop: 8 }}>
            <YAvatar name={c.who} size={20}></YAvatar>
            <span style={{ fontSize: 12.5, fontWeight: 600, color: 'var(--muted)' }}>{c.who}</span>
          </div>
        </div>
        <div style={{ textAlign: 'right', flexShrink: 0 }}>
          {!enrolled && <div style={{ fontSize: 17, fontWeight: 800, letterSpacing: -0.4 }}>{c.price}</div>}
          {!enrolled && <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--muted)', marginTop: 2 }}>one payment</div>}
          {enrolled && <YChip kind="booked"><YCheck></YCheck>Enrolled</YChip>}
        </div>
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 12 }}>
        {c.state === 'open' && (
          <React.Fragment>
            <YButton variant="primary" small>Enroll · {c.price}</YButton>
            <span style={{ fontSize: 12, fontWeight: 700, color: 'var(--muted)' }}>{c.spots}</span>
          </React.Fragment>
        )}
        {c.state === 'full' && (
          <React.Fragment>
            <YChip kind="full">{c.spots}</YChip>
            <span style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--primary)' }}>Join waitlist</span>
          </React.Fragment>
        )}
        {enrolled && (
          <div style={{ flex: 1 }}>
            <div style={{ display: 'flex', gap: 4 }}>
              {[1, 1, 0, 0, 0, 0].map((f, i) => (
                <div key={i} style={{ flex: 1, height: 6, borderRadius: 4, background: f ? 'var(--primary)' : 'var(--surface)', border: f ? 'none' : '1px solid var(--border-strong)' }}></div>
              ))}
            </div>
            <div style={{ fontSize: 11.5, fontWeight: 600, color: 'var(--muted)', marginTop: 6 }}>{c.progress}</div>
          </div>
        )}
      </div>
    </div>
  );
}

function YEnrollListScreen({ vars }) {
  return (
    <YScreen vars={vars} tab="book">
      <YBookHeader tab="enrollments"></YBookHeader>
      <div style={{ padding: '16px 20px 0', display: 'flex', flexDirection: 'column', gap: 10 }}>
        {YENROLL_COURSES.map((c) => <YCourseCard key={c.name} c={c}></YCourseCard>)}
        <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--muted)', lineHeight: 1.5, padding: '4px 2px' }}>
          Enrolling reserves your spot in every session of the course — one payment, no credits needed.
        </div>
      </div>
    </YScreen>
  );
}

// ——— Enroll sheet: one payment → all sessions listed & booked ———
function YEnrollSheetScreen({ vars }) {
  const sessions = ['Wed 17 Jun', 'Wed 24 Jun', 'Wed 1 Jul', 'Wed 8 Jul', 'Wed 15 Jul', 'Wed 22 Jul'];
  return (
    <div style={{ position: 'absolute', inset: 0 }}>
      <YEnrollListScreen vars={vars}></YEnrollListScreen>
      <div style={{ position: 'absolute', inset: 0, background: 'rgba(15,10,5,0.4)', backdropFilter: 'blur(2px)' }}></div>
      <div style={{
        ...vars, position: 'absolute', left: 0, right: 0, bottom: 0,
        background: 'var(--surface)', borderRadius: '24px 24px 0 0', padding: '10px 20px 36px',
        fontFamily: '"Hanken Grotesk", system-ui, sans-serif', color: 'var(--text)',
        boxShadow: '0 -12px 40px rgba(0,0,0,0.25)',
      }}>
        <div style={{ width: 38, height: 4, borderRadius: 4, background: 'var(--border-strong)', margin: '0 auto 16px' }}></div>
        <div style={{ display: 'flex', alignItems: 'flex-start', gap: 12 }}>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 19, fontWeight: 800, letterSpacing: -0.4 }}>Beginners' Course</div>
            <div style={{ fontSize: 13, fontWeight: 500, color: 'var(--muted)', marginTop: 3 }}>6 sessions · Wednesdays 18:00 · Garden Studio · Mara Kovac</div>
          </div>
          <YChip kind="accent">3 of 10 left</YChip>
        </div>

        <div style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--muted)', margin: '16px 0 8px', letterSpacing: 0.3 }}>YOU'LL BE BOOKED INTO ALL 6</div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 6 }}>
          {sessions.map((s, i) => (
            <div key={s} style={{
              borderRadius: 10, padding: '8px 4px', textAlign: 'center',
              background: 'var(--primary-soft)', color: 'var(--primary-strong)',
              fontSize: 11.5, fontWeight: 700,
            }}>
              <span style={{ display: 'block', fontSize: 10, fontWeight: 800, opacity: 0.65 }}>WK {i + 1}</span>
              {s}
            </div>
          ))}
        </div>
        <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--muted)', marginTop: 10, lineHeight: 1.45 }}>
          Can't make a week? Sessions you miss aren't refunded, but you can offer your spot to the waitlist.
        </div>

        <div style={{ marginTop: 14, borderRadius: 'var(--r-card)', background: 'var(--surface-2)', padding: '12px 14px', display: 'flex', alignItems: 'center', gap: 10 }}>
          <div style={{ flex: 1, fontSize: 13.5, fontWeight: 700 }}>One payment · no credits used</div>
          <div style={{ fontSize: 19, fontWeight: 800, letterSpacing: -0.4 }}>£60</div>
        </div>
        <YButton style={{ width: '100%', boxSizing: 'border-box', marginTop: 12 }}>Enroll & pay £60</YButton>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6, marginTop: 10, color: 'var(--muted)' }}>
          <YIcon d="M7 11V8a5 5 0 0110 0v3M6 11h12a1 1 0 011 1v8a1 1 0 01-1 1H6a1 1 0 01-1-1v-8a1 1 0 011-1z" size={12}></YIcon>
          <span style={{ fontSize: 11.5, fontWeight: 600 }}>Stripe checkout · Apple Pay / Google Pay / card</span>
        </div>
      </div>
    </div>
  );
}

// ——— Manager: series roster — attendance grid across weeks ———
function KSeriesCell({ v }) {
  if (v === 1) return <div style={{ width: 22, height: 22, borderRadius: 7, background: 'var(--primary)', color: 'var(--on-primary)', display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto' }}><YCheck size={10}></YCheck></div>;
  if (v === 0) return <div style={{ width: 22, height: 22, borderRadius: 7, background: 'var(--text)', color: 'var(--bg)', display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto', fontSize: 10, fontWeight: 800 }}>✕</div>;
  return <div style={{ width: 22, height: 22, borderRadius: 7, border: '1px dashed var(--border-strong)', margin: '0 auto' }}></div>;
}

function KSeriesRoster({ vars }) {
  const students = [
    ['Maya Rowe', [1, 1, null, null, null, null]],
    ['Jo Park', [1, 0, null, null, null, null]],
    ['Ren Ito', [1, 1, null, null, null, null]],
    ['Eva Lund', [0, 1, null, null, null, null]],
    ['Tom Hale', [1, 1, null, null, null, null]],
  ];
  const cols = '1.4fr repeat(6, 64px) 90px';
  return (
    <KShell vars={vars} active="schedule" title="Mindful Mornings" sub="Course · 6 sessions · Mondays 7:00 · Asha Patel · 1 Jun – 6 Jul"
      actions={<React.Fragment><YButton variant="outline" small>Edit series</YButton><YButton small>+ Add student</YButton></React.Fragment>}>
      <div style={{ display: 'flex', gap: 14, marginBottom: 16 }}>
        <KStat label="Enrolled" value="9 / 12" sub="3 spots still selling"></KStat>
        <KStat label="Revenue" value="£486" sub="9 × £54 · one-time"></KStat>
        <KStat label="Attendance so far" value="83%" sub="15 of 18 session-visits"></KStat>
      </div>
      <KCard title="Attendance — week by week" action="Session 2 of 6 · next Mon 15">
        <KRow cols={cols} head>
          <span>Student</span>
          {['1 Jun', '8 Jun', '15', '22', '29', '6 Jul'].map((w, i) => (
            <span key={w} style={{ textAlign: 'center', color: i === 2 ? 'var(--primary)' : undefined }}>{w}</span>
          ))}
          <span></span>
        </KRow>
        {students.map(([n, weeks], i) => (
          <KRow key={n} cols={cols} last={i === students.length - 1}>
            <span style={{ display: 'flex', alignItems: 'center', gap: 9, fontWeight: 700 }}><YAvatar name={n} size={26}></YAvatar>{n}</span>
            {weeks.map((v, j) => <KSeriesCell key={j} v={v}></KSeriesCell>)}
            <span style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--primary)', textAlign: 'right' }}>View</span>
          </KRow>
        ))}
        <div style={{ display: 'flex', gap: 16, marginTop: 14, fontSize: 12, fontWeight: 600, color: 'var(--muted)', alignItems: 'center' }}>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}><KSeriesCell v={1}></KSeriesCell> Present</span>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}><KSeriesCell v={0}></KSeriesCell> No-show</span>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}><KSeriesCell v={null}></KSeriesCell> Upcoming</span>
          <span style={{ marginLeft: 'auto' }}>+ 4 more students</span>
        </div>
      </KCard>
    </KShell>
  );
}

Object.assign(window, { YEnrollListScreen, YEnrollSheetScreen, YCourseCard, KSeriesRoster });
