// yoga-app.jsx — canvas layout + Tweaks (theme-token system controls)

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "preset": "clay",
  "appearance": "light",
  "radius": 16
}/*EDITMODE-END*/;

// preset key <-> swatch trio (light variant: primary / accent / background)
const YOGA_SWATCHES = Object.fromEntries(
  Object.entries(YOGA_PRESETS).map(([k, p]) => [k, [p.light.primary, p.light.accent, p.light.background]])
);
function yogaPresetFromSwatch(arr) {
  return Object.keys(YOGA_SWATCHES).find((k) => YOGA_SWATCHES[k][0] === arr[0]) || 'clay';
}

// Phone artboard: device frame wrapping a themed screen.
// NOTE: called as a plain function (not JSX) so the element DCSection sees
// is a real DCArtboard — DCSection only recognizes direct DCArtboard children.
function yPhone(id, label, dark, screen) {
  return (
    <DCArtboard id={id} label={label} width={402} height={874}>
      <IOSDevice dark={dark}>
        <div style={{ position: 'absolute', inset: 0 }}>{screen}</div>
      </IOSDevice>
    </DCArtboard>
  );
}

// ——— Token sheet artboard: what the studio sets vs what the app derives ———
function YSwatch({ label, value, varName, border }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
      <div style={{
        height: 44, borderRadius: 10, background: value,
        border: border ? '1px solid rgba(0,0,0,0.1)' : 'none',
      }}></div>
      <div style={{ fontSize: 11.5, fontWeight: 700 }}>{label}</div>
      <div style={{ fontSize: 10, fontWeight: 500, color: '#8a8378', fontFamily: 'ui-monospace, monospace', marginTop: -3 }}>{varName}</div>
    </div>
  );
}

function YTokenBoard({ presetKey, dark, radius }) {
  const p = YOGA_PRESETS[presetKey][dark ? 'dark' : 'light'];
  const v = yogaVars(presetKey, dark, radius);
  return (
    <div style={{ ...v, background: 'var(--bg)', padding: 24, minHeight: 826, boxSizing: 'border-box' }}>
      <div style={{ fontSize: 12, fontWeight: 700, letterSpacing: 1.4, textTransform: 'uppercase', color: 'var(--muted)' }}>
        Theme · {YOGA_PRESETS[presetKey].name} · {dark ? 'Dark' : 'Light'}
      </div>
      <div style={{ fontSize: 19, fontWeight: 800, letterSpacing: -0.3, margin: '6px 0 18px' }}>Semantic tokens — studio sets six</div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12 }}>
        <YSwatch label="Primary" value={p.primary} varName="primary"></YSwatch>
        <YSwatch label="Accent" value={p.accent} varName="accent"></YSwatch>
        <YSwatch label="Background" value={p.background} varName="background" border></YSwatch>
        <YSwatch label="Surface" value={p.surface} varName="surface" border></YSwatch>
        <YSwatch label="Text" value={p.text} varName="text"></YSwatch>
        <YSwatch label="Text muted" value={p.textMuted} varName="text_muted"></YSwatch>
      </div>
      <div style={{ fontSize: 13.5, fontWeight: 700, margin: '20px 0 10px', color: 'var(--muted)' }}>Derived automatically (hover, tints, borders, contrast-safe text)</div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10 }}>
        <YSwatch label="Primary soft" value={v['--primary-soft']} varName="derived" border></YSwatch>
        <YSwatch label="Accent soft" value={v['--accent-soft']} varName="derived" border></YSwatch>
        <YSwatch label="Surface 2" value={v['--surface-2']} varName="derived" border></YSwatch>
        <YSwatch label="On primary" value={v['--on-primary']} varName="derived" border></YSwatch>
      </div>
      <div style={{ fontSize: 13.5, fontWeight: 700, margin: '20px 0 10px', color: 'var(--muted)' }}>Type — fixed scale, Hanken Grotesk (weights do the work)</div>
      <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 'var(--r-card)', padding: '14px 16px', display: 'flex', flexDirection: 'column', gap: 7 }}>
        <div style={{ fontSize: 26, fontWeight: 800, letterSpacing: -0.5 }}>Greeting / 26 · 800</div>
        <div style={{ fontSize: 17, fontWeight: 700, letterSpacing: -0.2 }}>Section head / 17 · 700</div>
        <div style={{ fontSize: 15, fontWeight: 700 }}>Row title / 15 · 700</div>
        <div style={{ fontSize: 13, fontWeight: 500, color: 'var(--muted)' }}>Meta / 13 · 500 · muted</div>
        <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--muted)' }}>CHIP / 12 · 600</div>
      </div>
      <div style={{ fontSize: 13.5, fontWeight: 700, margin: '20px 0 10px', color: 'var(--muted)' }}>Core states</div>
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
        <YButton small>Book</YButton>
        <YButton variant="soft" small>Book</YButton>
        <YButton variant="outline" small>See passes</YButton>
        <YChip kind="booked"><YCheck></YCheck>Booked</YChip>
        <YChip kind="full">Full · 3 waiting</YChip>
        <YChip kind="accent">Reformer only</YChip>
      </div>
      <div style={{ marginTop: 18, fontSize: 12, lineHeight: 1.55, color: 'var(--muted)', fontWeight: 500 }}>
        Contrast guardrail: on-primary text is computed from primary's luminance, so any palette a
        studio saves stays readable. The theme editor would warn below WCAG 4.5:1 on text/surface pairs.
      </div>
    </div>
  );
}

