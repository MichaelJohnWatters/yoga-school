// Manager Settings — Studio + Policies + Themes.
//
// Layout follows the design's two-column shape: left = Studio (read-only)
// and Policies (editable), right = Themes list + inline token editor.
// Activating a theme invalidates the bootstrap so the manager's own UI
// instantly re-themes; students see the new theme on next launch.

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/appearance_card.dart';
import '../../widgets/polling.dart';
import '../../widgets/yoga_primitives.dart';
import 'class_dialogs.dart' show adminRoomsProvider;
import 'manager_shell.dart';
import 'media_picker.dart';

final adminThemesProvider = FutureProvider<List<ThemeRow>>((ref) async {
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
  void initState() {
    super.initState();
    // Silent refresh on visit — see admin_audit_screen for the rationale.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.invalidate(adminThemesProvider);
        ref.invalidate(_stripeCredsProvider);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final themes = ref.watch(adminThemesProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 900;
        final padH = isNarrow ? 14.0 : 30.0;
        final padV = isNarrow ? 18.0 : 26.0;

        // Each card lives in its own boundary so a build-time crash in
        // one section (e.g. a null cast on a sparse map, a missing
        // model field) shows as a labelled red tile in-place instead
        // of cascading the whole settings page into a NEEDS-LAYOUT
        // loop. Kept long-term — settings is the most-edited surface
        // and the cost is one wrapper Builder per card.
        final left = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DebugBoundary(
              tag: '_StudioCard',
              child: _StudioCard(studio: widget.studio),
            ),
            const SizedBox(height: 16),
            _DebugBoundary(
              tag: '_PoliciesCard',
              child: _PoliciesCard(studio: widget.studio),
            ),
            const SizedBox(height: 16),
            const _DebugBoundary(tag: '_StripeCard', child: _StripeCard()),
            const SizedBox(height: 16),
            const _DebugBoundary(tag: '_RoomsCard', child: _RoomsCard()),
            const SizedBox(height: 16),
            const _DebugBoundary(tag: '_AdvancedCard', child: _AdvancedCard()),
          ],
        );
        // Right column groups everything cosmetic: the theme list + editor
        // (where the splash background is picked), then Appearance and the
        // Images library.
        final themesCard = themes.when(
          data: (list) => _DebugBoundary(
            tag: '_ThemesColumn',
            child: _ThemesColumn(
              themes: list,
              editingId: _editingThemeId,
              onPickEdit: (id) => setState(() => _editingThemeId = id),
            ),
          ),
          loading: () => const ManagerCard(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
          error: (e, _) => ManagerCard(
            child: Text("Can't load themes: ${ApiError.fromAny(e).message}"),
          ),
        );
        final right = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            themesCard,
            const SizedBox(height: 16),
            const _DebugBoundary(
              tag: 'AppearanceCard',
              child: AppearanceCard(),
            ),
            const SizedBox(height: 16),
            const _DebugBoundary(
              tag: 'MediaLibrarySection',
              child: MediaLibrarySection(),
            ),
          ],
        );

        return Padding(
          padding: EdgeInsets.fromLTRB(padH, padV, padH, padV),
          child: ListView(
            children: [
              const ManagerPageHeader(
                title: 'Settings',
                sub: 'Studio, policies, and the look of the app',
              ),
              if (isNarrow) ...[
                // Stack the columns on mobile. Each card already paints its
                // own divider, so a plain Column is enough.
                left,
                const SizedBox(height: 16),
                right,
              ] else ...[
                // Desktop: side-by-side. mainAxisSize.min on each inner
                // Column is load-bearing — without it the Columns default to
                // .max and try to fill the ListView's unbounded vertical
                // axis, collapsing the whole Row to 0 height (no error
                // thrown, page just renders blank). IntrinsicHeight would
                // also fix sizing but it forces every descendant TextField
                // to provide intrinsic dimensions, which they cannot.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 5, child: left),
                    const SizedBox(width: 16),
                    Expanded(flex: 7, child: right),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Isolates a single section so its synchronous build crash renders a
/// labelled red box instead of taking the whole settings page down.
/// Doesn't catch layout-time errors — those route through the
/// dev-only `ErrorWidget.builder` set in main.dart. Worth keeping
/// long-term: settings is the densest manager screen and a single
/// null cast in one card shouldn't blank the whole page.
class _DebugBoundary extends StatelessWidget {
  final String tag;
  final Widget child;
  const _DebugBoundary({required this.tag, required this.child});

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (ctx) {
        try {
          // Builder forces a re-build inside this subtree; if the child's
          // build method throws synchronously we catch + render the
          // message in place. Layout-time crashes still go through
          // ErrorWidget.builder (set in main.dart).
          return child;
        } catch (e, st) {
          return Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0x33FF3333),
              border: Border.all(color: const Color(0xFFA33B2E)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$tag crashed:',
                  style: const TextStyle(
                    color: Color(0xFFA33B2E),
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  ApiError.fromAny(e).message,
                  style: const TextStyle(
                    color: Color(0xFFA33B2E),
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  st.toString().split('\n').take(4).join('\n'),
                  style: const TextStyle(
                    color: Color(0xFF6A2A1F),
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          );
        }
      },
    );
  }
}

// ============================== STUDIO CARD ==============================

class _StudioCard extends ConsumerStatefulWidget {
  final StudioConfig studio;
  const _StudioCard({required this.studio});

  @override
  ConsumerState<_StudioCard> createState() => _StudioCardState();
}

class _StudioCardState extends ConsumerState<_StudioCard> {
  late final TextEditingController _welcomeCtrl;
  bool _saving = false;
  String? _saved;

  @override
  void initState() {
    super.initState();
    _welcomeCtrl = TextEditingController(text: widget.studio.welcomeMessage);
  }

  @override
  void dispose() {
    _welcomeCtrl.dispose();
    super.dispose();
  }

  bool get _dirty =>
      _welcomeCtrl.text.trim() != widget.studio.welcomeMessage.trim();

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _saved = null;
    });
    try {
      await ref
          .read(apiClientProvider)
          .adminUpdateStudioConfig(welcomeMessage: _welcomeCtrl.text.trim());
      ref.invalidate(bootstrapProvider);
      if (mounted) setState(() => _saved = 'Saved');
    } catch (e) {
      if (mounted) {
        setState(() => _saved = 'Save failed: ${ApiError.fromAny(e).message}');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return ManagerCard(
      title: 'Studio',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ReadField(label: 'DISPLAY NAME', value: widget.studio.name),
          const SizedBox(height: 12),
          _SettingsField(
            label: 'WELCOME MESSAGE',
            controller: _welcomeCtrl,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          // Timezone moved to the Policies card (editable). Currency
          // stays read-only here — set by ops, not the manager.
          _ReadField(label: 'CURRENCY', value: widget.studio.currency),
          const SizedBox(height: 14),
          // Save row for the welcome message edit. Disabled until the
          // field is dirty so accidental clicks don't fire a no-op
          // PATCH. Failures surface inline rather than via snackbar so
          // the row context (which message) is obvious.
          Row(
            children: [
              if (_saved != null) ...[
                Text(
                  _saved!,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: _saved!.startsWith('Save failed')
                        ? const Color(0xFFA33B2E)
                        : y.muted,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              const Spacer(),
              YButton(
                label: _saving ? 'Saving…' : 'Save changes',
                small: true,
                onTap: (_dirty && !_saving) ? _save : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingsField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  const _SettingsField({
    required this.label,
    required this.controller,
    this.onChanged,
  });

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
          decoration: BoxDecoration(
            border: Border.all(color: y.borderStrong),
            borderRadius: BorderRadius.circular(10),
          ),
          child: TextField(
            controller: controller,
            onChanged: onChanged,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: y.text,
            ),
            decoration: const InputDecoration(
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              isDense: true,
              border: InputBorder.none,
            ),
          ),
        ),
      ],
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
  late String _timezone;
  late final TextEditingController _cutoffCtrl;
  bool _saving = false;

  bool get _dirty =>
      _cutoffHours != widget.studio.freeCancelCutoffHours ||
      _plusOne != widget.studio.allowStudentPlusOne ||
      _buyLayout != widget.studio.buyLayout ||
      _timezone != widget.studio.timezone;

  @override
  void initState() {
    super.initState();
    _cutoffHours = widget.studio.freeCancelCutoffHours;
    _plusOne = widget.studio.allowStudentPlusOne;
    _buyLayout = widget.studio.buyLayout;
    _timezone = widget.studio.timezone;
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
      await ref
          .read(apiClientProvider)
          .adminUpdateStudioConfig(
            freeCancelCutoffHours: _cutoffHours,
            allowStudentPlusOne: _plusOne,
            buyLayout: _buyLayout,
            timezone: _timezone != widget.studio.timezone ? _timezone : null,
          );
      // Re-fetch studio config so the rest of the UI picks up the change.
      ref.invalidate(bootstrapProvider);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Policies saved.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Save failed: ${ApiError.fromAny(e).message}'),
          ),
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
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
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
          _LayoutPicker(
            value: _buyLayout,
            onChanged: (v) => setState(() => _buyLayout = v),
          ),
          const SizedBox(height: 18),
          Text(
            'TIMEZONE',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: y.muted,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 6),
          _TimezoneDropdown(
            value: _timezone,
            onChanged: (v) => setState(() => _timezone = v),
          ),
          const SizedBox(height: 4),
          Text(
            'Drives day boundaries on reports + dashboard.',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: y.muted,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

/// Curated dropdown of common IANA timezones plus a custom-pinned
/// entry for the studio's current value if it isn't in the list. The
/// custom entry lets a studio in an exotic zone keep their existing
/// setting without being forced into a re-pick.
class _TimezoneDropdown extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _TimezoneDropdown({required this.value, required this.onChanged});

  /// Hand-picked common zones. Add to this list as studios elsewhere
  /// come online — the full IANA tzdata has ~400 entries which would
  /// drown the picker.
  static const _common = <String>[
    'Europe/London',
    'Europe/Dublin',
    'Europe/Paris',
    'Europe/Berlin',
    'Europe/Madrid',
    'Europe/Rome',
    'Europe/Amsterdam',
    'Europe/Stockholm',
    'Europe/Athens',
    'America/New_York',
    'America/Chicago',
    'America/Denver',
    'America/Los_Angeles',
    'America/Phoenix',
    'America/Toronto',
    'America/Vancouver',
    'America/Mexico_City',
    'America/Sao_Paulo',
    'Australia/Sydney',
    'Australia/Melbourne',
    'Australia/Perth',
    'Pacific/Auckland',
    'Asia/Tokyo',
    'Asia/Singapore',
    'Asia/Hong_Kong',
    'Asia/Dubai',
    'Asia/Kolkata',
    'Africa/Johannesburg',
    'UTC',
  ];

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final inList = _common.contains(value);
    final entries = [if (!inList && value.isNotEmpty) value, ..._common];
    return SizedBox(
      width: 280,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: y.borderStrong),
          borderRadius: BorderRadius.circular(10),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: entries.contains(value) ? value : entries.first,
            isExpanded: true,
            isDense: true,
            icon: Icon(Icons.expand_more, size: 18, color: y.muted),
            items: [
              for (final tz in entries)
                DropdownMenuItem(
                  value: tz,
                  child: Text(
                    tz,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: y.text,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      ),
    );
  }
}

/// Three tap-able preview cards — each shows a miniature of the layout
/// the student would see in Buy. The manager picks by tapping the preview,
/// not a label, so the choice is informed.
class _LayoutPicker extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _LayoutPicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    const opts = [
      (key: 'grouped', label: 'Grouped', sub: 'Hero + packs'),
      (key: 'grid', label: 'Grid', sub: '2-col tiles'),
      (key: 'list', label: 'List', sub: 'Flat rows'),
    ];
    // IntrinsicHeight + crossAxisAlignment.stretch makes all three tiles
    // line up at the tallest tile's height. Plain stretch without
    // IntrinsicHeight requires a bounded Row height — which we don't
    // have here (we sit inside ManagerCard's default-max Column inside
    // a ListView item, vertical axis is effectively unbounded), so
    // stretch flips its child's incoming constraint to infinity and the
    // whole settings page throws "BoxConstraints forces an infinite
    // height". IntrinsicHeight collapses that to a finite measurement.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < opts.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: _LayoutPreviewTile(
                kind: opts[i].key,
                label: opts[i].label,
                sub: opts[i].sub,
                selected: opts[i].key == value,
                onTap: () => onChanged(opts[i].key),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LayoutPreviewTile extends StatelessWidget {
  final String kind;
  final String label;
  final String sub;
  final bool selected;
  final VoidCallback onTap;
  const _LayoutPreviewTile({
    required this.kind,
    required this.label,
    required this.sub,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 9),
        decoration: BoxDecoration(
          color: selected ? y.surface : y.surface2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? y.primary : y.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Fixed-height preview window so the three tiles line up.
            SizedBox(
              height: 70,
              child: _LayoutMini(kind: kind, selected: selected),
            ),
            const SizedBox(height: 9),
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: y.text,
                    ),
                  ),
                ),
                if (selected)
                  Icon(Icons.check_circle, size: 14, color: y.primary),
              ],
            ),
            const SizedBox(height: 1),
            Text(
              sub,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: y.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Mini-render of a Buy layout shape. Pure decoration — uses theme tokens
/// so it tracks any active palette.
class _LayoutMini extends StatelessWidget {
  final String kind;
  final bool selected;
  const _LayoutMini({required this.kind, required this.selected});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final block = selected ? y.primary : y.muted.withValues(alpha: 0.5);
    final soft = selected ? y.primarySoft : y.surface2;
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: y.background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: y.border),
      ),
      child: switch (kind) {
        // 70px outer minus 12px padding = 58px usable.
        // Hero 20 + gap 3 + (bar 8 + gap 3) × 2 + bar 8 = 53 px.
        // I keep getting bitten here when I recount — explicit budget:
        //   20 + 3 + 8 + 3 + 8 + 3 + 8 = 53 ≤ 58.
        'grouped' => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Hero / membership block.
            Container(
              height: 20,
              decoration: BoxDecoration(
                color: block,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(height: 3),
            // Three pack rows underneath.
            _PreviewBar(color: soft, height: 8),
            const SizedBox(height: 3),
            _PreviewBar(color: soft, height: 8),
            const SizedBox(height: 3),
            _PreviewBar(color: soft, height: 8),
          ],
        ),
        'grid' => Column(
          children: [
            SizedBox(
              height: 24,
              child: Row(
                children: [
                  Expanded(child: _PreviewBox(color: block)),
                  const SizedBox(width: 4),
                  Expanded(child: _PreviewBox(color: block)),
                ],
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 24,
              child: Row(
                children: [
                  Expanded(child: _PreviewBox(color: soft)),
                  const SizedBox(width: 4),
                  Expanded(child: _PreviewBox(color: soft)),
                ],
              ),
            ),
          ],
        ),
        'list' => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PreviewBar(color: soft, height: 11),
            const SizedBox(height: 4),
            _PreviewBar(color: soft, height: 11),
            const SizedBox(height: 4),
            _PreviewBar(color: soft, height: 11),
            const SizedBox(height: 4),
            _PreviewBar(color: soft, height: 11),
          ],
        ),
        _ => const SizedBox.shrink(),
      },
    );
  }
}

class _PreviewBar extends StatelessWidget {
  final Color color;
  final double height;
  const _PreviewBar({required this.color, this.height = 9});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

class _PreviewBox extends StatelessWidget {
  final Color color;
  const _PreviewBox({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
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
    // mainAxisSize.min is load-bearing — see the long comment in
    // AdminSettingsScreen.build() on the left column. Same trap: this
    // Column lives inside Expanded → Row → ListView (unbounded vertical
    // axis), so default MainAxisSize.max blows up `hasSize` on every
    // descendant and cascades into "Unexpected null value" further up.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ManagerCard(
          title: 'Themes',
          action: '+ New theme',
          onAction: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('New custom theme — not yet wired in.'),
              ),
            );
          },
          child: Column(
            children: [
              for (var i = 0; i < themes.length; i++)
                _ThemeListRow(
                  theme: themes[i],
                  isLast: i == themes.length - 1,
                  isEditing: themes[i].id == editingId,
                  onActivate: () async {
                    // The "Set as" action targets the slot that matches
                    // this theme's mode. The server enforces the rule too
                    // (theme_mode_mismatch), so we don't need a separate
                    // affordance per slot — one button per row, labelled
                    // by mode.
                    final slot = themes[i].mode == 'dark' ? 'dark' : 'light';
                    try {
                      await ref
                          .read(apiClientProvider)
                          .adminActivateTheme(themes[i].id, slot: slot);
                      ref.invalidate(adminThemesProvider);
                      ref.invalidate(bootstrapProvider);
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Activate failed: ${ApiError.fromAny(e).message}',
                            ),
                          ),
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
          _ThemeEditorPanel(theme: editing, onClose: () => onPickEdit(null)),
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
    // Whole row opens the editor (colours + splash background). The
    // "Set as light/dark" link keeps its own tap so activating doesn't
    // also open the editor.
    return InkWell(
      onTap: onEdit,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: isLast ? null : Border(bottom: BorderSide(color: y.border)),
        ),
        child: Row(
          children: [
            _SwatchTrio(
              primary: _parseHex(t['primary']),
              accent: _parseHex(t['accent']),
              surface: _parseHex(t['surface']),
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
                    theme.isPreset
                        ? 'Preset · ${theme.mode}'
                        : 'Custom · ${theme.mode}',
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
            // Slot indicator + activate affordance. A theme can be the
            // active light slot, the active dark slot, both (theoretically —
            // gated on mode so in practice one), or neither. When it's
            // active in its own slot, show an ACTIVE chip; otherwise expose
            // a "Set as light" / "Set as dark" link styled by mode.
            if (theme.isActiveLight)
              const YChip(
                kind: YChipKind.booked,
                label: 'Active · light',
                leadingCheck: true,
              )
            else if (theme.isActiveDark)
              const YChip(
                kind: YChipKind.booked,
                label: 'Active · dark',
                leadingCheck: true,
              )
            else
              GestureDetector(
                onTap: onActivate,
                child: Text(
                  theme.mode == 'dark' ? 'Set as dark' : 'Set as light',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: y.primary,
                  ),
                ),
              ),
            const SizedBox(width: 14),
            Icon(
              isEditing ? Icons.edit : Icons.edit_outlined,
              size: 17,
              color: isEditing ? y.primary : y.muted,
            ),
          ],
        ),
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
  // '' = no splash; otherwise an asset: reference or a URL.
  late String _splash;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _tokens = Map.from(widget.theme.tokens);
    _splash = widget.theme.splashImageUrl ?? '';
  }

  @override
  void didUpdateWidget(_ThemeEditorPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.theme.id != widget.theme.id) {
      _tokens = Map.from(widget.theme.tokens);
      _splash = widget.theme.splashImageUrl ?? '';
    }
  }

  bool get _tokensDirty {
    for (final k in _tokens.keys) {
      if (_tokens[k] != widget.theme.tokens[k]) return true;
    }
    return false;
  }

  bool get _splashDirty => _splash != (widget.theme.splashImageUrl ?? '');

  bool get _dirty => _tokensDirty || _splashDirty;

  Color get _primary => _parseHex(_tokens['primary']);
  Color get _surface => _parseHex(_tokens['surface']);
  Color get _text => _parseHex(_tokens['text']);

  double get _textOnSurface => YogaTokens.contrastRatio(_text, _surface);
  double get _onPrimaryOnPrimary {
    // Pick black/white using the same rule as `_onColor` in YogaTokens.
    final yogaSemantic = YogaSemanticTokens.fromHexMap(_tokens);
    final derived = YogaTokens.derive(
      yogaSemantic,
      dark: widget.theme.mode == 'dark',
    );
    return YogaTokens.contrastRatio(derived.onPrimary, _primary);
  }

  bool get _passesAA => _textOnSurface >= 4.5 && _onPrimaryOnPrimary >= 4.5;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref
          .read(apiClientProvider)
          .adminUpdateTheme(
            themeId: widget.theme.id,
            tokens: _tokensDirty ? _tokens : null,
            splashImageUrl: _splashDirty ? _splash : null,
          );
      ref.invalidate(adminThemesProvider);
      // If this theme is in either active slot, the bootstrap's cached
      // tokens just went stale — re-fetch so the live MaterialApp picks
      // up the new colours on the next frame.
      if (widget.theme.isActiveLight || widget.theme.isActiveDark) {
        ref.invalidate(bootstrapProvider);
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Theme saved.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Save failed: ${ApiError.fromAny(e).message}'),
          ),
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
                  hex: _tokens[k] ?? '',
                  onChange: (next) => setState(() => _tokens[k] = next),
                ),
            ],
          ),
          const SizedBox(height: 14),
          _ContrastBar(
            textOnSurface: _textOnSurface,
            onPrimaryOnPrimary: _onPrimaryOnPrimary,
          ),
          const SizedBox(height: 18),
          _SplashPicker(
            value: _splash,
            onChanged: (next) => setState(() => _splash = next),
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

/// Built-in splash backgrounds a studio can pick without hosting an image.
/// The value is an `asset:` reference resolved by [studioImageProvider] on
/// the splash screen; the asset path itself (sans scheme) renders the
/// thumbnail here. Add more rows as we bundle more photos.
const _splashPresets = <({String label, String value})>[
  (label: 'Studio class', value: 'asset:assets/splash/studio_class.webp'),
];

/// Splash-background chooser for the theme editor: None, the bundled preset
/// thumbnails, and a custom-URL escape hatch. Emits the chosen value ('' for
/// none, an `asset:` reference, or a URL) via [onChanged].
class _SplashPicker extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _SplashPicker({required this.value, required this.onChanged});

  @override
  State<_SplashPicker> createState() => _SplashPickerState();
}

class _SplashPickerState extends State<_SplashPicker> {
  late final TextEditingController _url;

  bool get _isPreset => _splashPresets.any((p) => p.value == widget.value);
  bool get _isCustomUrl =>
      widget.value.isNotEmpty &&
      !_isPreset &&
      !widget.value.startsWith('asset:');

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: _isCustomUrl ? widget.value : '');
  }

  @override
  void didUpdateWidget(_SplashPicker old) {
    super.didUpdateWidget(old);
    // Keep the URL field in sync when a preset/None tile clears it.
    if (!_isCustomUrl && _url.text.isNotEmpty) _url.clear();
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _openLibrary() async {
    final url = await showMediaPicker(context);
    if (url != null && url.isNotEmpty) widget.onChanged(url);
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    Widget tile({
      required bool selected,
      required VoidCallback onTap,
      required Widget preview,
      required String label,
    }) {
      return GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 104,
              height: 64,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: y.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected ? y.primary : y.border,
                  width: selected ? 2 : 1,
                ),
              ),
              child: preview,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: selected ? y.text : y.muted,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'SPLASH BACKGROUND',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: y.muted,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            tile(
              selected: widget.value.isEmpty,
              onTap: () => widget.onChanged(''),
              label: 'None',
              preview: Center(
                child: Icon(Icons.block, size: 20, color: y.muted),
              ),
            ),
            for (final p in _splashPresets)
              tile(
                selected: widget.value == p.value,
                onTap: () => widget.onChanged(p.value),
                label: p.label,
                preview: Image.asset(
                  p.value.substring('asset:'.length),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Center(
                    child: Icon(Icons.image, size: 18, color: y.muted),
                  ),
                ),
              ),
            // A custom upload/library URL shows as its own selected tile so
            // the manager sees the chosen image, not just a long URL string.
            if (_isCustomUrl)
              tile(
                selected: true,
                onTap: _openLibrary,
                label: 'Selected',
                preview: Image.network(
                  widget.value,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Center(
                    child: Icon(Icons.broken_image, size: 18, color: y.muted),
                  ),
                ),
              ),
            // Opens the manager media library (upload new + reuse existing).
            tile(
              selected: false,
              onTap: _openLibrary,
              label: 'Library',
              preview: Center(
                child: Icon(
                  Icons.photo_library_outlined,
                  size: 20,
                  color: y.primary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _url,
          style: TextStyle(fontSize: 12.5, color: y.text),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Or paste an image URL…',
            hintStyle: TextStyle(color: y.muted, fontSize: 12.5),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            filled: true,
            fillColor: y.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: y.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: y.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: y.primary),
            ),
          ),
          onChanged: (v) => widget.onChanged(v.trim()),
        ),
      ],
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

// Tolerant of null/empty/malformed input — returns transparent so a theme
// with a missing or junk token renders blank instead of crashing the whole
// settings screen with a layout cascade. The token shape comes from a JSON
// blob in SQLite, so we can't assume every key is present.
Color _parseHex(String? hex) {
  if (hex == null || hex.isEmpty) return const Color(0x00000000);
  var h = hex.replaceFirst('#', '');
  if (h.length == 6) h = 'FF$h';
  try {
    return Color(int.parse(h, radix: 16));
  } on FormatException {
    return const Color(0x00000000);
  }
}

bool _passesAA(ThemeRow t) {
  try {
    final text = _parseHex(t.tokens['text']);
    final surface = _parseHex(t.tokens['surface']);
    final ratio = YogaTokens.contrastRatio(text, surface);
    return ratio >= 4.5;
  } catch (_) {
    return false;
  }
}

// ============================== STRIPE CARD ==============================

final _stripeCredsProvider = FutureProvider<StripeCredentialsView>(
  (ref) => ref.watch(apiClientProvider).adminStripeCredentials(),
);

/// Manager-facing Stripe credentials panel. Three pillars:
///   1) Mode toggle (test / live)
///   2) Publishable key (plain text — meant for client-side use anyway)
///   3) Secret key + webhook secret (encrypted server-side; masked here)
///
/// Secret rows show "•••• abcd" once saved, with a "Replace" button that
/// reveals an entry field. Sending a blank string clears the value
/// server-side; sending nothing (the default state) leaves it alone.
class _StripeCard extends ConsumerStatefulWidget {
  const _StripeCard();

  @override
  ConsumerState<_StripeCard> createState() => _StripeCardState();
}

class _StripeCardState extends ConsumerState<_StripeCard> {
  @override
  Widget build(BuildContext context) {
    final creds = ref.watch(_stripeCredsProvider);
    return ManagerCard(
      title: 'Stripe credentials',
      child: creds.when(
        data: (c) => _StripeForm(initial: c),
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
        error: (e, _) => Text(
          "Can't load Stripe settings: ${ApiError.fromAny(e).message}",
          style: TextStyle(color: context.yoga.muted),
        ),
      ),
    );
  }
}

class _StripeForm extends ConsumerStatefulWidget {
  final StripeCredentialsView initial;
  const _StripeForm({required this.initial});

  @override
  ConsumerState<_StripeForm> createState() => _StripeFormState();
}

class _StripeFormState extends ConsumerState<_StripeForm> {
  late String _mode;
  late final TextEditingController _accountIdCtrl;
  late final TextEditingController _pubCtrl;
  final _secretCtrl = TextEditingController();
  final _webhookCtrl = TextEditingController();
  bool _replaceSecret = false;
  bool _replaceWebhook = false;
  bool _saving = false;
  String? _error;
  String? _info;

  @override
  void initState() {
    super.initState();
    _mode = widget.initial.mode;
    _accountIdCtrl = TextEditingController(
      text: widget.initial.accountId ?? '',
    );
    _pubCtrl = TextEditingController(text: widget.initial.publishableKey ?? '');
  }

  @override
  void dispose() {
    _accountIdCtrl.dispose();
    _pubCtrl.dispose();
    _secretCtrl.dispose();
    _webhookCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
      _info = null;
    });
    try {
      final patch = <String, dynamic>{
        'mode': _mode,
        'account_id': _accountIdCtrl.text.trim(),
        'publishable_key': _pubCtrl.text.trim(),
      };
      if (_replaceSecret) {
        patch['secret_key'] = _secretCtrl.text.trim();
      }
      if (_replaceWebhook) {
        patch['webhook_secret'] = _webhookCtrl.text.trim();
      }
      await ref.read(apiClientProvider).adminUpdateStripeCredentials(patch);
      ref.invalidate(_stripeCredsProvider);
      if (mounted) {
        setState(() {
          _secretCtrl.clear();
          _webhookCtrl.clear();
          _replaceSecret = false;
          _replaceWebhook = false;
          _info = 'Saved.';
        });
      }
    } catch (e) {
      setState(() => _error = ApiError.fromAny(e).message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final c = widget.initial;
    final encOff = !c.encryptionConfigured;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (encOff)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: y.accentSoft,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'Encryption is not configured on this server (STRIPE_KEY_ENC_MASTER is unset). '
              'You can save the publishable key + account id, but secret-key fields are disabled. '
              'Ask ops to set the env var before going live.',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: y.text,
                height: 1.4,
              ),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: _StripeLabeledField(
                label: 'MODE',
                child: _ModeRadio(
                  value: _mode,
                  onChanged: (v) => setState(() => _mode = v),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StripeLabeledField(
                label: 'ACCOUNT ID',
                child: _StripeTextInput(controller: _accountIdCtrl),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _StripeLabeledField(
          label: 'PUBLISHABLE KEY (pk_…)',
          child: _StripeTextInput(controller: _pubCtrl),
        ),
        const SizedBox(height: 12),
        _SecretRow(
          label: 'SECRET KEY (sk_…)',
          last4: c.secretKeyLast4,
          isSet: c.secretKeySet,
          editing: _replaceSecret,
          disabled: encOff,
          controller: _secretCtrl,
          onReplace: () => setState(() => _replaceSecret = true),
          onCancel: () => setState(() {
            _replaceSecret = false;
            _secretCtrl.clear();
          }),
        ),
        const SizedBox(height: 12),
        _SecretRow(
          label: 'WEBHOOK SECRET (whsec_…)',
          last4: c.webhookSecretLast4,
          isSet: c.webhookSecretSet,
          editing: _replaceWebhook,
          disabled: encOff,
          controller: _webhookCtrl,
          onReplace: () => setState(() => _replaceWebhook = true),
          onCancel: () => setState(() {
            _replaceWebhook = false;
            _webhookCtrl.clear();
          }),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(
            _error!,
            style: const TextStyle(color: Color(0xFFA33B2E), fontSize: 12.5),
          ),
        ],
        if (_info != null) ...[
          const SizedBox(height: 10),
          Text(
            _info!,
            style: TextStyle(
              color: y.primary,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerRight,
          child: YButton(
            label: _saving ? 'Saving…' : 'Save Stripe settings',
            small: true,
            onTap: _saving ? null : _save,
          ),
        ),
      ],
    );
  }
}

class _ModeRadio extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _ModeRadio({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    Widget pill(String mode, String label) {
      final on = value == mode;
      return Expanded(
        child: GestureDetector(
          onTap: () => onChanged(mode),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: on ? y.text : y.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: on ? Colors.transparent : y.border),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: on ? y.background : y.muted,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        pill('test', 'TEST'),
        const SizedBox(width: 6),
        pill('live', 'LIVE'),
      ],
    );
  }
}

class _StripeLabeledField extends StatelessWidget {
  final String label;
  final Widget child;
  const _StripeLabeledField({required this.label, required this.child});

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
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

class _StripeTextInput extends StatelessWidget {
  final TextEditingController controller;
  final String? hint;
  final bool obscure;
  const _StripeTextInput({
    required this.controller,
    this.hint,
    this.obscure = false,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: y.borderStrong),
        borderRadius: BorderRadius.circular(10),
      ),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        style: TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          color: y.text,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 5),
          hintText: hint,
        ),
      ),
    );
  }
}

