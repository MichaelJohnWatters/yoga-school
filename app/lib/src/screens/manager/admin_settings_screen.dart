// Manager Settings — Studio + Policies + Themes.
//
// Layout follows the design's two-column shape: left = Studio (read-only)
// and Policies (editable), right = Themes list + inline token editor.
// Activating a theme invalidates the bootstrap so the manager's own UI
// instantly re-themes; students see the new theme on next launch.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'manager_shell.dart';

final adminThemesProvider =
    FutureProvider.autoDispose<List<ThemeRow>>((ref) async {
  return ref.watch(apiClientProvider).adminListThemes();
});

class AdminSettingsScreen extends ConsumerStatefulWidget {
  final StudioConfig studio;
  const AdminSettingsScreen({super.key, required this.studio});

  @override
  ConsumerState<AdminSettingsScreen> createState() =>
      _AdminSettingsScreenState();
}

class _AdminSettingsScreenState extends ConsumerState<AdminSettingsScreen> {
  String? _editingThemeId;

  @override
  Widget build(BuildContext context) {
    final themes = ref.watch(adminThemesProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
      child: ListView(
        children: [
          const ManagerPageHeader(
            title: 'Settings',
            sub: 'Studio, policies, and the look of the app',
          ),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 5,
                  child: Column(
                    children: [
                      _StudioCard(studio: widget.studio),
                      const SizedBox(height: 16),
                      _PoliciesCard(studio: widget.studio),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 7,
                  child: themes.when(
                    data: (list) => _ThemesColumn(
                      themes: list,
                      editingId: _editingThemeId,
                      onPickEdit: (id) =>
                          setState(() => _editingThemeId = id),
                    ),
                    loading: () => const ManagerCard(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 40),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ),
                    error: (e, _) => ManagerCard(
                      child: Text("Can't load themes: $e"),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================== STUDIO CARD ==============================

class _StudioCard extends StatelessWidget {
  final StudioConfig studio;
  const _StudioCard({required this.studio});

  @override
  Widget build(BuildContext context) {
    return ManagerCard(
      title: 'Studio',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ReadField(label: 'DISPLAY NAME', value: studio.name),
          const SizedBox(height: 12),
          _ReadField(
            label: 'WELCOME MESSAGE',
            value: studio.welcomeMessage,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _ReadField(label: 'TIMEZONE', value: studio.timezone),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ReadField(label: 'CURRENCY', value: studio.currency),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ReadField extends StatelessWidget {
  final String label;
  final String value;
  const _ReadField({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: y.muted,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            border: Border.all(color: y.borderStrong),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            value.isEmpty ? '—' : value,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: value.isEmpty ? y.muted : y.text,
            ),
          ),
        ),
      ],
    );
  }
}

// ============================ POLICIES CARD ============================

class _PoliciesCard extends ConsumerStatefulWidget {
  final StudioConfig studio;
  const _PoliciesCard({required this.studio});

  @override
  ConsumerState<_PoliciesCard> createState() => _PoliciesCardState();
}

class _PoliciesCardState extends ConsumerState<_PoliciesCard> {
  late int _cutoffHours;
  late bool _plusOne;
  late String _buyLayout;
  late final TextEditingController _cutoffCtrl;
  bool _saving = false;

  bool get _dirty =>
      _cutoffHours != widget.studio.freeCancelCutoffHours ||
      _plusOne != widget.studio.allowStudentPlusOne ||
      _buyLayout != widget.studio.buyLayout;

  @override
  void initState() {
    super.initState();
    _cutoffHours = widget.studio.freeCancelCutoffHours;
    _plusOne = widget.studio.allowStudentPlusOne;
    _buyLayout = widget.studio.buyLayout;
    _cutoffCtrl = TextEditingController(text: '$_cutoffHours');
  }

  @override
  void dispose() {
    _cutoffCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(apiClientProvider).adminUpdateStudioConfig(
            freeCancelCutoffHours: _cutoffHours,
            allowStudentPlusOne: _plusOne,
            buyLayout: _buyLayout,
          );
      // Re-fetch studio config so the rest of the UI picks up the change.
      ref.invalidate(bootstrapProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Policies saved.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return ManagerCard(
      title: 'Policies',
      action: _dirty ? (_saving ? 'Saving…' : 'Save') : null,
      onAction: _dirty && !_saving ? _save : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'FREE CANCELLATION CUTOFF',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: y.muted,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: 150,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                border: Border.all(color: y.borderStrong),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _cutoffCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      onChanged: (v) {
                        final n = int.tryParse(v);
                        if (n != null) setState(() => _cutoffHours = n);
                      },
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: y.text,
                      ),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 4),
                      ),
                    ),
                  ),
                  Text(
                    'hours',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: y.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Students can bring a +1',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: y.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Uses a 2nd credit when booking. Manager can override.",
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: y.muted,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _plusOne,
                onChanged: (v) => setState(() => _plusOne = v),
                activeThumbColor: y.onPrimary,
                activeTrackColor: y.primary,
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            'BUY SCREEN LAYOUT',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: y.muted,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 6),
          _LayoutSegmented(
            value: _buyLayout,
            onChanged: (v) => setState(() => _buyLayout = v),
          ),
        ],
      ),
    );
  }
}

class _LayoutSegmented extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _LayoutSegmented({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    const opts = ['grid', 'list', 'grouped'];
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          for (final o in opts)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(o),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  decoration: BoxDecoration(
                    color: o == value ? y.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: o == value ? y.border : Colors.transparent,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    o[0].toUpperCase() + o.substring(1),
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: o == value ? y.text : y.muted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ============================== THEMES COLUMN ==============================

class _ThemesColumn extends ConsumerWidget {
  final List<ThemeRow> themes;
  final String? editingId;
  final ValueChanged<String?> onPickEdit;
  const _ThemesColumn({
    required this.themes,
    required this.editingId,
    required this.onPickEdit,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editing = themes.where((t) => t.id == editingId).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ManagerCard(
          title: 'Themes',
          action: '+ New theme',
          onAction: () {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('New custom theme — not yet wired in.'),
            ));
          },
          child: Column(
            children: [
              for (var i = 0; i < themes.length; i++)
                _ThemeListRow(
                  theme: themes[i],
                  isLast: i == themes.length - 1,
                  isEditing: themes[i].id == editingId,
                  onActivate: () async {
                    try {
                      await ref
                          .read(apiClientProvider)
                          .adminActivateTheme(themes[i].id);
                      ref.invalidate(adminThemesProvider);
                      ref.invalidate(bootstrapProvider);
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Activate failed: $e')),
                        );
                      }
                    }
                  },
                  onEdit: () => onPickEdit(themes[i].id),
                ),
            ],
          ),
        ),
        if (editing != null) ...[
          const SizedBox(height: 12),
          _ThemeEditorPanel(
            theme: editing,
            onClose: () => onPickEdit(null),
          ),
        ],
      ],
    );
  }
}

