// Manager Promotions — list, create, edit, archive. The cards here are what
// students see on their home screen (a horizontal rail). Backend: store CRUD
// + audit live in server/internal/store/promotions.go.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'manager_shell.dart';
import 'media_picker.dart';

/// All promotions including archived — managers manage the full set.
final adminPromotionsProvider = FutureProvider<List<Promotion>>((ref) async {
  return ref.watch(apiClientProvider).adminListPromotions();
});

const double _kNarrow = 700;

class AdminPromotionsScreen extends ConsumerWidget {
  const AdminPromotionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(adminPromotionsProvider);
    return RefreshOnMount(
      onMount: () => ref.invalidate(adminPromotionsProvider),
      child: LayoutBuilder(builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < _kNarrow;
        final padH = isNarrow ? 14.0 : 30.0;
        final padV = isNarrow ? 18.0 : 26.0;
        return Padding(
          padding: EdgeInsets.fromLTRB(padH, padV, padH, padV),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ManagerPageHeader(
                title: 'Promotions',
                sub: 'Cards shown on the student home screen',
                actions: [
                  YButton(
                    label: '+ New promotion',
                    small: true,
                    onTap: () => _openSheet(context, ref, null),
                  ),
                ],
              ),
              Expanded(
                child: data.when(
                  data: (rows) => _List(rows: rows),
                  loading: () => const Center(
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  error: (e, _) => Center(
                    child: Text(
                      "Can't load promotions: ${ApiError.fromAny(e).message}",
                      style: TextStyle(color: context.yoga.muted),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

Future<void> _openSheet(
    BuildContext context, WidgetRef ref, Promotion? existing) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _PromotionSheet(existing: existing),
  );
  if (saved == true) ref.invalidate(adminPromotionsProvider);
}

class _List extends ConsumerWidget {
  final List<Promotion> rows;
  const _List({required this.rows});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = rows.where((p) => !p.isArchived).toList();
    final archived = rows.where((p) => p.isArchived).toList();
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ManagerCard(
            title:
                '${active.length} live promotion${active.length == 1 ? '' : 's'}',
            child: active.isEmpty
                ? _EmptyHint()
                : Column(
                    children: [
                      for (var i = 0; i < active.length; i++)
                        _PromotionRow(
                          p: active[i],
                          isLast: i == active.length - 1,
                          onEdit: () => _openSheet(context, ref, active[i]),
                          onArchive: () => _archive(context, ref, active[i]),
                        ),
                    ],
                  ),
          ),
          if (archived.isNotEmpty) ...[
            const SizedBox(height: 14),
            ManagerCard(
              title: 'Archived',
              child: Column(
                children: [
                  for (var i = 0; i < archived.length; i++)
                    _PromotionRow(
                      p: archived[i],
                      isLast: i == archived.length - 1,
                      onEdit: () => _openSheet(context, ref, archived[i]),
                      onArchive: null,
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _archive(
      BuildContext context, WidgetRef ref, Promotion p) async {
    final y = context.yoga;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: y.surface,
        title: Text('Archive "${p.title}"?',
            style: TextStyle(color: y.text)),
        content: Text(
          "It'll stop showing on the student home screen. You can still see "
          "it here under Archived.",
          style: TextStyle(color: y.text, fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiClientProvider).adminArchivePromotion(p.id);
      ref.invalidate(adminPromotionsProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text('Archive failed: ${ApiError.fromAny(e).message}')),
        );
      }
    }
  }
}

class _EmptyHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(
        'No promotions yet — click "+ New promotion" to feature an offer or '
        'studio item on the home screen.',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: context.yoga.muted,
        ),
      ),
    );
  }
}

class _PromotionRow extends StatelessWidget {
  final Promotion p;
  final bool isLast;
  final VoidCallback onEdit;
  final VoidCallback? onArchive;
  const _PromotionRow({
    required this.p,
    required this.isLast,
    required this.onEdit,
    required this.onArchive,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return InkWell(
      onTap: onEdit,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: isLast ? null : Border(bottom: BorderSide(color: y.border)),
        ),
        child: Row(
          children: [
            _Thumb(url: p.imageUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: y.text,
                    ),
                  ),
                  if (p.body.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      p.body,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: y.muted,
                      ),
                    ),
                  ],
                  if (_window(p) != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      _window(p)!,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: y.primary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (onArchive != null)
              IconButton(
                onPressed: onArchive,
                icon: Icon(Icons.archive_outlined, size: 18, color: y.muted),
                tooltip: 'Archive',
              ),
            Icon(Icons.chevron_right, size: 18, color: y.muted),
          ],
        ),
      ),
    );
  }

  static String? _window(Promotion p) {
    String d(DateTime t) =>
        '${t.day}/${t.month}/${t.year % 100}';
    if (p.startsAt == null && p.endsAt == null) return null;
    if (p.startsAt != null && p.endsAt != null) {
      return '${d(p.startsAt!)} – ${d(p.endsAt!)}';
    }
    if (p.endsAt != null) return 'Until ${d(p.endsAt!)}';
    return 'From ${d(p.startsAt!)}';
  }
}

class _Thumb extends StatelessWidget {
  final String url;
  const _Thumb({required this.url});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: y.border),
        image: url.isNotEmpty
            ? DecorationImage(image: NetworkImage(url), fit: BoxFit.cover)
            : null,
      ),
      child: url.isEmpty
          ? Icon(Icons.local_offer_outlined, size: 18, color: y.muted)
          : null,
    );
  }
}

