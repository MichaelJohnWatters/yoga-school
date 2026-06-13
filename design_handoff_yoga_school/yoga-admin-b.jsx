// yoga-admin-b.jsx — Roster/check-in, Students, Reports, Studio Settings
// (Settings carries the theme editor + the new buy-screen-layout studio option.)

function KAttendanceSeg({ state }) {
  return (
    <div style={{ display: 'flex', gap: 4 }}>
      {['Present', 'No-show'].map((o) => {
        const on = (state === 'present' && o === 'Present') || (state === 'noshow' && o === 'No-show');
        return (
          <span key={o} style={{
            padding: '5px 12px', borderRadius: 999, fontSize: 12, fontWeight: 700,
            background: on ? (o === 'Present' ? 'var(--primary)' : 'var(--text)') : 'var(--surface)',
            color: on ? 'var(--on-primary)' : 'var(--muted)',
            border: on ? '1px solid transparent' : '1px solid var(--border-strong)',
          }}>{o}</span>
        );
      })}
    </div>
  );
}

function KRosterFilter({ options, value }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 14 }}>
      <div style={{ display: 'flex', gap: 6, flex: 1 }}>
        {options.map(([label, count]) => {
          const on = label === value;
          return (
            <span key={label} style={{
              display: 'inline-flex', alignItems: 'center', gap: 6, padding: '6px 12px', borderRadius: 999,
              fontSize: 12.5, fontWeight: 700,
              background: on ? 'var(--text)' : 'var(--surface)',
              color: on ? 'var(--bg)' : 'var(--muted)',
              border: on ? '1px solid transparent' : '1px solid var(--border-strong)',
            }}>
              {label}
              <span style={{ fontSize: 11, fontWeight: 800, opacity: 0.65, fontVariantNumeric: 'tabular-nums' }}>{count}</span>
            </span>
          );
        })}
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 7, border: '1px solid var(--border-strong)', borderRadius: 999, padding: '6px 12px', color: 'var(--muted)', width: 150 }}>
        <YIcon d="M11 18a7 7 0 110-14 7 7 0 010 14zM21 21l-5-5" size={13}></YIcon>
        <span style={{ fontSize: 12.5, fontWeight: 600 }}>Find a name…</span>
      </div>
    </div>
  );
}

function KRoster({ vars }) {
  const rows = [
    ['Maya Rowe', '5-Class Pack', 'present', 'scan'],
    ['Tom Hale', 'Unlimited Monthly', 'present', 'scan'],
    ['Lena Fox', 'Reformer 5-Pack', 'noshow', 'manual'],
    ['Sam Idowu', 'Unlimited Monthly', null, null],
    ['Ana Reyes', '10-Class Pack · +1 guest', null, null],
  ];
  return (
    <KShell vars={vars} active="roster" title="Yin & Restore" sub="Thursday 11 June · 12:15 – 13:30 · Mara Kovac · Room 1"
      actions={<React.Fragment><YButton variant="outline" small>+ Add student</YButton><YButton small>Scan check-in</YButton></React.Fragment>}>
      <div style={{ display: 'grid', gridTemplateColumns: '1.8fr 1fr', gap: 16, alignItems: 'start' }}>
        <KCard title="Booked · 16 of 16" action="Mark all present">
          <KRosterFilter value="All" options={[['All', 16], ['Unmarked', 13], ['Present', 2], ['No-show', 1]]}></KRosterFilter>
          <KRow cols="1.3fr 1.2fr 190px" head><span>Student</span><span>Pass used</span><span>Attendance</span></KRow>
          {rows.map(([n, pass, st, by], i) => (
            <KRow key={n} cols="1.3fr 1.2fr 190px" last={i === rows.length - 1}>
              <span style={{ display: 'flex', alignItems: 'center', gap: 9, fontWeight: 700 }}>
                <YAvatar name={n} size={26}></YAvatar>{n}
                {by === 'scan' && <span style={{ fontSize: 10.5, fontWeight: 700, color: 'var(--accent)' }}>· scanned</span>}
              </span>
              <span style={{ color: 'var(--muted)' }}>{pass}</span>
              <KAttendanceSeg state={st}></KAttendanceSeg>
            </KRow>
          ))}
          <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--muted)', marginTop: 12 }}>+ 11 more booked</div>
        </KCard>
        <KCard title="Waitlist · 3">
          {[['Jo Park', 1], ['Ren Ito', 2], ['Eva Lund', 3]].map(([n, p], i, a) => (
            <KRow key={n} cols="24px 1fr 90px" last={i === a.length - 1}>
              <span style={{ fontWeight: 800, color: 'var(--muted)' }}>{p}</span>
              <span style={{ display: 'flex', alignItems: 'center', gap: 9, fontWeight: 700 }}><YAvatar name={n} size={26}></YAvatar>{n}</span>
              <YButton variant="soft" small>Promote</YButton>
            </KRow>
          ))}
          <div style={{ marginTop: 14, padding: '11px 13px', borderRadius: 12, background: 'var(--surface-2)', fontSize: 12, fontWeight: 600, color: 'var(--muted)', lineHeight: 1.5 }}>
            Promoting notifies the student — their spot holds for 60 minutes before passing on.
          </div>
        </KCard>
      </div>
    </KShell>
  );
}

