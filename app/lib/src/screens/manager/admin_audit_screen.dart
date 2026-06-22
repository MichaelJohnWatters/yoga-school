// Manager Activity log — read-only viewer for audit_log rows.
// Filter chips switch the action filter (All / Grants / Adjusts / Voids).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/polling.dart';
import '../../widgets/yoga_primitives.dart';
import 'class_dialogs.dart';
import 'manager_shell.dart';

// Session-scoped — the audit log is heavy to render but cheap to keep
// in memory, and managers tab back to it often when investigating a
// student's history. Each filter chip is a family key so all of them
// stay warm.
final adminAuditProvider =
    FutureProvider.family<List<AuditEntry>, String>((ref, filter) async {
  return ref.watch(apiClientProvider).adminAudit(action: filter);
});

final adminClassTemplatesProvider =
    FutureProvider<List<ClassTemplate>>((ref) async {
  return ref.watch(apiClientProvider).adminListClassTemplates();
});

class AdminAuditScreen extends ConsumerStatefulWidget {
  const AdminAuditScreen({super.key});

  @override
  ConsumerState<AdminAuditScreen> createState() => _AdminAuditScreenState();
}

class _AdminAuditScreenState extends ConsumerState<AdminAuditScreen> {
  String _filter = 'all';
  // Free-text filter — matches case-insensitively against actor name,
  // action, and the visible detail values (titles, names, reasons,
  // notes). Applied client-side on top of the server-side action filter.
  String _query = '';

  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    // Initial refresh on visit + periodic polling at the audit cadence.
    // Wrapping in PollingRefresh-style logic without the widget here
    // because the State has a single body — the timer lives directly
    // on the State and reads the user's polling speed each tick.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshAll();
      _restartPoll();
    });
  }

  void _refreshAll() {
    if (!mounted) return;
    ref.invalidate(adminAuditProvider(_filter));
    ref.invalidate(adminClassTemplatesProvider);
  }

  void _restartPoll() {
    _pollTimer?.cancel();
    final prefs = ref.read(pollingPrefsProvider);
    final i = prefs.intervalFor(PollingSurface.audit);
    if (i == null) return;
    _pollTimer = Timer.periodic(i, (_) => _refreshAll());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  // Filter chips. Ordered by how often a manager reaches for them when
  // investigating: money first, then schedule, then access/config. Action
  // names match the server's audit_log.action values 1:1.
  static const _filters = {
    'all': 'All',
    // Money
    'cash_grant': 'Cash grants',
    'credit_adjust': 'Credit adjusts',
    'void': 'Voids',
    'purchase_refund': 'Refunds',
    'discount_create': 'New discounts',
    'discount_archive': 'Archived discounts',
    // Schedule
    'class_create': 'New classes',
    'class_update': 'Class edits',
    'class_cancel': 'Cancelled classes',
    'template_create': 'Templates',
    'template_revert': 'Template undos',
    'rule_create': 'Recurrences',
    'series_create': 'New series',
    'series_update': 'Series edits',
    // Student-initiated bookings + purchases
    'booking_create': 'Bookings',
    'series_join': 'Series joins',
    'purchase': 'Purchases',
    'purchase_pending': 'Pending purchases',
    // Attendance + waitlist + manager-side bookings
    'attendance_mark': 'Attendance marks',
    'attendance_scan': 'Check-in scans',
    'waitlist_promote': 'Waitlist promotes',
    'booking_create_admin': 'Manager bookings',
    'booking_cancel_admin': 'Manager cancels',
    // Catalogue + config
    'product_create': 'New products',
    'product_update': 'Product edits',
    'product_archive': 'Archived products',
    'class_type_create': 'New class types',
    'class_type_update': 'Class type edits',
    'promotion_create': 'New promotions',
    'promotion_update': 'Promotion edits',
    'promotion_archive': 'Archived promotions',
    // Access + studio
    'staff_create': 'New staff',
    'staff_update': 'Staff edits',
    'theme_create': 'New themes',
    'theme_update': 'Theme edits',
    'theme_activate': 'Theme activations',
    'studio_config_update': 'Studio settings',
    'stripe_credentials_update': 'Stripe credentials',
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
            padding: const EdgeInsets.only(bottom: 10),
            child: _AuditSearchBar(
              value: _query,
              onChanged: (q) => setState(() => _query = q),
            ),
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
            data: (rows) {
              final visible = _applyQuery(rows, _query);
              if (visible.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text(
                      _query.trim().isEmpty
                          ? 'No entries match this filter.'
                          : 'No entries match "${_query.trim()}".',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: context.yoga.muted,
                      ),
                    ),
                  ),
                );
              }
              return ManagerCard(
                child: Column(
                  children: [
                    if (_query.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '${visible.length} of ${rows.length} match',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: context.yoga.muted,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                      ),
                    for (var i = 0; i < visible.length; i++)
                      _AuditRow(
                        e: visible[i],
                        isLast: i == visible.length - 1,
                      ),
                  ],
                ),
              );
            },
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  "Can't load audit log: ${ApiError.fromAny(e).message}",
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

