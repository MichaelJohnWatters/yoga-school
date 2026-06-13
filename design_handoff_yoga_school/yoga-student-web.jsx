// yoga-student-web.jsx — student app at desktop width (Flutter web).
// Same tokens & components, reflowed: top nav instead of tab bar, 1040px content column.

function WShell({ vars, active, children }) {
  const nav = ['Home', 'Book', 'Buy'];
  return (
    <div style={{
      ...vars, width: '100%', height: '100%', boxSizing: 'border-box', background: 'var(--bg)',
      fontFamily: '"Hanken Grotesk", system-ui, sans-serif', WebkitFontSmoothing: 'antialiased',
      overflow: 'hidden', display: 'flex', flexDirection: 'column', textAlign: 'left',
    }}>
      {/* top nav */}
      <div style={{ background: 'var(--surface)', borderBottom: '1px solid var(--border)', flexShrink: 0 }}>
        <div style={{ maxWidth: 1040, margin: '0 auto', padding: '0 24px', height: 64, display: 'flex', alignItems: 'center', gap: 28 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <YLogo size={32}></YLogo>
            <span style={{ fontSize: 15, fontWeight: 800, letterSpacing: -0.2 }}>Studio 52</span>
          </div>
          <div style={{ display: 'flex', gap: 4, flex: 1 }}>
            {nav.map((n) => {
              const on = n.toLowerCase() === active;
              return (
                <span key={n} style={{
                  padding: '8px 16px', borderRadius: 999, fontSize: 14, fontWeight: 700,
                  background: on ? 'var(--primary-soft)' : 'transparent',
                  color: on ? 'var(--primary-strong)' : 'var(--muted)',
                }}>{n}</span>
              );
            })}
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <div style={{ position: 'relative', width: 38, height: 38, borderRadius: '50%', border: '1px solid var(--border-strong)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
              <YIcon d="M12 3a6 6 0 016 6c0 5 2 6 2 6H4s2-1 2-6a6 6 0 016-6zM10 20a2.2 2.2 0 004 0" size={18}></YIcon>
              <div style={{ position: 'absolute', top: 7, right: 8, width: 7, height: 7, borderRadius: '50%', background: 'var(--accent)' }}></div>
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 9 }}>
              <YAvatar name="Maya Rowe" size={34} tone="accent"></YAvatar>
              <span style={{ fontSize: 13.5, fontWeight: 700 }}>Maya</span>
            </div>
          </div>
        </div>
      </div>
      <div style={{ flex: 1, minHeight: 0, overflow: 'hidden' }}>
        <div style={{ maxWidth: 1040, margin: '0 auto', padding: '28px 24px 0', boxSizing: 'border-box' }}>{children}</div>
      </div>
    </div>
  );
}

// ——— Home: two-column — upcoming hero left, this-week rail right ———
function WHome({ vars }) {
  return (
    <WShell vars={vars} active="home">
      <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between' }}>
        <div>
          <div style={{ fontSize: 28, fontWeight: 800, letterSpacing: -0.6 }}>Good morning, Maya</div>
          <div style={{ fontSize: 14, color: 'var(--muted)', fontWeight: 500, marginTop: 3 }}>Thursday 11 June</div>
        </div>
      </div>
      {/* slim promo */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, background: 'var(--accent-soft)', borderRadius: 'var(--r-card)', padding: '11px 16px', marginTop: 18 }}>
        <span style={{ color: 'var(--accent)', display: 'flex' }}><YIcon d="M20 12l-8 8-9-9V4h7l10 8zM7.5 7.5h.01" size={16}></YIcon></span>
        <div style={{ flex: 1, fontSize: 13.5, fontWeight: 600 }}>Summer offer — 20% off Unlimited Monthly until 21 June</div>
        <span style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--accent)' }}>See offer →</span>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1.5fr 1fr', gap: 20, marginTop: 22 }}>
        <div>
          <YSectionHead title="Upcoming" action="All bookings"></YSectionHead>
          <div style={{ background: 'var(--surface)', borderRadius: 'var(--r-card)', boxShadow: 'var(--shadow)', border: '1px solid var(--border)', padding: 18, display: 'flex', gap: 16, alignItems: 'center' }}>
            <YDateTile dow="FRI" day="12"></YDateTile>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 18, fontWeight: 800, letterSpacing: -0.3 }}>Vinyasa Flow</div>
              <div style={{ fontSize: 13.5, color: 'var(--muted)', fontWeight: 500, marginTop: 3 }}>7:30 – 8:30 · Room 1</div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 7, marginTop: 8 }}>
                <YAvatar name="Asha Patel" size={22}></YAvatar>
                <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--muted)' }}>Asha Patel</span>
              </div>
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 8 }}>
              <YChip kind="booked"><YCheck></YCheck>Booked</YChip>
              <span style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--muted)' }}>Cancel</span>
            </div>
          </div>
          <div style={{ background: 'var(--surface)', borderRadius: 'var(--r-card)', border: '1px solid var(--border)', padding: '13px 18px', display: 'flex', gap: 12, alignItems: 'center', marginTop: 10 }}>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 15, fontWeight: 700 }}>Reformer Pilates</div>
              <div style={{ fontSize: 12.5, color: 'var(--muted)', fontWeight: 500, marginTop: 2 }}>Sat 13 · 9:00 · Jonas Meyer</div>
            </div>
            <YChip kind="booked"><YCheck></YCheck>Booked</YChip>
          </div>
          {/* quiet milestones */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '11px 16px', borderRadius: 'var(--r-card)', border: '1px dashed var(--border-strong)', color: 'var(--muted)', marginTop: 14 }}>
            <span style={{ color: 'var(--accent)', display: 'flex' }}><YIcon d="M12 3l2.2 5.4L20 9l-4.4 3.9L17 19l-5-3.2L7 19l1.4-6.1L4 9l5.8-.6z" size={15}></YIcon></span>
            <span style={{ fontSize: 12.5, fontWeight: 600 }}>24 classes · 3-week streak</span>
          </div>
        </div>
        <div>
          <YSectionHead title="This week" action="Full schedule"></YSectionHead>
          <div style={{ background: 'var(--surface)', borderRadius: 'var(--r-card)', border: '1px solid var(--border)', overflow: 'hidden' }}>
            {[
              ['Yin & Restore', 'Today · 19:00 · Mara Kovac'],
              ['Power Vinyasa', 'Fri · 17:45 · Asha Patel'],
              ['Community Flow', 'Sat · 10:30 · Asha Patel'],
            ].map(([n, m], i) => (
              <div key={n} style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '12px 14px', borderTop: i ? '1px solid var(--border)' : 'none' }}>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 13.5, fontWeight: 700 }}>{n}</div>
                  <div style={{ fontSize: 12, color: 'var(--muted)', fontWeight: 500, marginTop: 1 }}>{m}</div>
                </div>
                <YButton variant="soft" small>Book</YButton>
              </div>
            ))}
          </div>
        </div>
      </div>
    </WShell>
  );
}