function KStudents({ vars }) {
  const rows = [
    ['Maya Rowe', '5-Class Pack', '3 left', 'Today', 'active'],
    ['Tom Hale', 'Unlimited Monthly', 'Renews 1 Jul', 'Yesterday', 'active'],
    ['Lena Fox', 'Reformer 5-Pack', '1 left', '3 days ago', 'active'],
    ['Sam Idowu', 'Unlimited Monthly', 'Renews 18 Jun', 'Today', 'active'],
    ['Ana Reyes', '10-Class Pack', '7 left', '1 week ago', 'active'],
    ['Jo Park', '—', 'No active pass', '3 weeks ago', 'none'],
  ];
  return (
    <KShell vars={vars} active="students" title="Students" sub="214 students · 128 with an active pass"
      actions={<YButton small>Grant a pass (cash)</YButton>}>
      <KCard>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, border: '1px solid var(--border-strong)', borderRadius: 12, padding: '10px 14px', marginBottom: 16, color: 'var(--muted)' }}>
          <YIcon d="M11 18a7 7 0 110-14 7 7 0 010 14zM21 21l-5-5" size={16}></YIcon>
          <span style={{ fontSize: 13.5, fontWeight: 600 }}>Search by name or email…</span>
        </div>
        <KRow cols="1.4fr 1.2fr 1fr 0.9fr 110px" head>
          <span>Student</span><span>Active pass</span><span>Remaining</span><span>Last visit</span><span></span>
        </KRow>
        {rows.map(([n, pass, rem, last, st], i) => (
          <KRow key={n} cols="1.4fr 1.2fr 1fr 0.9fr 110px" last={i === rows.length - 1}>
            <span style={{ display: 'flex', alignItems: 'center', gap: 9, fontWeight: 700 }}><YAvatar name={n} size={26}></YAvatar>{n}</span>
            <span style={{ color: st === 'none' ? 'var(--muted)' : 'var(--text)' }}>{pass}</span>
            <span style={{ color: 'var(--muted)' }}>{rem}</span>
            <span style={{ color: 'var(--muted)' }}>{last}</span>
            <span style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--primary)' }}>{st === 'none' ? 'Grant pass' : 'View'}</span>
          </KRow>
        ))}
      </KCard>
    </KShell>
  );
}