class _ThemeListRow extends StatelessWidget {
  final ThemeRow theme;
  final bool isLast;
  final bool isEditing;
  final VoidCallback onActivate;
  final VoidCallback onEdit;
  const _ThemeListRow({
    required this.theme,
    required this.isLast,
    required this.isEditing,
    required this.onActivate,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final t = theme.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: y.border)),
      ),
      child: Row(
        children: [
          _SwatchTrio(
            primary: _parseHex(t['primary']!),
            accent: _parseHex(t['accent']!),
            surface: _parseHex(t['surface']!),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  theme.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  theme.isPreset ? 'Preset · ${theme.mode}' : 'Custom · ${theme.mode}',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: y.muted,
                  ),
                ),
              ],
            ),
          ),
          if (_passesAA(theme)) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: y.surface2,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check, size: 11, color: y.muted),
                  const SizedBox(width: 3),
                  Text(
                    'Contrast AA',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: y.muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
          ],
          if (theme.isActive)
            const YChip(kind: YChipKind.booked, label: 'Active', leadingCheck: true)
          else
            GestureDetector(
              onTap: onActivate,
              child: Text(
                'Activate',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: y.primary,
                ),
              ),
            ),
          const SizedBox(width: 14),
          GestureDetector(
            onTap: onEdit,
            child: Icon(
              isEditing ? Icons.edit : Icons.edit_outlined,
              size: 17,
              color: isEditing ? y.primary : y.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _SwatchTrio extends StatelessWidget {
  final Color primary;
  final Color accent;
  final Color surface;
  const _SwatchTrio({
    required this.primary,
    required this.accent,
    required this.surface,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    Widget dot(Color c) => Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: c,
            shape: BoxShape.circle,
            border: Border.all(color: y.border),
          ),
        );
    return SizedBox(
      width: 48,
      height: 18,
      child: Stack(
        children: [
          Positioned(left: 0, child: dot(primary)),
          Positioned(left: 14, child: dot(accent)),
          Positioned(left: 28, child: dot(surface)),
        ],
      ),
    );
  }
}

// ============================== EDITOR PANEL ==============================

class _ThemeEditorPanel extends ConsumerStatefulWidget {
  final ThemeRow theme;
  final VoidCallback onClose;
  const _ThemeEditorPanel({required this.theme, required this.onClose});

  @override
  ConsumerState<_ThemeEditorPanel> createState() => _ThemeEditorPanelState();
}

class _ThemeEditorPanelState extends ConsumerState<_ThemeEditorPanel> {
  late Map<String, String> _tokens;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _tokens = Map.from(widget.theme.tokens);
  }

  @override
  void didUpdateWidget(_ThemeEditorPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.theme.id != widget.theme.id) {
      _tokens = Map.from(widget.theme.tokens);
    }
  }

  bool get _dirty {
    for (final k in _tokens.keys) {
      if (_tokens[k] != widget.theme.tokens[k]) return true;
    }
    return false;
  }

  Color get _primary => _parseHex(_tokens['primary']!);
  Color get _surface => _parseHex(_tokens['surface']!);
  Color get _text => _parseHex(_tokens['text']!);

  double get _textOnSurface => YogaTokens.contrastRatio(_text, _surface);
  double get _onPrimaryOnPrimary {
    // Pick black/white using the same rule as `_onColor` in YogaTokens.
    final yogaSemantic = YogaSemanticTokens.fromHexMap(_tokens);
    final derived = YogaTokens.derive(yogaSemantic, dark: widget.theme.mode == 'dark');
    return YogaTokens.contrastRatio(derived.onPrimary, _primary);
  }

  bool get _passesAA => _textOnSurface >= 4.5 && _onPrimaryOnPrimary >= 4.5;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(apiClientProvider).adminUpdateThemeTokens(
            themeId: widget.theme.id,
            tokens: _tokens,
          );
      ref.invalidate(adminThemesProvider);
      if (widget.theme.isActive) {
        ref.invalidate(bootstrapProvider);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Theme saved.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    const labels = {
      'primary': 'PRIMARY',
      'accent': 'ACCENT',
      'background': 'BACKGROUND',
      'surface': 'SURFACE',
      'text': 'TEXT',
      'textMuted': 'TEXT MUTED',
    };
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(y.radiusCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Editing · ${widget.theme.name}',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                  ),
                ),
              ),
              GestureDetector(
                onTap: widget.onClose,
                child: Icon(Icons.close, size: 18, color: y.muted),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final k in labels.keys)
                _TokenSwatch(
                  label: labels[k]!,
                  hex: _tokens[k]!,
                  onChange: (next) => setState(() => _tokens[k] = next),
                ),
            ],
          ),
          const SizedBox(height: 14),
          _ContrastBar(
            textOnSurface: _textOnSurface,
            onPrimaryOnPrimary: _onPrimaryOnPrimary,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Spacer(),
              YButton(
                label: _saving
                    ? 'Saving…'
                    : (_passesAA ? 'Save changes' : 'Fix contrast first'),
                onTap: (_dirty && _passesAA && !_saving) ? _save : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TokenSwatch extends StatefulWidget {
  final String label;
  final String hex;
  final ValueChanged<String> onChange;
  const _TokenSwatch({
    required this.label,
    required this.hex,
    required this.onChange,
  });

  @override
  State<_TokenSwatch> createState() => _TokenSwatchState();
}

class _TokenSwatchState extends State<_TokenSwatch> {
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.hex);
  }

  @override
  void didUpdateWidget(_TokenSwatch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hex != widget.hex && _ctrl.text != widget.hex) {
      _ctrl.text = widget.hex;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      width: 168,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: y.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: y.muted,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: _safeParse(widget.hex),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: y.borderStrong),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  onChanged: (v) {
                    final cleaned = _normalize(v);
                    if (cleaned != null) widget.onChange(cleaned);
                  },
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: y.text,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 2),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String? _normalize(String raw) {
    var v = raw.trim().toUpperCase();
    if (!v.startsWith('#')) v = '#$v';
    if (v.length != 7) return null;
    final hex = v.substring(1);
    if (RegExp(r'^[0-9A-F]{6}$').hasMatch(hex)) return v;
    return null;
  }

  static Color _safeParse(String hex) {
    try {
      return _parseHex(hex);
    } catch (_) {
      return const Color(0xFF000000);
    }
  }
}

