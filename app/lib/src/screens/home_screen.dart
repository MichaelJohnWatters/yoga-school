// Home — populated state. Mirrors yoga-home.jsx (YHomeScreen).
// "Upcoming" reads /bookings?scope=upcoming; "This week" reads
// /classes?from=&to= filtered to upcoming non-booked classes.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/api_error.dart';
import '../api/models.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/polling.dart';
import '../widgets/yoga_primitives.dart';
import 'achievements_screen.dart';
import 'booking_sheet.dart';
import 'profile_screen.dart' show entitlementsProvider;

final upcomingBookingsProvider =
    // Session-scoped — see notification provider notes. Home is the
    // landing tab; its upcoming-bookings list should snap in from cache
    // and refresh silently rather than spinner-flashing every visit.
    FutureProvider<List<UpcomingBooking>>((ref) async {
  return ref.watch(apiClientProvider).upcomingBookings();
});

/// Classes for the next 7 days, used by Home's "This week at the studio" rail.
/// Lives in Home for now; promote to a shared file if Book starts using a
/// month-level summary too.
final thisWeekClassesProvider =
    FutureProvider.autoDispose<List<ClassRow>>((ref) async {
  final now = DateTime.now();
  final from = DateTime(now.year, now.month, now.day);
  return ref.watch(apiClientProvider).classesInRange(
        from: from,
        to: from.add(const Duration(days: 7)),
      );
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
    final entitlements = ref.watch(entitlementsProvider);

    // First-run inviting empty state: zero upcoming bookings AND zero active
    // passes. Anything else (bookings present, or passes present) falls
    // through to the populated layout below. (yoga-home.jsx:127-159)
    final isFirstRun = upcoming.maybeWhen(
          data: (b) => b.isEmpty,
          orElse: () => false,
        ) &&
        entitlements.maybeWhen(
          data: (e) => e.where((p) => p.isActive).isEmpty,
          orElse: () => false,
        );

    // PollingRefresh outside the RefreshIndicator so the periodic tick
    // keeps firing even when the user isn't pulling to refresh. The
    // explicit refresh pulls all three providers, matching what the
    // populated state actually reads from.
    return PollingRefresh(
      surface: PollingSurface.upcomingBookings,
      onPoll: () => ref.invalidate(upcomingBookingsProvider),
      child: RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(upcomingBookingsProvider);
        ref.invalidate(entitlementsProvider);
        ref.invalidate(thisWeekClassesProvider);
      },
      child: ListView(
        padding: const EdgeInsets.only(top: 16, bottom: 24),
        children: [
          _Header(me: me, studio: studio, onTapProfile: onTapProfile),
          const SizedBox(height: 16),
          const _PromoBanner(),
          const SizedBox(height: 20),
          if (isFirstRun) ...[
            const _FirstRunCard(),
            const SizedBox(height: 14),
            const _BeginnersTip(),
          ] else ...[
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
                child: Text(
                  "Can't load bookings: ${ApiError.fromAny(e).message}",
                ),
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
        ],
      ),
    ),
    );
  }
}

