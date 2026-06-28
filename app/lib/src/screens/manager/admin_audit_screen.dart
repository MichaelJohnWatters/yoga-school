// Manager Activity log — read-only viewer for audit_log rows.
// Filter chips switch the action filter (All / Grants / Adjusts / Voids).

import 'dart:async';
import 'dart:convert';

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

final adminClassTemplatesProvider = FutureProvider<List<ClassTemplate>>((
  ref,
) async {
  return ref.watch(apiClientProvider).adminListClassTemplates();
});

class AdminAuditScreen extends ConsumerStatefulWidget {
  const AdminAuditScreen({super.key});

  @override
  ConsumerState<AdminAuditScreen> createState() => _AdminAuditScreenState();
}

class _AdminAuditScreenState extends ConsumerState<AdminAuditScreen> {
  String _filter = 'all';
  // Free-text search — runs SERVER-SIDE (matches actor name / action / detail
  // across the whole table), debounced, so it stays correct across pages.
  String _query = '';

  final _scroll = ScrollController();
  Timer? _pollTimer;
  Timer? _searchDebounce;

  // Keyset-paginated state. _rows accumulates pages; _cursor is the next
  // page's seek token (null = no more). _reqSeq drops out-of-order responses
  // when the filter/search changes faster than requests return.
  List<AuditEntry> _rows = const [];
  String? _cursor;
  bool _hasMore = true;
  bool _loading = true; // first-page (or reset) load in flight
  bool _loadingMore = false;
  Object? _error;
  int _reqSeq = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load(reset: true);
      ref.invalidate(adminClassTemplatesProvider);
      _restartPoll();
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _pollTimer?.cancel();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _restartPoll() {
    _pollTimer?.cancel();
    final i = ref.read(pollingPrefsProvider).intervalFor(PollingSurface.audit);
    if (i == null) return;
    _pollTimer = Timer.periodic(i, (_) {
      // Only auto-refresh when the user is at the top (newest rows). Don't
      // yank them back to page 1 while they're reading older history.
      if (!_scroll.hasClients || _scroll.position.pixels <= 80) {
        _load(reset: true);
      }
      ref.invalidate(adminClassTemplatesProvider);
    });
  }

