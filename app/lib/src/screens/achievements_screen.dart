// Achievements full screen — all 8 catalogue badges with locked / earned
// state. Reachable from the Home strip ("X badges · latest …" → tap).
//
// Earned badges show with the accent tone + filled icon and an "earned on
// {date}" line. Locked badges are dimmed with an outline icon and the
// rule's hint as the subtitle so the user knows what unlocks them.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../api/api_error.dart';
import '../theme/yoga_tokens.dart';
import 'home_screen.dart' show achievementsProvider;

class AchievementsScreen extends ConsumerWidget {
  const AchievementsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final ach = ref.watch(achievementsProvider);
    return Scaffold(
      backgroundColor: y.background,
      appBar: AppBar(
        backgroundColor: y.background,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: y.text,
        title: Text(
          'Achievements',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
            color: y.text,
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ach.when(
          data: (list) => _Body(items: list),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
            child: Text(
              "Can't load achievements: ${ApiError.fromAny(e).message}",
              style: TextStyle(color: y.muted),
            ),
          ),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final List<Achievement> items;
  const _Body({required this.items});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final earnedCount = items.where((a) => a.isEarned).length;
    final summary = Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        '$earnedCount of ${items.length} earned',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: y.muted,
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, c) {
        // Desktop: centre the wall and lay the badges out two-up so a card
        // isn't stretched across the whole window. Mobile keeps one column.
        if (c.maxWidth >= 700) {
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
                children: [
                  summary,
                  LayoutBuilder(
                    builder: (context, cc) {
                      final cardW = (cc.maxWidth - 12) / 2;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (final a in items)
                            SizedBox(
                              width: cardW,
                              child: _AchievementCard(item: a),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            summary,
            for (final a in items) ...[
              _AchievementCard(item: a),
              const SizedBox(height: 8),
            ],
          ],
        );
      },
    );
  }
}

class _AchievementCard extends StatelessWidget {
  final Achievement item;
  const _AchievementCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final earned = item.isEarned;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: earned ? y.surface : y.surface2,
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: y.border),
      ),
      child: Opacity(
        opacity: earned ? 1 : 0.55,
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: earned ? y.accentSoft : y.surface,
                shape: BoxShape.circle,
                border: earned ? null : Border.all(color: y.borderStrong),
              ),
              alignment: Alignment.center,
              child: Icon(
                _iconFor(item.badgeKey, earned: earned),
                size: 20,
                color: earned ? y.accent : y.muted,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.title,
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                            color: y.text,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                      if (earned)
                        Text(
                          _earnedOn(item.earnedAt!),
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: y.accent,
                          ),
                        )
                      else
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: y.surface2,
                            borderRadius: BorderRadius.circular(y.radiusChip),
                            border: Border.all(color: y.borderStrong),
                          ),
                          child: Text(
                            'Locked',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: y.muted,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    item.sub,
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
      ),
    );
  }

  static IconData _iconFor(String key, {required bool earned}) {
    // Hand-picked icon per badge — different from the strip's generic star
    // so each card reads as itself at a glance. Filled vs outlined shifts
    // with earned state.
    switch (key) {
      case 'first_class':
        return earned ? Icons.flag : Icons.flag_outlined;
      case 'regular':
        return earned ? Icons.directions_run : Icons.directions_run_outlined;
      case 'devotee':
        return earned
            ? Icons.local_fire_department
            : Icons.local_fire_department_outlined;
      case 'early_bird':
        return earned ? Icons.wb_sunny : Icons.wb_sunny_outlined;
      case 'night_owl':
        return earned ? Icons.nightlight_round : Icons.nightlight_outlined;
      case 'variety':
        return earned ? Icons.dashboard : Icons.dashboard_outlined;
      case 'streak_3':
        return earned ? Icons.calendar_today : Icons.calendar_today_outlined;
      case 'course_graduate':
        return earned ? Icons.school : Icons.school_outlined;
      default:
        return earned ? Icons.star : Icons.star_border;
    }
  }

  static String _earnedOn(DateTime d) {
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
    final l = d.toLocal();
    return '${l.day} ${mons[l.month - 1]}';
  }
}