/// Case-insensitive substring filter across the most identifying fields
/// of each audit entry. Returns the original list when [query] is blank
/// so we don't pay the per-row build cost in the common no-filter case.
///
/// Matched fields per row:
///   * actor name + action key (the chip's labels are derived from these)
///   * the action's natural subject — title, name, user_name,
///     class_title, promoted_user_name
///   * support keys — reason, note, mode, status, via, final_status
///
/// We deliberately stop short of stringifying the whole detail map: a
/// match on a raw UUID or a payload key would be noise, and the listed
/// fields already cover everything the row visibly renders.
List<AuditEntry> _applyQuery(List<AuditEntry> rows, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return rows;
  bool matches(AuditEntry e) {
    final d = e.detail;
    final blob = [
      e.actorName,
      e.action,
      d['title'],
      d['name'],
      d['product_name'],
      d['enrollment_title'],
      d['user_name'],
      d['student_name'],
      d['class_title'],
      d['promoted_user_name'],
      d['reason'],
      d['note'],
      d['mode'],
      d['status'],
      d['via'],
      d['final_status'],
      d['pass_kind'],
      d['payment_method'],
      d['discount_code'],
      d['code'],
      d['instructor_name'],
      d['room_name'],
      // Previous values from update audits — let a manager find "the
      // edit that renamed Vinyasa → Flow" by searching for either side.
      d['previous_name'],
      d['previous_email'],
      d['previous_role'],
      d['previous_full_name'],
      // affected_users names — let "ben" find a class_cancel that
      // released Ben's booking even if his name isn't in the subject.
      for (final raw in (d['affected_users'] as List? ?? const []))
        if (raw is Map) raw['name'],
    ].whereType<String>().join(' ').toLowerCase();
    return blob.contains(q);
  }
  return rows.where(matches).toList();
}

/// Search input above the filter chips. Mirrors the roster screen's
/// search pill but stretches full-width — the audit log is a single
/// dense column so there's nothing competing for horizontal space.
///
/// Stateful so the clear-X button can actually clear the visible text:
/// without an owned controller, `onChanged('')` only updates the parent
/// state, not the TextField's internal buffer.
class _AuditSearchBar extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _AuditSearchBar({required this.value, required this.onChanged});

  @override
  State<_AuditSearchBar> createState() => _AuditSearchBarState();
}

