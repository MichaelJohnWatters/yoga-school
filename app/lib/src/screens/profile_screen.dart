// Profile — Overview + Wallet (segmented).
// Mirrors yoga-student2.jsx YProfileScreen + YWalletScreen.
//
// Overview: stats card (3 numbers + 12-week bar chart), Active passes,
// History (muted).
// Wallet: payment methods (stub), purchase history.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_stripe/flutter_stripe.dart' as stripe;

import '../api/api_client.dart';
import '../api/api_error.dart';
import '../api/models.dart';
import '../api/web_redirect.dart';
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

/// The user's saved cards (real, from Stripe). Refreshed after adding/removing.
final paymentMethodsProvider =
    FutureProvider<List<PaymentMethod>>((ref) async {
  return ref.watch(apiClientProvider).listPaymentMethods();
});

// Keep in sync with checkout_sheet.dart's _stripeApiVersion — the ephemeral
// key must be minted with the version flutter_stripe's SDK is pinned to.
const _walletStripeApiVersion = '2020-08-27';

final subscriptionsProvider =
    FutureProvider<List<Subscription>>((ref) async {
  return ref.watch(apiClientProvider).mySubscriptions();
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

/// Which Profile segment is showing: 0 = Overview, 1 = Bookings, 2 = Wallet.
/// A provider (rather than local state) so other flows can deep-link into a
/// segment — e.g. the purchase-success screen's "Go to wallet / bookings"
/// buttons set the tab to Profile and this to the right segment.
class ProfileSegmentNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void set(int i) {
    if (state != i) state = i;
  }
}

final profileSegmentProvider =
    NotifierProvider<ProfileSegmentNotifier, int>(ProfileSegmentNotifier.new);

const profileSegBookings = 1;
const profileSegWallet = 2;

class ProfileScreen extends ConsumerStatefulWidget {
  final Me me;
  final StudioConfig? studio;
  const ProfileScreen({super.key, required this.me, this.studio});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
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
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(myBookingsUpcomingProvider);
      ref.invalidate(myBookingsPastProvider);
    });
  }

  /// Switch segment + silently refresh the data that segment shows, so tapping
  /// Bookings/Wallet always reflects changes made elsewhere (a manager grant, a
  /// cancellation, a fresh purchase) without a manual pull-to-refresh.
  void _onSeg(int i) {
    ref.read(profileSegmentProvider.notifier).set(i);
    switch (i) {
      case 1: // Bookings
        ref.invalidate(myBookingsUpcomingProvider);
        ref.invalidate(myBookingsPastProvider);
      case 2: // Wallet
        ref.invalidate(purchasesProvider);
        ref.invalidate(subscriptionsProvider);
      default: // Overview
        ref.invalidate(entitlementsProvider);
        ref.invalidate(attendanceProvider);
        ref.invalidate(subscriptionsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final studio = widget.studio;
    final seg = ref.watch(profileSegmentProvider);
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
            seg: seg,
            onSeg: _onSeg,
          ),
          const SizedBox(height: 18),
          switch (seg) {
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
        // Stats first.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: attendance.when(
            data: (a) => _StatsCard(attendance: a),
            loading: _loaderBox,
            error: (e, _) => _errorBox(context, "Can't load attendance: ${ApiError.fromAny(e).message}"),
          ),
        ),
        const SizedBox(height: 18),
        // Then the wallet content that matters most: passes + history.
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
        const SizedBox(height: 18),
        const _MembershipSection(),
        // Appearance (light/dark theme) last — least important, tucked away.
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: AppearanceCard(),
        ),
        const SizedBox(height: 18),
      ],
    );
  }
}


/// Membership status block in the Overview. Shows active/past-due/pending
/// memberships with Manage (Stripe billing portal) + Cancel/Resume. Hidden
/// entirely when the student has no ongoing membership.
class _MembershipSection extends ConsumerWidget {
  const _MembershipSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subs = ref.watch(subscriptionsProvider);
    return subs.maybeWhen(
      data: (list) {
        final ongoing = list
            .where((s) => s.isActive || s.isPastDue || s.isPending)
            .toList();
        if (ongoing.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: YSectionHead(title: 'Membership'),
            ),
            for (final s in ongoing)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: _MembershipCard(sub: s),
              ),
            const SizedBox(height: 6),
          ],
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _MembershipCard extends ConsumerStatefulWidget {
  final Subscription sub;
  const _MembershipCard({required this.sub});

  @override
  ConsumerState<_MembershipCard> createState() => _MembershipCardState();
}

class _MembershipCardState extends ConsumerState<_MembershipCard> {
  bool _busy = false;

