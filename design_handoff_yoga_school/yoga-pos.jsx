// yoga-pos.jsx — front-desk point of sale: Stripe Terminal sale dialog
// + customer-facing display (desk tablet) in payment & approved states.

// ——— Manager side: Sell a pass via card reader ———
function KSellReaderDialog({ vars }) {
  return (
    <KDialogFrame vars={vars} title="Sell a pass" sub="Take payment at the desk — card reader, cash, or record a transfer/comp." confirmLabel="Send to reader · £60">
      <KStudentLine></KStudentLine>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
        <KField label="Product"><KInput value="5-Class Pack" suffix="▾"></KInput></KField>
        <KField label="Paid via"><KSeg options={['Card · reader', 'Cash', 'Other']} value="Card · reader"></KSeg></KField>
      </div>
      {/* reader status */}
      <div style={{ marginTop: 14, border: '1px solid var(--border)', borderRadius: 12, padding: '12px 14px', display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ width: 34, height: 46, borderRadius: 7, background: 'var(--text)', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 3, flexShrink: 0 }}>
          <div style={{ width: 20, height: 13, borderRadius: 2.5, background: 'var(--bg)', opacity: 0.9 }}></div>
          <div style={{ width: 12, height: 2.5, borderRadius: 2, background: 'var(--bg)', opacity: 0.5 }}></div>
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 13.5, fontWeight: 700 }}>Front Desk Reader</div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginTop: 2 }}>
            <span style={{ width: 7, height: 7, borderRadius: '50%', background: '#2E9E5B' }}></span>
            <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--muted)' }}>Connected · WisePOS E · battery 84%</span>
          </div>
        </div>
        <span style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--primary)' }}>Change</span>
      </div>
      <div style={{ marginTop: 14, padding: '10px 13px', borderRadius: 10, background: 'var(--surface-2)', fontSize: 12, fontWeight: 600, color: 'var(--muted)', lineHeight: 1.5 }}>
        The customer display shows the order while they pay. On approval the pass is granted instantly
        and recorded as card-present revenue in Reports.
      </div>
    </KDialogFrame>
  );
}

// ——— Customer-facing display (desk tablet, landscape) ———
function PosDisplayShell({ vars, children }) {
  return (
    <div style={{
      ...vars, width: '100%', height: '100%', boxSizing: 'border-box', background: 'var(--bg)',
      fontFamily: '"Hanken Grotesk", system-ui, sans-serif', WebkitFontSmoothing: 'antialiased',
      display: 'flex', flexDirection: 'column', overflow: 'hidden', textAlign: 'left',
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '26px 36px 0' }}>
        <YLogo size={38}></YLogo>
        <span style={{ fontSize: 17, fontWeight: 800, letterSpacing: -0.2 }}>Studio 52</span>
      </div>
      <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '0 36px' }}>{children}</div>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 7, paddingBottom: 22, color: 'var(--muted)' }}>
        <YIcon d="M7 11V8a5 5 0 0110 0v3M6 11h12a1 1 0 011 1v8a1 1 0 01-1 1H6a1 1 0 01-1-1v-8a1 1 0 011-1z" size={13}></YIcon>
        <span style={{ fontSize: 12.5, fontWeight: 600 }}>Payments secured by Stripe</span>
      </div>
    </div>
  );
}

function PosDisplayPay({ vars }) {
  return (
    <PosDisplayShell vars={vars}>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 48, alignItems: 'center', width: '100%', maxWidth: 880 }}>
        <div>
          <div style={{ fontSize: 15, fontWeight: 700, color: 'var(--muted)', letterSpacing: 0.4 }}>YOUR ORDER</div>
          <div style={{ marginTop: 14, background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 'var(--r-card)', padding: '20px 22px' }}>
            <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between' }}>
              <div>
                <div style={{ fontSize: 19, fontWeight: 800, letterSpacing: -0.3 }}>5-Class Pack</div>
                <div style={{ fontSize: 13.5, fontWeight: 600, color: 'var(--muted)', marginTop: 4 }}>5 credits · all yoga · valid 90 days</div>
              </div>
              <div style={{ fontSize: 19, fontWeight: 800 }}>£60.00</div>
            </div>
            <div style={{ height: 1, background: 'var(--border)', margin: '16px 0' }}></div>
            <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between' }}>
              <span style={{ fontSize: 15, fontWeight: 700 }}>Total</span>
              <span style={{ fontSize: 30, fontWeight: 800, letterSpacing: -0.7 }}>£60.00</span>
            </div>
          </div>
        </div>
        <div style={{ textAlign: 'center' }}>
          <div style={{
            width: 130, height: 130, borderRadius: '50%', margin: '0 auto',
            background: 'var(--primary-soft)', color: 'var(--primary-strong)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>
            {/* contactless waves */}
            <svg width="56" height="56" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
              <path d="M6 8.5a9.5 9.5 0 010 7"></path>
              <path d="M9.5 7a13 13 0 010 10"></path>
              <path d="M13 5.5a16.5 16.5 0 010 13"></path>
              <path d="M16.5 4a20 20 0 010 16"></path>
            </svg>
          </div>
          <div style={{ fontSize: 24, fontWeight: 800, letterSpacing: -0.4, marginTop: 22 }}>Tap, insert or swipe</div>
          <div style={{ fontSize: 14.5, fontWeight: 500, color: 'var(--muted)', marginTop: 6 }}>Use the card reader when you're ready</div>
        </div>
      </div>
    </PosDisplayShell>
  );
}

function PosDisplayDone({ vars }) {
  return (
    <PosDisplayShell vars={vars}>
      <div style={{ textAlign: 'center' }}>
        <div style={{ width: 110, height: 110, borderRadius: '50%', margin: '0 auto', background: 'var(--primary)', color: 'var(--on-primary)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <svg width="44" height="44" viewBox="0 0 12 12" fill="none">
            <path d="M2 6.5L4.8 9.2 10 3.5" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round"></path>
          </svg>
        </div>
        <div style={{ fontSize: 28, fontWeight: 800, letterSpacing: -0.5, marginTop: 24 }}>Thank you, Jo</div>
        <div style={{ fontSize: 15, fontWeight: 500, color: 'var(--muted)', marginTop: 8, lineHeight: 1.5 }}>
          £60.00 · Visa ···· 9201 approved<br></br>Your 5-Class Pack is ready in the app — receipt by email.
        </div>
        <div style={{ display: 'inline-flex', alignItems: 'center', gap: 8, marginTop: 24, padding: '10px 18px', borderRadius: 999, background: 'var(--primary-soft)', color: 'var(--primary-strong)', fontSize: 14, fontWeight: 700 }}>
          See you in class 🙏
        </div>
      </div>
    </PosDisplayShell>
  );
}

Object.assign(window, { KSellReaderDialog, PosDisplayShell, PosDisplayPay, PosDisplayDone });
