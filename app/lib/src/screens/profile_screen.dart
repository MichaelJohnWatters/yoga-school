// Profile — Overview + Wallet (segmented).
// Mirrors yoga-student2.jsx YProfileScreen + YWalletScreen.
//
// Overview: stats card (3 numbers + 12-week bar chart), Active passes,
// History (muted).
// Wallet: payment methods (stub), purchase history.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/api_error.dart';
import '../api/models.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/appearance_card.dart';
import '../widgets/yoga_primitives.dart';

final entitlementsProvider =
    // Session-scoped — see notification provider notes. Profile is
    // visited often; spinning every visit while data already exists is
    // pure friction.
    FutureProvider<List<WalletEntitlement>>((ref) async {
  return ref.watch(apiClientProvider).myEntitlements();
});

final purchasesProvider =
    FutureProvider<List<WalletPurchase>>((ref) async {
  return ref.watch(apiClientProvider).myPurchases();
});

final attendanceProvider =
    FutureProvider<AttendanceSummary>((ref) async {
  return ref.watch(apiClientProvider).myAttendance();
});

// Upcoming + past bookings live in separate providers so each list can
// refresh independently — invalidating one doesn't blow away the cached
// other. Both are session-scoped; RootShell's OnTabVisible wrapper
// invalidates them when the Profile tab becomes visible.
final myBookingsUpcomingProvider =
    FutureProvider<List<UpcomingBooking>>((ref) async {
  return ref.watch(apiClientProvider).upcomingBookings();
});

final myBookingsPastProvider =
    FutureProvider<List<UpcomingBooking>>((ref) async {
  return ref.watch(apiClientProvider).pastBookings();
});

class ProfileScreen extends ConsumerStatefulWidget {
  final Me me;
  final StudioConfig? studio;
  const ProfileScreen({super.key, required this.me, this.studio});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  int _seg = 0;

  @override
  void initState() {
    super.initState();
    // Silent refresh on visit — wallet stats / entitlements can change
    // out from under the user (a manager grants a pass, a booking
    // completes elsewhere), so revalidate every time they open Profile.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.invalidate(entitlementsProvider);
      ref.invalidate(purchasesProvider);
      ref.invalidate(attendanceProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final studio = widget.studio;
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(entitlementsProvider);
        ref.invalidate(purchasesProvider);
        ref.invalidate(attendanceProvider);
      },
      child: ListView(
        padding: const EdgeInsets.only(top: 0, bottom: 24),
        children: [
          if (studio != null) ...[
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
              child: YStudioTopBar(
                studioName: studio.name,
                userFullName: widget.me.fullName,
                userPhotoUrl: widget.me.photoUrl,
              ),
            ),
            const SizedBox(height: 18),
          ],
          _Header(
            me: widget.me,
            seg: _seg,
            onSeg: (i) => setState(() => _seg = i),
          ),
          const SizedBox(height: 18),
          switch (_seg) {
            0 => const _OverviewBody(),
            1 => const _BookingsBody(),
            _ => const _WalletBody(),
          },
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final Me me;
  final int seg;
  final ValueChanged<int> onSeg;
  const _Header({required this.me, required this.seg, required this.onSeg});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              YAvatar(name: me.fullName, size: 56, tone: YAvatarTone.accent, photoUrl: me.photoUrl),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      me.fullName,
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                        color: y.text,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      'Member since ${_memberSince(me.createdAt)}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: y.muted,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: y.borderStrong),
                ),
                child: Icon(Icons.edit_outlined, size: 16, color: y.muted),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Segmented(
            segments: const ['Overview', 'Bookings', 'Wallet'],
            active: seg,
            onTap: onSeg,
          ),
        ],
      ),
    );
  }
}