class _AuditSearchBarState extends State<_AuditSearchBar> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _clear() {
    _ctrl.clear();
    widget.onChanged('');
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(y.radiusChip),
        border: Border.all(color: y.border),
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 16, color: y.muted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _ctrl,
              onChanged: widget.onChanged,
              style: TextStyle(fontSize: 13, color: y.text),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Filter by name, class, reason…',
                hintStyle: TextStyle(color: y.muted),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
          // Drive visibility off widget.value so the X appears on the next
          // rebuild after onChanged — the controller mutates without
          // triggering our setState, so we'd otherwise lag a keystroke.
          if (widget.value.isNotEmpty)
            InkWell(
              onTap: _clear,
              borderRadius: BorderRadius.circular(999),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.close, size: 14, color: y.muted),
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

/// Redesigned activity row — a structured card per event instead of a
/// dense RichText line. Top row carries the action chip + actor +
/// relative time; second row carries the action's natural subject
/// (class title for class events, "+10 credits" for a credit adjust);
/// optional reason/note sits below in a muted strip. For class_cancel
/// we expand a second block listing affected users so the manager can
/// see at a glance who lost their booking.
class _AuditRow extends StatelessWidget {
  final AuditEntry e;
  final bool isLast;
  const _AuditRow({required this.e, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final reasonOrNote = e.detail['reason'] ?? e.detail['note'];
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: y.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header — action chip, actor, time.
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _ActionChip(action: e.action),
              const SizedBox(width: 10),
              YAvatar(name: e.actorName, size: 22),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  e.actorName,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: y.text,
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
          const SizedBox(height: 8),
          // Action-specific subject + metric pills.
          _AuditBody(entry: e),
          // Reason / note as a quoted muted strip.
          if (reasonOrNote is String && reasonOrNote.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: y.surface2,
                borderRadius: BorderRadius.circular(6),
                border: Border(
                  left: BorderSide(color: y.border, width: 2),
                ),
              ),
              child: Text(
                reasonOrNote,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: y.muted,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ],
      ),
    );
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

class _ActionChip extends StatelessWidget {
  final String action;
  const _ActionChip({required this.action});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    // Three colour tracks:
    //  - primary  = a creating / activating event
    //  - accent   = a non-destructive edit or money inflow
    //  - red      = a destructive / removing / refunding event
    //  - surface2 = neutral (config tweaks, attendance marks, etc.)
    const red = Color(0xFFA33B2E);
    final (label, fg, bg) = switch (action) {
      // Money
      'cash_grant' => ('CASH GRANT', y.onPrimary, y.primary),
      'credit_adjust' => ('CREDITS', y.text, y.accentSoft),
      'void' => ('VOID', Colors.white, red),
      'purchase_refund' => ('REFUND', Colors.white, red),
      'discount_create' => ('DISCOUNT', y.onPrimary, y.primary),
      'discount_archive' => ('DISCOUNT ARCHIVED', Colors.white, red),
      // Schedule
      'class_create' => ('NEW CLASS', y.onPrimary, y.primary),
      'class_update' => ('CLASS EDIT', y.text, y.accentSoft),
      'class_cancel' => ('CANCELLED', Colors.white, red),
      'template_create' => ('TEMPLATE', y.onPrimary, y.primary),
      'template_revert' => ('UNDONE', Colors.white, red),
      'rule_create' => ('RECURRENCE', y.onPrimary, y.primary),
      'series_create' => ('NEW SERIES', y.onPrimary, y.primary),
      'series_update' => ('SERIES EDIT', y.text, y.accentSoft),
      // Student-initiated bookings + purchases
      'booking_create' => ('BOOKING', y.onPrimary, y.primary),
      'series_join' => ('SERIES JOIN', y.onPrimary, y.primary),
      'purchase' => ('PURCHASE', y.onPrimary, y.primary),
      'purchase_pending' => ('PENDING PURCHASE', y.text, y.surface2),
      // Attendance + waitlist + manager-side bookings
      'attendance_mark' => ('ATTENDANCE', y.text, y.surface2),
      'attendance_scan' => ('CHECK-IN', y.text, y.surface2),
      'waitlist_promote' => ('PROMOTED', y.onPrimary, y.primary),
      'booking_create_admin' => ('MGR BOOKING', y.onPrimary, y.primary),
      'booking_cancel_admin' => ('MGR CANCEL', Colors.white, red),
      // Catalogue + config
      'product_create' => ('NEW PRODUCT', y.onPrimary, y.primary),
      'product_update' => ('PRODUCT EDIT', y.text, y.accentSoft),
      'product_archive' => ('PRODUCT ARCHIVED', Colors.white, red),
      'class_type_create' => ('NEW TYPE', y.onPrimary, y.primary),
      'class_type_update' => ('TYPE EDIT', y.text, y.accentSoft),
      'promotion_create' => ('PROMOTION', y.onPrimary, y.primary),
      'promotion_update' => ('PROMOTION EDIT', y.text, y.accentSoft),
      'promotion_archive' => ('PROMOTION ARCHIVED', Colors.white, red),
      // Access + studio
      'staff_create' => ('NEW STAFF', y.onPrimary, y.primary),
      'staff_update' => ('STAFF EDIT', y.text, y.accentSoft),
      'theme_create' => ('NEW THEME', y.onPrimary, y.primary),
      'theme_update' => ('THEME EDIT', y.text, y.accentSoft),
      'theme_activate' => ('THEME ACTIVE', y.onPrimary, y.primary),
      'studio_config_update' => ('SETTINGS', y.text, y.accentSoft),
      'stripe_credentials_update' => ('STRIPE', y.text, y.accentSoft),
      _ => (action.toUpperCase().replaceAll('_', ' '), y.text, y.surface2),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
          height: 1.0,
        ),
      ),
    );
  }
}