  /// Load a page. reset=true replaces the list (first page / filter change /
  /// poll); otherwise appends the next page using the cursor.
  Future<void> _load({bool reset = false}) async {
    if (!reset && (_loadingMore || !_hasMore || _loading)) return;
    final seq = ++_reqSeq;
    setState(() {
      if (reset) {
        _loading = true;
        _error = null;
      } else {
        _loadingMore = true;
      }
    });
    try {
      final page = await ref
          .read(apiClientProvider)
          .adminAudit(
            action: _filter,
            search: _query,
            cursor: reset ? null : _cursor,
          );
      if (!mounted || seq != _reqSeq) return;
      setState(() {
        _rows = reset ? page.entries : [..._rows, ...page.entries];
        _cursor = page.nextCursor;
        _hasMore = page.nextCursor != null;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || seq != _reqSeq) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = e;
      });
    }
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 300) {
      _load();
    }
  }

  void _onFilter(String f) {
    if (f == _filter) return;
    setState(() => _filter = f);
    _load(reset: true);
  }

  void _onSearch(String q) {
    setState(() => _query = q);
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      const Duration(milliseconds: 350),
      () => _load(reset: true),
    );
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
    'booking_cancel': 'Cancellations',
    'booking_plus_one': '+1 guests',
    'series_join': 'Series joins',
    'purchase': 'Purchases',
    'purchase_pending': 'Pending purchases',
    // Attendance + waitlist + manager-side bookings
    'attendance_mark': 'Attendance marks',
    'attendance_scan': 'Check-in scans',
    'waitlist_join': 'Waitlist joins',
    'waitlist_leave': 'Waitlist leaves',
    'waitlist_promote': 'Waitlist promotes',
    'waitlist_auto_book': 'Waitlist auto-books',
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
    'user_erased': 'GDPR erasures',
    // Student notes — staff-authored context attached to a student.
    'student_note_create': 'Student notes',
    'student_note_update': 'Student note edits',
    'student_note_delete': 'Student note deletes',
  };

  @override
  Widget build(BuildContext context) {
    final templates = ref.watch(adminClassTemplatesProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
      child: ListView(
        controller: _scroll,
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
                                  _load(reset: true);
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
            child: _AuditSearchBar(value: _query, onChanged: _onSearch),
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
                    onTap: () => _onFilter(entry.key),
                  ),
              ],
            ),
          ),
          _buildContent(context),
        ],
      ),
    );
  }

  /// Paginated audit content: first-load spinner, error, empty state, or the
  /// accumulated rows with a load-more spinner / end-of-log marker.
  Widget _buildContent(BuildContext context) {
    final y = context.yoga;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            "Can't load audit log: ${ApiError.fromAny(_error!).message}",
            style: TextStyle(color: y.muted),
          ),
        ),
      );
    }
    if (_rows.isEmpty) {
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
              color: y.muted,
            ),
          ),
        ),
      );
    }
    return ManagerCard(
      child: Column(
        children: [
          for (var i = 0; i < _rows.length; i++)
            _AuditRow(
              e: _rows[i],
              isLast: i == _rows.length - 1 && !_hasMore && !_loadingMore,
            ),
          if (_loadingMore)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          if (!_hasMore)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '— end of log —',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: y.muted,
                  letterSpacing: 0.4,
                ),
              ),
            ),
        ],
      ),
    );
  }
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
class _AuditRow extends StatefulWidget {
  final AuditEntry e;
  final bool isLast;
  const _AuditRow({required this.e, required this.isLast});

  @override
  State<_AuditRow> createState() => _AuditRowState();
}

