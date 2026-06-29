// Enrollment bottom sheet — review sessions + pay-once Enroll button.
// Mirrors yoga-enroll.jsx YEnrollSheet.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_stripe/flutter_stripe.dart' as stripe;

import '../api/api_client.dart';
import '../api/api_error.dart';
import '../api/models.dart';
import '../api/web_redirect.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/yoga_primitives.dart';
import 'enrollments_tab.dart';
import 'home_screen.dart';

Future<bool?> showEnrollSheet({
  required BuildContext context,
  required String enrollmentId,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x66100A05),
    builder: (_) => EnrollSheet(enrollmentId: enrollmentId),
  );
}

class EnrollSheet extends ConsumerStatefulWidget {
  final String enrollmentId;
  const EnrollSheet({super.key, required this.enrollmentId});

  @override
  ConsumerState<EnrollSheet> createState() => _EnrollSheetState();
}

class _EnrollSheetState extends ConsumerState<EnrollSheet> {
  late Future<EnrollmentDetail> _detail;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _detail = ref.read(apiClientProvider).getEnrollment(widget.enrollmentId);
  }

  // Pay for the series through Stripe — same handshake as a one-time pass:
  // web → hosted Checkout redirect; native → PaymentSheet. The
  // checkout.session.completed / payment_intent.succeeded webhook enrolls the
  // student (books every session), or refunds if the series filled meanwhile.
  Future<void> _enroll(EnrollmentDetail d) async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);

      if (kIsWeb) {
        final base = Uri.base;
        String ret(String outcome) {
          final qp = {...base.queryParameters, 'checkout': outcome};
          var url = base.replace(queryParameters: qp).toString();
          if (outcome == 'success') {
            url += '${url.contains('?') ? '&' : '?'}session_id={CHECKOUT_SESSION_ID}';
          }
          return url;
        }

        final session = await api.createCheckoutSession(
          enrollmentId: widget.enrollmentId,
          successUrl: ret('success'),
          cancelUrl: ret('cancel'),
        );
        redirectToCheckout(session.url); // page unloads here
        return;
      }

      // Native: PaymentSheet on a card PaymentIntent for the series.
      final cfg = await ref.read(paymentConfigProvider.future);
      final pending =
          await api.createCardPurchaseIntent(enrollmentId: widget.enrollmentId);
      stripe.Stripe.publishableKey = cfg.publishableKey;
      await stripe.Stripe.instance.applySettings();
      await stripe.Stripe.instance.initPaymentSheet(
        paymentSheetParameters: stripe.SetupPaymentSheetParameters(
          paymentIntentClientSecret: pending.clientSecret,
          merchantDisplayName: cfg.merchantDisplayName.isEmpty
              ? 'Yoga School'
              : cfg.merchantDisplayName,
        ),
      );
      try {
        await stripe.Stripe.instance.presentPaymentSheet();
      } on stripe.StripeException catch (e) {
        if (e.error.code == stripe.FailureCode.Canceled) {
          if (mounted) setState(() => _submitting = false);
          return; // user dismissed
        }
        rethrow;
      }
      await api.confirmPurchase(pending.purchaseId);
      ref.invalidate(enrollmentsProvider);
      ref.invalidate(upcomingBookingsProvider);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("You're enrolled — see your sessions in Bookings."),
        ),
      );
    } on BookingConflict catch (e) {
      // e.g. "series is full" / "already enrolled in this series".
      setState(() {
        _submitting = false;
        _error = e.message;
      });
    } catch (e) {
      setState(() {
        _submitting = false;
        _error = ApiError.fromAny(e).message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: y.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 28),
        child: SafeArea(
          top: false,
          child: FutureBuilder<EnrollmentDetail>(
            future: _detail,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 60),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snap.hasError) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Text(
                    "Can't load course: ${snap.error}",
                    style: TextStyle(color: y.muted),
                  ),
                );
              }
              return _Loaded(detail: snap.data!, state: this);
            },
          ),
        ),
      ),
    );
  }
}

class _Loaded extends StatelessWidget {
  final EnrollmentDetail detail;
  final _EnrollSheetState state;
  const _Loaded({required this.detail, required this.state});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final s = detail.summary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: y.borderStrong,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          s.title,
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w800,
            color: y.text,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                _meta(s),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: y.muted,
                ),
              ),
            ),
            if (s.seatsLeft <= 3 && s.seriesState == 'open')
              YChip(
                kind: YChipKind.accent,
                label: '${s.seatsLeft} of ${s.capacity} left',
              ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          "YOU'LL BE BOOKED INTO ALL ${s.sessionCount}",
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: y.muted,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 8),
        _SessionsGrid(sessions: detail.sessions),
        const SizedBox(height: 12),
        Text(
          "Missed a session? You can join the next class in the series — credits don't roll over outside the course window.",
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: y.muted,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 14),
        _TotalRow(item: s),
        if (state._error != null) ...[
          const SizedBox(height: 10),
          Text(state._error!,
              style: const TextStyle(color: Color(0xFFA33B2E), fontSize: 12.5)),
        ],
        const SizedBox(height: 14),
        YButton(
          label: state._submitting
              ? 'Processing…'
              : 'Enroll & pay ${s.formattedPrice()}',
          onTap: state._submitting ? null : () => state._enroll(detail),
        ),
        const SizedBox(height: 8),
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 12, color: y.muted),
              const SizedBox(width: 6),
              Text(
                'Apple Pay / Google Pay / card — secured by Stripe',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: y.muted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _meta(EnrollmentSummary s) {
    final parts = <String>['${s.sessionCount} sessions'];
    if (s.startsAt != null) {
      parts.add('${_short(s.startsAt!)}'
          '${s.endsAt != null ? ' – ${_short(s.endsAt!)}' : ''}');
    }
    if (s.instructorName.isNotEmpty) parts.add('with ${s.instructorName}');
    return parts.join(' · ');
  }

  static String _short(DateTime d) {
    const mons = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final l = d.toLocal();
    return '${l.day} ${mons[l.month - 1]}';
  }
}

class _SessionsGrid extends StatelessWidget {
  final List<EnrollmentSession> sessions;
  const _SessionsGrid({required this.sessions});

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      childAspectRatio: 1.7,
      children: [
        for (final s in sessions) _SessionTile(session: s),
      ],
    );
  }
}

class _SessionTile extends StatelessWidget {
  final EnrollmentSession session;
  const _SessionTile({required this.session});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final l = session.startsAt.toLocal();
    const mons = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: y.primarySoft,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'WK ${session.weekIdx}',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
              color: y.primaryStrong,
            ),
          ),
          Text(
            '${l.day} ${mons[l.month - 1]}',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: y.primaryStrong,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

class _TotalRow extends StatelessWidget {
  final EnrollmentSummary item;
  const _TotalRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(y.radiusCard),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'One payment',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                  ),
                ),
                Text(
                  'No credits used — all ${item.sessionCount} sessions covered',
                  style: TextStyle(
                    fontSize: 11.5,
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
              fontSize: 19,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
              color: y.text,
            ),
          ),
        ],
      ),
    );
  }
}