class _AuditBody extends StatelessWidget {
  final AuditEntry entry;
  const _AuditBody({required this.entry});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    const red = Color(0xFFA33B2E);
    final d = entry.detail;

    // ---- numeric / metric fields commonly seen across actions ----
    final amount = d['amount_minor'] as int?;
    final delta = d['delta'];
    final refund = d['refunded_minor'] as int?;
    final priceMinor = d['price_minor'] as int?;
    final refundAmount = d['refund_amount_minor'] as int?;
    final totalRefunded = d['total_refunded'] as int?;
    final weeks = d['weeks'] as int?;
    final generated = d['generated_classes'] as int?;
    final cancelled = d['bookings_cancelled'] as int?;
    final creditsReturned = d['credits_returned'] as int?;
    final templateTotal = d['total_classes'] as int?;
    final classesUpdated = d['classes_updated'] as int?;
    final fromPosition = d['from_position'] as int?;

    // ---- string fields — many actions stash a primary subject under
    // either `title` (classes/series/templates) or `name` (products,
    // themes, class types, promotions). Newer events also carry human
    // labels (`user_name`, `class_title`, `promoted_user_name`) so the
    // log doesn't render opaque IDs. Prefer whichever the row provides.
    final title = d['title'] as String?;
    final name = d['name'] as String?;
    final classTitle = d['class_title'] as String?;
    // Older money-mutator rows used `student_name`/`student_id`; newer
    // booking/attendance rows use `user_name`/`user_id`. Prefer either
    // — the activity log treats them as the same field semantically.
    final userName = (d['user_name'] as String?) ?? (d['student_name'] as String?);
    final userIdAffected = (d['user_id'] as String?) ?? (d['student_id'] as String?);
    final promotedName = d['promoted_user_name'] as String?;
    final mode = d['mode'] as String?;
    final slot = d['slot'] as String?;
    final scope = d['scope'] as String?;
    final status = d['status'] as String?;
    final via = d['via'] as String?;
    final finalStatus = d['final_status'] as String?;
    final note = d['note'] as String?;

