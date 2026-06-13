// Enrollments tab for Book — list of multi-session series.
// Mirrors yoga-enroll.jsx list section.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/yoga_primitives.dart';
import 'enroll_sheet.dart';

final enrollmentsProvider =
    FutureProvider.autoDispose<List<EnrollmentSummary>>((ref) async {
  return ref.watch(apiClientProvider).listEnrollments();
});

class EnrollmentsTab extends ConsumerWidget {
  const EnrollmentsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(enrollmentsProvider);
    return data.when(
      data: (list) => list.isEmpty
          ? const _Empty()
          : _List(items: list, onReload: () {
              ref.invalidate(enrollmentsProvider);
            }),
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            "Can't load enrollments: $e",
            style: TextStyle(color: context.yoga.muted),
          ),
        ),
      ),
    );
  }
}

class _List extends StatelessWidget {
  final List<EnrollmentSummary> items;
  final VoidCallback onReload;
  const _List({required this.items, required this.onReload});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
      itemCount: items.length + 1, // last item is the footer note
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        if (i == items.length) return const _FooterNote();
        return _CourseCard(item: items[i], onReload: onReload);
      },
    );
  }
}

class _CourseCard extends StatelessWidget {
  final EnrollmentSummary item;
  final VoidCallback onReload;
  const _CourseCard({required this.item, required this.onReload});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final enrolled = item.seriesState == 'enrolled';
    final full = item.seriesState == 'full';
    final meta = _seriesMeta(item);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: enrolled ? y.primarySoft : y.surface,
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: enrolled
            ? null
            : Border.all(color: y.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.2,
                        color: y.text,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      meta,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: y.muted,
                      ),
                    ),
                    if (item.instructorName.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          YAvatar(name: item.instructorName, size: 20),
                          const SizedBox(width: 6),
                          Text(
                            'with ${item.instructorName}',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: y.muted,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    item.formattedPrice(),
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                      color: y.text,
                    ),
                  ),
                  Text(
                    'one payment',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: y.muted,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (enrolled)
            _EnrolledBar(item: item)
          else if (full)
            _FullRow()
          else
            _OpenRow(item: item, onReload: onReload),
        ],
      ),
    );
  }

  static String _seriesMeta(EnrollmentSummary e) {
    final parts = <String>['${e.sessionCount} sessions'];
    if (e.startsAt != null) {
      const dows = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
      final dow = dows[(e.startsAt!.weekday - 1) % 7];
      final hh = '${e.startsAt!.hour.toString().padLeft(2, '0')}:${e.startsAt!.minute.toString().padLeft(2, '0')}';
      parts.add('${dow}s $hh');
      if (e.endsAt != null) {
        parts.add('${_short(e.startsAt!)} – ${_short(e.endsAt!)}');
      }
    }
    return parts.join(' · ');
  }

  static String _short(DateTime d) {
    const mons = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final l = d.toLocal();
    return '${l.day} ${mons[l.month - 1]}';
  }
}

class _OpenRow extends StatelessWidget {
  final EnrollmentSummary item;
  final VoidCallback onReload;
  const _OpenRow({required this.item, required this.onReload});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final spotsHint = item.seatsLeft <= 3
        ? '${item.seatsLeft} of ${item.capacity} left'
        : '${item.enrolledCount} of ${item.capacity} enrolled';
    return Row(
      children: [
        Text(
          spotsHint,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: item.seatsLeft <= 3 ? y.accent : y.muted,
          ),
        ),
        const Spacer(),
        YButton(
          label: 'Enroll · ${item.formattedPrice()}',
          small: true,
          onTap: () async {
            final ok = await showEnrollSheet(
              context: context,
              enrollmentId: item.id,
            );
            if (ok == true) onReload();
          },
        ),
      ],
    );
  }
}

class _FullRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Row(
      children: [
        const YChip(kind: YChipKind.full, label: 'Full'),
        const Spacer(),
        Text(
          'Join waitlist',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: y.primary,
          ),
        ),
      ],
    );
  }
}

class _EnrolledBar extends StatelessWidget {
  final EnrollmentSummary item;
  const _EnrolledBar({required this.item});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const YChip(kind: YChipKind.booked, label: 'Enrolled', leadingCheck: true),
            const Spacer(),
            Text(
              'Bookings live in your Home upcoming list.',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: y.muted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            for (var i = 0; i < item.sessionCount; i++) ...[
              Expanded(
                child: Container(
                  height: 7,
                  decoration: BoxDecoration(
                    color: y.primary,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              if (i < item.sessionCount - 1) const SizedBox(width: 4),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'All ${item.sessionCount} sessions are booked in your name.',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: y.muted,
          ),
        ),
      ],
    );
  }
}

class _FooterNote extends StatelessWidget {
  const _FooterNote();

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: y.surface2,
          borderRadius: BorderRadius.circular(y.radiusCard),
        ),
        child: RichText(
          text: TextSpan(
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: y.muted,
              height: 1.5,
            ),
            children: [
              const TextSpan(text: 'Enrollments are sold as a course — '),
              TextSpan(
                text: 'one payment books every session',
                style: TextStyle(color: y.text, fontWeight: FontWeight.w700),
              ),
              const TextSpan(
                text: ". You can miss a week but credits aren't refunded for missed sessions.",
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 40, 20, 20),
      child: Center(
        child: Column(
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: y.surface2,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.school_outlined, size: 24, color: y.muted),
            ),
            const SizedBox(height: 14),
            Text(
              'No courses scheduled',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: y.text,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              "We'll add new courses to this tab as soon as they're announced.",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                color: y.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