class _SecretRow extends StatelessWidget {
  final String label;
  final String? last4;
  final bool isSet;
  final bool editing;
  final bool disabled;
  final TextEditingController controller;
  final VoidCallback onReplace;
  final VoidCallback onCancel;
  const _SecretRow({
    required this.label,
    required this.last4,
    required this.isSet,
    required this.editing,
    required this.disabled,
    required this.controller,
    required this.onReplace,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    if (editing) {
      return _StripeLabeledField(
        label: label,
        child: Row(
          children: [
            Expanded(
              child: _StripeTextInput(
                controller: controller,
                obscure: true,
                hint: 'Paste new value — sending blank clears it',
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onCancel,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Text(
                  'Cancel',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: y.muted,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return _StripeLabeledField(
      label: label,
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: y.surface2,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: y.border),
              ),
              child: Text(
                isSet ? '•••• ${last4 ?? '????'}' : 'Not set',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: isSet ? y.text : y.muted,
                  letterSpacing: 1.0,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          YButton(
            label: isSet ? 'Replace' : 'Set',
            variant: YButtonVariant.soft,
            small: true,
            onTap: disabled ? null : onReplace,
          ),
        ],
      ),
    );
  }
}

// Rooms — manager-facing CRUD for studio rooms. Reads + writes are
// gated server-side (manager group); the UI here is the only path into
// those mutators.
//
// Renames are inline: tap the name, edit, blur/Enter commits. Adding a
// room reveals an inline name field at the bottom. Deletes refuse with
// a clear message when the room is still attached to a class / rule /
// template — the server returns code `room_in_use`, surfaced as
// [RoomInUseException] and shown verbatim in a snackbar.
class _RoomsCard extends ConsumerWidget {
  const _RoomsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final rooms = ref.watch(adminRoomsProvider);
    return ManagerCard(
      title: 'Rooms',
      child: rooms.when(
        data: (list) => _RoomsBody(rooms: list),
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
        error: (e, _) => Text(
          "Can't load rooms: ${ApiError.fromAny(e).message}",
          style: TextStyle(color: y.muted),
        ),
      ),
    );
  }
}

class _RoomsBody extends ConsumerStatefulWidget {
  final List<AdminRoom> rooms;
  const _RoomsBody({required this.rooms});

  @override
  ConsumerState<_RoomsBody> createState() => _RoomsBodyState();
}

class _RoomsBodyState extends ConsumerState<_RoomsBody> {
  // When non-null, the inline "+ Add room" input is shown and gets
  // focus. Save / cancel hide it again.
  bool _adding = false;
  final TextEditingController _newCtrl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _newCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _newCtrl.text.trim();
    if (name.isEmpty) return;
    setState(() => _saving = true);
    try {
      await ref.read(apiClientProvider).adminCreateRoom(name);
      _newCtrl.clear();
      if (mounted) setState(() => _adding = false);
      ref.invalidate(adminRoomsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_errorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.rooms.isEmpty && !_adding)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              "No rooms yet. Add the first one — every class needs a "
              "room to live in.",
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: y.muted,
                height: 1.45,
              ),
            ),
          ),
        for (var i = 0; i < widget.rooms.length; i++)
          _RoomRow(
            room: widget.rooms[i],
            isLast: i == widget.rooms.length - 1 && !_adding,
          ),
        if (_adding) ...[
          if (widget.rooms.isNotEmpty) Container(height: 1, color: y.border),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newCtrl,
                    autofocus: true,
                    onSubmitted: (_) => _saving ? null : _create(),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Room name',
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: y.border),
                      ),
                    ),
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: y.text,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                YButton(
                  label: _saving ? 'Saving…' : 'Save',
                  small: true,
                  onTap: _saving ? null : _create,
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: _saving
                      ? null
                      : () {
                          setState(() {
                            _adding = false;
                            _newCtrl.clear();
                          });
                        },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      'Cancel',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: y.muted,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: GestureDetector(
            onTap: _adding ? null : () => setState(() => _adding = true),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                _adding ? '' : '+ Add room',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: y.primary,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Curated palette for the rooms colour picker. Picked for legibility
/// as a 4px stripe + an 18% background wash on class cards in both
/// light and dark themes — not neon, not muddy. Ordered roughly by
/// hue so the picker reads as a spectrum (warm → cool → neutral)
/// rather than a random scatter. The custom hex field below the
/// presets stays as an escape hatch for studios that need a brand
/// match outside this set.
const List<String> _kRoomColorPresets = [
  // Warm — reds, pinks, oranges, ambers.
  '#e27d60', // coral
  '#d97757', // terracotta
  '#e8a87c', // peach
  '#c25a5a', // brick
  '#e0a3a3', // blush
  '#c38d9e', // rose
  '#ab83a1', // plum
  '#8b7baa', // periwinkle
  // Yellows + earths.
  '#e8b04a', // amber
  '#d4a574', // sand
  '#b5651d', // clay
  '#c4a85e', // olive
  // Cool — greens.
  '#85dcb0', // mint
  '#41b3a3', // teal
  '#8ba888', // sage
  '#5b8c5a', // moss
  // Cool — blues + neutral.
  '#5b8fa8', // sky
  '#6b7785', // slate
];

/// Lenient hex parser used by the swatch + preview. Returns null when
/// [raw] isn't a `#rrggbb` string so callers can fall back to the theme
/// default rather than crash on a malformed value (the server validates,
/// but defence in depth is cheap here).
Color? _parseRoomColor(String? raw) {
  if (raw == null) return null;
  final s = raw.trim().toLowerCase();
  if (!RegExp(r'^#[0-9a-f]{6}$').hasMatch(s)) return null;
  return Color(int.parse(s.substring(1), radix: 16) | 0xFF000000);
}

class _RoomRow extends ConsumerStatefulWidget {
  final AdminRoom room;
  final bool isLast;
  const _RoomRow({required this.room, required this.isLast});

  @override
  ConsumerState<_RoomRow> createState() => _RoomRowState();
}

class _RoomRowState extends ConsumerState<_RoomRow> {
  bool _editing = false;
  late TextEditingController _ctrl;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.room.name);
  }

  @override
  void didUpdateWidget(_RoomRow old) {
    super.didUpdateWidget(old);
    // Server-driven rename — keep the field in sync when not editing.
    if (!_editing && old.room.name != widget.room.name) {
      _ctrl.text = widget.room.name;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _rename() async {
    final next = _ctrl.text.trim();
    if (next == widget.room.name) {
      setState(() => _editing = false);
      return;
    }
    if (next.isEmpty) {
      _ctrl.text = widget.room.name;
      setState(() => _editing = false);
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(apiClientProvider).adminRenameRoom(widget.room.id, next);
      ref.invalidate(adminRoomsProvider);
      if (mounted) setState(() => _editing = false);
    } catch (e) {
      _ctrl.text = widget.room.name;
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_errorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickColor() async {
    final picked = await showDialog<_RoomColorChoice>(
      context: context,
      builder: (_) => _RoomColorPickerDialog(initial: widget.room.color),
    );
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    try {
      // Empty string is the "clear" signal — distinct from omitting the
      // field, which would leave the colour alone server-side.
      await ref
          .read(apiClientProvider)
          .adminUpdateRoom(widget.room.id, color: picked.color ?? '');
      ref.invalidate(adminRoomsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_errorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete room?'),
        content: Text("Remove '${widget.room.name}'? This can't be undone."),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(apiClientProvider).adminDeleteRoom(widget.room.id);
      ref.invalidate(adminRoomsProvider);
    } on RoomInUseException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_errorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final swatchColor = _parseRoomColor(widget.room.color);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: widget.isLast
            ? null
            : Border(bottom: BorderSide(color: y.border)),
      ),
      child: Row(
        children: [
          // Swatch doubles as both the room indicator AND the "set
          // colour" affordance — tap to open the picker. Empty rooms
          // get an outlined circle with an eyedropper icon + a primary
          // tint on the icon so it reads as "tap to set", not decor.
          // Material + InkWell so the hover/splash overlay actually
          // paints on web/desktop (same fix as YButton's hover).
          Tooltip(
            message: swatchColor != null
                ? 'Change room colour'
                : 'Pick a room colour',
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              child: InkWell(
                onTap: _busy ? null : _pickColor,
                customBorder: const CircleBorder(),
                hoverColor: y.primary.withValues(alpha: 0.08),
                splashColor: y.primary.withValues(alpha: 0.16),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: swatchColor ?? Colors.transparent,
                    shape: BoxShape.circle,
                    border: Border.all(
                      // Primary-tinted border on the empty state so the
                      // chip pulls a bit of attention. Once a colour is
                      // set, the border drops back to neutral so the
                      // colour itself does the talking.
                      color: swatchColor == null
                          ? y.primary.withValues(alpha: 0.55)
                          : y.border,
                      width: swatchColor == null ? 1.4 : 1.2,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: swatchColor == null
                      ? Icon(Icons.colorize, size: 14, color: y.primary)
                      : null,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _editing
                ? TextField(
                    controller: _ctrl,
                    autofocus: true,
                    onSubmitted: (_) => _rename(),
                    onTapOutside: (_) => _rename(),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: y.border),
                      ),
                    ),
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: y.text,
                    ),
                  )
                : GestureDetector(
                    onTap: _busy ? null : () => setState(() => _editing = true),
                    child: Text(
                      widget.room.name,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: y.text,
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: 8),
          if (_busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else ...[
            if (!_editing)
              GestureDetector(
                onTap: () => setState(() => _editing = true),
                child: Icon(Icons.edit_outlined, size: 18, color: y.muted),
              ),
            const SizedBox(width: 14),
            GestureDetector(
              onTap: _delete,
              child: Icon(Icons.delete_outline, size: 18, color: y.muted),
            ),
          ],
        ],
      ),
    );
  }
}

/// Dialog return type. `color` is the `#rrggbb` to save (or null to
/// clear). Distinguishes "no result" (dialog dismissed) from "save the
/// cleared state" (Save returned with color = null) so the caller can
/// no-op on the dismiss path without an explicit boolean.
class _RoomColorChoice {
  final String? color;
  const _RoomColorChoice(this.color);
}

class _RoomColorPickerDialog extends StatefulWidget {
  final String? initial;
  const _RoomColorPickerDialog({required this.initial});

  @override
  State<_RoomColorPickerDialog> createState() => _RoomColorPickerDialogState();
}

class _RoomColorPickerDialogState extends State<_RoomColorPickerDialog> {
  late TextEditingController _customCtrl;
  String? _customError;

  @override
  void initState() {
    super.initState();
    final init = widget.initial?.toLowerCase();
    // Pre-fill the custom field with the current value when it's not in
    // the preset list — saves the manager from having to retype it just
    // to nudge a hue.
    _customCtrl = TextEditingController(
      text: init != null && !_kRoomColorPresets.contains(init) ? init : '',
    );
  }

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  /// Pop with the given choice, closing the dialog. Centralises the
  /// "tap = commit" behaviour so every entry point (preset, custom hex,
  /// Clear) goes through the same single exit.
  void _commit(String? color) {
    Navigator.of(context).pop(_RoomColorChoice(color));
  }

  /// Validate + commit the custom hex on Enter / blur. Empty input is
  /// ignored (doesn't accidentally clear the colour — that's what the
  /// explicit Clear action is for).
  void _commitCustom() {
    final raw = _customCtrl.text.trim().toLowerCase();
    if (raw.isEmpty) return;
    if (!RegExp(r'^#[0-9a-f]{6}$').hasMatch(raw)) {
      setState(() => _customError = 'Use a hex value like #a3b7c1.');
      return;
    }
    _commit(raw);
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final initial = widget.initial?.toLowerCase();
    return AlertDialog(
      backgroundColor: y.surface,
      title: const Text('Room colour'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tap a preset to apply it. Or type a custom hex and press '
              'Enter. Either commits straight away — Cancel keeps the '
              'current colour.',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: y.muted,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final hex in _kRoomColorPresets)
                  _PresetSwatch(
                    hex: hex,
                    // Highlight the currently-saved colour so it's
                    // obvious which preset matches the room's existing
                    // value. No selection-then-confirm dance — the
                    // mark is just a "you're already on this" hint.
                    selected: initial == hex,
                    onTap: () => _commit(hex),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              'CUSTOM',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
                color: y.muted,
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _customCtrl,
              onChanged: (_) {
                if (_customError != null) {
                  setState(() => _customError = null);
                }
              },
              onSubmitted: (_) => _commitCustom(),
              decoration: InputDecoration(
                isDense: true,
                hintText: '#a3b7c1  (press Enter)',
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: _customError == null ? y.border : Colors.redAccent,
                  ),
                ),
              ),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
                color: y.text,
              ),
            ),
            if (_customError != null) ...[
              const SizedBox(height: 6),
              Text(
                _customError!,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.redAccent,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        // Removes the current colour entirely — equivalent to "no tint".
        TextButton(
          onPressed: () => _commit(null),
          child: Text('Remove colour', style: TextStyle(color: y.muted)),
        ),
        const Spacer(),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _PresetSwatch extends StatelessWidget {
  final String hex;
  final bool selected;
  final VoidCallback onTap;
  const _PresetSwatch({
    required this.hex,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final c = _parseRoomColor(hex) ?? y.surface2;
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? y.text : y.border,
            width: selected ? 2.2 : 1.0,
          ),
        ),
        alignment: Alignment.center,
        child: selected
            ? const Icon(Icons.check, size: 16, color: Colors.white)
            : null,
      ),
    );
  }
}

/// Normalise any thrown error to a single line for snackbar display.
/// DioException wraps a typed payload; for everything else fall back to
/// the default toString.
String _errorMessage(Object e) {
  if (e is RoomInUseException) return e.message;
  if (e is DioException) {
    final data = e.response?.data;
    if (data is Map && data['error'] is String) {
      return data['error'] as String;
    }
    return e.message ?? 'Network error.';
  }
  return ApiError.fromAny(e).message;
}

// Advanced — session-scoped knobs that don't fit the studio/policies
// model. Right now: how aggressively each page re-fetches in the
// background. Persists in-memory only; resets on app reload.
//
// Two layers of control:
//   * "Default" sets the cadence for every surface that hasn't been
//     overridden — the single most common knob to reach for.
//   * Each surface listed below can override the default with its own
//     pill (Default / Off / Slow / Normal / Fast). The effective
//     interval is shown in muted text so the manager can tell what they
//     just picked.
class _AdvancedCard extends ConsumerWidget {
  const _AdvancedCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final prefs = ref.watch(pollingPrefsProvider);
    return ManagerCard(
      title: 'Advanced',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Background refresh',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: y.text,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "How often each page silently re-fetches while open. Pages "
            "always refresh once when you arrive — this only controls "
            "what happens after.",
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              fontWeight: FontWeight.w500,
              color: y.muted,
            ),
          ),
          const SizedBox(height: 14),
          _GlobalDefaultBlock(
            current: prefs.global,
            onPick: (s) => ref.read(pollingPrefsProvider.notifier).setGlobal(s),
          ),
          const SizedBox(height: 18),
          Container(height: 1, color: y.border),
          const SizedBox(height: 14),
          Text(
            'Per-page overrides',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: y.text,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "Pick Default to follow the global setting above, or set a "
            "specific cadence for any page.",
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              fontWeight: FontWeight.w500,
              color: y.muted,
            ),
          ),
          const SizedBox(height: 8),
          for (final s in PollingSurface.values)
            _SurfaceOverrideRow(surface: s, prefs: prefs),
        ],
      ),
    );
  }
}

