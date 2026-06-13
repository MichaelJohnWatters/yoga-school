// yoga-checkout.jsx — Stripe purchase flow: checkout sheet over Buy + success.
// POST /purchases → Stripe payment → /purchases/{id}/confirm → entitlement.

function YCheckoutScreen({ vars }) {
  return (
    <div style={{ position: 'absolute', inset: 0 }}>
      <YBuyGrouped vars={vars}></YBuyGrouped>
      <div style={{ position: 'absolute', inset: 0, background: 'rgba(15,10,5,0.4)', backdropFilter: 'blur(2px)' }}></div>
      <div style={{
        ...vars, position: 'absolute', left: 0, right: 0, bottom: 0,
        background: 'var(--surface)', borderRadius: '24px 24px 0 0', padding: '10px 20px 40px',
        fontFamily: '"Hanken Grotesk", system-ui, sans-serif', color: 'var(--text)',
        boxShadow: '0 -12px 40px rgba(0,0,0,0.25)',
      }}>
        <div style={{ width: 38, height: 4, borderRadius: 4, background: 'var(--border-strong)', margin: '0 auto 16px' }}></div>
        <div style={{ fontSize: 19, fontWeight: 800, letterSpacing: -0.4 }}>Confirm purchase</div>

        {/* order summary */}
        <div style={{ marginTop: 14, borderRadius: 'var(--r-card)', background: 'var(--primary-soft)', padding: '14px 16px', display: 'flex', alignItems: 'center', gap: 12 }}>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 15, fontWeight: 800, letterSpacing: -0.2 }}>5-Class Pack</div>
            <div style={{ fontSize: 12.5, fontWeight: 600, color: 'var(--muted)', marginTop: 2 }}>5 credits · all yoga · valid 90 days</div>
          </div>
          <div style={{ fontSize: 19, fontWeight: 800, letterSpacing: -0.4 }}>£60</div>
        </div>

        {/* express wallets — Stripe payment request buttons */}
        <div style={{ display: 'flex', gap: 8, marginTop: 16 }}>
          <div style={{ flex: 1, height: 46, borderRadius: 'var(--r-chip)', background: '#000', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 5, fontSize: 15, fontWeight: 600 }}>
            <svg width="14" height="17" viewBox="0 0 14 17" fill="currentColor"><path d="M11.6 9c0-2 1.6-2.9 1.7-3-1-1.4-2.4-1.6-2.9-1.6-1.2-.1-2.4.7-3 .7-.6 0-1.6-.7-2.6-.7C3.4 4.5 2.2 5.2 1.5 6.3c-1.4 2.4-.4 6 1 8 .7 1 1.5 2 2.5 2 1 0 1.4-.6 2.6-.6 1.2 0 1.5.6 2.6.6s1.8-1 2.4-2c.8-1.1 1.1-2.2 1.1-2.3 0 0-2.1-.8-2.1-3zM9.6 3.1c.5-.7.9-1.6.8-2.6-.8 0-1.8.6-2.3 1.2-.5.6-1 1.6-.8 2.5.9.1 1.8-.4 2.3-1.1z"></path></svg>
            Pay
          </div>
          <div style={{ flex: 1, height: 46, borderRadius: 'var(--r-chip)', background: '#fff', color: '#3c4043', border: '1px solid #dadce0', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6, fontSize: 15, fontWeight: 600 }}>
            <span style={{ fontWeight: 800, background: 'linear-gradient(90deg,#4285F4,#EA4335,#FBBC05,#34A853)', WebkitBackgroundClip: 'text', backgroundClip: 'text', color: 'transparent' }}>G</span>
            Pay
          </div>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, margin: '16px 0 8px' }}>
          <div style={{ flex: 1, height: 1, background: 'var(--border)' }}></div>
          <span style={{ fontSize: 11.5, fontWeight: 700, color: 'var(--muted)', letterSpacing: 0.3 }}>OR PAY WITH CARD</span>
          <div style={{ flex: 1, height: 1, background: 'var(--border)' }}></div>
        </div>
        <div style={{ border: '1.5px solid var(--primary)', borderRadius: 'var(--r-card)', padding: '12px 14px', display: 'flex', alignItems: 'center', gap: 12 }}>
          <div style={{ width: 18, height: 18, borderRadius: '50%', border: '5px solid var(--primary)', background: 'var(--surface)', flexShrink: 0 }}></div>
          <div style={{ width: 38, height: 25, borderRadius: 5, background: 'var(--text)', color: 'var(--bg)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 9, fontWeight: 800, letterSpacing: 0.5 }}>VISA</div>
          <div style={{ flex: 1, fontSize: 14, fontWeight: 700 }}>···· 4242</div>
          <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--muted)' }}>Default</span>
        </div>
        <div style={{ borderRadius: 'var(--r-card)', border: '1px solid var(--border)', padding: '11px 14px', display: 'flex', alignItems: 'center', gap: 12, marginTop: 8 }}>
          <div style={{ width: 18, height: 18, borderRadius: '50%', border: '1.5px solid var(--border-strong)', flexShrink: 0 }}></div>
          <div style={{ flex: 1, fontSize: 14, fontWeight: 700, color: 'var(--muted)' }}>Use a different card…</div>
          <YIcon d="M9 5l7 7-7 7" size={13}></YIcon>
        </div>

        <YButton style={{ width: '100%', boxSizing: 'border-box', marginTop: 18 }}>Pay £60</YButton>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6, marginTop: 12, color: 'var(--muted)' }}>
          <YIcon d="M7 11V8a5 5 0 0110 0v3M6 11h12a1 1 0 011 1v8a1 1 0 01-1 1H6a1 1 0 01-1-1v-8a1 1 0 011-1z" size={12}></YIcon>
          <span style={{ fontSize: 11.5, fontWeight: 600 }}>Payments secured by Stripe · receipt by email</span>
        </div>
      </div>
    </div>
  );
}