class _Segmented extends StatelessWidget {
  final List<String> segments;
  final int active;
  final ValueChanged<int> onTap;
  const _Segmented({
    required this.segments,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(y.radiusChip),
      ),
      child: Row(
        children: [
          for (var i = 0; i < segments.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => onTap(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: i == active ? y.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(y.radiusChip),
                    border: Border.all(
                      color: i == active ? y.border : Colors.transparent,
                    ),
                    boxShadow: i == active ? y.shadow : null,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    segments[i],
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: i == active ? y.text : y.muted,
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

class _OverviewBody extends ConsumerWidget {
  const _OverviewBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final attendance = ref.watch(attendanceProvider);
    final entitlements = ref.watch(entitlementsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: attendance.when(
            data: (a) => _StatsCard(attendance: a),
            loading: _loaderBox,
            error: (e, _) => _errorBox(context, "Can't load attendance: ${ApiError.fromAny(e).message}"),
          ),
        ),
        const SizedBox(height: 18),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: AppearanceCard(),
        ),
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: const YSectionHead(title: 'Active passes'),
        ),
        entitlements.when(
          data: (list) => _ActivePassesAndHistory(items: list),
          loading: () => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _loaderBox(),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _errorBox(context, "Can't load passes: ${ApiError.fromAny(e).message}"),
          ),
        ),
      ],
    );
  }
}


class _StatsCard extends StatelessWidget {
  final AttendanceSummary attendance;
  const _StatsCard({required this.attendance});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    if (attendance.allTime == 0) {
      return Container(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 22),
        decoration: BoxDecoration(
          color: y.surface,
          borderRadius: BorderRadius.circular(y.radiusCard),
          border: Border.all(color: y.border),
        ),
        child: Column(
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: y.primarySoft,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.bar_chart_rounded, size: 26, color: y.primaryStrong),
            ),
            const SizedBox(height: 12),
            Text(
              'Your stats will appear here',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: y.text,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Book your first class — streaks and totals start once you turn up.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: y.muted,
                height: 1.4,
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: y.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _StatCell(
                value: '${attendance.thisMonth}',
                label: 'this month',
              ),
              _StatDivider(),
              _StatCell(
                value: '${attendance.weekStreak} wk${attendance.weekStreak == 1 ? '' : 's'}',
                label: 'streak',
              ),
              _StatDivider(),
              _StatCell(value: '${attendance.allTime}', label: 'all time'),
            ],
          ),
          const SizedBox(height: 16),
          _WeeklyBars(counts: attendance.weeklyCounts),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                '12 weeks ago',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: y.muted,
                ),
              ),
              const Spacer(),
              Text(
                'classes / week',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: y.muted,
                ),
              ),
              const Spacer(),
              Text(
                'now',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: y.muted,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  final String value;
  final String label;
  const _StatCell({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
              color: y.text,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: y.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: 36, color: context.yoga.border);
  }
}