    // ---- subject line: the single most identifying string for the row.
    // Picks per action so the log reads naturally rather than dumping
    // the first non-empty field it finds.
    String? subject;
    switch (entry.action) {
      case 'attendance_mark':
      case 'attendance_scan':
        // "<student> · <class>" so the manager sees who and where.
        final left = (userName ?? '').trim();
        final right = (classTitle ?? '').trim();
        if (left.isNotEmpty && right.isNotEmpty) {
          subject = '$left · $right';
        } else if (left.isNotEmpty) {
          subject = left;
        } else if (right.isNotEmpty) {
          subject = right;
        }
        break;
      case 'waitlist_promote':
        final left = (promotedName ?? '').trim();
        final right = (classTitle ?? '').trim();
        if (left.isNotEmpty && right.isNotEmpty) {
          subject = '$left → $right';
        } else if (right.isNotEmpty) {
          subject = right;
        } else if (left.isNotEmpty) {
          subject = left;
        }
        break;
      case 'booking_create_admin':
      case 'booking_cancel_admin':
        // Manager booked/cancelled <student> into <class>.
        final left = (userName ?? '').trim();
        final right = (classTitle ?? '').trim();
        if (left.isNotEmpty && right.isNotEmpty) {
          subject = '$left · $right';
        } else if (left.isNotEmpty) {
          subject = left;
        } else if (right.isNotEmpty) {
          subject = right;
        }
        break;
      case 'booking_create':
        // Student-self bookings record only class_title (actor is on the
        // header already). Fall through cleanly when the row pre-dates
        // the enrichment (older rows have only class_id).
        final ct = (classTitle ?? '').trim();
        if (ct.isNotEmpty) subject = ct;
        break;
      case 'purchase':
      case 'purchase_pending':
        // product_name is the natural subject for a purchase row.
        final p = (d['product_name'] as String?)?.trim() ?? '';
        if (p.isNotEmpty) subject = p;
        break;
      case 'series_join':
        final et = (d['enrollment_title'] as String?)?.trim() ?? '';
        if (et.isNotEmpty) subject = et;
        break;
      case 'cash_grant':
        // "<product> · <student>" so the line reads top-to-bottom as
        // "[CASH GRANT] Manager · 5m · 10-pack · Maya Lopez".
        final p = (d['product_name'] as String?)?.trim() ?? '';
        final s = (userName ?? '').trim();
        if (p.isNotEmpty && s.isNotEmpty) {
          subject = '$p · $s';
        } else if (p.isNotEmpty) {
          subject = p;
        } else if (s.isNotEmpty) {
          subject = s;
        }
        break;
      case 'credit_adjust':
      case 'void':
      case 'purchase_refund':
        // Affected student name is the subject — the change amount /
        // refund / delta is already on the pill row.
        final s = (userName ?? '').trim();
        if (s.isNotEmpty) subject = s;
        break;
      case 'class_cancel':
      case 'booking_cancel':
      case 'booking_plus_one':
      case 'waitlist_join':
      case 'waitlist_leave':
      case 'waitlist_auto_book':
        // Class title (now stored on every one of these audit rows) is
        // the natural subject — answers "which class?" without making
        // the reader follow class_id back to the classes table.
        final ct = (classTitle ?? '').trim();
        if (ct.isNotEmpty) subject = ct;
        break;
      case 'discount_archive':
        // Discount code (e.g. "SPRING25") if the discount had one,
        // otherwise fall through to no subject — a no-code discount is
        // identified only by id, which is opaque.
        final code = (d['code'] as String?)?.trim() ?? '';
        if (code.isNotEmpty) subject = code;
        break;
      case 'series_update':
        // enrollment_title is always written even when the patch only
        // touched description/capacity, so prefer it over title (which
        // is only present when the title itself changed).
        final et = (d['enrollment_title'] as String?)?.trim() ?? '';
        if (et.isNotEmpty) subject = et;
        break;
      case 'template_create':
        if (generated != null && weeks != null) {
          subject = '$generated classes generated over $weeks weeks';
        } else {
          subject = title;
        }
        break;
      case 'studio_config_update':
        subject = 'Studio settings updated';
        break;
      case 'stripe_credentials_update':
        subject = 'Stripe credentials updated';
        break;
      default:
        // Most other actions: class/series/promotion `title`, or
        // product/theme/class-type `name`.
        final t = (title ?? '').trim();
        final n = (name ?? '').trim();
        subject = t.isNotEmpty ? t : (n.isNotEmpty ? n : null);
    }

