// Manager Reports — month stats + revenue stacked bars + instructor pay.
// Card revenue = solid primary bottom; cash = accentSoft on top with a 2 px
// accent top edge (per the design's KReports spec).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../export/csv_download.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'manager_shell.dart';

/// Assembles the combined report from the three range-aware endpoints, keyed by
/// the selected window, so the existing widgets keep consuming a single
/// [AdminReports]. Keyed by [ReportRange] (with value equality) so each window
/// caches independently and a re-selected preset reuses its payload.
final adminReportsProvider = FutureProvider.family<AdminReports, ReportRange>((
  ref,
  range,
) async {
  final api = ref.watch(apiClientProvider);
  final results = await Future.wait<Object>([
    api.revenueReport(
      from: range.from,
      to: range.to,
      granularity: range.granularity,
    ),
    api.attendanceReport(from: range.from, to: range.to),
    api.instructorPayReport(from: range.from, to: range.to),
  ]);
  final rev = results[0] as RevenueReport;
  final att = results[1] as AttendanceReport;
  final pay = results[2] as InstructorPayReport;
  return AdminReports(
    revenueMonth: rev.month,
    revenueByWeek: rev.byWeek,
    avgOccupancyPct: att.avgOccupancyPct,
    noShowRatePct: att.noShowRatePct,
    instructorPay: pay.rows,
  );
});

/// Filter key for the customer report. Value equality lets each
/// (window, sort, search) combination cache independently.
class CustomerQuery {
  final ReportRange range;
  final String sort;
  final String q;
  const CustomerQuery({
    required this.range,
    required this.sort,
    required this.q,
  });

  @override
  bool operator ==(Object other) =>
      other is CustomerQuery &&
      other.range == range &&
      other.sort == sort &&
      other.q == q;

  @override
  int get hashCode => Object.hash(range, sort, q);
}

final customerReportProvider =
    FutureProvider.family<CustomerReport, CustomerQuery>((ref, query) async {
      return ref
          .watch(apiClientProvider)
          .customerReport(
            from: query.range.from,
            to: query.range.to,
            sort: query.sort,
            q: query.q,
          );
    });

final builderSchemaProvider = FutureProvider<List<BuilderDataset>>((ref) async {
  return ref.watch(apiClientProvider).builderSchema();
});

class AdminReportsScreen extends ConsumerStatefulWidget {
  const AdminReportsScreen({super.key});

  @override
  ConsumerState<AdminReportsScreen> createState() => _AdminReportsScreenState();
}

enum _ReportTab { overview, customers, builder }

class _AdminReportsScreenState extends ConsumerState<AdminReportsScreen> {
  ReportRange _range = ReportRange.last12Weeks();
  _ReportTab _tab = _ReportTab.overview;

  @override
  Widget build(BuildContext context) {
    // The range bar applies to the overview and customers tabs; the builder
    // carries its own filters.
    final showRange = _tab != _ReportTab.builder;
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ManagerPageHeader(
            title: 'Reports',
            sub: 'Revenue, attendance, customers & ad-hoc queries',
            actions: _tab == _ReportTab.overview
                ? [_ExportButton(range: _range)]
                : null,
          ),
          _TabBar(current: _tab, onChanged: (t) => setState(() => _tab = t)),
          const SizedBox(height: 16),
          if (showRange) ...[
            _RangeBar(
              current: _range,
              onChanged: (r) => setState(() => _range = r),
            ),
            const SizedBox(height: 18),
          ],
          Expanded(child: _tabBody()),
        ],
      ),
    );
  }

  Widget _tabBody() {
    switch (_tab) {
      case _ReportTab.overview:
        final data = ref.watch(adminReportsProvider(_range));
        return RefreshOnMount(
          onMount: () => ref.invalidate(adminReportsProvider(_range)),
          child: data.when(
            data: (r) => _Body(r: r),
            loading: () =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (e, _) => Center(
              child: Text(
                "Can't load reports: ${ApiError.fromAny(e).message}",
                style: TextStyle(color: context.yoga.muted),
              ),
            ),
          ),
        );
      case _ReportTab.customers:
        return _CustomersView(range: _range);
      case _ReportTab.builder:
        return const _BuilderView();
    }
  }
}