function KBars({ data, labels }) {
  const max = Math.max(...data.map((d) => d[0] + d[1]));
  return (
    <div>
      <div style={{ display: 'flex', alignItems: 'flex-end', gap: 14, height: 110 }}>
        {data.map(([card, cash], i) => (
          <div key={i} style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'flex-end', gap: 2, height: '100%' }}>
            <div style={{ height: (cash / max) * 100 + '%', borderRadius: '4px 4px 0 0', background: 'var(--accent-soft)', borderTop: '2px solid var(--accent)' }}></div>
            <div style={{ height: (card / max) * 100 + '%', borderRadius: 2, background: 'var(--primary)' }}></div>
          </div>
        ))}
      </div>
      <div style={{ display: 'flex', gap: 14, marginTop: 7 }}>
        {labels.map((l) => <div key={l} style={{ flex: 1, textAlign: 'center', fontSize: 11, fontWeight: 600, color: 'var(--muted)' }}>{l}</div>)}
      </div>
    </div>
  );
}

function KReports({ vars }) {
  return (
    <KShell vars={vars} active="reports" title="Reports" sub="June 2026"
      actions={<YButton variant="outline" small>Export CSV</YButton>}>
      <div style={{ display: 'flex', gap: 14, marginBottom: 16 }}>
        <KStat label="Revenue this month" value="£4,820" sub="£4,240 card · £580 cash"></KStat>
        <KStat label="Avg occupancy" value="74%" sub="up 6% on May"></KStat>
        <KStat label="No-show rate" value="4.1%" sub="11 of 268 bookings"></KStat>
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: '1.4fr 1fr', gap: 16, alignItems: 'start' }}>
        <KCard title="Revenue by week" action="card ▮ · cash ▯">
          <KBars data={[[980, 120], [1140, 160], [1060, 180], [1060, 120]]} labels={['1–7 Jun', '8–14', '15–21', '22–28']}></KBars>
        </KCard>
        <KCard title="Instructor pay — June">
          <KRow cols="1.2fr 0.8fr 0.6fr" head><span>Instructor</span><span>Classes</span><span>Pay</span></KRow>
          {[['Asha Patel', 22, '£880'], ['Mara Kovac', 18, '£720'], ['Jonas Meyer', 14, '£630']].map(([n, c, p], i, a) => (
            <KRow key={n} cols="1.2fr 0.8fr 0.6fr" last={i === a.length - 1}>
              <span style={{ display: 'flex', alignItems: 'center', gap: 9, fontWeight: 700 }}><YAvatar name={n} size={26}></YAvatar>{n}</span>
              <span style={{ color: 'var(--muted)' }}>{c} taught</span>
              <span style={{ fontWeight: 800, fontVariantNumeric: 'tabular-nums' }}>{p}</span>
            </KRow>
          ))}
        </KCard>
      </div>
    </KShell>
  );
}

// ——— Studio Settings: config + theme editor ———
function KThemeRow({ presetKey, active, scheduled }) {
  const p = YOGA_PRESETS[presetKey];
  return (
    <KRow cols="86px 1fr 150px 90px" last={presetKey === 'citrus'}>
      <span style={{ display: 'flex', gap: 4 }}>
        {[p.light.primary, p.light.accent, p.light.background].map((c, i) => (
          <span key={i} style={{ width: 22, height: 22, borderRadius: 7, background: c, border: '1px solid rgba(0,0,0,0.12)' }}></span>
        ))}
      </span>
      <span style={{ fontWeight: 700 }}>{p.name}
        {scheduled && <span style={{ fontSize: 11, fontWeight: 700, color: 'var(--accent)', marginLeft: 8 }}>auto-activates 1 Dec</span>}
      </span>
      <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--muted)' }}>Contrast ✓ AA</span>
      {active
        ? <span><YChip kind="booked"><YCheck></YCheck>Active</YChip></span>
        : <span style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--primary)' }}>Activate</span>}
    </KRow>
  );
}