  Future<void> _openPortal() async {
    final messenger = ScaffoldMessenger.of(context);
    if (!kIsWeb) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Manage your membership in the web app for now.'),
      ));
      return;
    }
    setState(() => _busy = true);
    try {
      final url = await ref
          .read(apiClientProvider)
          .billingPortalUrl(returnUrl: Uri.base.toString());
      redirectToCheckout(url); // full-page navigate to Stripe's portal
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        messenger.showSnackBar(SnackBar(
          content: Text("Couldn't open billing portal: ${ApiError.fromAny(e).message}"),
        ));
      }
    }
  }

  Future<void> _cancel() async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel membership?'),
        content: const Text(
          'Your access continues until the end of the current billing period, '
          'then the membership ends. You can resume any time before then.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel membership'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(apiClientProvider).cancelSubscription(widget.sub.id);
      ref.invalidate(subscriptionsProvider);
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(
          content: Text("Couldn't cancel: ${ApiError.fromAny(e).message}"),
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resume() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(apiClientProvider).resumeSubscription(widget.sub.id);
      ref.invalidate(subscriptionsProvider);
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(
          content: Text("Couldn't resume: ${ApiError.fromAny(e).message}"),
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final s = widget.sub;
    final pastDue = s.isPastDue;
    final period = s.currentPeriodEnd != null
        ? _d(DateTime.parse(s.currentPeriodEnd!))
        : null;

    const danger = Color(0xFFA33B2E);
    final (String statusLine, Color accent) = switch (s) {
      _ when pastDue => ('Payment failed — update your card to restore access', danger),
      _ when s.isPending => ('Awaiting payment confirmation…', y.muted),
      _ when s.cancelAtPeriodEnd => (
          period != null ? 'Ends $period' : 'Cancelling at period end',
          y.muted,
        ),
      _ => (period != null ? 'Renews $period' : 'Active', y.primaryStrong),
    };

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: pastDue ? danger : y.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.autorenew_rounded, size: 18, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.productName,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            statusLine,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: accent,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (pastDue || s.isActive)
                TextButton(
                  onPressed: _busy ? null : _openPortal,
                  child: Text(pastDue ? 'Update payment' : 'Manage'),
                ),
              if (s.isActive && !s.cancelAtPeriodEnd)
                TextButton(
                  onPressed: _busy ? null : _cancel,
                  child: const Text('Cancel'),
                ),
              if (s.cancelAtPeriodEnd)
                FilledButton(
                  onPressed: _busy ? null : _resume,
                  child: const Text('Resume'),
                ),
            ],
          ),
        ],
      ),
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
    final methods = ref.watch(paymentMethodsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: YSectionHead(
            title: 'Payment methods',
            action: 'Add',
            onAction: () => _addCard(context, ref),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: methods.when(
            data: (list) => list.isEmpty
                ? const _NoCardsYet()
                : Column(
                    children: [
                      for (final m in list)
                        _PaymentMethodRow(
                          method: m,
                          onDelete: () => _deleteCard(context, ref, m),
                        ),
                    ],
                  ),
            loading: () => _loaderBox(),
            error: (e, _) => _errorBox(
                context, "Can't load cards: ${ApiError.fromAny(e).message}"),
          ),
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

  /// Add a card with no charge. Native uses the PaymentSheet in setup mode;
  /// web redirects to a hosted setup Checkout (returns via ?setup=success).
  Future<void> _addCard(BuildContext context, WidgetRef ref) async {
    final api = ref.read(apiClientProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (kIsWeb) {
        final base = Uri.base;
        String ret(String o) => base
            .replace(queryParameters: {...base.queryParameters, 'setup': o})
            .toString();
        final url = await api.createSetupCheckout(
          successUrl: ret('success'),
          cancelUrl: ret('cancel'),
        );
        redirectToCheckout(url); // full-page navigate; return handled in main
        return;
      }
      final cfg = await ref.read(paymentConfigProvider.future);
      final setup = await api.createSetupIntent();
      final ek = await api.stripeEphemeralKey(apiVersion: _walletStripeApiVersion);
      stripe.Stripe.publishableKey = cfg.publishableKey;
      await stripe.Stripe.instance.applySettings();
      await stripe.Stripe.instance.initPaymentSheet(
        paymentSheetParameters: stripe.SetupPaymentSheetParameters(
          setupIntentClientSecret: setup.clientSecret,
          customerId: setup.customerId,
          customerEphemeralKeySecret: ek,
          merchantDisplayName: cfg.merchantDisplayName.isEmpty
              ? 'Yoga School'
              : cfg.merchantDisplayName,
        ),
      );
      await stripe.Stripe.instance.presentPaymentSheet();
      ref.invalidate(paymentMethodsProvider);
      messenger.showSnackBar(const SnackBar(content: Text('Card saved.')));
    } on stripe.StripeException catch (e) {
      if (e.error.code == stripe.FailureCode.Canceled) return; // dismissed
      messenger.showSnackBar(SnackBar(
        content: Text(
            'Could not add card: ${e.error.localizedMessage ?? e.error.code}'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Could not add card: ${ApiError.fromAny(e).message}'),
      ));
    }
  }

  Future<void> _deleteCard(
      BuildContext context, WidgetRef ref, PaymentMethod m) async {
    final y = context.yoga;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: y.surface,
        title: Text('Remove card?', style: TextStyle(color: y.text)),
        content: Text(
          'Remove ${m.brandLabel} ···· ${m.last4} from your wallet? You can '
          'always add it again at checkout.',
          style: TextStyle(color: y.text, fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiClientProvider).deletePaymentMethod(m.id);
      ref.invalidate(paymentMethodsProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not remove: ${ApiError.fromAny(e).message}'),
        ));
      }
    }
  }
}