    // ---- pills: small metric badges describing the change.
    final pills = <Widget>[];
    if (amount != null) pills.add(_pill('£${_money(amount)}', y.text));
    if (priceMinor != null) pills.add(_pill('£${_money(priceMinor)}', y.text));
    if (delta is int) {
      final sign = delta > 0 ? '+' : '';
      pills.add(_pill('$sign$delta credits', y.text));
    }
    if (refund != null) pills.add(_pill('refund £${_money(refund)}', red));
    if (refundAmount != null) {
      pills.add(_pill('refund £${_money(refundAmount)}', red));
    }
    if (totalRefunded != null && totalRefunded != refundAmount) {
      pills.add(_pill('total refunded £${_money(totalRefunded)}', y.muted));
    }
    if (cancelled != null && cancelled > 0) {
      pills.add(_pill(
        '$cancelled booking${cancelled == 1 ? '' : 's'} released',
        red,
      ));
    }
    if (creditsReturned != null && creditsReturned > 0) {
      pills.add(_pill(
        '$creditsReturned credit${creditsReturned == 1 ? '' : 's'} returned',
        y.text,
      ));
    }
    if (templateTotal != null) {
      pills.add(_pill(
        '$templateTotal session${templateTotal == 1 ? '' : 's'} cancelled',
        red,
      ));
    }
    if (classesUpdated != null && classesUpdated > 0) {
      pills.add(_pill(
        '$classesUpdated class${classesUpdated == 1 ? '' : 'es'} updated',
        y.text,
      ));
    }
    if (status != null && status.isNotEmpty) {
      pills.add(_pill(status, y.text));
    }
    if (finalStatus != null && finalStatus.isNotEmpty) {
      pills.add(_pill(finalStatus, y.text));
    }
    if (via != null && via.isNotEmpty) {
      pills.add(_pill('via $via', y.muted));
    }
    if (mode != null && mode.isNotEmpty) {
      pills.add(_pill('mode: $mode', y.text));
    }
    if (slot != null && slot.isNotEmpty) {
      pills.add(_pill('$slot slot', y.text));
    }
    if (scope != null && scope.isNotEmpty && scope != 'this') {
      // "this" is the default single-class scope — too noisy to surface.
      pills.add(_pill('scope: $scope', y.muted));
    }
    if (fromPosition != null) {
      pills.add(_pill('from #$fromPosition', y.muted));
    }
    // class_create stores instructor + room labels alongside their
    // ids so the row can stand on its own — render them as quiet
    // metadata pills next to the title-as-subject.
    final instructorPill = (d['instructor_name'] as String?)?.trim() ?? '';
    if (instructorPill.isNotEmpty) {
      pills.add(_pill(instructorPill, y.muted));
    }
    final roomPill = (d['room_name'] as String?)?.trim() ?? '';
    if (roomPill.isNotEmpty) {
      pills.add(_pill(roomPill, y.muted));
    }
    // Manager-cancel: surface the refund decision explicitly so the
    // activity log answers "did the credit come back?" at a glance.
    if (entry.action == 'booking_cancel_admin') {
      final refunded = d['credit_returned'] == true;
      pills.add(_pill(
        refunded ? 'credit returned' : 'credit consumed',
        refunded ? y.text : red,
      ));
    }
    // Stripe credentials store which fields rotated, not their values.
    final secretChange = d['secret_key'] as String?;
    if (secretChange != null && secretChange.isNotEmpty) {
      pills.add(_pill('secret $secretChange', y.text));
    }
    final webhookChange = d['webhook_secret'] as String?;
    if (webhookChange != null && webhookChange.isNotEmpty) {
      pills.add(_pill('webhook $webhookChange', y.text));
    }
    // ---- before → after diffs ----
    // Updates that snapshot a `previous_*` value next to the new value
    // render as a single "label: old → new" pill. Useful for renames
    // (class type, room, theme), role transitions (instructor → manager),
    // and studio-config tweaks (cutoff hours, timezone, …).
    const diffKeys = <String, String>{
      'name': 'name',
      'discipline': 'discipline',
      'mode': 'mode',
      'role': 'role',
      'email': 'email',
      'full_name': 'name',
      'free_cancel_cutoff_hours': 'cutoff',
      'allow_student_plus_one': '+1 allowed',
      'buy_layout': 'layout',
      'welcome_message': 'welcome',
      'timezone': 'tz',
    };
    diffKeys.forEach((key, label) {
      final prev = d['previous_$key'];
      final next = d[key];
      if (prev == null || next == null) return;
      if (prev.toString() == next.toString()) return;
      pills.add(_pill(
        '$label: ${_diffVal(prev)} → ${_diffVal(next)}',
        y.text,
      ));
    });
    // class_update scoped branch records the list of field names the
    // manager touched. Render as a single comma-joined pill — the
    // per-class diff isn't meaningful for a bulk edit.
    final fieldsChanged = d['fields_changed'];
    if (fieldsChanged is List && fieldsChanged.isNotEmpty) {
      pills.add(_pill(
        'changed: ${fieldsChanged.join(', ')}',
        y.muted,
      ));
    }