/// First-run welcome card shown when the student has no upcoming bookings
/// AND no active passes. Mirrors yoga-home.jsx YHomeEmptyScreen.
class _FirstRunCard extends StatelessWidget {
  const _FirstRunCard();

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
        decoration: BoxDecoration(
          color: y.surface,
          borderRadius: BorderRadius.circular(y.radiusCard),
          border: Border.all(color: y.border),
          boxShadow: y.shadow,
        ),
        child: Column(
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: y.primarySoft,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.calendar_month_outlined,
                size: 24,
                color: y.primaryStrong,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Your week is wide open',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
                color: y.text,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              "Browse the schedule and book your first class — we'll keep your spot here.",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                color: y.muted,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const YButton(label: 'Browse classes'),
                const SizedBox(width: 8),
                YButton(
                  label: 'See passes',
                  variant: YButtonVariant.outline,
                  onTap: () {},
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Quiet beginners tip strip shown below the first-run card.
class _BeginnersTip extends StatelessWidget {
  const _BeginnersTip();

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: y.surface2,
          borderRadius: BorderRadius.circular(y.radiusCard),
        ),
        child: Row(
          children: [
            Icon(Icons.schedule_outlined, size: 17, color: y.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                "New here? Most students start with Yin & Restore or Beginners' Vinyasa.",
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: y.muted,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UpcomingList extends ConsumerWidget {
  final List<UpcomingBooking> items;
  const _UpcomingList({required this.items});

  /// Fetches the full ClassRow for the booking then opens the standard
  /// BookingSheet — same modal students use from the Book tab. The sheet
  /// already covers cancel / +1 / chat-entry, so a tap from Home is the
  /// quickest path to "I want to do something with this booking".
  Future<void> _openSheet(
    BuildContext context,
    WidgetRef ref,
    UpcomingBooking booking,
  ) async {
    try {
      final detail = await ref
          .read(apiClientProvider)
          .getClass(booking.classId);
      if (!context.mounted) return;
      final changed = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        barrierColor: const Color(0x66100A05),
        builder: (_) => BookingSheet(classRow: detail.row),
      );
      if (changed == true) {
        ref.invalidate(upcomingBookingsProvider);
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Couldn't open: ${ApiError.fromAny(e).message}"),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hero = items.first;
    final rest = items.skip(1).take(2).toList();
    return Column(
      children: [
        _HeroBookingCard(
          booking: hero,
          onTap: () => _openSheet(context, ref, hero),
        ),
        for (final b in rest) ...[
          const SizedBox(height: 8),
          _CompactBookingCard(
            booking: b,
            onTap: () => _openSheet(context, ref, b),
          ),
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
  final VoidCallback? onTap;
  const _HeroBookingCard({required this.booking, this.onTap});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final local = booking.startsAt.toLocal();
    const dows = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
    final dow = dows[(local.weekday + 6) % 7];
    final start = '${local.hour}:${local.minute.toString().padLeft(2, '0')}';
    final endLocal = booking.endsAt.toLocal();
    final end = '${endLocal.hour}:${endLocal.minute.toString().padLeft(2, '0')}';
    final radius = BorderRadius.circular(y.radiusCard);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Material(
        color: y.surface,
        borderRadius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: radius,
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
        ),
      ),
    );
  }
}

class _CompactBookingCard extends StatelessWidget {
  final UpcomingBooking booking;
  final VoidCallback? onTap;
  const _CompactBookingCard({required this.booking, this.onTap});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final local = booking.startsAt.toLocal();
    const dows = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final dow = dows[(local.weekday + 6) % 7];
    final start = '${local.hour}:${local.minute.toString().padLeft(2, '0')}';
    final radius = BorderRadius.circular(y.radiusCard);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Material(
        color: y.surface,
        borderRadius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: radius,
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
        ),
      ),
    );
  }
}

class _WeekRailCard extends ConsumerWidget {
  const _WeekRailCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final classes = ref.watch(thisWeekClassesProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        decoration: BoxDecoration(
          color: y.surface,
          borderRadius: BorderRadius.circular(y.radiusCard),
          border: Border.all(color: y.border),
        ),
        child: classes.when(
          data: (rows) {
            // Show up to 3 classes the student isn't booked into, skipping
            // ones already past. Lightly curated rail.
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
      ),
    );
  }
}

final achievementsProvider = FutureProvider<List<Achievement>>((ref) async {
  return ref.watch(apiClientProvider).myAchievements();
});

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
    final dayLabel = isToday
        ? 'Today'
        : dowShort[(local.weekday + 6) % 7];
    final time = '${local.hour}:${local.minute.toString().padLeft(2, '0')}';
    final meta = '$dayLabel · $time · ${row.instructorName}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
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
      // Both behaviours: dashed border (per the design spec) AND tap to
      // open the full achievements wall.
      child: InkWell(
        borderRadius: BorderRadius.circular(y.radiusCard),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => const AchievementsScreen(),
        )),
        child: YDashedBorder(
          color: y.borderStrong,
          radius: y.radiusCard,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
      ),
    );
  }
}