// ——— Book: day strip + rows left, persistent class-detail panel right ———
// On desktop the booking sheet becomes a side panel — no overlay needed.
function WBook({ vars }) {
  return (
    <WShell vars={vars} active="book">
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div style={{ fontSize: 28, fontWeight: 800, letterSpacing: -0.6 }}>Book</div>
        <div style={{ display: 'flex', background: 'var(--surface-2)', borderRadius: 999, padding: 3, width: 280 }}>
          {['Classes', 'Enrollments'].map((t, i) => (
            <div key={t} style={{
              flex: 1, textAlign: 'center', padding: '7px 0', borderRadius: 999, fontSize: 13, fontWeight: 700,
              background: i === 0 ? 'var(--surface)' : 'transparent',
              color: i === 0 ? 'var(--text)' : 'var(--muted)',
              border: i === 0 ? '1px solid var(--border)' : '1px solid transparent',
            }}>{t}</div>
          ))}
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1.6fr 1fr', gap: 20, marginTop: 20 }}>
        <div>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8 }}>
            <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--muted)', letterSpacing: 0.4 }}>JUNE 2026</div>
            <div style={{ display: 'flex', gap: 14, color: 'var(--muted)' }}>
              <YIcon d="M15 5l-7 7 7 7" size={14}></YIcon>
              <YIcon d="M9 5l7 7-7 7" size={14}></YIcon>
            </div>
          </div>
          <div style={{ display: 'flex', gap: 6 }}>
            {[['M', 8], ['T', 9], ['W', 10], ['T', 11, true], ['F', 12], ['S', 13], ['S', 14]].map(([d, n, sel], i) => (
              <div key={i} style={{
                flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 3,
                padding: '8px 0 6px', borderRadius: 12,
                background: sel ? 'var(--primary)' : 'var(--surface)',
                color: sel ? 'var(--on-primary)' : 'var(--text)',
                border: sel ? '1px solid transparent' : '1px solid var(--border)',
              }}>
                <div style={{ fontSize: 10.5, fontWeight: 700, opacity: sel ? 0.8 : 0.55 }}>{d}</div>
                <div style={{ fontSize: 15, fontWeight: 800 }}>{n}</div>
                <div style={{ width: 4, height: 4, borderRadius: '50%', background: i !== 6 ? (sel ? 'var(--on-primary)' : 'var(--primary)') : 'transparent' }}></div>
              </div>
            ))}
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8, marginTop: 14 }}>
            <YClassRow time="7:30" dur="60 min" name="Vinyasa Flow" who="Asha Patel"
              state={<YChip kind="booked"><YCheck></YCheck>Booked</YChip>}></YClassRow>
            <div style={{ borderRadius: 'var(--r-card)', border: '1.5px solid var(--primary)', boxShadow: 'var(--shadow)' }}>
              <YClassRow time="9:00" dur="50 min" name="Reformer Pilates" who="Jonas Meyer"
                state={<YChip kind="accent">Selected</YChip>} hint="2 spots left"></YClassRow>
            </div>
            <YClassRow time="12:15" dur="75 min" name="Yin & Restore" who="Mara Kovac"
              state={<YChip kind="full">Full · 3 waiting</YChip>}
              hint={<span style={{ color: 'var(--primary)', fontWeight: 700 }}>Join waitlist</span>}></YClassRow>
            <YClassRow time="17:45" dur="60 min" name="Power Vinyasa" who="Asha Patel"
              state={<YButton variant="primary" small>Book</YButton>}></YClassRow>
          </div>
        </div>

        {/* detail panel = the mobile sheet, docked */}
        <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 'var(--r-card)', padding: 20, alignSelf: 'start' }}>
          <div style={{ fontSize: 18, fontWeight: 800, letterSpacing: -0.3 }}>Reformer Pilates</div>
          <div style={{ fontSize: 13, fontWeight: 500, color: 'var(--muted)', marginTop: 3 }}>Thu 11 June · 9:00 – 9:50 · Room 2</div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 12 }}>
            <YAvatar name="Jonas Meyer" size={28}></YAvatar>
            <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--muted)' }}>with Jonas Meyer · 10 of 12 booked</span>
          </div>
          <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--muted)', margin: '16px 0 7px', letterSpacing: 0.3 }}>PAY WITH</div>
          <div style={{ border: '1.5px solid var(--primary)', background: 'var(--primary-soft)', borderRadius: 12, padding: '11px 13px', display: 'flex', alignItems: 'center', gap: 10 }}>
            <div style={{ width: 17, height: 17, borderRadius: '50%', border: '5px solid var(--primary)', background: 'var(--surface)', flexShrink: 0 }}></div>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 13.5, fontWeight: 700 }}>Reformer 5-Pack</div>
              <div style={{ fontSize: 11.5, fontWeight: 600, color: 'var(--muted)' }}>3 credits left · expires 12 Aug</div>
            </div>
            <span style={{ fontSize: 12.5, fontWeight: 800 }}>1 credit</span>
          </div>
          <div style={{ borderRadius: 12, border: '1px solid var(--border)', padding: '10px 13px', display: 'flex', alignItems: 'center', gap: 10, marginTop: 7 }}>
            <div style={{ width: 17, height: 17, borderRadius: '50%', border: '1.5px solid var(--border-strong)', flexShrink: 0 }}></div>
            <span style={{ flex: 1, fontSize: 13.5, fontWeight: 700, color: 'var(--muted)' }}>Buy a new pass…</span>
          </div>
          <div style={{ fontSize: 11.5, fontWeight: 500, color: 'var(--muted)', marginTop: 12, lineHeight: 1.45 }}>
            Free cancellation until Wed 21:00. After that, your credit is used.
          </div>
          <YButton style={{ width: '100%', boxSizing: 'border-box', marginTop: 12 }}>Book this class</YButton>
        </div>
      </div>
    </WShell>
  );
}