class _WeeklyBars extends StatelessWidget {
  final List<int> counts;
  const _WeeklyBars({required this.counts});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final maxV = counts.fold<int>(0, (m, n) => n > m ? n : m).clamp(1, 999);
    return SizedBox(
      height: 44,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < counts.length; i++) ...[
            if (i > 0) const SizedBox(width: 5),
            Expanded(
              child: Container(
                height: 4 + (counts[i] / maxV) * 40,
                decoration: BoxDecoration(
                  color: i == counts.length - 1 ? y.primary : y.primarySoft,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ActivePassesAndHistory extends StatelessWidget {
  final List<WalletEntitlement> items;
  const _ActivePassesAndHistory({required this.items});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final active = items.where((e) => e.isActive).toList();
    final history = items.where((e) => !e.isActive).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (active.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: y.surface2,
                borderRadius: BorderRadius.circular(y.radiusCard),
              ),
              child: Row(
                children: [
                  Icon(Icons.shopping_bag_outlined, size: 18, color: y.muted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'No active passes — browse Buy to get one.',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: y.text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          for (final e in active) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _ActivePassCard(item: e),
            ),
            const SizedBox(height: 8),
          ],
        if (history.isNotEmpty) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: const YSectionHead(title: 'History'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              decoration: BoxDecoration(
                color: y.surface,
                borderRadius: BorderRadius.circular(y.radiusCard),
                border: Border.all(color: y.border),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < history.length; i++) ...[
                    if (i > 0) Divider(height: 1, color: y.border),
                    _HistoryRow(item: history[i]),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ActivePassCard extends StatelessWidget {
  final WalletEntitlement item;
  const _ActivePassCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final total = item.creditsTotal ?? 0;
    final remaining = item.creditsRemaining ?? 0;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: y.primarySoft,
        borderRadius: BorderRadius.circular(y.radiusCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.label,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                    color: y.text,
                  ),
                ),
              ),
              YChip(
                kind: item.gateIsAccent ? YChipKind.accent : YChipKind.booked,
                label: item.gateLabel(),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (item.isUnlimited)
            Container(
              height: 7,
              decoration: BoxDecoration(
                color: y.primary,
                borderRadius: BorderRadius.circular(4),
              ),
            )
          else
            Row(
              children: [
                for (var i = 0; i < total; i++) ...[
                  if (i > 0) const SizedBox(width: 5),
                  Expanded(
                    child: Container(
                      height: 7,
                      decoration: BoxDecoration(
                        color: i < remaining ? y.primary : y.surface,
                        borderRadius: BorderRadius.circular(4),
                        border: i < remaining
                            ? null
                            : Border.all(color: y.borderStrong),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: y.muted,
                    ),
                    children: [
                      TextSpan(
                        text: item.isUnlimited
                            ? 'Unlimited classes'
                            : '$remaining of $total',
                        style: TextStyle(color: y.text, fontWeight: FontWeight.w800),
                      ),
                      TextSpan(text: item.isUnlimited ? '' : ' credits left'),
                    ],
                  ),
                ),
              ),
              if (item.expiresAt != null)
                Text(
                  'Expires ${_d(item.expiresAt!)}',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: y.muted,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  final WalletEntitlement item;
  const _HistoryRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Opacity(
      opacity: 0.75,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.label,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: y.muted,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    _ranges(item),
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: y.muted,
                    ),
                  ),
                ],
              ),
            ),
            YChip(
              kind: YChipKind.full,
              label: item.status[0].toUpperCase() + item.status.substring(1),
            ),
          ],
        ),
      ),
    );
  }

  static String _ranges(WalletEntitlement e) {
    final start = _d(e.createdAt);
    if (e.expiresAt != null) {
      return '$start – ${_d(e.expiresAt!)}';
    }
    return start;
  }
}

String _d(DateTime d) {
  const mons = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final l = d.toLocal();
  return '${l.day} ${mons[l.month - 1]}';
}

String _memberSince(DateTime d) {
  const mons = ['January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'];
  final l = d.toLocal();
  return '${mons[l.month - 1]} ${l.year}';
}

/// Bookings tab — full history of the student's bookings, grouped into
/// Upcoming (chronological) and Past (newest first). Status badge on
/// past rows reflects the final outcome (attended / no_show / cancelled
/// / unmarked).
class _BookingsBody extends ConsumerWidget {
  const _BookingsBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final upcoming = ref.watch(myBookingsUpcomingProvider);
    final past = ref.watch(myBookingsPastProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const YSectionHead(title: 'Upcoming'),
          const SizedBox(height: 6),
          upcoming.when(
            data: (rows) => rows.isEmpty
                ? const _BookingsEmpty(
                    label: 'Nothing booked yet — head to the Book tab.',
                  )
                : Column(
                    children: [
                      for (final b in rows) _BookingRow(b: b, isPast: false),
                    ],
                  ),
            loading: _loaderBox,
            error: (e, _) =>
                _errorBox(context, "Can't load upcoming: ${ApiError.fromAny(e).message}"),
          ),
          const SizedBox(height: 22),
          const YSectionHead(title: 'Past'),
          const SizedBox(height: 6),
          past.when(
            data: (rows) => rows.isEmpty
                ? const _BookingsEmpty(
                    label: 'No history yet — your past classes will show here.',
                  )
                : Column(
                    children: [
                      for (final b in rows) _BookingRow(b: b, isPast: true),
                    ],
                  ),
            loading: _loaderBox,
            error: (e, _) => _errorBox(context, "Can't load history: ${ApiError.fromAny(e).message}"),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _BookingsEmpty extends StatelessWidget {
  final String label;
  const _BookingsEmpty({required this.label});
  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: y.border),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
          height: 1.45,
          color: y.muted,
        ),
      ),
    );
  }
}