    final affected = <_AffectedUser>[
      for (final raw in (d['affected_users'] as List? ?? const []))
        if (raw is Map)
          _AffectedUser(
            id: (raw['id'] ?? '').toString(),
            name: (raw['name'] ?? '').toString(),
            // Older rows pre-aggregation default to 1 seat / unknown pass.
            seats: (raw['seats'] is int) ? raw['seats'] as int : 1,
            passKind: (raw['pass_kind'] ?? '').toString(),
            plusOneName: (raw['plus_one_name'] ?? '').toString(),
          ),
    ];

    // Did this action affect someone other than the actor? If yes,
    // render a small "for <name>" chip so the row reads as
    // "<actor> did X — for <affected>" instead of relying on the
    // reader to spot the difference between actor name (in the
    // header) and a student name buried in the subject.
    final affectedName = (userName ?? '').trim().isNotEmpty
        ? userName!.trim()
        : (promotedName ?? '').trim();
    final showAffected = affectedName.isNotEmpty &&
        affectedName.toLowerCase() != entry.actorName.toLowerCase() &&
        // class_cancel renders its own affected-users strip below; no
        // need to also tag the row with a single representative name.
        entry.action != 'class_cancel';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (subject != null && subject.isNotEmpty)
          Text(
            subject,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              color: y.text,
            ),
          ),
        if (showAffected) ...[
          const SizedBox(height: 4),
          _AffectedUserChip(name: affectedName, userId: userIdAffected),
        ],
        if (note != null && note.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            note,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: y.muted,
            ),
          ),
        ],
        if (pills.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: pills,
          ),
        ],
        if (entry.action == 'class_cancel' && affected.isNotEmpty) ...[
          const SizedBox(height: 10),
          _AffectedUsersStrip(users: affected),
        ],
      ],
    );
  }

  Widget _pill(String text, Color fg) => Builder(
        builder: (context) {
          final y = context.yoga;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: y.surface2,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: y.border),
            ),
            child: Text(
              text,
              style: TextStyle(
                color: fg,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          );
        },
      );

  static String _money(int minor) => (minor / 100).toStringAsFixed(2);

  /// Format one side of a diff pill. Truncates long strings so the pill
  /// stays readable, renders booleans as on/off, and quotes strings so
  /// "" → "empty" is visible (instead of a blank).
  static String _diffVal(Object v) {
    if (v is bool) return v ? 'on' : 'off';
    final s = v.toString();
    if (s.isEmpty) return '∅';
    if (s.length > 32) return '${s.substring(0, 30)}…';
    return s;
  }
}