class _AuditRowState extends State<_AuditRow> {
  // Tap the row to reveal the full, raw detail payload — everything the
  // server recorded, even fields the curated view above doesn't surface.
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final e = widget.e;
    final reasonOrNote = e.detail['reason'] ?? e.detail['note'];
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          border: widget.isLast
              ? null
              : Border(bottom: BorderSide(color: y.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header — action chip, actor, time, expand affordance.
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
                const SizedBox(width: 4),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: y.muted,
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: y.surface2,
                  borderRadius: BorderRadius.circular(6),
                  border: Border(left: BorderSide(color: y.border, width: 2)),
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
            // Full raw payload — the "nothing hidden" view.
            if (_expanded) ...[
              const SizedBox(height: 10),
              _RawDetailTable(
                detail: e.detail,
                targetType: e.targetType,
                targetId: e.targetId,
                createdAt: e.createdAt,
              ),
            ],
          ],
        ),
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
      'booking_cancel' => ('CANCELLED', Colors.white, red),
      'booking_plus_one' => ('+1 GUEST', y.text, y.accentSoft),
      'series_join' => ('SERIES JOIN', y.onPrimary, y.primary),
      'purchase' => ('PURCHASE', y.onPrimary, y.primary),
      'purchase_pending' => ('PENDING PURCHASE', y.text, y.surface2),
      // Attendance + waitlist + manager-side bookings
      'attendance_mark' => ('ATTENDANCE', y.text, y.surface2),
      'attendance_scan' => ('CHECK-IN', y.text, y.surface2),
      'waitlist_join' => ('WAITLIST JOIN', y.text, y.surface2),
      'waitlist_leave' => ('WAITLIST LEAVE', y.text, y.surface2),
      'waitlist_promote' => ('PROMOTED', y.onPrimary, y.primary),
      'waitlist_auto_book' => ('AUTO-BOOKED', y.onPrimary, y.primary),
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
      'user_erased' => ('GDPR ERASURE', Colors.white, red),
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

/// A one-line, plain-English summary of an audit row, so the Activity log
/// reads as a narrative ("Granted Maya Rowe the 10-pack — cash · £110.")
/// rather than a terse subject + a row of pills. The actor is already in the
/// header, so the sentence is phrased as their action (verb-first). Returns
/// null for actions without bespoke phrasing — the caller then falls back to
/// the structured subject line.
String? _auditNarrative(AuditEntry e) {
  final d = e.detail;
  String str(String k) => (d[k] as String?)?.trim() ?? '';
  int? intg(String k) => d[k] is int ? d[k] as int : null;
  String money(int m) => '£${(m / 100).toStringAsFixed(2)}';
  // Quote a value, or fall back to a generic noun when it's missing.
  String named(String v, String fallback) => v.isEmpty ? fallback : '“$v”';

  final user = str('user_name').isNotEmpty
      ? str('user_name')
      : str('student_name');
  final who = user.isEmpty ? 'a student' : user;
  final poss = user.isEmpty ? "a student's" : "$user's";
  final cls = named(str('class_title'), 'a class');
  final product = str('product_name');

  // " (cash · £110.00)" payment tail, from whichever amount the row carries.
  String paid() {
    final parts = <String>[];
    final pay = str('payment_method');
    if (pay.isNotEmpty) parts.add(pay);
    final amt = intg('amount_minor') ?? intg('price_minor');
    if (amt != null) parts.add(money(amt));
    return parts.isEmpty ? '' : ' (${parts.join(' · ')})';
  }

  switch (e.action) {
    case 'cash_grant':
      return 'Granted $who ${named(product, 'a pass')}${paid()}.';
    case 'credit_adjust':
      final delta = intg('delta');
      final before = d['before'], after = d['after'];
      final move = (before != null && after != null)
          ? ' ($before → $after)'
          : '';
      final ds = delta == null
          ? 'credits'
          : '${delta > 0 ? '+' : ''}$delta credit${delta.abs() == 1 ? '' : 's'}';
      return "Adjusted $poss balance by $ds$move.";
    case 'void':
      final refunded = intg('refunded_minor');
      final opt = str('refund_option');
      final tail = (refunded != null && refunded > 0)
          ? ' — refunded ${money(refunded)}'
          : (opt.isNotEmpty ? ' — $opt refund' : '');
      return 'Voided $poss pass$tail.';
    case 'purchase':
      return 'Bought ${named(product, 'a pass')}${paid()}.';
    case 'purchase_refund':
      final amt = intg('refund_amount_minor') ?? intg('refunded_minor');
      return 'Refunded ${amt != null ? money(amt) : 'a purchase'}.';
    case 'discount_create':
      final code = str('code');
      final v = intg('value');
      return 'Created a discount${code.isEmpty ? '' : ' $code'}'
          '${v != null ? ' ($v% off)' : ''}.';
    case 'discount_archive':
      final code = str('code');
      return 'Archived a discount${code.isEmpty ? '' : ' $code'}.';
    case 'product_create':
      return 'Created product ${named(str('name'), 'a product')}.';
    case 'product_update':
      return 'Edited product ${named(str('name'), 'a product')}.';
    case 'product_archive':
      return 'Archived product ${named(str('name'), 'a product')}.';
    case 'class_create':
      final inst = str('instructor_name');
      final room = str('room_name');
      var out = 'Scheduled ${named(str('title'), 'a class')}';
      if (inst.isNotEmpty) out += ' with $inst';
      if (room.isNotEmpty) out += ' in $room';
      return '$out.';
    case 'class_update':
      final fc = d['fields_changed'];
      final changed = (fc is List && fc.isNotEmpty)
          ? ' (changed ${fc.join(', ')})'
          : '';
      return 'Edited ${named(str('class_title'), 'a class')}$changed.';
    case 'class_cancel':
      final n = intg('bookings_cancelled') ?? 0;
      final cr = intg('credits_returned');
      var out = 'Cancelled ${named(str('class_title'), 'a class')}';
      if (n > 0) out += ' — released $n booking${n == 1 ? '' : 's'}';
      if (cr != null && cr > 0) {
        out += '${n > 0 ? ',' : ' —'} returned $cr credit${cr == 1 ? '' : 's'}';
      }
      return '$out.';
    case 'class_type_create':
      return 'Created class type ${named(str('name'), '')}.'.replaceAll(
        ' .',
        '.',
      );
    case 'class_type_update':
      return 'Edited class type ${named(str('name'), '')}.'.replaceAll(
        ' .',
        '.',
      );
    case 'rule_create':
      final ses = intg('sessions');
      return 'Set up a recurring class ${named(str('title'), '')}'
              '${ses != null ? ' ($ses sessions)' : ''}.'
          .replaceAll('  ', ' ');
    case 'series_create':
      final t = str('enrollment_title').isEmpty
          ? str('title')
          : str('enrollment_title');
      return 'Created the ${named(t, 'a')} series.';
    case 'series_update':
      return 'Edited the ${named(str('enrollment_title'), '')} series.';
    case 'series_join':
      return 'Joined the ${named(str('enrollment_title'), '')} series.';
    case 'template_create':
      final ses = intg('total_classes') ?? intg('generated_classes');
      final wk = intg('weeks');
      var out = 'Created a class template ${named(str('title'), '')}'
          .trimRight();
      if (ses != null && wk != null) {
        out += ' — $ses sessions over $wk weeks';
      }
      return '$out.';
    case 'booking_create':
      return 'Booked $cls.';
    case 'booking_create_admin':
      return 'Booked $who into $cls.';
    case 'booking_cancel':
      final friend = str('friend_name');
      final outcome = str('outcome');
      final f = friend.isEmpty ? '' : ' (with $friend)';
      var tail = '';
      if (outcome == 'cancelled_late_burned') {
        tail = ' — credit burned';
      } else if (outcome == 'cancelled_free') {
        tail = ' — credit returned';
      }
      return 'Cancelled $cls$f$tail.';
    case 'booking_plus_one':
      final friend = str('friend_name');
      return 'Brought a +1${friend.isEmpty ? '' : ' ($friend)'} to $cls.';
    case 'attendance_mark':
      final st = str('status');
      final label = st == 'no_show'
          ? 'a no-show'
          : (st.isEmpty ? 'attended' : st);
      return 'Marked $who $label for $cls.';
    case 'waitlist_join':
      return 'Joined the waitlist for $cls.';
    case 'waitlist_leave':
      return 'Left the waitlist for $cls.';
    case 'waitlist_promote':
    case 'waitlist_auto_book':
      final p = str('promoted_user_name');
      final verb = e.action == 'waitlist_promote' ? 'Promoted' : 'Auto-booked';
      return '$verb ${p.isEmpty ? 'the next waiter' : p} off the waitlist into $cls.';
    case 'staff_create':
      final n = [
        str('full_name'),
        str('name'),
        str('email'),
      ].firstWhere((v) => v.isNotEmpty, orElse: () => '');
      final role = str('role');
      return 'Added staff${n.isEmpty ? '' : ' $n'}'
          '${role.isEmpty ? '' : ' ($role)'}.';
    case 'staff_update':
      final n = [
        str('full_name'),
        str('name'),
        str('email'),
      ].firstWhere((v) => v.isNotEmpty, orElse: () => '');
      return 'Updated staff${n.isEmpty ? '' : ' $n'}.';
    case 'theme_create':
      return 'Created theme ${named(str('name'), '')}.'.replaceAll(' .', '.');
    case 'theme_update':
      return 'Edited theme ${named(str('name'), '')}.'.replaceAll(' .', '.');
    case 'theme_activate':
      return 'Activated theme ${named(str('name'), '')}.'.replaceAll(' .', '.');
    case 'studio_config_update':
      return 'Updated the studio settings.';
    case 'stripe_credentials_update':
      return 'Updated the Stripe credentials.';
    case 'student_note_create':
      return 'Added a note${user.isEmpty ? '' : ' on $user'}.';
    case 'student_note_update':
      return 'Edited a student note.';
    case 'student_note_delete':
      return 'Deleted a student note.';
    case 'conversation_create':
      return 'Started the ${named(str('title'), 'a')} group chat.';
    case 'dm_open':
      return 'Opened a direct message.';
    case 'message_send':
      return 'Sent a chat message.';
    case 'class_chat_create':
      return 'Opened the class chat${str('class_title').isEmpty ? '' : ' for $cls'}.';
    case 'user_erased':
      return "Erased a student's personal data (GDPR Art. 17).";
  }
  return null;
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
    final userName =
        (d['user_name'] as String?) ?? (d['student_name'] as String?);
    final userIdAffected =
        (d['user_id'] as String?) ?? (d['student_id'] as String?);
    final promotedName = d['promoted_user_name'] as String?;
    final mode = d['mode'] as String?;
    final slot = d['slot'] as String?;
    final scope = d['scope'] as String?;
    final status = d['status'] as String?;
    final via = d['via'] as String?;
    final finalStatus = d['final_status'] as String?;
    final note = d['note'] as String?;
    // Newly-surfaced fields that were captured but previously hidden.
    final outcome = d['outcome'] as String?; // booking_cancel free/burned
    final friendName = d['friend_name'] as String?; // +1 guest name
    final addedAfterBooking = d['added_after_booking'] == true;
    final refundOption = d['refund_option'] as String?; // void
    final before = d['before']; // credit_adjust balance before…
    final after = d['after']; // …and after
    final notificationsSent = d['notifications_sent'] as int?; // class_cancel
    final waitlistCleared = d['waitlist_cleared'] as int?; // class_cancel

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
      case 'user_erased':
        subject = 'Student data erased (GDPR Art. 17)';
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
      pills.add(
        _pill('$cancelled booking${cancelled == 1 ? '' : 's'} released', red),
      );
    }
    if (creditsReturned != null && creditsReturned > 0) {
      pills.add(
        _pill(
          '$creditsReturned credit${creditsReturned == 1 ? '' : 's'} returned',
          y.text,
        ),
      );
    }
    if (templateTotal != null) {
      pills.add(
        _pill(
          '$templateTotal session${templateTotal == 1 ? '' : 's'} cancelled',
          red,
        ),
      );
    }
    if (classesUpdated != null && classesUpdated > 0) {
      pills.add(
        _pill(
          '$classesUpdated class${classesUpdated == 1 ? '' : 'es'} updated',
          y.text,
        ),
      );
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
    // Cancel outcome — did the credit get burned (late) or returned (free)?
    if (outcome == 'cancelled_late_burned') {
      pills.add(_pill('credit burned', red));
    } else if (outcome == 'cancelled_free') {
      pills.add(_pill('free cancel', y.muted));
    }
    // The +1 guest's name — on the add row and on a cancel that cascaded one.
    if (friendName != null && friendName.isNotEmpty) {
      pills.add(_pill('with $friendName', y.text));
    }
    if (addedAfterBooking) pills.add(_pill('added after booking', y.muted));
    // Credit adjust: the absolute balance move, not just the delta pill.
    if (before != null && after != null) {
      pills.add(_pill('$before → $after credits', y.text));
    }
    // Void: which refund option the manager chose.
    if (refundOption != null && refundOption.isNotEmpty) {
      pills.add(_pill('refund: $refundOption', y.text));
    }
    // Class-cancel fan-out counts.
    if (notificationsSent != null && notificationsSent > 0) {
      pills.add(_pill('$notificationsSent notified', y.muted));
    }
    if (waitlistCleared != null && waitlistCleared > 0) {
      pills.add(_pill('$waitlistCleared waitlist cleared', y.muted));
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
      pills.add(
        _pill(
          refunded ? 'credit returned' : 'credit consumed',
          refunded ? y.text : red,
        ),
      );
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
      'booking_window_days': 'book-ahead',
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
      pills.add(_pill('$label: ${_diffVal(prev)} → ${_diffVal(next)}', y.text));
    });
    // class_update scoped branch records the list of field names the
    // manager touched. Render as a single comma-joined pill — the
    // per-class diff isn't meaningful for a bulk edit.
    final fieldsChanged = d['fields_changed'];
    if (fieldsChanged is List && fieldsChanged.isNotEmpty) {
      pills.add(_pill('changed: ${fieldsChanged.join(', ')}', y.muted));
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
    final showAffected =
        affectedName.isNotEmpty &&
        affectedName.toLowerCase() != entry.actorName.toLowerCase() &&
        // class_cancel renders its own affected-users strip below; no
        // need to also tag the row with a single representative name.
        entry.action != 'class_cancel';

    // Plain-English narrative leads the row; the structured subject is the
    // fallback when an action has no bespoke sentence. When a narrative is
    // shown it already names the affected person, so the "for <name>" chip
    // would be redundant.
    final narrative = _auditNarrative(entry);
    final hasNarrative = narrative != null && narrative.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasNarrative)
          Text(
            narrative,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: y.text,
              height: 1.4,
            ),
          )
        else if (subject != null && subject.isNotEmpty)
          Text(
            subject,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              color: y.text,
            ),
          ),
        if (showAffected && !hasNarrative) ...[
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
          Wrap(spacing: 6, runSpacing: 6, children: pills),
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

/// The full, raw audit payload — shown when a row is expanded. Renders every
/// `detail` key as a humanised "label · value" line (plus the target + exact
/// timestamp), so nothing the server recorded is unreachable. Scalars format
/// nicely (money, booleans, IDs); nested lists/maps fall back to compact JSON.
class _RawDetailTable extends StatelessWidget {
  final Map<String, dynamic> detail;
  final String targetType;
  final String targetId;
  final DateTime createdAt;
  const _RawDetailTable({
    required this.detail,
    required this.targetType,
    required this.targetId,
    required this.createdAt,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final keys = detail.keys.toList()..sort();
    final rows = <Widget>[
      _kv(
        y,
        'target',
        targetId.isEmpty ? targetType : '$targetType · $targetId',
      ),
      _kv(y, 'at', createdAt.toLocal().toString()),
      for (final k in keys) _kv(y, _humanizeKey(k), _formatValue(k, detail[k])),
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: y.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'RAW DETAIL',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              color: y.muted,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 5),
            rows[i],
          ],
        ],
      ),
    );
  }

  Widget _kv(YogaTokens y, String label, String value) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 132,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: y.muted,
          ),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: SelectableText(
          value,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: y.text,
            height: 1.35,
          ),
        ),
      ),
    ],
  );

  static String _humanizeKey(String k) => k.replaceAll('_', ' ');

  /// Pretty-print a single detail value. Money keys (`*_minor`) render as
  /// currency; booleans as yes/no; null as ∅; lists/maps as compact JSON.
  static String _formatValue(String key, Object? v) {
    if (v == null) return '∅';
    if (v is bool) return v ? 'yes' : 'no';
    if (v is num && key.endsWith('_minor')) {
      return '£${(v / 100).toStringAsFixed(2)}';
    }
    if (v is String) return v.isEmpty ? '∅' : v;
    if (v is num) return v.toString();
    // Lists / maps (e.g. affected_users, fields_changed) → compact JSON.
    try {
      return const JsonEncoder.withIndent('  ').convert(v);
    } catch (_) {
      return v.toString();
    }
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
                    bottom: i == visible.length - 1 && extras == 0 ? 0 : 6,
                  ),
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