class _GlobalDefaultBlock extends StatelessWidget {
  final PollingSpeed current;
  final ValueChanged<PollingSpeed> onPick;
  const _GlobalDefaultBlock({required this.current, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Default for all pages',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: y.text,
          ),
        ),
        const SizedBox(height: 8),
        _SpeedPillRow(
          options: PollingSpeed.values,
          isSelected: (s) => s == current,
          labelFor: PollingPrefs.speedLabel,
          onPick: onPick,
        ),
        const SizedBox(height: 8),
        Text(
          _hint(current),
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: y.muted,
          ),
        ),
      ],
    );
  }

  static String _hint(PollingSpeed s) => switch (s) {
    PollingSpeed.off =>
      "Off · pages only refresh when you open them or after an action.",
    PollingSpeed.slow =>
      "Slow · half the Normal rate. Good on metered connections.",
    PollingSpeed.normal =>
      "Normal · the default cadence (dashboard ~45s, schedule ~60s).",
    PollingSpeed.fast =>
      "Fast · double the Normal rate. Useful during busy class swaps.",
  };
}

/// One row per [PollingSurface]: label + override pills + the resolved
/// interval text on the right. Supports a "Custom" mode that exposes a
/// seconds field — input is validated (positive integer only) and rolled
/// back if the user clears the field.
///
/// Stateful because the seconds input is a TextField with its own
/// controller; the rest of the row stays driven by [pollingPrefsProvider].
class _SurfaceOverrideRow extends ConsumerStatefulWidget {
  final PollingSurface surface;
  final PollingPrefs prefs;
  const _SurfaceOverrideRow({required this.surface, required this.prefs});