/// One affected user, aggregated across parent + +1 booking rows by the
/// server. `seats` is 1 for solo, 2 when a +1 was included; `passKind`
/// drives the "1 credit returned" vs "unlimited pass" copy; `plusOneName`
/// is the friend's name when a +1 was on the parent booking.
/// Small inline chip rendered under the subject of an audit row when
/// the action affected someone other than the actor — e.g. a manager
/// granting a pass to a student. Reads as "for Maya Lopez" with a
/// little avatar so the eye lands on it without needing to parse the
/// subject text. Hidden when actor == affected (the student's own
/// self-bookings, where rendering this would be redundant noise).
class _AffectedUserChip extends StatelessWidget {
  final String name;
  final String? userId;
  const _AffectedUserChip({required this.name, this.userId});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 3, 9, 3),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: y.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'for ',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: y.muted,
            ),
          ),
          YAvatar(name: name, size: 16),
          const SizedBox(width: 5),
          Text(
            name,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: y.text,
            ),
          ),
        ],
      ),
    );
  }
}

class _AffectedUser {
  final String id;
  final String name;
  final int seats;
  final String passKind;
  final String plusOneName;
  const _AffectedUser({
    required this.id,
    required this.name,
    required this.seats,
    required this.passKind,
    required this.plusOneName,
  });
}

/// Affected-users block — shown under a class_cancel audit entry to
/// surface "who lost their seat". Each row reads `<name> · <refund>`
/// so the manager can scan who got what without opening the student
/// detail page; +1 bookings render as "Ben · 2 credits returned (with
/// Friend)". Renders up to ~6 entries with a "+N more" badge.
class _AffectedUsersStrip extends StatelessWidget {
  final List<_AffectedUser> users;
  const _AffectedUsersStrip({required this.users});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    const maxVisible = 6;
    final visible = users.take(maxVisible).toList();
    final extras = users.length - visible.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: y.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'AFFECTED · ${users.length}',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              color: y.muted,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < visible.length; i++)
                Padding(
                  padding: EdgeInsets.only(
                      bottom: i == visible.length - 1 && extras == 0 ? 0 : 6),
                  child: _AffectedUserRow(user: visible[i]),
                ),
              if (extras > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '+$extras more',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: y.muted,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AffectedUserRow extends StatelessWidget {
  final _AffectedUser user;
  const _AffectedUserRow({required this.user});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Row(
      children: [
        YAvatar(name: user.name, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            user.name.isEmpty ? '—' : user.name,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: y.text,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          _refundText(user),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: y.muted,
          ),
        ),
      ],
    );
  }

  /// Per-user refund summary. Credit passes report seat count
  /// ("1 credit returned" / "2 credits returned"); unlimited passes
  /// just say "unlimited pass" since nothing was burned. A +1 booking
  /// appends `(with <friend>)` so the row makes sense without needing
  /// to cross-reference seat counts.
  static String _refundText(_AffectedUser u) {
    String base;
    if (u.passKind == 'credit') {
      base = '${u.seats} credit${u.seats == 1 ? '' : 's'} returned';
    } else if (u.passKind == 'unlimited') {
      base = 'unlimited pass';
    } else {
      // Older rows pre-aggregation (no pass_kind stored) — fall back
      // to seat count without a kind label.
      base = '${u.seats} seat${u.seats == 1 ? '' : 's'}';
    }
    if (u.plusOneName.isNotEmpty) {
      base = '$base (with ${u.plusOneName})';
    }
    return base;
  }
}