// ——— Buy: grouped layout breathes at desktop width ———
function WBuy({ vars }) {
  return (
    <WShell vars={vars} active="buy">
      <div style={{ fontSize: 28, fontWeight: 800, letterSpacing: -0.6 }}>Buy</div>
      <div style={{ fontSize: 14, color: 'var(--muted)', fontWeight: 500, marginTop: 3 }}>Passes & memberships</div>
      <div style={{ marginTop: 22 }}>
        <YSectionHead title="Memberships"></YSectionHead>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          {YBUY_PRODUCTS.memberships.map((p) => {
            const fill = !!p.hero;
            return (
              <div key={p.name} style={{
                borderRadius: 'var(--r-card)', padding: '18px 20px',
                background: fill ? 'var(--primary)' : 'var(--primary-soft)',
                color: fill ? 'var(--on-primary)' : 'var(--text)',
                boxShadow: fill ? 'var(--shadow)' : 'none',
                display: 'flex', alignItems: 'center', gap: 16,
              }}>
                <div style={{ flex: 1 }}>
                  <YRenewTag onFill={fill}></YRenewTag>
                  <div style={{ fontSize: 17, fontWeight: 800, letterSpacing: -0.3, marginTop: 5 }}>{p.name}</div>
                  <div style={{ fontSize: 12, fontWeight: 600, opacity: fill ? 0.85 : 0.6, marginTop: 3 }}>{p.meta}</div>
                </div>
                <div style={{ textAlign: 'right' }}>
                  <span style={{ fontSize: 24, fontWeight: 800, letterSpacing: -0.6 }}>{p.price}</span>
                  <span style={{ fontSize: 12.5, fontWeight: 600, opacity: 0.7 }}>{p.per}</span>
                </div>
              </div>
            );
          })}
        </div>
        <div style={{ margin: '20px 0 0' }}>
          <YSectionHead title="Class packs"></YSectionHead>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          {YBUY_PRODUCTS.packs.map((p) => (
            <div key={p.name} style={{
              display: 'flex', alignItems: 'center', gap: 12, padding: '14px 18px',
              borderRadius: 'var(--r-card)', background: 'var(--surface)', border: '1px solid var(--border)',
            }}>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 14.5, fontWeight: 800, letterSpacing: -0.2 }}>{p.name}</div>
                <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--muted)', marginTop: 2 }}>{p.meta}</div>
              </div>
              <YGateChip gate={p.gate} accentGate={p.accentGate}></YGateChip>
              <div style={{ fontSize: 17, fontWeight: 800, letterSpacing: -0.4 }}>{p.price}</div>
            </div>
          ))}
        </div>
      </div>
    </WShell>
  );
}

Object.assign(window, { WShell, WHome, WBook, WBuy });
