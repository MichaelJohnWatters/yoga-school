// yoga-admin-c.jsx — manager money dialogs: grant pass (cash), adjust credits,
// void & refund. Rendered as centered modals over a dimmed Students screen.

function KDialogFrame({ vars, title, sub, children, confirmLabel, danger }) {
  return (
    <div style={{ position: 'relative', width: '100%', height: '100%' }}>
      <KStudents vars={vars}></KStudents>
      <div style={{ position: 'absolute', inset: 0, background: 'rgba(15,10,5,0.45)', backdropFilter: 'blur(2px)' }}></div>
      <div style={{
        ...vars, position: 'absolute', top: '50%', left: '50%', transform: 'translate(-50%, -50%)',
        width: 460, background: 'var(--surface)', borderRadius: 'var(--r-card)',
        boxShadow: '0 24px 80px rgba(0,0,0,0.35)', padding: 24, boxSizing: 'border-box',
        fontFamily: '"Hanken Grotesk", system-ui, sans-serif', color: 'var(--text)', textAlign: 'left',
      }}>
        <div style={{ fontSize: 18, fontWeight: 800, letterSpacing: -0.3 }}>{title}</div>
        {sub && <div style={{ fontSize: 13, fontWeight: 500, color: 'var(--muted)', marginTop: 4, lineHeight: 1.45 }}>{sub}</div>}
        <div style={{ marginTop: 18 }}>{children}</div>
        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, marginTop: 22 }}>
          <YButton variant="outline" small>Cancel</YButton>
          <YButton small style={danger ? { background: '#A33B2E', color: '#FFFFFF' } : {}}>{confirmLabel}</YButton>
        </div>
      </div>
    </div>
  );
}

function KStudentLine() {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 12px', borderRadius: 12, background: 'var(--surface-2)', marginBottom: 16 }}>
      <YAvatar name="Jo Park" size={30}></YAvatar>
      <div style={{ flex: 1 }}>
        <div style={{ fontSize: 13.5, fontWeight: 700 }}>Jo Park</div>
        <div style={{ fontSize: 11.5, fontWeight: 500, color: 'var(--muted)' }}>jo.park@mail.com · no active pass</div>
      </div>
      <span style={{ fontSize: 12, fontWeight: 700, color: 'var(--primary)' }}>Change</span>
    </div>
  );
}

// ① Grant a pass — records a cash/comp sale outside Stripe
function KGrantPassDialog({ vars }) {
  return (
    <KDialogFrame vars={vars} title="Grant a pass" sub="Records a sale made outside the app — cash at the desk, bank transfer, or a comp." confirmLabel="Grant pass · £60">
      <KStudentLine></KStudentLine>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
        <KField label="Product"><KInput value="5-Class Pack" suffix="▾"></KInput></KField>
        <KField label="Paid via"><KSeg options={['Cash', 'Card · reader', 'Transfer', 'Comp']} value="Cash"></KSeg></KField>
        <KField label="Amount received"><KInput value="60.00" suffix="GBP"></KInput></KField>
        <KField label="Starts"><KInput value="Today, 12 Jun" suffix="▾"></KInput></KField>
      </div>
      <div style={{ marginTop: 14 }}>
        <KField label="Note (visible in audit log)"><KInput value="Paid cash at the desk — morning shift"></KInput></KField>
      </div>
      <div style={{ marginTop: 14, padding: '10px 13px', borderRadius: 10, background: 'var(--surface-2)', fontSize: 12, fontWeight: 600, color: 'var(--muted)', lineHeight: 1.5 }}>
        Jo gets the pass instantly and a receipt by email. Recorded as cash revenue in Reports.
      </div>
    </KDialogFrame>
  );
}

// ② Adjust credits — goodwill / correction, reason required
function KAdjustCreditsDialog({ vars }) {
  return (
    <KDialogFrame vars={vars} title="Adjust credits" sub="Add or remove credits on an active pass. Every adjustment is logged with your name." confirmLabel="Add 1 credit">
      <KStudentLine></KStudentLine>
      <KField label="Pass">
        <div style={{ border: '1px solid var(--border-strong)', borderRadius: 12, padding: '11px 13px', display: 'flex', alignItems: 'center', gap: 10 }}>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 13.5, fontWeight: 700 }}>5-Class Pack</div>
            <div style={{ fontSize: 11.5, fontWeight: 600, color: 'var(--muted)' }}>3 of 5 credits · expires 12 Aug</div>
          </div>
          <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--muted)' }}>▾</span>
        </div>
      </KField>
      <div style={{ display: 'flex', alignItems: 'center', gap: 14, marginTop: 14 }}>
        <KField label="Adjustment">
          <div style={{ display: 'flex', alignItems: 'center', gap: 0, border: '1px solid var(--border-strong)', borderRadius: 12, overflow: 'hidden' }}>
            <div style={{ width: 42, height: 40, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 800, color: 'var(--muted)', borderRight: '1px solid var(--border)' }}>−</div>
            <div style={{ width: 56, textAlign: 'center', fontSize: 15, fontWeight: 800 }}>+1</div>
            <div style={{ width: 42, height: 40, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 800, color: 'var(--primary)', borderLeft: '1px solid var(--border)' }}>+</div>
          </div>
        </KField>
        <div style={{ flex: 1, fontSize: 12.5, fontWeight: 600, color: 'var(--muted)', paddingTop: 18 }}>3 → <b style={{ color: 'var(--text)' }}>4 of 5</b> credits</div>
      </div>
      <div style={{ marginTop: 14 }}>
        <KField label="Reason (required)"><KInput value="Class cancelled late — goodwill credit"></KInput></KField>
      </div>
    </KDialogFrame>
  );
}

// ③ Void & refund — destructive, double-confirm
function KVoidRefundDialog({ vars }) {
  return (
    <KDialogFrame vars={vars} title="Void pass & refund" sub="Ends the pass immediately. Refunds through Stripe go back to the original card." confirmLabel="Void & refund £36" danger>
      <KStudentLine></KStudentLine>
      <div style={{ border: '1px solid var(--border-strong)', borderRadius: 12, padding: '11px 13px', marginBottom: 14 }}>
        <div style={{ fontSize: 13.5, fontWeight: 700 }}>5-Class Pack · £60</div>
        <div style={{ fontSize: 11.5, fontWeight: 600, color: 'var(--muted)', marginTop: 2 }}>Bought 14 May · card ···· 4242 · 3 of 5 credits unused</div>
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
        <KField label="Refund"><KSeg options={['Unused · £36', 'Full · £60', 'None']} value="Unused · £36"></KSeg></KField>
        <KField label="Method"><KInput value="Stripe → ···· 4242" suffix="▾"></KInput></KField>
      </div>
      <div style={{ marginTop: 14 }}>
        <KField label="Reason (required)"><KInput value="Student moving away"></KInput></KField>
      </div>
      <div style={{ marginTop: 14, padding: '10px 13px', borderRadius: 10, background: 'var(--accent-soft)', fontSize: 12, fontWeight: 600, color: 'var(--text)', lineHeight: 1.5 }}>
        ⚠ Jo has 1 upcoming booking using this pass — it will be cancelled and they'll be notified.
      </div>
    </KDialogFrame>
  );
}

Object.assign(window, { KGrantPassDialog, KAdjustCreditsDialog, KVoidRefundDialog, KDialogFrame });
