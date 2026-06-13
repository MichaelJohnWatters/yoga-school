// yoga-buy.jsx — Buy screen in three candidate layouts (grid / list / grouped).
// Memberships are distinguished from one-off packs by COLOR TREATMENT (decided):
// memberships get the primary-filled / primary-tinted card, packs stay on surface.

const YBUY_PRODUCTS = {
  memberships: [
    { name: 'Unlimited Monthly', price: '£89', per: '/month', meta: 'All classes · renews monthly', gate: 'All disciplines', hero: true },
    { name: 'Intro Month', price: '£49', per: '', meta: 'Unlimited · first 30 days · new students', gate: 'All disciplines' },
  ],
  packs: [
    { name: 'Single Class', price: '£14', per: '', meta: '1 credit · valid 30 days', gate: 'All yoga' },
    { name: '5-Class Pack', price: '£60', per: '', meta: '5 credits · valid 90 days', gate: 'All yoga' },
    { name: '10-Class Pack', price: '£110', per: '', meta: '10 credits · valid 180 days', gate: 'All yoga' },
    { name: 'Reformer 5-Pack', price: '£75', per: '', meta: '5 credits · valid 90 days', gate: 'Reformer only', accentGate: true },
  ],
};

function YBuyHeader() {
  return (
    <div style={{ padding: '70px 20px 0' }}>
      <div style={{ fontSize: 28, fontWeight: 800, letterSpacing: -0.6 }}>Buy</div>
      <div style={{ fontSize: 14, color: 'var(--muted)', fontWeight: 500, marginTop: 2 }}>Passes & memberships</div>
      <div style={{ display: 'flex', gap: 6, marginTop: 14 }}>
        {['All', 'Yoga', 'Reformer'].map((f, i) => (
          <div key={f} style={{
            padding: '7px 16px', borderRadius: 'var(--r-chip)', fontSize: 13, fontWeight: 700,
            background: i === 0 ? 'var(--text)' : 'var(--surface)',
            color: i === 0 ? 'var(--bg)' : 'var(--muted)',
            border: i === 0 ? '1px solid transparent' : '1px solid var(--border-strong)',
          }}>{f}</div>
        ))}
      </div>
    </div>
  );
}

function YGateChip({ gate, accentGate, onFill }) {
  return (
    <span style={{
      fontSize: 11, fontWeight: 700, padding: '3px 9px', borderRadius: 'var(--r-chip)',
      background: onFill ? 'rgba(255,255,255,0.18)' : accentGate ? 'var(--accent-soft)' : 'var(--surface-2)',
      color: onFill ? 'var(--on-primary)' : accentGate ? 'var(--accent)' : 'var(--muted)',
      whiteSpace: 'nowrap',
    }}>{gate}</span>
  );
}

function YRenewTag({ onFill }) {
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontSize: 11.5, fontWeight: 700, color: onFill ? 'var(--on-primary)' : 'var(--primary)', opacity: onFill ? 0.9 : 1 }}>
      <YIcon d="M20 11A8 8 0 105.6 17M4 13a8 8 0 0014.4-6M20 4v4h-4M4 20v-4h4" size={12}></YIcon>
      Membership
    </span>
  );
}

// ——— A · Grid (2-up cards) ———
function YBuyGrid({ vars }) {
  const all = [...YBUY_PRODUCTS.memberships, ...YBUY_PRODUCTS.packs];
  return (
    <YScreen vars={vars} tab="buy">
      <YBuyHeader></YBuyHeader>
      <div style={{ padding: '16px 20px 0', display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }}>
        {all.map((p, i) => {
          const fill = !!p.hero;
          const member = i < 2;
          return (
            <div key={p.name} style={{
              borderRadius: 'var(--r-card)', padding: '14px 14px 12px',
              background: fill ? 'var(--primary)' : member ? 'var(--primary-soft)' : 'var(--surface)',
              color: fill ? 'var(--on-primary)' : 'var(--text)',
              border: fill || member ? '1px solid transparent' : '1px solid var(--border)',
              boxShadow: fill ? 'var(--shadow)' : 'none',
              display: 'flex', flexDirection: 'column', gap: 6, minHeight: 118,
            }}>
              {member ? <YRenewTag onFill={fill}></YRenewTag> : <YGateChip gate={p.gate} accentGate={p.accentGate}></YGateChip>}
              <div style={{ fontSize: 14.5, fontWeight: 800, letterSpacing: -0.2, lineHeight: 1.2 }}>{p.name}</div>
              <div style={{ marginTop: 'auto' }}>
                <span style={{ fontSize: 21, fontWeight: 800, letterSpacing: -0.5 }}>{p.price}</span>
                <span style={{ fontSize: 12, fontWeight: 600, opacity: 0.7 }}>{p.per}</span>
                <div style={{ fontSize: 11, fontWeight: 600, opacity: fill ? 0.85 : 0.6, marginTop: 2, lineHeight: 1.35 }}>{p.meta}</div>
              </div>
            </div>
          );
        })}
      </div>
    </YScreen>
  );
}

