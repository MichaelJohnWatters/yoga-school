// Home — populated state. Mirrors yoga-home.jsx (YHomeScreen).
// "Upcoming" reads /bookings?scope=upcoming; "This week" is still seeded
// content until a /classes?from=&to= summary endpoint exists.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/api_error.dart';
import '../api/models.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/polling.dart';
import '../widgets/yoga_primitives.dart';
import 'achievements_screen.dart';

final upcomingBookingsProvider =
    // Session-scoped — see notification provider notes. Home is the
    // landing tab; its upcoming-bookings list should snap in from cache
    // and refresh silently rather than spinner-flashing every visit.
    FutureProvider<List<UpcomingBooking>>((ref) async {
  return ref.watch(apiClientProvider).upcomingBookings();
});

class HomeScreen extends ConsumerWidget {
  final Me me;
  final StudioConfig studio;
  final VoidCallback? onTapProfile;
  const HomeScreen({
    super.key,
    required this.me,
    required this.studio,
    this.onTapProfile,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final upcoming = ref.watch(upcomingBookingsProvider);
    return PollingRefresh(
      surface: PollingSurface.upcomingBookings,
      onPoll: () => ref.invalidate(upcomingBookingsProvider),
      child: RefreshIndicator(
      onRefresh: () async => ref.invalidate(upcomingBookingsProvider),
      child: ListView(
        padding: const EdgeInsets.only(top: 16, bottom: 24),
        children: [
          _Header(me: me, studio: studio, onTapProfile: onTapProfile),
          const SizedBox(height: 16),
          const _PromoBanner(),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: const YSectionHead(title: 'Upcoming', action: 'All bookings'),
          ),
          upcoming.when(
            data: (list) => list.isEmpty
                ? const _NoUpcomingCard()
                : _UpcomingList(items: list),
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text("Can't load bookings: ${ApiError.fromAny(e).message}"),
            ),
          ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: const YSectionHead(
              title: 'This week at the studio',
              action: 'Full schedule',
            ),
          ),
          const _WeekRailCard(),
          const SizedBox(height: 14),
          const _MilestonesStrip(),
        ],
      ),
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

class _NoUpcomingCard extends StatelessWidget {
  const _NoUpcomingCard();

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
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
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: y.text,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final Me me;
  final StudioConfig studio;
  final VoidCallback? onTapProfile;
  const _Header({
    required this.me,
    required this.studio,
    this.onTapProfile,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          YStudioTopBar(
            studioName: studio.name,
            userFullName: me.fullName,
            userPhotoUrl: me.photoUrl,
            onAvatarTap: onTapProfile,
          ),
          const SizedBox(height: 18),
          Text(
            'Good morning, ${me.firstName}',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
              height: 1.15,
              color: y.text,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            _today(),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: y.muted,
            ),
          ),
        ],
      ),
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
  const _PromoBanner();

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: y.accentSoft,
          borderRadius: BorderRadius.circular(y.radiusCard),
        ),
        child: Row(
          children: [
            Icon(Icons.local_offer_outlined, size: 17, color: y.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Summer offer — 20% off Unlimited Monthly until 21 June',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                  color: y.text,
                ),
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: y.muted),
          ],
        ),
      ),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: y.surface,
          borderRadius: BorderRadius.circular(y.radiusCard),
          border: Border.all(color: y.border),
          boxShadow: y.shadow,
        ),
        child: Row(
          children: [
            YDateTile(dow: dow, day: '${local.day}'),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    booking.title,
                    style: TextStyle(
                      fontSize: 16.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                      color: y.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$start – $end · ${booking.roomName}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: y.muted,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      YAvatar(name: booking.instructorName, photoUrl: booking.instructorPhotoUrl, size: 20),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          booking.instructorName,
                          style: TextStyle(
                            fontSize: 12.5,
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
            const SizedBox(width: 6),
            const YChip(kind: YChipKind.booked, label: 'Booked', leadingCheck: true),
          ],
        ),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
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
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: y.text,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    '$dow ${local.day} · $start · ${booking.instructorName}',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: y.muted,
                    ),
                  ),
                ],
              ),
            ),
            const YChip(kind: YChipKind.booked, label: 'Booked', leadingCheck: true),
          ],
        ),
      ),
    );
  }
}

class _WeekRailCard extends StatelessWidget {
  const _WeekRailCard();

  static const _rows = [
    ('Yin & Restore', 'Today · 19:00 · Mara Kovac', 'Mara Kovac'),
    ('Power Vinyasa', 'Fri · 17:45 · Asha Patel', 'Asha Patel'),
  ];

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        decoration: BoxDecoration(
          color: y.surface,
          borderRadius: BorderRadius.circular(y.radiusCard),
          border: Border.all(color: y.border),
        ),
        child: Column(
          children: [
            for (var i = 0; i < _rows.length; i++) ...[
              if (i > 0) Divider(height: 1, color: y.border),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                child: Row(
                  children: [
                    YAvatar(name: _rows[i].$3, size: 34),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _rows[i].$1,
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                              color: y.text,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            _rows[i].$2,
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
              ),
            ],
          ],
        ),
      ),
    );
  }
}

final achievementsProvider = FutureProvider<List<Achievement>>((ref) async {
  return ref.watch(apiClientProvider).myAchievements();
});

/// Cosmetic strip on Home that surfaces the latest badge. Per the spec
/// achievements are intentionally secondary, not a hero — when the user
/// has none yet the strip is hidden entirely rather than showing an
/// awkward "no achievements" placeholder.
class _MilestonesStrip extends ConsumerWidget {
  const _MilestonesStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final ach = ref.watch(achievementsProvider);
    // Empty / loading / error all collapse to "render nothing" — the strip
    // is cosmetic, so any failure stays silent rather than nagging the
    // student with a "couldn't load badges" complaint on Home.
    // Full catalogue from the server — filter to actually-earned for the
    // strip's "latest" headline.
    final all = ach.asData?.value ?? const <Achievement>[];
    final earned = all.where((a) => a.isEarned).toList();
    if (earned.isEmpty) return const SizedBox.shrink();

    // Latest is what the strip leads with. Achievements come back in
    // catalogue order, not earned-recency order — sort here so a fresh
    // grant always shows.
    final sorted = [...earned]
      ..sort((a, b) => b.earnedAt!.compareTo(a.earnedAt!));
    final latest = sorted.first;
    final tail = earned.length == 1
        ? 'First badge earned'
        : '${earned.length} badges · latest';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: InkWell(
        borderRadius: BorderRadius.circular(y.radiusCard),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => const AchievementsScreen(),
        )),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(y.radiusCard),
            border: Border.all(color: y.borderStrong, style: BorderStyle.solid),
          ),
          child: Row(
            children: [
              Icon(Icons.star_border_rounded, size: 16, color: y.accent),
              const SizedBox(width: 10),
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: y.muted,
                    ),
                    children: [
                      TextSpan(text: '$tail · '),
                      TextSpan(
                        text: latest.title,
                        style: TextStyle(
                          color: y.text,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Icon(Icons.chevron_right, size: 14, color: y.muted),
            ],
          ),
        ),
      ),
    );
  }
}
