// Manager Activity log — read-only viewer for audit_log rows.
// Filter chips switch the action filter (All / Grants / Adjusts / Voids).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'class_dialogs.dart';
import 'manager_shell.dart';

final adminAuditProvider =
    FutureProvider.autoDispose.family<List<AuditEntry>, String>((ref, filter) async {
  return ref.watch(apiClientProvider).adminAudit(action: filter);
});

final adminClassTemplatesProvider =
    FutureProvider.autoDispose<List<ClassTemplate>>((ref) async {
  return ref.watch(apiClientProvider).adminListClassTemplates();
});

class AdminAuditScreen extends ConsumerStatefulWidget {
  const AdminAuditScreen({super.key});

  @override
  ConsumerState<AdminAuditScreen> createState() => _AdminAuditScreenState();
}

class _AdminAuditScreenState extends ConsumerState<AdminAuditScreen> {
  String _filter = 'all';

  static const _filters = {
    'all': 'All',
    'class_create': 'New classes',
    'class_cancel': 'Cancelled classes',
    'template_create': 'Templates',
    'template_revert': 'Template undos',
    'cash_grant': 'Cash grants',
    'credit_adjust': 'Credit adjusts',
    'void': 'Voids',
  };

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(adminAuditProvider(_filter));
    final templates = ref.watch(adminClassTemplatesProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
      child: ListView(
        children: [
          const ManagerPageHeader(
            title: 'Activity log',
            sub: 'Read-only — every sensitive action is here.',
          ),
          // Recent templates panel — surface Undo affordance for active ones.
          templates.maybeWhen(
            data: (list) => list.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: ManagerCard(
                      title: 'Recent class templates',
                      child: Column(
                        children: [
                          for (var i = 0; i < list.length && i < 5; i++)
                            _TemplateRow(
                              template: list[i],
                              isLast: i == list.length - 1 || i == 4,
                              onUndo: () async {
                                final undone = await showUndoTemplateDialog(
                                  context: context,
                                  template: list[i],
                                );
                                if (undone == true) {
                                  ref.invalidate(adminClassTemplatesProvider);
                                  ref.invalidate(adminAuditProvider);
                                }
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final entry in _filters.entries)
                  _FilterPill(
                    label: entry.value,
                    active: entry.key == _filter,
                    onTap: () => setState(() => _filter = entry.key),
                  ),
              ],
            ),
          ),
          data.when(
            data: (rows) => rows.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        'No entries match this filter.',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: context.yoga.muted,
                        ),
                      ),
                    ),
                  )
                : ManagerCard(
                    child: Column(
                      children: [
                        for (var i = 0; i < rows.length; i++)
                          _AuditRow(
                            e: rows[i],
                            isLast: i == rows.length - 1,
                          ),
                      ],
                    ),
                  ),
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  "Can't load audit log: $e",
                  style: TextStyle(color: context.yoga.muted),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TemplateRow extends StatelessWidget {
  final ClassTemplate template;
  final bool isLast;
  final VoidCallback onUndo;
  const _TemplateRow({
    required this.template,
    required this.isLast,
    required this.onUndo,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final active = template.status == 'active';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: y.border)),
      ),
      child: Row(
        children: [
          Icon(
            active ? Icons.event_repeat : Icons.history,
            size: 18,
            color: active ? y.primary : y.muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  template.title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                  ),
                ),
                Text(
                  '${template.generatedClassIds.length} session${template.generatedClassIds.length == 1 ? '' : 's'} · created ${_relTime(template.createdAt)}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: y.muted,
                  ),
                ),
              ],
            ),
          ),
          if (active)
            YButton(
              label: 'Undo',
              variant: YButtonVariant.outline,
              small: true,
              onTap: onUndo,
            )
          else
            YChip(kind: YChipKind.neutral, label: 'Reverted'),
        ],
      ),
    );
  }

  static String _relTime(DateTime t) {
    final delta = DateTime.now().difference(t);
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inHours < 1) return '${delta.inMinutes}m ago';
    if (delta.inDays < 1) return '${delta.inHours}h ago';
    if (delta.inDays < 7) return '${delta.inDays}d ago';
    return '${(delta.inDays / 7).floor()}w ago';
  }
}