function KSettings({ vars, buyLayout = 'Grouped' }) {
  return (
    <KShell vars={vars} active="settings" title="Studio Settings" sub="Branding, policies and themes — changes apply to the student app instantly">
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1.25fr', gap: 16, alignItems: 'start' }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          <KCard title="Studio" pad={20}>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
              <KField label="Display name"><KInput value="Studio 52"></KInput></KField>
              <KField label="Welcome message"><KInput value="Glad you're here"></KInput></KField>
              <KField label="Timezone"><KInput value="Europe/London"></KInput></KField>
              <KField label="Currency"><KInput value="GBP £"></KInput></KField>
            </div>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, marginTop: 14, paddingTop: 14, borderTop: '1px solid var(--border)' }}>
              <div>
                <div style={{ fontSize: 13.5, fontWeight: 700 }}>Splash image</div>
                <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--muted)', marginTop: 2 }}>Optional · full-bleed behind the logo at launch</div>
              </div>
              <YButton variant="outline" small>Upload…</YButton>
            </div>
          </KCard>
          <KCard title="Policies" pad={20}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
                <div style={{ fontSize: 13.5, fontWeight: 700 }}>Free cancellation cutoff</div>
                <KInput value="12" suffix="hours" w={110}></KInput>
              </div>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
                <div>
                  <div style={{ fontSize: 13.5, fontWeight: 700 }}>Students can bring a +1</div>
                  <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--muted)', marginTop: 2 }}>Guests use a second credit from the booker's pass</div>
                </div>
                <KToggle on></KToggle>
              </div>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
                <div>
                  <div style={{ fontSize: 13.5, fontWeight: 700 }}>Buy screen layout</div>
                  <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--muted)', marginTop: 2 }}>How passes & memberships are presented to students</div>
                </div>
                <div style={{ width: 230 }}><KSeg options={['Grid', 'List', 'Grouped']} value={buyLayout}></KSeg></div>
              </div>
            </div>
          </KCard>
        </div>
        <KCard title="Themes" action="+ New theme" pad={20}>
          <KRow cols="86px 1fr 150px 90px" head><span>Palette</span><span>Name</span><span>Guardrail</span><span></span></KRow>
          <KThemeRow presetKey="clay" active></KThemeRow>
          <KThemeRow presetKey="slate"></KThemeRow>
          <KThemeRow presetKey="sage"></KThemeRow>
          <KThemeRow presetKey="citrus" scheduled></KThemeRow>
          <div style={{ marginTop: 16, padding: 16, borderRadius: 12, background: 'var(--surface-2)' }}>
            <div style={{ fontSize: 12.5, fontWeight: 800, marginBottom: 10 }}>Edit tokens — Warm Clay</div>
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              {[['Primary', 'var(--primary)'], ['Accent', 'var(--accent)'], ['Background', 'var(--bg)'], ['Surface', 'var(--surface)'], ['Text', 'var(--text)'], ['Muted', 'var(--muted)']].map(([l, c]) => (
                <span key={l} style={{ display: 'inline-flex', alignItems: 'center', gap: 7, padding: '6px 10px', borderRadius: 999, border: '1px solid var(--border-strong)', background: 'var(--surface)', fontSize: 12, fontWeight: 700 }}>
                  <span style={{ width: 16, height: 16, borderRadius: 6, background: c, border: '1px solid rgba(0,0,0,0.12)' }}></span>{l}
                </span>
              ))}
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 12, fontSize: 12, fontWeight: 600, color: 'var(--muted)' }}>
              <span style={{ color: 'var(--primary)', display: 'flex' }}><YCheck size={12}></YCheck></span>
              Text on surface 12.6 : 1 · Text on primary 4.9 : 1 — both pass. The editor blocks saving below 4.5 : 1.
            </div>
          </div>
        </KCard>
      </div>
    </KShell>
  );
}

Object.assign(window, { KRoster, KRosterFilter, KStudents, KReports, KSettings, KAttendanceSeg, KBars });