class _ContrastBar extends StatelessWidget {
  final double textOnSurface;
  final double onPrimaryOnPrimary;
  const _ContrastBar({
    required this.textOnSurface,
    required this.onPrimaryOnPrimary,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final passSurface = textOnSurface >= 4.5;
    final passPrimary = onPrimaryOnPrimary >= 4.5;
    final passAll = passSurface && passPrimary;
    final fg = passAll ? y.text : const Color(0xFFA33B2E);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: y.border),
      ),
      child: RichText(
        text: TextSpan(
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: y.muted,
          ),
          children: [
            const TextSpan(text: 'Text on surface '),
            TextSpan(
              text: '${textOnSurface.toStringAsFixed(1)}:1',
              style: TextStyle(
                color: passSurface ? y.text : const Color(0xFFA33B2E),
                fontWeight: FontWeight.w800,
              ),
            ),
            const TextSpan(text: ' · Text on primary '),
            TextSpan(
              text: '${onPrimaryOnPrimary.toStringAsFixed(1)}:1',
              style: TextStyle(
                color: passPrimary ? y.text : const Color(0xFFA33B2E),
                fontWeight: FontWeight.w800,
              ),
            ),
            TextSpan(
              text: passAll
                  ? ' — both pass.'
                  : ' — below 4.5:1 minimum. Editor blocks saving.',
              style: TextStyle(color: fg, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================== HELPERS ==============================

Color _parseHex(String hex) {
  var h = hex.replaceFirst('#', '');
  if (h.length == 6) h = 'FF$h';
  return Color(int.parse(h, radix: 16));
}

bool _passesAA(ThemeRow t) {
  try {
    final text = _parseHex(t.tokens['text']!);
    final surface = _parseHex(t.tokens['surface']!);
    final ratio = YogaTokens.contrastRatio(text, surface);
    return ratio >= 4.5;
  } catch (_) {
    return false;
  }
}