  @override
  ConsumerState<_SurfaceOverrideRow> createState() =>
      _SurfaceOverrideRowState();
}

class _SurfaceOverrideRowState extends ConsumerState<_SurfaceOverrideRow> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: _initialSeconds().toString());
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  int _initialSeconds() {
    final ov = widget.prefs.overrides[widget.surface];
    if (ov is CustomInterval) return ov.interval.inSeconds;
    // Pre-fill with the base so picking Custom doesn't drop us at 0.
    return widget.surface.base.inSeconds;
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final prefs = widget.prefs;
    final surface = widget.surface;
    final ov = prefs.overrides[surface];
    final interval = prefs.intervalFor(surface);
    final overriding = prefs.hasOverride(surface);
    final isCustom = ov is CustomInterval;
    // The pill model: Default (no override) + four speeds + Custom. We
    // keep the active selection visible by checking each pill against the
    // current override shape.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      surface.label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: y.text,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      surface.description,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: y.muted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                formatPollInterval(interval),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: overriding ? y.primaryStrong : y.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _SurfacePillRow(
            isDefault: !overriding,
            isCustom: isCustom,
            speed: ov is SpeedOverride ? ov.speed : null,
            onDefault: () => _setOverride(null),
            onSpeed: (s) => _setOverride(SpeedOverride(s)),
            onCustom: () {
              // Adopt the current effective interval as the starting value
              // so picking Custom doesn't surprise the manager with 0s.
              final start = interval?.inSeconds ?? surface.base.inSeconds;
              _ctrl.text = start.toString();
              _setOverride(CustomInterval(Duration(seconds: start)));
            },
          ),
          if (isCustom) ...[
            const SizedBox(height: 10),
            _CustomSecondsField(
              controller: _ctrl,
              onCommit: (seconds) {
                // Validation: positive int only. Anything else snaps the
                // input back to the last accepted value so the displayed
                // override stays consistent with what the system uses.
                if (seconds <= 0) {
                  _ctrl.text = (ov.interval.inSeconds).toString();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Refresh interval must be at least 1 second.',
                      ),
                    ),
                  );
                  return;
                }
                _setOverride(CustomInterval(Duration(seconds: seconds)));
              },
            ),
          ],
        ],
      ),
    );
  }

  void _setOverride(PollingOverride? next) {
    ref.read(pollingPrefsProvider.notifier).setOverride(widget.surface, next);
  }
}