/// Segmented control switching between the report facets.
class _TabBar extends StatelessWidget {
  final _ReportTab current;
  final ValueChanged<_ReportTab> onChanged;
  const _TabBar({required this.current, required this.onChanged});

  static const _labels = {
    _ReportTab.overview: 'Overview',
    _ReportTab.customers: 'Customers',
    _ReportTab.builder: 'Builder',
  };

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(y.radiusChip + 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final t in _ReportTab.values)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onChanged(t),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: current == t ? y.surface : Colors.transparent,
                  borderRadius: BorderRadius.circular(y.radiusChip),
                ),
                child: Text(
                  _labels[t]!,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: current == t ? y.text : y.muted,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final AdminReports r;
  const _Body({required this.r});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        _StatsRow(r: r),
        const SizedBox(height: 16),
        ManagerCard(
          title: 'Revenue',
          action:
              '${_currencyLabel(r.revenueMonth.currency)} · ${r.revenueMonth.monthLabel}',
          child: _RevenueChart(
            weeks: r.revenueByWeek,
            currency: r.revenueMonth.currency,
          ),
        ),
        const SizedBox(height: 16),
        ManagerCard(
          title: 'Instructor pay',
          action: r.revenueMonth.monthLabel,
          child: _InstructorPayTable(
            rows: r.instructorPay,
            currency: r.revenueMonth.currency,
          ),
        ),
      ],
    );
  }

  static String _currencyLabel(String c) => switch (c) {
    'GBP' => 'GBP',
    'USD' => 'USD',
    'EUR' => 'EUR',
    _ => c,
  };
}

class _StatsRow extends StatelessWidget {
  final AdminReports r;
  const _StatsRow({required this.r});

  @override
  Widget build(BuildContext context) {
    final rev = r.revenueMonth;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ManagerStat(
              label: 'Revenue · ${rev.monthLabel}',
              value: _fmt(rev.totalMinor, rev.currency),
              sub:
                  '${_fmt(rev.cardMinor, rev.currency)} card · ${_fmt(rev.cashMinor, rev.currency)} cash',
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: ManagerStat(
              label: 'Avg occupancy',
              value: '${r.avgOccupancyPct}%',
              sub: r.avgOccupancyPct >= 75
                  ? 'Strong — classes feel full'
                  : 'Headroom for growth',
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: ManagerStat(
              label: 'No-show rate',
              value: '${r.noShowRatePct}%',
              accent: r.noShowRatePct >= 10,
              sub: r.noShowRatePct >= 10
                  ? 'Worth a look at cancellation policy'
                  : 'Healthy',
            ),
          ),
        ],
      ),
    );
  }
}

class _RevenueChart extends StatelessWidget {
  final List<ReportWeekRevenue> weeks;
  final String currency;
  const _RevenueChart({required this.weeks, required this.currency});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final maxTotal = weeks.fold<int>(0, (m, w) => w.total > m ? w.total : m);
    final hasAny = maxTotal > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 180,
          child: hasAny
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var i = 0; i < weeks.length; i++) ...[
                      Expanded(
                        child: _WeekBar(
                          card: weeks[i].cardMinor,
                          cash: weeks[i].cashMinor,
                          maxTotal: maxTotal,
                        ),
                      ),
                      if (i < weeks.length - 1) const SizedBox(width: 6),
                    ],
                  ],
                )
              : Center(
                  child: Text(
                    'No revenue yet — make a sale to fill this chart.',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: y.muted,
                    ),
                  ),
                ),
        ),
        const SizedBox(height: 8),
        if (hasAny)
          Row(
            children: [
              for (var i = 0; i < weeks.length; i++) ...[
                Expanded(
                  child: Text(
                    _shortLabel(weeks[i].weekStart),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: y.muted,
                    ),
                  ),
                ),
                if (i < weeks.length - 1) const SizedBox(width: 6),
              ],
            ],
          ),
        const SizedBox(height: 14),
        Row(
          children: [
            _LegendDot(color: y.primary, label: 'Card'),
            const SizedBox(width: 18),
            _LegendDot(color: y.accent, label: 'Cash', dim: true),
            const Spacer(),
            Text(
              'Peak: ${_fmt(maxTotal, currency)}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: y.muted,
              ),
            ),
          ],
        ),
      ],
    );
  }

  static String _shortLabel(String iso) {
    // YYYY-MM-DD → "23 Mar"
    final parts = iso.split('-');
    if (parts.length < 3) return iso;
    const mons = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final m = int.tryParse(parts[1]) ?? 1;
    final d = int.tryParse(parts[2]) ?? 1;
    return '$d ${mons[m - 1]}';
  }
}