// Desktop artboard: manager console board
function kBoard(id, label, node) {
  return (
    <DCArtboard id={id} label={label} width={1240} height={800}>
      <div style={{ width: 1240, height: 800 }}>{node}</div>
    </DCArtboard>
  );
}

// ——— App ———
function App() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const dark = t.appearance === 'dark';
  const vars = yogaVars(t.preset, dark, t.radius);
  const presetName = YOGA_PRESETS[t.preset].name;

  return (
    <div>
      <DesignCanvas>
        <DCSection id="foundations" title="Foundations — token-based theme system" subtitle="Studio sets 6 semantic tokens; everything else is derived. Use Tweaks to switch the 4 starter presets + light/dark — every screen follows.">
          <DCArtboard id="tokens" label={'Tokens · ' + presetName} width={430} height={826}>
            <YTokenBoard presetKey={t.preset} dark={dark} radius={t.radius}></YTokenBoard>
          </DCArtboard>
          <DCPostIt id="assumptions" title="Assumptions — confirm">
            ① Spec fixes the tab bar as Book/Buy/Profile/More, but Home is a primary screen — I assumed Home is the leading 5th tab. ② Instructor photos & studio logo are initials/monogram placeholders until real assets arrive. ③ Currency shown GBP per schema default.
          </DCPostIt>
        </DCSection>

        <DCSection id="core" title="Core screens" subtitle="Home (promo banner up top, bookings lead) · Book (dotted 7-day strip, middle-density rows, full-class badge)">
          {yPhone('home', 'Home', dark, <YHomeScreen vars={vars}></YHomeScreen>)}
          {yPhone('book', 'Book · Classes', dark, <YBookScreen vars={vars}></YBookScreen>)}
        </DCSection>

        <DCSection id="onboard" title="Splash, sign-in & check-in" subtitle="Splash: standard themed design; studio may set an optional full-bleed image in Settings. Check-in: the screen behind Book's barcode button.">
          {yPhone('splash', 'Splash · standard', dark, <YSplashScreen vars={vars}></YSplashScreen>)}
          {yPhone('splash-img', 'Splash · studio image', dark, <YSplashScreen vars={vars} withImage></YSplashScreen>)}
          {yPhone('auth', 'Sign in', dark, <YAuthScreen vars={vars}></YAuthScreen>)}
          {yPhone('checkin', 'Check-in code', dark, <YCheckinScreen vars={vars}></YCheckinScreen>)}
        </DCSection>

        <DCSection id="enroll" title="Enrollments — courses & series" subtitle="One payment → booked into every session (e.g. £60 · 6 Wednesdays). No credits involved. Manager gets a week-by-week attendance grid per series.">
          {yPhone('enroll-list', 'Book · Enrollments', dark, <YEnrollListScreen vars={vars}></YEnrollListScreen>)}
          {yPhone('enroll-sheet', 'Enroll sheet · all sessions', dark, <YEnrollSheetScreen vars={vars}></YEnrollSheetScreen>)}
          {kBoard('m-series', 'Manager · series roster', <KSeriesRoster vars={vars}></KSeriesRoster>)}
        </DCSection>

        <DCSection id="buy" title="Buy — all three layouts ship" subtitle="Studio picks one in Settings → Policies · Buy screen layout. Memberships vs packs distinguished by color treatment; discipline gates as quiet chips.">
          {yPhone('buy-grid', 'A · Grid 2-up', dark, <YBuyGrid vars={vars}></YBuyGrid>)}
          {yPhone('buy-list', 'B · Full-width list', dark, <YBuyList vars={vars}></YBuyList>)}
          {yPhone('buy-grouped', 'C · Grouped sections', dark, <YBuyGrouped vars={vars}></YBuyGrouped>)}
        </DCSection>

        <DCSection id="purchase" title="Purchase flow — Stripe" subtitle="Express wallets (Apple Pay / Google Pay) first, saved card fallback · success turns the purchase into a wallet pass with a straight path to Book.">
          {yPhone('checkout', 'Checkout sheet', dark, <YCheckoutScreen vars={vars}></YCheckoutScreen>)}
          {yPhone('purchase-success', 'Purchase confirmed', dark, <YPurchaseSuccessScreen vars={vars}></YPurchaseSuccessScreen>)}
        </DCSection>

        <DCSection id="detail" title="Booking flow & profile" subtitle="Class detail sheet (eligible pass → book, +1, cancel policy) · Profile: active passes lead, history below · attendance numbers + weekly chart">
          {yPhone('class-sheet', 'Class detail · booking sheet', dark, <YClassSheetScreen vars={vars}></YClassSheetScreen>)}
          {yPhone('profile', 'Profile · Overview', dark, <YProfileScreen vars={vars}></YProfileScreen>)}
          {yPhone('wallet', 'Profile · Wallet', dark, <YWalletScreen vars={vars}></YWalletScreen>)}
        </DCSection>

        <DCSection id="empty" title="First-run & empty states" subtitle="Warm but brief. Home empty points to Book and Buy; an empty day offers the next bookable day; quiet notifications.">
          {yPhone('home-empty', 'Home · new student', dark, <YHomeEmptyScreen vars={vars}></YHomeEmptyScreen>)}
          {yPhone('book-empty', 'Book · no classes', dark, <YBookEmptyScreen vars={vars}></YBookEmptyScreen>)}
          {yPhone('notifs', 'Notifications', dark, <YNotifScreen vars={vars}></YNotifScreen>)}
          {yPhone('notifs-empty', 'Notifications · empty', dark, <YNotifEmptyScreen vars={vars}></YNotifEmptyScreen>)}
        </DCSection>

        <DCSection id="student-web" title="Student app — desktop / web" subtitle="Same tokens & components reflowed for laptop: top nav replaces tab bar, 1040px column. Book docks the booking sheet as a persistent side panel.">
          {kBoard('w-home', 'Web · Home', <WHome vars={vars}></WHome>)}
          {kBoard('w-book', 'Web · Book + docked detail', <WBook vars={vars}></WBook>)}
          {kBoard('w-buy', 'Web · Buy (grouped)', <WBuy vars={vars}></WBuy>)}
        </DCSection>

        <DCSection id="console-run" title="Manager console — run the day" subtitle="Calm chrome, spacious tables · same tokens at desktop density. Dashboard → today; Schedule → week; Roster → attendance + waitlist.">
          {kBoard('m-dash', 'Dashboard', <KDashboard vars={vars}></KDashboard>)}
          {kBoard('m-sched', 'Schedule · week', <KSchedule vars={vars}></KSchedule>)}
          {kBoard('m-sched-day', 'Schedule · day × rooms', <KScheduleDay vars={vars}></KScheduleDay>)}
          {kBoard('m-roster', 'Roster · check-in', <KRoster vars={vars}></KRoster>)}
        </DCSection>

        <DCSection id="console-build" title="Manager console — build & measure" subtitle="Product Builder: single form with live student-card preview (credit vs unlimited branches once) · Students · Reports">
          {kBoard('m-product', 'Product Builder', <KProductBuilder vars={vars}></KProductBuilder>)}
          {kBoard('m-students', 'Students', <KStudents vars={vars}></KStudents>)}
          {kBoard('m-reports', 'Reports', <KReports vars={vars}></KReports>)}
        </DCSection>

        <DCSection id="console-config" title="Manager console — Studio Settings" subtitle="The theming system's home: saveable presets, token editing with contrast guardrail, scheduled activation — plus the Buy-layout studio option.">
          {kBoard('m-settings', 'Settings · themes & policies', <KSettings vars={vars}></KSettings>)}
        </DCSection>

        <DCSection id="console-money" title="Manager dialogs — money" subtitle="Grant pass records cash/transfer/comp sales · credit adjustments require a reason and are audit-logged · void & refund is double-confirmed and warns about affected bookings.">
          {kBoard('m-grant', 'Grant a pass (cash)', <KGrantPassDialog vars={vars}></KGrantPassDialog>)}
          {kBoard('m-adjust', 'Adjust credits', <KAdjustCreditsDialog vars={vars}></KAdjustCreditsDialog>)}
          {kBoard('m-void', 'Void & refund', <KVoidRefundDialog vars={vars}></KVoidRefundDialog>)}
        </DCSection>

        <DCSection id="pos" title="Front desk POS — Stripe Terminal" subtitle="Third payment channel (card-present) alongside in-app Stripe and cash. Manager sends the sale to the reader; a desk tablet faces the customer. Needs payment_method += 'card_present' in the schema.">
          {kBoard('pos-sell', 'Sell a pass · send to reader', <KSellReaderDialog vars={vars}></KSellReaderDialog>)}
          {kBoard('pos-pay', 'Customer display · paying', <PosDisplayPay vars={vars}></PosDisplayPay>)}
          {kBoard('pos-done', 'Customer display · approved', <PosDisplayDone vars={vars}></PosDisplayDone>)}
        </DCSection>
      </DesignCanvas>

      <TweaksPanel>
        <TweakSection label={'Theme preset · ' + presetName}></TweakSection>
        <TweakColor label="Studio palette" value={YOGA_SWATCHES[t.preset]}
          options={Object.values(YOGA_SWATCHES)}
          onChange={(v) => setTweak('preset', yogaPresetFromSwatch(v))}></TweakColor>
        <TweakRadio label="Appearance" value={t.appearance} options={['light', 'dark']}
          onChange={(v) => setTweak('appearance', v)}></TweakRadio>
        <TweakSection label="Shape"></TweakSection>
        <TweakSlider label="Card radius" value={t.radius} min={10} max={24} step={1} unit="px"
          onChange={(v) => setTweak('radius', v)}></TweakSlider>
      </TweaksPanel>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App></App>);