class _PromotionSheet extends ConsumerStatefulWidget {
  final Promotion? existing;
  const _PromotionSheet({required this.existing});

  @override
  ConsumerState<_PromotionSheet> createState() => _PromotionSheetState();
}

class _PromotionSheetState extends ConsumerState<_PromotionSheet> {
  late final TextEditingController _title;
  late final TextEditingController _body;
  String _imageUrl = '';
  DateTime? _startsAt;
  DateTime? _endsAt;
  bool _submitting = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(text: e?.title ?? '');
    _body = TextEditingController(text: e?.body ?? '');
    _imageUrl = e?.imageUrl ?? '';
    _startsAt = e?.startsAt;
    _endsAt = e?.endsAt;
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: y.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: y.borderStrong,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _isEdit ? 'Edit promotion' : 'New promotion',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _title,
                  enabled: !_submitting,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Title',
                    hintText: 'Summer offer · Reformer intro',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _body,
                  enabled: !_submitting,
                  maxLines: 2,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Body (optional)',
                    hintText: '20% off Unlimited Monthly until 21 June',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 14),
                _ImageField(
                  url: _imageUrl,
                  enabled: !_submitting,
                  onPick: () async {
                    final picked = await showMediaPicker(context);
                    if (picked != null) setState(() => _imageUrl = picked);
                  },
                  onClear: () => setState(() => _imageUrl = ''),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: _DateField(
                        label: 'Starts',
                        value: _startsAt,
                        enabled: !_submitting,
                        onPick: (d) => setState(() => _startsAt = d),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _DateField(
                        label: 'Ends',
                        value: _endsAt,
                        enabled: !_submitting,
                        onPick: (d) => setState(() => _endsAt = d),
                      ),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _error!,
                    style: const TextStyle(
                      color: Color(0xFFA33B2E),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                YButton(
                  label: _submitting
                      ? 'Saving…'
                      : (_isEdit ? 'Save changes' : 'Create promotion'),
                  onTap: _submitting ? null : _submit,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (_title.text.trim().isEmpty) {
      setState(() => _error = 'A title is required.');
      return;
    }
    if (_startsAt != null && _endsAt != null && _endsAt!.isBefore(_startsAt!)) {
      setState(() => _error = 'End date is before the start date.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      if (_isEdit) {
        await api.adminUpdatePromotion(
          id: widget.existing!.id,
          title: _title.text.trim(),
          body: _body.text.trim(),
          imageUrl: _imageUrl,
          startsAt: _startsAt,
          endsAt: _endsAt,
        );
      } else {
        await api.adminCreatePromotion(
          title: _title.text.trim(),
          body: _body.text.trim(),
          imageUrl: _imageUrl,
          startsAt: _startsAt,
          endsAt: _endsAt,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _submitting = false;
        _error = ApiError.fromAny(e).message;
      });
    }
  }
}

class _ImageField extends StatelessWidget {
  final String url;
  final bool enabled;
  final VoidCallback onPick;
  final VoidCallback onClear;
  const _ImageField({
    required this.url,
    required this.enabled,
    required this.onPick,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Row(
      children: [
        _Thumb(url: url),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            url.isEmpty ? 'No image' : 'Image set',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: y.muted,
            ),
          ),
        ),
        if (url.isNotEmpty)
          TextButton(
            onPressed: enabled ? onClear : null,
            child: const Text('Clear'),
          ),
        YButton(
          label: url.isEmpty ? 'Choose image' : 'Change',
          small: true,
          variant: YButtonVariant.outline,
          onTap: enabled ? onPick : null,
        ),
      ],
    );
  }
}

class _DateField extends StatelessWidget {
  final String label;
  final DateTime? value;
  final bool enabled;
  final ValueChanged<DateTime?> onPick;
  const _DateField({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final text = value == null
        ? 'Any'
        : '${value!.day}/${value!.month}/${value!.year % 100}';
    return InkWell(
      onTap: enabled
          ? () async {
              final now = DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: value ?? now,
                firstDate: DateTime(now.year - 1),
                lastDate: DateTime(now.year + 3),
              );
              if (picked != null) onPick(picked);
            }
          : null,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
          suffixIcon: value != null
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 16),
                  onPressed: enabled ? () => onPick(null) : null,
                )
              : const Icon(Icons.calendar_today_outlined, size: 16),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: value == null ? y.muted : y.text,
          ),
        ),
      ),
    );
  }
}
