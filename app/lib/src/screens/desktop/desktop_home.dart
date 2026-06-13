// Desktop Home — two-column 1.5fr/1fr per the spec.
// Reuses upcomingBookingsProvider from the mobile Home.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import '../home_screen.dart'
    show upcomingBookingsProvider, thisWeekClassesProvider;

class DesktopHome extends ConsumerWidget {
  final Me me;
  final StudioConfig studio;
  const DesktopHome({super.key, required this.me, required this.studio});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final upcoming = ref.watch(upcomingBookingsProvider);
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        // Greeting row.
        Text(
          'Good morning, ${me.firstName}',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
            color: y.text,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _today(),
          style: TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w500,
            color: y.muted,
          ),
        ),
        const SizedBox(height: 18),
        _PromoBanner(),
        const SizedBox(height: 22),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left column (1.5fr).
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const YSectionHead(
                      title: 'Upcoming',
                      action: 'All bookings',
                    ),
                    upcoming.when(
                      data: (list) => list.isEmpty
                          ? _NoUpcomingCard()
                          : _UpcomingList(items: list),
                      loading: () => const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                      error: (e, _) => Text("Can't load bookings: $e"),
                    ),
                    const SizedBox(height: 18),
                    _MilestonesStrip(),
                  ],
                ),
              ),
              const SizedBox(width: 20),
              // Right column (1fr).
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const YSectionHead(
                      title: 'This week at the studio',
                      action: 'Full schedule',
                    ),
                    _WeekRailCard(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _today() {
    const dow = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const mon = ['January', 'February', 'March', 'April', 'May', 'June',
                  'July', 'August', 'September', 'October', 'November', 'December'];
    final d = DateTime.now();
    return '${dow[d.weekday - 1]} ${d.day} ${mon[d.month - 1]}';
  }
}

class _PromoBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: y.accentSoft,
        borderRadius: BorderRadius.circular(y.radiusCard),
      ),
      child: Row(
        children: [
          Icon(Icons.local_offer_outlined, size: 18, color: y.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Summer offer — 20% off Unlimited Monthly until 21 June',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: y.text,
              ),
            ),
          ),
          GestureDetector(
            onTap: () {},
            child: Text(
              'See offer →',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: y.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UpcomingList extends StatelessWidget {
  final List<UpcomingBooking> items;
  const _UpcomingList({required this.items});

  @override
  Widget build(BuildContext context) {
    final hero = items.first;
    final rest = items.skip(1).take(2).toList();
    return Column(
      children: [
        _HeroBookingCard(booking: hero),
        for (final b in rest) ...[
          const SizedBox(height: 8),
          _CompactBookingCard(booking: b),
        ],
      ],
    );
  }
}

class _HeroBookingCard extends StatelessWidget {
  final UpcomingBooking booking;
  const _HeroBookingCard({required this.booking});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final local = booking.startsAt.toLocal();
    const dows = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
    final dow = dows[(local.weekday + 6) % 7];
    final start = '${local.hour}:${local.minute.toString().padLeft(2, '0')}';
    final endLocal = booking.endsAt.toLocal();
    final end = '${endLocal.hour}:${endLocal.minute.toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: y.border),
        boxShadow: y.shadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              YDateTile(dow: dow, day: '${local.day}'),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      booking.title,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: y.text,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '$start – $end · ${booking.roomName}',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: y.muted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        YAvatar(name: booking.instructorName, photoUrl: booking.instructorPhotoUrl, size: 22),
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            booking.instructorName,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: y.muted,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const YChip(
                    kind: YChipKind.booked,
                    label: 'Booked',
                    leadingCheck: true,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Cancel',
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
        ],
      ),
    );
  }
}

class _CompactBookingCard extends StatelessWidget {
  final UpcomingBooking booking;
  const _CompactBookingCard({required this.booking});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final local = booking.startsAt.toLocal();
    const dows = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final dow = dows[(local.weekday + 6) % 7];
    final start = '${local.hour}:${local.minute.toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: y.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  booking.title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: y.text,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  '$dow ${local.day} · $start · ${booking.instructorName}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: y.muted,
                  ),
                ),
              ],
            ),
          ),
          const YChip(
            kind: YChipKind.booked,
            label: 'Booked',
            leadingCheck: true,
          ),
        ],
      ),
    );
  }
}

class _NoUpcomingCard extends StatelessWidget {
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
      child: Row(
        children: [
          Icon(Icons.calendar_today_outlined, color: y.muted, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'No upcoming classes — browse the schedule to book one.',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: y.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MilestonesStrip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return YDashedBorder(
      color: y.borderStrong,
      radius: y.radiusCard,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.star_border_rounded, size: 18, color: y.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '24 classes · 3-week streak',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: y.muted,
                ),
              ),
            ),
            Icon(Icons.chevron_right, size: 14, color: y.muted),
          ],
        ),
      ),
    );
  }
}

class _WeekRailCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final classes = ref.watch(thisWeekClassesProvider);
    return Container(
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: y.border),
      ),
      child: classes.when(
        data: (rows) {
          final now = DateTime.now();
          final upcoming = rows.where((r) =>
              r.startsAt.isAfter(now) &&
              r.bookingState != BookingState.booked).toList();
          if (upcoming.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
              child: Text(
                'No more classes this week.',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: y.muted,
                ),
              ),
            );
          }
          final picks = upcoming.take(3).toList();
          return Column(
            children: [
              for (var i = 0; i < picks.length; i++) ...[
                if (i > 0) Divider(height: 1, color: y.border),
                _WeekRailRow(row: picks[i]),
              ],
            ],
          );
        },
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
        error: (_, __) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          child: Text(
            "Can't load this week's classes.",
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: y.muted,
            ),
          ),
        ),
      ),
    );
  }
}

class _WeekRailRow extends StatelessWidget {
  final ClassRow row;
  const _WeekRailRow({required this.row});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final local = row.startsAt.toLocal();
    final today = DateTime.now();
    const dowShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final isToday = local.year == today.year &&
        local.month == today.month &&
        local.day == today.day;
    final dayLabel =
        isToday ? 'Today' : dowShort[(local.weekday + 6) % 7];
    final time = '${local.hour}:${local.minute.toString().padLeft(2, '0')}';
    final meta = '$dayLabel · $time · ${row.instructorName}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          YAvatar(
            name: row.instructorName,
            photoUrl: row.instructorPhotoUrl,
            size: 34,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.title,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: y.text,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  meta,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: y.muted,
                  ),
                ),
              ],
            ),
          ),
          const YButton(
            label: 'Book',
            variant: YButtonVariant.soft,
            small: true,
          ),
        ],
      ),
    );
  }
}