/// Per-surface pill row: Default · Off · Slow · Normal · Fast · Custom.
/// Selection state is computed from the parent's flags rather than
/// stored locally so the row stays in sync with [pollingPrefsProvider].
class _SurfacePillRow extends StatelessWidget {
  final bool isDefault;
  final bool isCustom;
  final PollingSpeed? speed;
  final VoidCallback onDefault;
  final ValueChanged<PollingSpeed> onSpeed;
  final VoidCallback onCustom;
  const _SurfacePillRow({
    required this.isDefault,
    required this.isCustom,
    required this.speed,
    required this.onDefault,
    required this.onSpeed,
    required this.onCustom,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    Widget pill(String label, bool selected, VoidCallback onTap) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? y.primarySoft : y.surface2,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? y.primary : y.border,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.1,
              color: selected ? y.primaryStrong : y.text,
            ),
          ),
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        pill('Default', isDefault, onDefault),
        for (final s in PollingSpeed.values)
          pill(
            PollingPrefs.speedLabel(s),
            !isDefault && !isCustom && s == speed,
            () => onSpeed(s),
          ),
        pill('Custom', isCustom, onCustom),
      ],
    );
  }
}

/// Compact number-of-seconds input shown beneath the pill row when
/// Custom is the active selection. Validation lives in the parent's
/// [onCommit] so this widget stays purely presentational.
class _CustomSecondsField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<int> onCommit;
  const _CustomSecondsField({required this.controller, required this.onCommit});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Row(
      children: [
        SizedBox(
          width: 96,
          child: TextField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(
              signed: false,
              decimal: false,
            ),
            inputFormatters: [
              // Digits only — no minus sign, no decimal point. Pairs with
              // the >0 check in the parent's onCommit to enforce the
              // "no zero, no negative" contract.
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(5),
            ],
            textInputAction: TextInputAction.done,
            onSubmitted: (raw) => onCommit(int.tryParse(raw.trim()) ?? 0),
            onEditingComplete: () =>
                onCommit(int.tryParse(controller.text.trim()) ?? 0),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              suffixText: 's',
              suffixStyle: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: y.muted,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: y.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: y.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: y.primary, width: 1.4),
              ),
            ),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: y.text,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          'Press Enter to apply · at least 1 second.',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: y.muted,
          ),
        ),
      ],
    );
  }
}

/// Generic pill row. Generic over the choice type so the same widget can
/// render either `List<PollingSpeed>` (global picker) or
/// `List<PollingSpeed?>` (per-surface picker with a null = Default slot).
class _SpeedPillRow<T> extends StatelessWidget {
  final List<T> options;
  final bool Function(T) isSelected;
  final String Function(T) labelFor;
  final ValueChanged<T> onPick;
  const _SpeedPillRow({
    required this.options,
    required this.isSelected,
    required this.labelFor,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final opt in options)
          GestureDetector(
            onTap: () => onPick(opt),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: isSelected(opt) ? y.primarySoft : y.surface2,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: isSelected(opt) ? y.primary : y.border,
                  width: isSelected(opt) ? 1.4 : 1,
                ),
              ),
              child: Text(
                labelFor(opt),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.1,
                  color: isSelected(opt) ? y.primaryStrong : y.text,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