// ——— B · Full-width list ———
function YBuyList({ vars }) {
  const all = [...YBUY_PRODUCTS.memberships, ...YBUY_PRODUCTS.packs];
  return (
    <YScreen vars={vars} tab="buy">
      <YBuyHeader></YBuyHeader>
      <div style={{ padding: '16px 20px 0', display: 'flex', flexDirection: 'column', gap: 8 }}>
        {all.map((p, i) => {
          const member = i < 2;
          const fill = !!p.hero;
          return (
            <div key={p.name} style={{
              display: 'flex', alignItems: 'center', gap: 12, padding: '13px 16px',
              borderRadius: 'var(--r-card)',
              background: fill ? 'var(--primary)' : member ? 'var(--primary-soft)' : 'var(--surface)',
              color: fill ? 'var(--on-primary)' : 'var(--text)',
              border: fill || member ? '1px solid transparent' : '1px solid var(--border)',
            }}>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <span style={{ fontSize: 15, fontWeight: 800, letterSpacing: -0.2 }}>{p.name}</span>
                  {member && <YRenewTag onFill={fill}></YRenewTag>}
                </div>
                <div style={{ fontSize: 12, fontWeight: 600, opacity: fill ? 0.85 : 0.6, marginTop: 3 }}>{p.meta}</div>
              </div>
              {!member && <YGateChip gate={p.gate} accentGate={p.accentGate}></YGateChip>}
              <div style={{ textAlign: 'right', flexShrink: 0 }}>
                <span style={{ fontSize: 18, fontWeight: 800, letterSpacing: -0.4 }}>{p.price}</span>
                <span style={{ fontSize: 11.5, fontWeight: 600, opacity: 0.7 }}>{p.per}</span>
              </div>
            </div>
          );
        })}
      </div>
    </YScreen>
  );
}

// ——— C · Grouped sections (Memberships, then Class packs) ———
function YBuyGrouped({ vars }) {
  return (
    <YScreen vars={vars} tab="buy">
      <YBuyHeader></YBuyHeader>
      <div style={{ padding: '16px 20px 0' }}>
        <YSectionHead title="Memberships"></YSectionHead>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }}>
          {YBUY_PRODUCTS.memberships.map((p) => {
            const fill = !!p.hero;
            return (
              <div key={p.name} style={{
                borderRadius: 'var(--r-card)', padding: '14px 14px 12px',
                background: fill ? 'var(--primary)' : 'var(--primary-soft)',
                color: fill ? 'var(--on-primary)' : 'var(--text)',
                display: 'flex', flexDirection: 'column', gap: 6, minHeight: 108,
                boxShadow: fill ? 'var(--shadow)' : 'none',
              }}>
                <YRenewTag onFill={fill}></YRenewTag>
                <div style={{ fontSize: 14.5, fontWeight: 800, lineHeight: 1.2 }}>{p.name}</div>
                <div style={{ marginTop: 'auto' }}>
                  <span style={{ fontSize: 21, fontWeight: 800, letterSpacing: -0.5 }}>{p.price}</span>
                  <span style={{ fontSize: 12, fontWeight: 600, opacity: 0.7 }}>{p.per}</span>
                  <div style={{ fontSize: 11, fontWeight: 600, opacity: fill ? 0.85 : 0.6, marginTop: 2, lineHeight: 1.35 }}>{p.meta}</div>
                </div>
              </div>
            );
          })}
        </div>
        <div style={{ marginTop: 18 }}>
          <YSectionHead title="Class packs"></YSectionHead>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          {YBUY_PRODUCTS.packs.map((p) => (
            <div key={p.name} style={{
              display: 'flex', alignItems: 'center', gap: 12, padding: '12px 16px',
              borderRadius: 'var(--r-card)', background: 'var(--surface)', border: '1px solid var(--border)',
            }}>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 14.5, fontWeight: 800, letterSpacing: -0.2 }}>{p.name}</div>
                <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--muted)', marginTop: 2 }}>{p.meta}</div>
              </div>
              <YGateChip gate={p.gate} accentGate={p.accentGate}></YGateChip>
              <div style={{ fontSize: 17, fontWeight: 800, letterSpacing: -0.4, flexShrink: 0 }}>{p.price}</div>
            </div>
          ))}
        </div>
      </div>
    </YScreen>
  );
}

Object.assign(window, { YBuyGrid, YBuyList, YBuyGrouped, YBuyHeader, YBUY_PRODUCTS });