// Success: the purchase becomes a pass, with an immediate path to Book.
function YPurchaseSuccessScreen({ vars }) {
  return (
    <YScreen vars={vars} tab="buy">
      <div style={{ padding: '120px 28px 0', textAlign: 'center' }}>
        <div style={{ width: 72, height: 72, borderRadius: '50%', background: 'var(--primary)', color: 'var(--on-primary)', display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto 18px' }}>
          <svg width="30" height="30" viewBox="0 0 12 12" fill="none">
            <path d="M2 6.5L4.8 9.2 10 3.5" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"></path>
          </svg>
        </div>
        <div style={{ fontSize: 22, fontWeight: 800, letterSpacing: -0.4 }}>You're all set</div>
        <div style={{ fontSize: 14, color: 'var(--muted)', fontWeight: 500, marginTop: 6, lineHeight: 1.5 }}>
          Your 5-Class Pack is in your wallet and ready to use.
        </div>

        <div style={{ marginTop: 24, borderRadius: 'var(--r-card)', background: 'var(--primary-soft)', padding: 18, textAlign: 'left' }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
            <div style={{ fontSize: 15.5, fontWeight: 800, letterSpacing: -0.2 }}>5-Class Pack</div>
            <YChip kind="accent">All yoga</YChip>
          </div>
          <div style={{ display: 'flex', gap: 5, margin: '14px 0 8px' }}>
            {[1, 1, 1, 1, 1].map((f, i) => (
              <div key={i} style={{ flex: 1, height: 7, borderRadius: 4, background: 'var(--primary)' }}></div>
            ))}
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12.5, fontWeight: 600, color: 'var(--muted)' }}>
            <span><b style={{ color: 'var(--text)' }}>5 of 5</b> credits</span>
            <span>Expires 9 Sep 2026</span>
          </div>
        </div>

        <YButton style={{ width: '100%', boxSizing: 'border-box', marginTop: 22 }}>Book your first class</YButton>
        <div style={{ fontSize: 13.5, fontWeight: 700, color: 'var(--muted)', marginTop: 14 }}>Done</div>
        <div style={{ fontSize: 11.5, fontWeight: 500, color: 'var(--muted)', marginTop: 22 }}>Receipt sent to maya@rowe.co · £60 on Visa ···· 4242</div>
      </div>
    </YScreen>
  );
}

Object.assign(window, { YCheckoutScreen, YPurchaseSuccessScreen });
