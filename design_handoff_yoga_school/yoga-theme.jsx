// yoga-theme.jsx — semantic token system + studio theme presets
// Studio sets ONLY: primary, accent, background, surface, text, textMuted.
// Everything else (borders, soft tints, on-primary, states) is derived here —
// mirroring how the Flutter app would compute it from /studio/config tokens.

const YOGA_PRESETS = {
  clay: {
    name: 'Warm Clay',
    light: { primary: '#B05C3B', accent: '#C8973F', background: '#FAF5EF', surface: '#FFFFFF', text: '#2D2218', textMuted: '#8F8174' },
    dark:  { primary: '#D08054', accent: '#D9AD5F', background: '#201A15', surface: '#2B231C', text: '#F3EDE6', textMuted: '#A79784' },
  },
  slate: {
    name: 'Cool Slate',
    light: { primary: '#3A5E7E', accent: '#64998F', background: '#F4F6F8', surface: '#FFFFFF', text: '#1E2730', textMuted: '#75828E' },
    dark:  { primary: '#7BA6C9', accent: '#84BCB2', background: '#14191F', surface: '#1E262E', text: '#E9EEF2', textMuted: '#93A1AD' },
  },
  sage: {
    name: 'Earthy Sage',
    light: { primary: '#5E7153', accent: '#A9744A', background: '#F6F5EE', surface: '#FFFFFF', text: '#272B20', textMuted: '#82876F' },
    dark:  { primary: '#93AB7F', accent: '#C99A6B', background: '#191C14', surface: '#232719', text: '#EEF0E6', textMuted: '#9CA28E' },
  },
  citrus: {
    name: 'Bright Citrus',
    light: { primary: '#D94F24', accent: '#17A398', background: '#FFFBF5', surface: '#FFFFFF', text: '#25211E', textMuted: '#8B8480' },
    dark:  { primary: '#FF7A4D', accent: '#2FC4B2', background: '#1C1715', surface: '#281F1B', text: '#F7F1EC', textMuted: '#A99F99' },
  },
};

// ---- color math ----------------------------------------------------------
function yogaHexRgb(hex) {
  const h = hex.replace('#', '');
  return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
}
function yogaLum([r, g, b]) {
  const f = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
  return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
}
function yogaMix(hexA, hexB, t) {
  const a = yogaHexRgb(hexA), b = yogaHexRgb(hexB);
  const m = a.map((v, i) => Math.round(v + (b[i] - v) * t));
  return '#' + m.map((v) => v.toString(16).padStart(2, '0')).join('');
}
function yogaAlpha(hex, a) {
  const [r, g, b] = yogaHexRgb(hex);
  return `rgba(${r},${g},${b},${a})`;
}

// Contrast guardrail: pick black/white for text-on-primary automatically.
function yogaOn(hex) {
  return yogaLum(yogaHexRgb(hex)) > 0.45 ? '#1A1611' : '#FFFFFF';
}

// ---- derived token sheet -------------------------------------------------
// Returns a style object of CSS custom properties for a theme root.
function yogaVars(presetKey, dark, radius = 16) {
  const t = (YOGA_PRESETS[presetKey] || YOGA_PRESETS.clay)[dark ? 'dark' : 'light'];
  return {
    '--primary': t.primary,
    '--on-primary': yogaOn(t.primary),
    '--primary-soft': dark ? yogaAlpha(t.primary, 0.16) : yogaMix(t.primary, t.background, 0.88),
    '--primary-strong': dark ? yogaMix(t.primary, '#FFFFFF', 0.12) : yogaMix(t.primary, t.text, 0.18),
    '--accent': t.accent,
    '--on-accent': yogaOn(t.accent),
    '--accent-soft': dark ? yogaAlpha(t.accent, 0.16) : yogaMix(t.accent, t.background, 0.86),
    '--bg': t.background,
    '--surface': t.surface,
    '--surface-2': dark ? yogaMix(t.surface, '#FFFFFF', 0.05) : yogaMix(t.surface, t.text, 0.035),
    '--text': t.text,
    '--muted': t.textMuted,
    '--border': yogaAlpha(t.text, dark ? 0.14 : 0.1),
    '--border-strong': yogaAlpha(t.text, dark ? 0.24 : 0.18),
    '--shadow': dark ? '0 4px 16px rgba(0,0,0,0.4)' : '0 2px 10px ' + yogaAlpha(t.text, 0.06),
    '--r-card': radius + 'px',
    '--r-chip': '999px',
    color: t.text,
    fontFamily: '"Hanken Grotesk", system-ui, sans-serif',
  };
}

Object.assign(window, { YOGA_PRESETS, yogaVars, yogaMix, yogaAlpha, yogaOn });