class _WeekBar extends StatelessWidget {
  final int card;
  final int cash;
  final int maxTotal;
  const _WeekBar({
    required this.card,
    required this.cash,
    required this.maxTotal,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final total = card + cash;
    if (total == 0) {
      return Container(
        height: 4,
        decoration: BoxDecoration(
          color: y.surface2,
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }
    final maxBarHeight = 170.0;
    final ratio = total / maxTotal;
    final barHeight = (ratio * maxBarHeight).clamp(8.0, maxBarHeight);
    final cardHeight = total == 0 ? 0.0 : barHeight * (card / total);
    final cashHeight = barHeight - cardHeight;
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (cash > 0)
          Container(
            height: cashHeight,
            decoration: BoxDecoration(
              color: y.accentSoft,
              border: Border(top: BorderSide(color: y.accent, width: 2)),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(3),
                topRight: Radius.circular(3),
              ),
            ),
          ),
        Container(
          height: cardHeight,
          decoration: BoxDecoration(
            color: y.primary,
            borderRadius: cash > 0
                ? const BorderRadius.only(
                    bottomLeft: Radius.circular(3),
                    bottomRight: Radius.circular(3),
                  )
                : const BorderRadius.all(Radius.circular(3)),
          ),
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  final bool dim;
  const _LegendDot({
    required this.color,
    required this.label,
    this.dim = false,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: dim ? color.withValues(alpha: 0.25) : color,
            border: dim ? Border.all(color: color, width: 2) : null,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: y.muted,
          ),
        ),
      ],
    );
  }
}

class _InstructorPayTable extends StatelessWidget {
  final List<ReportInstructorPay> rows;
  final String currency;
  const _InstructorPayTable({required this.rows, required this.currency});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          'No instructors yet.',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: y.muted,
          ),
        ),
      );
    }
    return Column(
      children: [
        _Head(),
        for (var i = 0; i < rows.length; i++)
          _Row(r: rows[i], currency: currency, isLast: i == rows.length - 1),
        const SizedBox(height: 12),
        Text(
          'Pay = classes taught × each instructor\'s per-class rate.',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            color: y.muted,
          ),
        ),
      ],
    );
  }
}