class _FilterPill extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _FilterPill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? y.text : y.surface,
          borderRadius: BorderRadius.circular(y.radiusChip),
          border: Border.all(color: active ? Colors.transparent : y.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: active ? y.background : y.muted,
          ),
        ),
      ),
    );
  }
}

class _AuditRow extends StatelessWidget {
  final AuditEntry e;
  final bool isLast;
  const _AuditRow({required this.e, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final actionLabel = switch (e.action) {
      'cash_grant' => 'Cash grant',
      'credit_adjust' => 'Credit adjust',
      'void' => 'Void',
      'class_create' => 'New class',
      'class_cancel' => 'Class cancelled',
      'template_create' => 'Template created',
      'template_revert' => 'Template undone',
      _ => e.action,
    };
    final reasonOrNote = e.detail['reason'] ?? e.detail['note'];
    final amount = e.detail['amount_minor'] as int?;
    final delta = e.detail['delta'];
    final refund = e.detail['refunded_minor'] as int?;
    final weeks = e.detail['weeks'] as int?;
    final generated = e.detail['generated_classes'] as int?;
    final cancelled = e.detail['bookings_cancelled'] as int?;
    final templateTotal = e.detail['total_classes'] as int?;
    final classTitle = e.detail['title'] as String?;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: y.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          YAvatar(name: e.actorName, size: 26),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: RichText(
                        text: TextSpan(
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: y.text,
                          ),
                          children: [
                            TextSpan(
                              text: e.actorName,
                              style: const TextStyle(fontWeight: FontWeight.w800),
                            ),
                            TextSpan(text: '  ·  '),
                            TextSpan(
                              text: actionLabel,
                              style: TextStyle(
                                color: _actionColor(context, e.action),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (amount != null)
                              TextSpan(text: '  ·  £${(amount / 100).toStringAsFixed(2)}'),
                            if (delta != null)
                              TextSpan(text: '  ·  ${delta is int && delta > 0 ? '+' : ''}$delta credits'),
                            if (refund != null)
                              TextSpan(text: '  ·  refund £${(refund / 100).toStringAsFixed(2)}'),
                            if (classTitle != null && classTitle.isNotEmpty)
                              TextSpan(text: '  ·  $classTitle'),
                            if (weeks != null && generated != null)
                              TextSpan(text: '  ·  $generated classes over $weeks weeks'),
                            if (cancelled != null && cancelled > 0)
                              TextSpan(text: '  ·  $cancelled booking${cancelled == 1 ? '' : 's'} released'),
                            if (templateTotal != null)
                              TextSpan(text: '  ·  $templateTotal session${templateTotal == 1 ? '' : 's'} cancelled'),
                          ],
                        ),
                      ),
                    ),
                    Text(
                      _relTime(e.createdAt),
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: y.muted,
                      ),
                    ),
                  ],
                ),
                if (reasonOrNote is String && reasonOrNote.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    reasonOrNote,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: y.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Color _actionColor(BuildContext context, String action) {
    final y = context.yoga;
    return switch (action) {
      'cash_grant' => y.primary,
      'credit_adjust' => y.accent,
      'void' => const Color(0xFFA33B2E),
      'class_create' => y.primary,
      'class_cancel' => const Color(0xFFA33B2E),
      'template_create' => y.primary,
      'template_revert' => const Color(0xFFA33B2E),
      _ => y.text,
    };
  }

  static String _relTime(DateTime t) {
    final delta = DateTime.now().difference(t);
    if (delta.inMinutes < 1) return 'now';
    if (delta.inHours < 1) return '${delta.inMinutes}m';
    if (delta.inDays < 1) return '${delta.inHours}h';
    if (delta.inDays < 7) return '${delta.inDays}d';
    return '${(delta.inDays / 7).floor()}w';
  }
}