class _PaymentMethodRow extends StatelessWidget {
  final PaymentMethod method;
  final VoidCallback onDelete;
  const _PaymentMethodRow({required this.method, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
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
              method.brandLabel.toUpperCase(),
              style: TextStyle(
                color: y.background,
                fontSize: 8.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.3,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '···· ${method.last4}',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ),
          if (method.expMonth > 0)
            Text(
              'Exp ${method.expMonth.toString().padLeft(2, '0')}/${method.expYear % 100}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: y.muted,
              ),
            ),
          IconButton(
            onPressed: onDelete,
            icon: Icon(Icons.delete_outline, size: 18, color: y.muted),
            tooltip: 'Remove',
          ),
        ],
      ),
    );
  }
}

class _NoCardsYet extends StatelessWidget {
  const _NoCardsYet();

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: y.border),
      ),
      child: Row(
        children: [
          Icon(Icons.credit_card_outlined, size: 18, color: y.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'No saved cards. Add one, or tick "save card" next time you pay.',
              style: TextStyle(
                fontSize: 13,
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
    // A 'completed' purchase is the settled, paid-for state — that's the
    // implicit norm, so it gets no badge. Anything else (pending while Stripe
    // confirms, voided after an abandoned/failed attempt, refunded) is called
    // out so the row isn't mistaken for a paid pass. Non-settled rows also mute
    // the price/title so they recede visually.
    final badge = _statusBadge(context, item.status);
    final settled = item.status == 'completed';
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
                    color: settled ? y.text : y.muted,
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
                const SizedBox(height: 2),
                Text(
                  item.passAwarded
                      ? 'Pass added to wallet'
                      : 'No pass added',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: y.muted.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                item.formattedPrice(),
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w800,
                  color: settled ? y.text : y.muted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (badge != null) ...[
                const SizedBox(height: 4),
                badge,
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// Badge for a purchase's lifecycle state. Returns null for the settled
  /// ('completed') case — the absence of a badge reads as "paid", and tagging
  /// every row would just be noise.
  static Widget? _statusBadge(BuildContext context, String status) {
    final y = context.yoga;
    final (String, Color, Color)? spec = switch (status) {
      'completed' => null,
      // DB value stays 'pending', but to a student "Pending" implies money is
      // moving — it isn't (no charge succeeded yet). Stripe's own dashboard
      // labels a not-yet-succeeded payment "Incomplete"; mirror that.
      'pending' => ('Incomplete', y.accentSoft, y.accent),
      'voided' => ('Voided', y.surface2, y.muted),
      'refunded' => ('Refunded', y.surface2, y.muted),
      _ => (status, y.surface2, y.muted),
    };
    if (spec == null) return null;
    final (label, bg, fg) = spec;
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

Widget _loaderBox() => const Padding(
      padding: EdgeInsets.symmetric(vertical: 24),
      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
    );

Widget _errorBox(BuildContext context, String msg) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(msg, style: TextStyle(color: context.yoga.muted)),
    );