class _Head extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final s = TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w700,
      color: y.muted,
      letterSpacing: 0.6,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Row(
        children: [
          Expanded(flex: 14, child: Text('INSTRUCTOR', style: s)),
          const SizedBox(width: 12),
          SizedBox(width: 140, child: Text('CLASSES TAUGHT', style: s)),
          const SizedBox(width: 12),
          SizedBox(
            width: 120,
            child: Text('PAY', style: s, textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final ReportInstructorPay r;
  final String currency;
  final bool isLast;
  const _Row({required this.r, required this.currency, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: y.border)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 14,
            child: Text(
              r.fullName,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: y.text,
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 140,
            child: Text(
              '${r.classesTaught}',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: y.muted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 120,
            child: Text(
              _fmt(r.payMinor, currency),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: y.text,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _fmt(int minor, String currency) {
  final symbol = switch (currency) {
    'GBP' => '£',
    'USD' => '\$',
    'EUR' => '€',
    _ => '$currency ',
  };
  final whole = minor ~/ 100;
  final cents = minor % 100;
  final body = cents == 0
      ? '$whole'
      : '$whole.${cents.toString().padLeft(2, '0')}';
  return '$symbol$body';
}

// ---- Time selection -------------------------------------------------------

/// A reporting window. [to] is exclusive. [granularity] is one of
/// 'day'|'week'|'month' and tells the server how to bucket the revenue chart.
class ReportRange {
  final DateTime from;
  final DateTime to;
  final String granularity;
  final String label;
  const ReportRange({
    required this.from,
    required this.to,
    required this.granularity,
    required this.label,
  });

  static DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);
  static DateTime _mondayOf(DateTime d) {
    final day = _dayOf(d);
    return day.subtract(Duration(days: day.weekday - 1)); // Mon=1
  }

  /// Mon-aligned 12-week window ending after the current week — preserves the
  /// screen's original default view.
  factory ReportRange.last12Weeks() {
    final thisMonday = _mondayOf(DateTime.now());
    return ReportRange(
      from: thisMonday.subtract(const Duration(days: 7 * 11)),
      to: thisMonday.add(const Duration(days: 7)),
      granularity: 'week',
      label: 'Last 12 weeks',
    );
  }

  factory ReportRange.thisMonth() {
    final now = DateTime.now();
    return ReportRange(
      from: DateTime(now.year, now.month, 1),
      to: DateTime(now.year, now.month + 1, 1),
      granularity: 'week',
      label: 'This month',
    );
  }

  factory ReportRange.last30Days() {
    final to = _dayOf(DateTime.now()).add(const Duration(days: 1));
    return ReportRange(
      from: to.subtract(const Duration(days: 30)),
      to: to,
      granularity: 'day',
      label: 'Last 30 days',
    );
  }

  factory ReportRange.thisYear() {
    final now = DateTime.now();
    return ReportRange(
      from: DateTime(now.year, 1, 1),
      to: DateTime(now.year + 1, 1, 1),
      granularity: 'month',
      label: 'This year',
    );
  }

  /// [toInclusive] is the last day the manager picked; stored as an exclusive
  /// bound. Granularity is chosen to keep the bucket count sensible.
  factory ReportRange.custom(DateTime from, DateTime toInclusive) {
    final f = _dayOf(from);
    final t = _dayOf(toInclusive).add(const Duration(days: 1));
    final span = t.difference(f).inDays;
    final g = span <= 31 ? 'day' : (span <= 120 ? 'week' : 'month');
    return ReportRange(from: f, to: t, granularity: g, label: 'Custom');
  }

  /// "1 Jun – 30 Jun" style label for the inclusive window.
  String get rangeText {
    const mon = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final a = from;
    final b = to.subtract(const Duration(days: 1));
    return '${a.day} ${mon[a.month - 1]} – ${b.day} ${mon[b.month - 1]}';
  }

  @override
  bool operator ==(Object other) =>
      other is ReportRange &&
      other.from == from &&
      other.to == to &&
      other.granularity == granularity &&
      other.label == label;

  @override
  int get hashCode => Object.hash(from, to, granularity, label);
}

class _RangeBar extends StatelessWidget {
  final ReportRange current;
  final ValueChanged<ReportRange> onChanged;
  const _RangeBar({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final presets = <ReportRange>[
      ReportRange.thisMonth(),
      ReportRange.last30Days(),
      ReportRange.last12Weeks(),
      ReportRange.thisYear(),
    ];
    void set(ReportRange r) => onChanged(r);

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final p in presets)
          _PresetChip(
            label: p.label,
            selected: current.label == p.label,
            onTap: () => set(p),
          ),
        _PresetChip(
          label: current.label == 'Custom' ? current.rangeText : 'Custom…',
          selected: current.label == 'Custom',
          onTap: () async {
            final picked = await showDateRangePicker(
              context: context,
              firstDate: DateTime(2020),
              lastDate: DateTime.now().add(const Duration(days: 1)),
              initialDateRange: DateTimeRange(
                start: current.from,
                end: current.to.subtract(const Duration(days: 1)),
              ),
            );
            if (picked != null) {
              set(ReportRange.custom(picked.start, picked.end));
            }
          },
        ),
      ],
    );
  }
}

// ---- Customers tab --------------------------------------------------------

class _CustomersView extends ConsumerStatefulWidget {
  final ReportRange range;
  const _CustomersView({required this.range});

  @override
  ConsumerState<_CustomersView> createState() => _CustomersViewState();
}

class _CustomersViewState extends ConsumerState<_CustomersView> {
  String _sort = 'spend';
  String _q = '';
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _q = v.trim());
    });
  }

  Future<void> _export() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final bytes = await ref
          .read(apiClientProvider)
          .reportCsv(
            '/admin/reports/customers',
            from: widget.range.from,
            to: widget.range.to,
            sort: _sort,
            q: _q,
          );
      await downloadCsv('customers.csv', bytes);
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Export failed: ${ApiError.fromAny(e).message}'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final query = CustomerQuery(range: widget.range, sort: _sort, q: _q);
    final data = ref.watch(customerReportProvider(query));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _SearchBox(onChanged: _onSearch)),
            const SizedBox(width: 12),
            _SortDropdown(
              value: _sort,
              onChanged: (v) => setState(() => _sort = v),
            ),
            const SizedBox(width: 12),
            _OutlineAction(
              icon: Icons.file_download_outlined,
              label: 'Export',
              onTap: _export,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: data.when(
            data: (rep) => _CustomerTable(rep: rep),
            loading: () =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (e, _) => Center(
              child: Text(
                "Can't load customers: ${ApiError.fromAny(e).message}",
                style: TextStyle(color: y.muted),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SearchBox extends StatelessWidget {
  final ValueChanged<String> onChanged;
  const _SearchBox({required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return TextField(
      onChanged: onChanged,
      style: TextStyle(fontSize: 14, color: y.text),
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Search name or email',
        hintStyle: TextStyle(color: y.muted, fontSize: 14),
        prefixIcon: Icon(Icons.search, size: 18, color: y.muted),
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
        filled: true,
        fillColor: y.surface2,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(y.radiusChip),
          borderSide: BorderSide(color: y.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(y.radiusChip),
          borderSide: BorderSide(color: y.border),
        ),
      ),
    );
  }
}

class _SortDropdown extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _SortDropdown({required this.value, required this.onChanged});

  static const _options = {
    'spend': 'Top spend',
    'visits': 'Most visits',
    'no_shows': 'Most no-shows',
    'name': 'Name (A–Z)',
  };

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(y.radiusChip),
        border: Border.all(color: y.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isDense: true,
          icon: Icon(Icons.unfold_more, size: 16, color: y.muted),
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: y.text,
          ),
          dropdownColor: y.surface,
          items: [
            for (final e in _options.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value)),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}

class _CustomerTable extends StatelessWidget {
  final CustomerReport rep;
  const _CustomerTable({required this.rep});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    if (rep.rows.isEmpty) {
      return Center(
        child: Text(
          'No customers match this window.',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: y.muted,
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        final narrow = c.maxWidth < 720;
        return ManagerCard(
          fill: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CustomerHead(narrow: narrow),
              const SizedBox(height: 6),
              Expanded(
                child: ListView.builder(
                  itemCount: rep.rows.length,
                  itemBuilder: (_, i) => _CustomerRow(
                    row: rep.rows[i],
                    currency: rep.currency,
                    narrow: narrow,
                    isLast: i == rep.rows.length - 1,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CustomerHead extends StatelessWidget {
  final bool narrow;
  const _CustomerHead({required this.narrow});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final s = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      color: y.muted,
      letterSpacing: 0.6,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Row(
        children: [
          Expanded(flex: 12, child: Text('CUSTOMER', style: s)),
          if (!narrow) ...[
            const SizedBox(width: 10),
            SizedBox(width: 90, child: Text('VISITS', style: s)),
            const SizedBox(width: 10),
            SizedBox(width: 90, child: Text('NO-SHOWS', style: s)),
          ],
          const SizedBox(width: 10),
          SizedBox(
            width: 100,
            child: Text('SPEND', style: s, textAlign: TextAlign.right),
          ),
          const SizedBox(width: 10),
          SizedBox(width: 96, child: Text('PASS', style: s)),
        ],
      ),
    );
  }
}

class _CustomerRow extends StatelessWidget {
  final CustomerReportRow row;
  final String currency;
  final bool narrow;
  final bool isLast;
  const _CustomerRow({
    required this.row,
    required this.currency,
    required this.narrow,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final numStyle = TextStyle(
      fontSize: 13.5,
      fontWeight: FontWeight.w600,
      color: y.muted,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 11),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: y.border)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.fullName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: y.text,
                  ),
                ),
                Text(
                  narrow
                      ? '${row.visits} visits · ${row.noShows} no-shows'
                      : row.email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: y.muted),
                ),
              ],
            ),
          ),
          if (!narrow) ...[
            const SizedBox(width: 10),
            SizedBox(width: 90, child: Text('${row.visits}', style: numStyle)),
            const SizedBox(width: 10),
            SizedBox(
              width: 90,
              child: Text(
                '${row.noShows}',
                style: numStyle.copyWith(
                  color: row.noShows > 0 ? y.accent : y.muted,
                ),
              ),
            ),
          ],
          const SizedBox(width: 10),
          SizedBox(
            width: 100,
            child: Text(
              _fmt(row.spendMinor, currency),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: y.text,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 96,
            child: Text(
              row.activePassLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: y.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Outline icon+label action button (export, run, etc.).
class _OutlineAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _OutlineAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(y.radiusChip),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(y.radiusChip),
            border: Border.all(color: y.borderStrong),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: y.text),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: y.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Header action that downloads the current range as CSV. Offers the two
/// row-shaped reports (revenue buckets + instructor pay) via a small menu.
class _ExportButton extends ConsumerWidget {
  final ReportRange range;
  const _ExportButton({required this.range});

  Future<void> _export(
    BuildContext context,
    WidgetRef ref,
    String path,
    String filename,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final bytes = await ref
          .read(apiClientProvider)
          .reportCsv(
            path,
            from: range.from,
            to: range.to,
            granularity: range.granularity,
          );
      await downloadCsv(filename, bytes);
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Export failed: ${ApiError.fromAny(e).message}'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    return PopupMenuButton<String>(
      tooltip: 'Export CSV',
      onSelected: (v) => switch (v) {
        'revenue' => _export(
          context,
          ref,
          '/admin/reports/revenue',
          'revenue.csv',
        ),
        _ => _export(
          context,
          ref,
          '/admin/reports/instructor-pay',
          'instructor-pay.csv',
        ),
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'revenue', child: Text('Export revenue')),
        PopupMenuItem(value: 'pay', child: Text('Export instructor pay')),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(y.radiusChip),
          border: Border.all(color: y.borderStrong),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.file_download_outlined, size: 16, color: y.text),
            const SizedBox(width: 6),
            Text(
              'Export',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: y.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Builder tab ----------------------------------------------------------

/// One in-progress filter condition the manager is editing. Mutable because the
/// row's three controls update independently before the query runs.
class _FilterCond {
  String? field;
  String? op;
  String value = '';
}

const _opLabels = {
  'eq': '=',
  'ne': '≠',
  'gt': '>',
  'gte': '≥',
  'lt': '<',
  'lte': '≤',
  'contains': 'contains',
};

class _BuilderView extends ConsumerStatefulWidget {
  const _BuilderView();

  @override
  ConsumerState<_BuilderView> createState() => _BuilderViewState();
}

class _BuilderViewState extends ConsumerState<_BuilderView> {
  BuilderDataset? _ds;
  Set<String> _cols = {};
  final List<_FilterCond> _filters = [];
  String? _sort;
  bool _sortDesc = true;

  BuilderResult? _result;
  bool _running = false;
  String? _runError;

  void _selectDataset(BuilderDataset ds) {
    setState(() {
      _ds = ds;
      _cols = ds.columns.map((c) => c.key).toSet();
      _filters.clear();
      _sort = null;
      _result = null;
      _runError = null;
    });
  }

  Map<String, dynamic> _spec() => {
    'dataset': _ds!.key,
    'columns': _cols.toList(),
    'filters': [
      for (final f in _filters)
        if (f.field != null && f.op != null)
          {'field': f.field, 'operator': f.op, 'value': f.value},
    ],
    if (_sort != null) ...{
      'sort': _sort,
      'sort_dir': _sortDesc ? 'desc' : 'asc',
    },
  };

  Future<void> _run() async {
    if (_ds == null || _cols.isEmpty) return;
    setState(() {
      _running = true;
      _runError = null;
    });
    try {
      final res = await ref.read(apiClientProvider).runBuilder(_spec());
      if (mounted) setState(() => _result = res);
    } catch (e) {
      if (mounted) setState(() => _runError = ApiError.fromAny(e).message);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _export() async {
    if (_ds == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final bytes = await ref.read(apiClientProvider).runBuilderCsv(_spec());
      await downloadCsv('report.csv', bytes);
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Export failed: ${ApiError.fromAny(e).message}'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final schema = ref.watch(builderSchemaProvider);
    return schema.when(
      data: (datasets) {
        if (datasets.isEmpty) {
          return Center(
            child: Text(
              'No datasets available.',
              style: TextStyle(color: y.muted),
            ),
          );
        }
        if (_ds == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _ds == null) _selectDataset(datasets.first);
          });
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        return ListView(
          children: [
            _config(context, datasets),
            const SizedBox(height: 16),
            ManagerCard(title: 'Results', child: _results(context)),
          ],
        );
      },
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (e, _) => Center(
        child: Text(
          "Can't load builder: ${ApiError.fromAny(e).message}",
          style: TextStyle(color: y.muted),
        ),
      ),
    );
  }

  Widget _config(BuildContext context, List<BuilderDataset> datasets) {
    final ds = _ds!;
    return ManagerCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Dataset picker.
          Row(
            children: [
              _FieldLabel('Dataset'),
              const SizedBox(width: 12),
              _Dropdown<String>(
                value: ds.key,
                items: {for (final d in datasets) d.key: d.label},
                onChanged: (k) {
                  final next = datasets.firstWhere((d) => d.key == k);
                  _selectDataset(next);
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          _FieldLabel('Columns'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in ds.columns)
                _PresetChip(
                  label: c.label,
                  selected: _cols.contains(c.key),
                  onTap: () => setState(() {
                    if (_cols.contains(c.key)) {
                      if (_cols.length > 1) _cols.remove(c.key);
                    } else {
                      _cols.add(c.key);
                    }
                  }),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _FieldLabel('Filters'),
              const Spacer(),
              if (ds.filters.isNotEmpty)
                TextButton.icon(
                  onPressed: () => setState(() => _filters.add(_FilterCond())),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add filter'),
                ),
            ],
          ),
          for (var i = 0; i < _filters.length; i++) ...[
            const SizedBox(height: 8),
            _FilterRow(
              ds: ds,
              cond: _filters[i],
              onChanged: () => setState(() {}),
              onRemove: () => setState(() => _filters.removeAt(i)),
            ),
          ],
          const SizedBox(height: 18),
          Row(
            children: [
              _FieldLabel('Sort'),
              const SizedBox(width: 12),
              _Dropdown<String?>(
                value: _sort,
                items: {
                  '': '— none —',
                  for (final c in ds.columns) c.key: c.label,
                },
                onChanged: (k) =>
                    setState(() => _sort = (k == null || k.isEmpty) ? null : k),
              ),
              const SizedBox(width: 10),
              if (_sort != null)
                _PresetChip(
                  label: _sortDesc ? 'Desc' : 'Asc',
                  selected: true,
                  onTap: () => setState(() => _sortDesc = !_sortDesc),
                ),
              const Spacer(),
              _OutlineAction(
                icon: Icons.file_download_outlined,
                label: 'Export',
                onTap: _export,
              ),
              const SizedBox(width: 10),
              YButton(
                label: _running ? 'Running…' : 'Run query',
                small: true,
                onTap: _running ? null : _run,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _results(BuildContext context) {
    final y = context.yoga;
    if (_runError != null) {
      return Text(
        'Query failed: $_runError',
        style: TextStyle(color: y.accent, fontWeight: FontWeight.w600),
      );
    }
    final res = _result;
    if (res == null) {
      return Text(
        'Configure columns and filters, then run a query.',
        style: TextStyle(color: y.muted, fontSize: 13),
      );
    }
    if (res.rows.isEmpty) {
      return Text(
        'No rows matched.',
        style: TextStyle(color: y.muted, fontSize: 13),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingTextStyle: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: y.muted,
          letterSpacing: 0.4,
        ),
        dataTextStyle: TextStyle(fontSize: 13, color: y.text),
        columns: [
          for (final c in res.columns) DataColumn(label: Text(c.label)),
        ],
        rows: [
          for (final row in res.rows)
            DataRow(cells: [for (final cell in row) DataCell(Text(cell))]),
        ],
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  final BuilderDataset ds;
  final _FilterCond cond;
  final VoidCallback onChanged;
  final VoidCallback onRemove;
  const _FilterRow({
    required this.ds,
    required this.cond,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final fieldDef = cond.field == null
        ? null
        : ds.filters.where((f) => f.key == cond.field).firstOrNull;
    return Row(
      children: [
        _Dropdown<String?>(
          value: cond.field,
          hint: 'Field',
          items: {for (final f in ds.filters) f.key: f.label},
          onChanged: (k) {
            cond.field = k;
            final def = ds.filters.firstWhere((f) => f.key == k);
            cond.op = def.operators.first;
            cond.value = '';
            onChanged();
          },
        ),
        const SizedBox(width: 8),
        if (fieldDef != null)
          _Dropdown<String?>(
            value: cond.op,
            items: {for (final o in fieldDef.operators) o: _opLabels[o] ?? o},
            onChanged: (o) {
              cond.op = o;
              onChanged();
            },
          ),
        const SizedBox(width: 8),
        Expanded(
          child: fieldDef != null && fieldDef.options.isNotEmpty
              ? _Dropdown<String?>(
                  value: cond.value.isEmpty ? null : cond.value,
                  hint: 'Value',
                  items: {for (final o in fieldDef.options) o: o},
                  onChanged: (v) {
                    cond.value = v ?? '';
                    onChanged();
                  },
                )
              : TextField(
                  controller: TextEditingController(text: cond.value)
                    ..selection = TextSelection.collapsed(
                      offset: cond.value.length,
                    ),
                  onChanged: (v) => cond.value = v,
                  style: TextStyle(fontSize: 13, color: y.text),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: fieldDef?.type == 'date' ? 'YYYY-MM-DD' : 'value',
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(y.radiusChip),
                    ),
                  ),
                ),
        ),
        IconButton(
          icon: Icon(Icons.close, size: 18, color: y.muted),
          onPressed: onRemove,
        ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);
  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        color: y.muted,
        letterSpacing: 0.6,
      ),
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  final T value;
  final Map<T, String> items;
  final ValueChanged<T?> onChanged;
  final String? hint;
  const _Dropdown({
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(y.radiusChip),
        border: Border.all(color: y.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: items.containsKey(value) ? value : null,
          isDense: true,
          hint: hint == null
              ? null
              : Text(hint!, style: TextStyle(fontSize: 13, color: y.muted)),
          icon: Icon(Icons.unfold_more, size: 16, color: y.muted),
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: y.text,
          ),
          dropdownColor: y.surface,
          items: [
            for (final e in items.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value)),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _PresetChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(y.radiusChip),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? y.primary : y.surface2,
            borderRadius: BorderRadius.circular(y.radiusChip),
            border: selected ? null : Border.all(color: y.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: selected ? y.onPrimary : y.muted,
            ),
          ),
        ),
      ),
    );
  }
}