class _BookingRow extends StatelessWidget {
  final UpcomingBooking b;
  // Past rows show the status badge + render in a slightly muted tone so
  // the eye treats them as history rather than actionable.
  final bool isPast;
  const _BookingRow({required this.b, required this.isPast});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final local = b.startsAt.toLocal();
    final dayLabel = _shortDay(local);
    final timeLabel = _hm(local);
    final badge = isPast ? _statusBadge(context, b.status) : null;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: y.border),
      ),
      child: Opacity(
        // Past rows: slightly faded so the active Upcoming section reads
        // as the primary content even when the history is much longer.
        opacity: isPast ? 0.82 : 1.0,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            YAvatar(
              name: b.instructorName,
              size: 36,
              tone: YAvatarTone.primary,
              photoUrl: b.instructorPhotoUrl,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    b.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                      color: y.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$dayLabel · $timeLabel · ${b.roomName} · ${b.instructorName}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: y.muted,
                    ),
                  ),
                ],
              ),
            ),
            if (badge != null) ...[
              const SizedBox(width: 8),
              badge,
            ],
          ],
        ),
      ),
    );
  }

  static String _shortDay(DateTime d) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const days = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    final dow = days[d.weekday - 1];
    return '$dow ${d.day} ${months[d.month - 1]}';
  }

  static String _hm(DateTime d) {
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  static Widget? _statusBadge(BuildContext context, String status) {
    final y = context.yoga;
    final (label, bg, fg) = switch (status) {
      'attended' => ('Attended', y.primarySoft, y.primaryStrong),
      'no_show' => ('No-show', y.accentSoft, y.accent),
      'cancelled_free' => ('Cancelled', y.surface2, y.muted),
      'cancelled_late_burned' =>
        ('Cancelled · late', y.surface2, y.muted),
      'cancelled' => ('Cancelled', y.surface2, y.muted),
      'booked' => ('Unmarked', y.surface2, y.muted),
      _ => (status, y.surface2, y.muted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }
}

class _WalletBody extends ConsumerWidget {
  const _WalletBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final purchases = ref.watch(purchasesProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: const YSectionHead(title: 'Payment methods', action: 'Add'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _VisaCard(),
        ),
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: const YSectionHead(title: 'Purchase history'),
        ),
        purchases.when(
          data: (list) => list.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: _NoPurchasesYet(),
                )
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: _PurchaseHistory(items: list),
                ),
          loading: () => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _loaderBox(),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _errorBox(context, "Can't load purchases: ${ApiError.fromAny(e).message}"),
          ),
        ),
      ],
    );
  }
}

class _VisaCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: y.border),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 28,
            decoration: BoxDecoration(
              color: y.text,
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: Text(
              'VISA',
              style: TextStyle(
                color: y.background,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              '···· 4242',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ),
          const YChip(kind: YChipKind.neutral, label: 'Default'),
        ],
      ),
    );
  }
}

class _NoPurchasesYet extends StatelessWidget {
  const _NoPurchasesYet();

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: y.border),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: y.surface2,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(Icons.receipt_long_outlined, size: 20, color: y.muted),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No purchases yet',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Receipts for the passes you buy will show up here.',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: y.muted,
                    height: 1.35,
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

class _PurchaseHistory extends StatelessWidget {
  final List<WalletPurchase> items;
  const _PurchaseHistory({required this.items});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: y.border),
      ),
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) Divider(height: 1, color: y.border),
            _PurchaseRow(item: items[i]),
          ],
        ],
      ),
    );
  }
}

class _PurchaseRow extends StatelessWidget {
  final WalletPurchase item;
  const _PurchaseRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final paid = switch (item.paymentMethod) {
      'cash' => 'Cash, at the desk',
      'card' => 'Card',
      _ => 'Card',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.productName,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: y.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_d(item.createdAt)} · $paid',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: y.muted,
                  ),
                ),
              ],
            ),
          ),
          Text(
            item.formattedPrice(),
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w800,
              color: y.text,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

Widget _loaderBox() => const Padding(
      padding: EdgeInsets.symmetric(vertical: 24),
      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
    );

Widget _errorBox(BuildContext context, String msg) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(msg, style: TextStyle(color: context.yoga.muted)),
    );
