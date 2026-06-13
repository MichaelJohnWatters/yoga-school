// Manager Reports — month stats + revenue stacked bars + instructor pay.
// Card revenue = solid primary bottom; cash = accentSoft on top with a 2 px
// accent top edge (per the design's KReports spec).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import 'manager_shell.dart';

final adminReportsProvider =
    FutureProvider.autoDispose<AdminReports>((ref) async {
  return ref.watch(apiClientProvider).adminReports();
});

class AdminReportsScreen extends ConsumerWidget {
  const AdminReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(adminReportsProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
      child: data.when(
        data: (r) => _Body(r: r),
        loading: () =>
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Center(
          child: Text(
            "Can't load reports: $e",
            style: TextStyle(color: context.yoga.muted),
          ),
        ),
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
        ManagerPageHeader(
          title: 'Reports',
          sub: '${r.revenueMonth.monthLabel} · last 12 weeks',
        ),
        _StatsRow(r: r),
        const SizedBox(height: 16),
        ManagerCard(
          title: 'Revenue by week',
          action: '${_currencyLabel(r.revenueMonth.currency)} · last 12 weeks',
          child: _RevenueChart(weeks: r.revenueByWeek, currency: r.revenueMonth.currency),
        ),
        const SizedBox(height: 16),
        ManagerCard(
          title: 'Instructor pay',
          action: r.revenueMonth.monthLabel,
          child: _InstructorPayTable(rows: r.instructorPay, currency: r.revenueMonth.currency),
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
              'Peak week: ${_fmt(maxTotal, currency)}',
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
    const mons = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
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
              border: Border(
                top: BorderSide(color: y.accent, width: 2),
              ),
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
  const _LegendDot({required this.color, required this.label, this.dim = false});

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
          _Row(
            r: rows[i],
            currency: currency,
            isLast: i == rows.length - 1,
          ),
        const SizedBox(height: 12),
        Text(
          'Rate is £35 per class — configurable per instructor in production.',
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
          SizedBox(width: 120, child: Text('PAY', style: s, textAlign: TextAlign.right)),
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
  final body =
      cents == 0 ? '$whole' : '$whole.${cents.toString().padLeft(2, '0')}';
  return '$symbol$body';
}
