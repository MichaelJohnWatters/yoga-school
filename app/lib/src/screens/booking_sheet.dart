// Booking sheet — bottom sheet shown when the user taps a class row.
// Mirrors the class detail / booking sheet pattern from yoga-student2.jsx.
//
// For an available class:
//   1. Fetch eligible entitlements
//   2. If none → show "Buy a new pass…" fallback (Buy flow not yet wired)
//   3. If one or more → preselect best, show "Book this class" button
//
// For a class the user already booked: shows "Cancel booking" with the
// snapshotted cutoff line.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/api_error.dart';
import '../api/models.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/yoga_primitives.dart';
import 'buy_screen.dart';
import 'chat_screen.dart';

/// Pick the entitlement we should pre-select when the booking sheet opens
/// with multiple eligible passes. The user can still swap rows; this is
/// only the default highlight + the pass that's consumed if they tap
/// Book without picking.
///
/// Sort order — use-it-before-you-lose-it:
///   1. **Soonest expiry first.** A credit (or unlimited) expiring in two
///      days ranks ahead of one expiring next month, regardless of kind.
///      Empty / never-expires expiries sort to the end.
///   2. **Credit before unlimited within the same expiry bracket.** When
///      two passes share a deadline, burn the consumable one first —
///      using an unlimited while a still-valid credit sits around wastes
///      the credit's residual value once it eventually expires unused.
///   3. **Fewest credits left first** (credit vs credit tiebreaker).
///      Drains near-empty packs so the user isn't left with a stray
///      one-credit remnant they forget about.
///
/// Pure function — no Riverpod, no state. Easy to unit-test later.
EligibleEntitlement pickDefaultEntitlement(List<EligibleEntitlement> list) {
  assert(list.isNotEmpty, 'pickDefaultEntitlement called with empty list');
  // Copy + sort to avoid mutating the caller's list (the server payload
  // may be shared via the Future returned to multiple consumers).
  final sorted = [...list]
    ..sort((a, b) {
      final ea = _expiryOrInfinity(a.expiresAt);
      final eb = _expiryOrInfinity(b.expiresAt);
      final byExpiry = ea.compareTo(eb);
      if (byExpiry != 0) return byExpiry;
      if (a.passKind != b.passKind) {
        // 'credit' < 'unlimited' alphabetically — but we want that order
        // explicitly anyway, so just hardcode the rule instead of leaning
        // on string comparison.
        return a.passKind == 'credit' ? -1 : 1;
      }
      if (a.passKind == 'credit') {
        final ca = a.creditsRemaining ?? 1 << 30;
        final cb = b.creditsRemaining ?? 1 << 30;
        return ca.compareTo(cb);
      }
      return 0;
    });
  return sorted.first;
}

/// Map an entitlement's expiry to a DateTime, treating null (the wire
/// representation of "never expires") as a far-future sentinel so it
/// sorts AFTER every dated pass.
DateTime _expiryOrInfinity(DateTime? raw) => raw ?? DateTime(9999);

class BookingSheet extends ConsumerStatefulWidget {
  final ClassRow classRow;

  /// Optional close callback. When supplied, the sheet calls this on a
  /// successful book / cancel / waitlist mutation instead of
  /// `Navigator.of(context).pop(true)`. The desktop layout passes its
  /// own callback so the sheet can dismiss without relying on a nested
  /// Navigator with one route (where pop is a no-op and the
  /// onDidRemovePage hook never fires — that's the bug this fixes).
  final VoidCallback? onClose;
  const BookingSheet({super.key, required this.classRow, this.onClose});

  @override
  ConsumerState<BookingSheet> createState() => _BookingSheetState();
}

class _BookingSheetState extends ConsumerState<BookingSheet> {
  late Future<List<EligibleEntitlement>> _eligible;
  // Server-side preview for the currently-selected entitlement. Tells
  // the UI whether the user can book, whether +1 is eligible, and why
  // not if it isn't — without any client-side eligibility logic.
  BookingPreview? _preview;
  String? _selectedEntitlementId;
  bool _plusOne = false;
  final _friendName = TextEditingController();
  bool _submitting = false;
  String? _conflict;
  // Becomes true once eligibility resolves to an empty list — the user
  // has no pass that covers this class. Drives the bottom CTA to switch
  // from "Book this class" to "Buy pass and book".
  bool _eligibleEmpty = false;
  // Set when the eligibility request itself failed (vs. resolved-but-
  // empty). We suppress the bottom Book CTA in this case — without
  // eligibility we can't decide between "Book this class" and "Buy pass
  // and book", so showing either would mislead.
  bool _eligibleErrored = false;
  // Monotonic id for in-flight preview requests. Drop responses whose
  // id is older than the latest issued — guards against a slow earlier
  // selection clobbering a faster later one when the user picks quickly.
  int _previewSeq = 0;

  /// Close the sheet after a successful mutation. Routes through the
  /// caller-supplied [BookingSheet.onClose] when one was provided
  /// (desktop docked-panel case); otherwise falls back to the mobile
  /// default of popping the route with a `true` result.
  void _close(BuildContext context) {
    final cb = widget.onClose;
    if (cb != null) {
      cb();
    } else {
      Navigator.of(context).pop(true);
    }
  }

  @override
  void dispose() {
    _friendName.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final api = ref.read(apiClientProvider);
    _eligible = api.eligibleEntitlements(widget.classRow.id);
    _eligible
        .then((list) {
          if (!mounted) return;
          if (list.isEmpty) {
            setState(() => _eligibleEmpty = true);
            return;
          }
          // Pick a smarter default than "first in the list" — use-it-before-
          // you-lose-it logic so a credit expiring tomorrow ranks ahead of an
          // unlimited that's safe for weeks. See pickDefaultEntitlement.
          final pick = pickDefaultEntitlement(list).id;
          setState(() => _selectedEntitlementId ??= pick);
          _fetchPreview(_selectedEntitlementId!);
        })
        .catchError((_) {
          if (!mounted) return;
          setState(() => _eligibleErrored = true);
        });
  }

  Future<void> _fetchPreview(String entitlementId) async {
    final reqId = ++_previewSeq;
    try {
      final p = await ref
          .read(apiClientProvider)
          .bookingPreview(
            classId: widget.classRow.id,
            entitlementId: entitlementId,
          );
      if (!mounted || reqId != _previewSeq) return;
      setState(() {
        _preview = p;
        // If the server says +1 isn't allowed for this selection but the
        // user had toggled it on for a previous selection, clear it now
        // so we don't send a request the server would reject.
        if (!p.plusOneEligible) _plusOne = false;
      });
    } catch (_) {
      // Preview failure shouldn't block the user — fall through and let
      // CreateBooking surface the real error if they try to book.
    }
  }

  void _onPickEntitlement(String id) {
    setState(() => _selectedEntitlementId = id);
    _fetchPreview(id);
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final c = widget.classRow;
    final boot = ref.watch(bootstrapProvider).value;
    // Server-authoritative gate for the +1 toggle. Until the preview
    // arrives we hide the toggle to avoid showing-then-hiding it.
    final plusOneEligible = _preview?.plusOneEligible ?? false;
    final cutoffHours = boot?.studio.freeCancelCutoffHours ?? 12;
    final localStart = c.startsAt.toLocal();
    const dowFull = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final dow = dowFull[(localStart.weekday + 6) % 7];
    final timeLabel =
        '${localStart.hour}:${localStart.minute.toString().padLeft(2, '0')}';
    final dateMeta = '$dow ${localStart.day} · $timeLabel · ${c.roomName}';

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: y.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
        child: SafeArea(
          top: false,
          child: Column(
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
                c.title,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: y.text,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    dateMeta,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: y.muted,
                    ),
                  ),
                  const Spacer(),
                  if (c.bookingState == BookingState.available &&
                      c.spotsLeft > 0 &&
                      c.spotsLeft <= 3)
                    YChip(
                      kind: YChipKind.accent,
                      label: '${c.spotsLeft} spots left',
                    )
                  else if (c.bookingState == BookingState.full)
                    const YChip(kind: YChipKind.full, label: 'Full class'),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  YAvatar(name: c.instructorName, size: 30),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'with ${c.instructorName} · ${c.bookedCount} of ${c.capacity} booked',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: y.muted,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              // Group chat for the class — visible to anyone eligible to
              // join: a booked student, a waitlister, or staff. Server
              // gates the actual open; this is just the discoverability
              // affordance. Suppressed on desktop (onClose != null), where
              // the docked panel hosts a Class | Chat TabBar that exposes
              // the same chat — having a row here too would be redundant.
              if (widget.onClose == null &&
                  (c.bookingState == BookingState.booked ||
                      c.waitlistPosition != null))
                _ClassChatRow(classId: c.id),
              if (c.bookingState == BookingState.booked)
                _BookedActions(
                  classRow: c,
                  cutoffHours: cutoffHours,
                  onCancelled: () => _close(context),
                )
              else if (c.bookingState == BookingState.full)
                _FullClassActions(classRow: c, onChanged: () => _close(context))
              else
                _PayWithSection(
                  eligible: _eligible,
                  selected: _selectedEntitlementId,
                  onSelect: _onPickEntitlement,
                ),
              if (c.bookingState == BookingState.available &&
                  plusOneEligible) ...[
                const SizedBox(height: 12),
                _PlusOneToggle(
                  on: _plusOne,
                  onChanged: (v) => setState(() => _plusOne = v),
                ),
                if (_plusOne) ...[
                  const SizedBox(height: 8),
                  _FriendNameField(controller: _friendName),
                ],
              ],
              if (_conflict != null) ...[
                const SizedBox(height: 12),
                Text(
                  _conflict!,
                  style: TextStyle(
                    color: const Color(0xFFA33B2E),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (c.bookingState == BookingState.available) ...[
                const SizedBox(height: 14),
                // Server-authoritative: if BookingPreview says canBook is
                // false (class started, full, no credits, etc.), hide the
                // Book button and show the reason instead. Until the
                // preview resolves we keep the button enabled — the worst
                // case is a doomed request that surfaces _conflict.
                if (_preview != null && !_preview!.canBook) ...[
                  Container(
                    key: const Key('booking-block-message'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: y.surface2,
                      borderRadius: BorderRadius.circular(y.radiusCard),
                    ),
                    child: Text(
                      _preview!.blockMessage.isEmpty
                          ? "You can't book this class right now."
                          : _preview!.blockMessage,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: y.muted,
                      ),
                    ),
                  ),
                ] else if (_eligibleErrored) ...[
                  // Eligibility lookup failed — we don't know whether to
                  // offer "Book" or "Buy pass and book", so show the
                  // failure inline and let the user retry by reopening.
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: y.surface2,
                      borderRadius: BorderRadius.circular(y.radiusCard),
                    ),
                    child: Text(
                      "Couldn't check your passes. Close and try again.",
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: y.muted,
                      ),
                    ),
                  ),
                ] else if (_eligibleEmpty) ...[
                  // No pass covers this class — take the user through the
                  // Buy flow, then auto-book this class once the new pass
                  // is in their wallet.
                  YButton(
                    key: const Key('booking-buy-and-book-button'),
                    label: 'Buy pass and book',
                    onTap: _submitting ? null : _buyPassAndBook,
                  ),
                ] else ...[
                  YButton(
                    key: const Key('booking-book-button'),
                    label: _submitting ? 'Booking…' : 'Book this class',
                    onTap: _submitting ? null : _book,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Free cancellation until $cutoffHours hours before. After that, your credit is used.',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: y.muted,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _book() async {
    final api = ref.read(apiClientProvider);
    final eligible = await _eligible;
    // Defensive fallback to the smart-picked entitlement in case the
    // user managed to tap Book before initState's pick landed in state.
    final id =
        _selectedEntitlementId ??
        (eligible.isEmpty ? null : pickDefaultEntitlement(eligible).id);
    if (id == null) {
      setState(() => _conflict = 'No eligible pass — buy one first.');
      return;
    }
    // Friend's name required for +1 — the server enforces this too, but
    // catching client-side gives faster feedback and a friendlier message.
    final friendName = _friendName.text.trim();
    if (_plusOne && friendName.isEmpty) {
      setState(() => _conflict = "Tell us your friend's name first.");
      return;
    }
    setState(() {
      _submitting = true;
      _conflict = null;
    });
    try {
      await api.createBooking(
        classId: widget.classRow.id,
        entitlementId: id,
        plusOne: _plusOne,
        plusOneName: friendName,
      );
      if (mounted) _close(context);
    } on BookingConflict catch (e) {
      setState(() {
        _submitting = false;
        _conflict = e.message;
      });
    } catch (e) {
      setState(() {
        _submitting = false;
        _conflict = ApiError.fromAny(e).message;
      });
    }
  }

  void _buyPassAndBook() {
    final classRow = widget.classRow;
    final localStart = classRow.startsAt.toLocal();
    final classDay = DateTime(
      localStart.year,
      localStart.month,
      localStart.day,
    );
    // Capture nav before pop — after pop, this State's context is being
    // torn down and Navigator.of(context) is unsafe.
    final nav = Navigator.of(context);
    nav.pop(false);
    nav.push(
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          // Bare AppBar gives web users a way back; iOS/Android system
          // back still works without it.
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(ctx).maybePop(),
            ),
          ),
          body: BuyScreen(
            coversClassTypeId: classRow.classTypeId,
            bookAfterPurchaseClassId: classRow.id,
            bookAfterPurchaseDay: classDay,
          ),
        ),
      ),
    );
  }
}

class _FriendNameField extends StatelessWidget {
  final TextEditingController controller;
  const _FriendNameField({required this.controller});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: y.borderStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "FRIEND'S NAME",
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: y.muted,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 2),
          TextField(
            controller: controller,
            textCapitalization: TextCapitalization.words,
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: y.text,
            ),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(vertical: 4),
              hintText: 'e.g. Sam Patel',
            ),
          ),
        ],
      ),
    );
  }
}

/// Banner shown inside the booked-actions section when the caller's
/// booking carries a +1 guest. Includes the friend's name so the student
/// remembers who they brought — useful when re-opening the sheet days
/// after booking.
class _PlusOneBookedBanner extends StatelessWidget {
  final String friendName;
  const _PlusOneBookedBanner({required this.friendName});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: y.accentSoft,
        borderRadius: BorderRadius.circular(y.radiusCard),
      ),
      child: Row(
        children: [
          Icon(Icons.person_add_alt_1, size: 16, color: y.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '+1 for your friend · $friendName',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: y.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlusOneToggle extends StatelessWidget {
  final bool on;
  final ValueChanged<bool> onChanged;
  const _PlusOneToggle({required this.on, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
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
                  'Bring a +1',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: y.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Uses a 2nd credit',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: y.muted,
                  ),
                ),
              ],
            ),
          ),
          Transform.scale(
            scale: 0.85,
            child: Switch(
              value: on,
              onChanged: onChanged,
              activeThumbColor: y.onPrimary,
              activeTrackColor: y.primary,
            ),
          ),
        ],
      ),
    );
  }
}

class _FullClassActions extends ConsumerStatefulWidget {
  final ClassRow classRow;
  final VoidCallback onChanged;
  const _FullClassActions({required this.classRow, required this.onChanged});

  @override
  ConsumerState<_FullClassActions> createState() => _FullClassActionsState();
}

class _FullClassActionsState extends ConsumerState<_FullClassActions> {
  bool _busy = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final pos = widget.classRow.waitlistPosition;
    final joined = pos != null;
    // Tone the explanatory card: accent for "you'll be notified" pre-join,
    // success-leaning for "you're in the queue" post-join.
    final note = joined
        ? "You're #$pos on the waitlist. We'll notify you the moment a spot opens — you'll have 60 minutes to claim it. No charge until you claim."
        : "We'll notify you if a spot opens — you'll have 60 minutes to claim it. No charge until you claim.";
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: joined
              ? const Key('booking-waitlist-joined-note')
              : const Key('booking-waitlist-pre-join-note'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: joined ? y.primarySoft : y.accentSoft,
            borderRadius: BorderRadius.circular(y.radiusCard),
          ),
          child: Row(
            children: [
              Icon(
                joined ? Icons.check_circle_outline_rounded : Icons.list_alt,
                size: 18,
                color: joined ? y.primary : y.accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  note,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: y.text,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(
            _error!,
            style: const TextStyle(
              color: Color(0xFFA33B2E),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        const SizedBox(height: 14),
        if (joined)
          YButton(
            key: const Key('booking-leave-waitlist-button'),
            label: _busy ? 'Leaving…' : 'Leave waitlist',
            variant: YButtonVariant.outline,
            onTap: _busy ? null : _leave,
          )
        else
          YButton(
            key: const Key('booking-join-waitlist-button'),
            label: _busy ? 'Joining…' : 'Join waitlist',
            onTap: _busy ? null : _join,
          ),
      ],
    );
  }

  Future<void> _join() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final pos = await ref
          .read(apiClientProvider)
          .joinWaitlist(widget.classRow.id);
      if (!mounted) return;
      _toast("You're #$pos on the waitlist — we'll notify you.");
      // Pop the sheet — BookScreen refreshes the day, which re-fetches
      // waitlistPosition for this row so the chip reflects the new state.
      widget.onChanged();
    } catch (e) {
      setState(() {
        _busy = false;
        _error = "Couldn't join waitlist: ${ApiError.fromAny(e).message}";
      });
    }
  }

  Future<void> _leave() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).leaveWaitlist(widget.classRow.id);
      if (!mounted) return;
      _toast("You've left the waitlist.");
      widget.onChanged();
    } catch (e) {
      setState(() {
        _busy = false;
        _error = "Couldn't leave waitlist: ${ApiError.fromAny(e).message}";
      });
    }
  }

  void _toast(String msg) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
      );
  }
}

class _PayWithSection extends StatelessWidget {
  final Future<List<EligibleEntitlement>> eligible;
  final String? selected;
  final ValueChanged<String> onSelect;
  const _PayWithSection({
    required this.eligible,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'PAY WITH',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: y.muted,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        FutureBuilder<List<EligibleEntitlement>>(
          future: eligible,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              );
            }
            if (snap.hasError) {
              return Text(
                "Can't load passes: ${snap.error}",
                style: TextStyle(color: y.muted, fontSize: 12),
              );
            }
            final list = snap.data ?? const <EligibleEntitlement>[];
            if (list.isEmpty) {
              return const _NoEligiblePassCTA();
            }
            // Mirror the state's smart-pick rule so the highlighted row
            // matches the entitlement the booking will actually consume
            // even before _BookingSheetState's initState.then() lands.
            final preselect = selected ?? pickDefaultEntitlement(list).id;
            return Column(
              children: [
                for (final e in list) ...[
                  _EntitlementRow(
                    item: e,
                    selected: e.id == preselect,
                    onTap: () => onSelect(e.id),
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

class _EntitlementRow extends StatelessWidget {
  final EligibleEntitlement item;
  final bool selected;
  final VoidCallback onTap;
  const _EntitlementRow({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final meta = item.passKind == 'unlimited'
        ? 'Unlimited · expires ${_d(item.expiresAt)}'
        : '${item.creditsRemaining ?? 0} credits left · expires ${_d(item.expiresAt)}';
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? y.primarySoft : y.surface,
          borderRadius: BorderRadius.circular(y.radiusCard),
          border: Border.all(
            color: selected ? y.primary : y.border,
            width: selected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? y.primary : y.borderStrong,
                  width: 1.5,
                ),
              ),
              alignment: Alignment.center,
              child: selected
                  ? Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: y.primary,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.label,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                      color: y.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    meta,
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
              item.passKind == 'unlimited' ? 'Unlimited' : '1 credit',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: y.primaryStrong,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _d(DateTime? d) {
    if (d == null) return '—';
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
    final local = d.toLocal();
    return '${local.day} ${mons[local.month - 1]}';
  }
}

class _BookedActions extends ConsumerStatefulWidget {
  final ClassRow classRow;
  final int cutoffHours;
  final VoidCallback onCancelled;
  const _BookedActions({
    required this.classRow,
    required this.cutoffHours,
    required this.onCancelled,
  });

  @override
  ConsumerState<_BookedActions> createState() => _BookedActionsState();
}

class _BookedActionsState extends ConsumerState<_BookedActions> {
  // Pre-fetched server preview. While null we still show the cancel
  // button (assume it works); when the preview arrives we'll either
  // confirm or hide the button + show the reason.
  CancelPreview? _preview;
  bool _cancelling = false;
  String? _error;
  // Credit passes that could fund a +1 on this class (the eligible list
  // filtered to credit kind — a +1 can't be paid by an unlimited pass). The
  // "Add a friend" button only appears when this is non-empty, and it seeds
  // the pass picker in the add sheet. Null while loading; never fetched when
  // the caller already brought a +1.
  List<EligibleEntitlement>? _plusOnePasses;

  @override
  void initState() {
    super.initState();
    final id = widget.classRow.bookingId;
    if (id != null) {
      ref
          .read(apiClientProvider)
          .cancelPreview(id)
          .then((p) {
            if (!mounted) return;
            setState(() => _preview = p);
          })
          .catchError((_) {
            // Preview failure is non-fatal — leave the button enabled and
            // let an actual cancel attempt surface the real error.
          });
    }
    // Only matters when they booked solo — fetch the passes that could pay
    // for a +1 so we can show (or hide) the "Add a friend" affordance.
    if (widget.classRow.myPlusOneName == null) {
      ref
          .read(apiClientProvider)
          .eligibleEntitlements(widget.classRow.id)
          .then((list) {
            if (!mounted) return;
            setState(
              () => _plusOnePasses = list
                  .where((e) => e.passKind == 'credit')
                  .toList(),
            );
          })
          .catchError((_) {
            if (mounted) setState(() => _plusOnePasses = const []);
          });
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    // Server says cancellation is blocked (e.g. class has started) —
    // hide the cancel button outright and show why.
    if (_preview != null && !_preview!.canCancel) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const YChip(
            kind: YChipKind.booked,
            label: 'You were booked',
            leadingCheck: true,
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: y.surface2,
              borderRadius: BorderRadius.circular(y.radiusCard),
            ),
            child: Text(
              _preview!.blockMessage.isEmpty
                  ? "Cancellation isn't available for this booking."
                  : _preview!.blockMessage,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: y.muted,
              ),
            ),
          ),
        ],
      );
    }
    final friendName = widget.classRow.myPlusOneName;
    // Offer "add a friend after the fact" when the caller booked solo, the
    // studio allows +1 guests, AND they hold at least one credit pass that
    // could fund it — so the button never shows for an unlimited-only / no-
    // spare-credit student. The server still does the authoritative check.
    final plusOneAllowed =
        ref.watch(bootstrapProvider).value?.studio.allowStudentPlusOne ?? false;
    final canAddPlusOne =
        friendName == null &&
        plusOneAllowed &&
        (_plusOnePasses?.isNotEmpty ?? false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const YChip(
          kind: YChipKind.booked,
          label: 'You\'re booked',
          leadingCheck: true,
        ),
        if (friendName != null) ...[
          const SizedBox(height: 10),
          _PlusOneBookedBanner(friendName: friendName),
        ],
        const SizedBox(height: 14),
        if (_error != null) ...[
          Text(
            _error!,
            style: const TextStyle(color: Color(0xFFA33B2E), fontSize: 13),
          ),
          const SizedBox(height: 10),
        ],
        if (canAddPlusOne) ...[
          YButton(
            key: const Key('booking-add-plus-one-button'),
            label: 'Add a friend (+1)',
            variant: YButtonVariant.outline,
            onTap: _cancelling ? null : _addPlusOne,
          ),
          const SizedBox(height: 8),
          Text(
            'Brings a guest on a credit from a pass you choose.',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: y.muted,
            ),
          ),
          const SizedBox(height: 14),
        ] else if (friendName == null &&
            plusOneAllowed &&
            (_plusOnePasses?.isEmpty ?? false)) ...[
          // Booked solo, the studio allows guests, but no credit pass can
          // fund a +1 (on an unlimited, out of credits, or no pass covering
          // this class type). A guest seat costs one credit from a pass that
          // covers this class — a single drop-in or a credit pack both work,
          // so the studio gets full value for the friend.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: y.surface2,
              borderRadius: BorderRadius.circular(y.radiusCard),
            ),
            child: Row(
              children: [
                Icon(Icons.person_add_alt_1, size: 16, color: y.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Want to bring a friend? Buy a pass that covers this '
                    'class and you can add a +1 to this booking.',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: y.muted,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
        YButton(
          key: const Key('booking-cancel-button'),
          label: _cancelling ? 'Cancelling…' : 'Cancel booking',
          variant: YButtonVariant.outline,
          onTap: _cancelling ? null : _cancel,
        ),
        const SizedBox(height: 8),
        Text(
          friendName != null
              ? 'Cancelling releases both seats. Free until ${widget.cutoffHours} hours before.'
              : 'Free cancellation until ${widget.cutoffHours} hours before.',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: y.muted,
          ),
        ),
      ],
    );
  }

  Future<void> _cancel() async {
    final id = widget.classRow.bookingId;
    if (id == null) return;
    final api = ref.read(apiClientProvider);
    // Ask the server what would happen right now — single source of truth.
    // Avoids the client and server disagreeing about whether we're past
    // the cutoff (TZ, clock skew, etc.).
    CancelPreview preview;
    try {
      preview = await api.cancelPreview(id);
    } catch (e) {
      setState(
        () => _error =
            "Couldn't check cancel policy: ${ApiError.fromAny(e).message}",
      );
      return;
    }
    if (!mounted) return;
    final ok = await _showCancelConfirm(context, preview: preview);
    if (ok != true || !mounted) return;
    setState(() {
      _cancelling = true;
      _error = null;
    });
    try {
      await api.cancelBooking(id);
      widget.onCancelled();
    } catch (e) {
      setState(() {
        _cancelling = false;
        _error = "Couldn't cancel: ${ApiError.fromAny(e).message}";
      });
    }
  }

  Future<void> _addPlusOne() async {
    final passes = _plusOnePasses ?? const <EligibleEntitlement>[];
    if (passes.isEmpty) return;
    // The add sheet handles name + pass choice + the API call itself, and
    // pops `true` once the +1 lands.
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          _AddPlusOneSheet(classId: widget.classRow.id, passes: passes),
    );
    if (ok == true && mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('Added your +1')));
      // Close the booking sheet — the day refreshes and re-fetches
      // myPlusOneName so a reopen shows the guest banner.
      widget.onCancelled();
    }
  }

  /// Confirm-dialog body. Branches on the cancel outcome (late / free)
  /// AND on whether a +1 is attached — the +1 path mentions the friend
  /// by name and uses plural "credits" framing because the cascade
  /// releases both bookings + (on free cancel) refunds both credits.
  String _cancelBody({
    required CancelPreview preview,
    required String? friendName,
  }) {
    final hasPlusOne = friendName != null;
    if (preview.isLate) {
      if (hasPlusOne) {
        return "You're past the free-cancellation window "
            "(${widget.cutoffHours} hours before start). Cancelling now "
            "releases your seat and your friend $friendName's, but both "
            "credits stay used.";
      }
      return "You're past the free-cancellation window "
          '(${widget.cutoffHours} hours before start). Cancelling now '
          "will use your credit — you won't get it back to your wallet.";
    }
    if (preview.creditWillReturn) {
      if (hasPlusOne) {
        return "Both your credit and $friendName's come back to your "
            "wallet, and both seats open up. Free until "
            "${widget.cutoffHours} hours before the class.";
      }
      return 'Your credit will come back to your wallet. Free '
          'cancellation is open until ${widget.cutoffHours} hours '
          'before the class.';
    }
    // Unlimited pass — nothing to refund, just seats opening up.
    if (hasPlusOne) {
      return "You can cancel for free. Both your seat and $friendName's "
          "open up — unlimited passes don't carry credits to refund.";
    }
    return 'You can cancel for free. Unlimited passes don\'t carry a '
        'credit to refund — the seat just opens up for someone else.';
  }

  /// Primary-action label on the confirm dialog. "Cancel & use credit"
  /// becomes plural when a +1 is attached so the action's consequence
  /// matches the body copy above.
  String _cancelCta({required bool isLate, required bool hasPlusOne}) {
    if (isLate) {
      return hasPlusOne ? 'Cancel & use credits' : 'Cancel & use credit';
    }
    return hasPlusOne ? 'Cancel both' : 'Cancel booking';
  }

  Future<bool?> _showCancelConfirm(
    BuildContext context, {
    required CancelPreview preview,
  }) {
    final y = context.yoga;
    final friend = widget.classRow.myPlusOneName;
    final hasPlusOne = friend != null;
    // Title shifts when a +1 is attached so the user understands the
    // action is releasing two seats, not one.
    final title = preview.isLate
        ? (hasPlusOne ? 'Cancel both seats late?' : 'Cancel late?')
        : (hasPlusOne ? 'Cancel both bookings?' : 'Cancel this booking?');
    final body = _cancelBody(preview: preview, friendName: friend);
    return showDialog<bool>(
      context: context,
      barrierColor: const Color(0x66100A05),
      builder: (ctx) => AlertDialog(
        backgroundColor: y.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(y.radiusCard),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: preview.isLate ? const Color(0xFFA33B2E) : y.text,
          ),
        ),
        content: Text(
          body,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w500,
            color: y.text,
            height: 1.45,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Keep booking',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: y.muted,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              _cancelCta(
                isLate: preview.isLate,
                hasPlusOne: widget.classRow.myPlusOneName != null,
              ),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: preview.isLate ? const Color(0xFFA33B2E) : y.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoEligiblePassCTA extends StatelessWidget {
  const _NoEligiblePassCTA();

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
          Icon(Icons.shopping_bag_outlined, color: y.muted, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'No eligible pass — buy one first.',
              style: TextStyle(
                fontSize: 13.5,
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

/// Opens (or lazy-creates) the class chat — visible in the booking sheet
/// to any caller eligible to join the room (booked, on the waitlist, or
/// staff). Server gates the real check; this is the discoverability path.
class _ClassChatRow extends ConsumerStatefulWidget {
  final String classId;
  const _ClassChatRow({required this.classId});

  @override
  ConsumerState<_ClassChatRow> createState() => _ClassChatRowState();
}

class _ClassChatRowState extends ConsumerState<_ClassChatRow> {
  bool _opening = false;

  Future<void> _open() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final api = ref.read(apiClientProvider);
      final conv = await api.openClassChat(widget.classId);
      // Me lives on the bootstrap; it's already resolved by the time the
      // booking sheet renders so this is a synchronous read.
      final me = ref.read(bootstrapProvider).asData?.value.me;
      if (!mounted || me == null) return;
      ref.invalidate(conversationsProvider);
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatThreadScreen(
            conversationId: conv.id,
            initialConversation: conv,
            me: me,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Couldn't open chat: ${ApiError.fromAny(e).message}"),
        ),
      );
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: y.surface2,
        borderRadius: BorderRadius.circular(y.radiusCard),
        child: InkWell(
          onTap: _opening ? null : _open,
          borderRadius: BorderRadius.circular(y.radiusCard),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(Icons.forum_outlined, size: 18, color: y.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Group chat',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: y.text,
                    ),
                  ),
                ),
                if (_opening)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(Icons.chevron_right, size: 18, color: y.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet for adding a +1 to a class you already booked solo. Collects
/// the friend's name and which CREDIT pass to charge (the caller may hold
/// several), then posts it. Pops `true` once the +1 is created so the booking
/// sheet can close + refresh.
class _AddPlusOneSheet extends ConsumerStatefulWidget {
  final String classId;
  final List<EligibleEntitlement> passes;
  const _AddPlusOneSheet({required this.classId, required this.passes});

  @override
  ConsumerState<_AddPlusOneSheet> createState() => _AddPlusOneSheetState();
}

class _AddPlusOneSheetState extends ConsumerState<_AddPlusOneSheet> {
  final _friendName = TextEditingController();
  late String _selectedId = pickDefaultEntitlement(widget.passes).id;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _friendName.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final friend = _friendName.text.trim();
    if (friend.isEmpty) {
      setState(() => _error = "Tell us your friend's name first.");
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref
          .read(apiClientProvider)
          .addPlusOne(
            classId: widget.classId,
            entitlementId: _selectedId,
            plusOneName: friend,
          );
      if (mounted) Navigator.of(context).pop(true);
    } on BookingConflict catch (e) {
      setState(() {
        _submitting = false;
        _error = e.message;
      });
    } catch (e) {
      setState(() {
        _submitting = false;
        _error = "Couldn't add +1: ${ApiError.fromAny(e).message}";
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
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
        child: SafeArea(
          top: false,
          child: Column(
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
                'Add a friend',
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: y.text,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Brings a +1 on one of your credit passes.',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: y.muted,
                ),
              ),
              const SizedBox(height: 16),
              _FriendNameField(controller: _friendName),
              const SizedBox(height: 16),
              Text(
                'PAY WITH',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: y.muted,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              for (final e in widget.passes) ...[
                _EntitlementRow(
                  item: e,
                  selected: e.id == _selectedId,
                  onTap: () => setState(() => _selectedId = e.id),
                ),
                const SizedBox(height: 8),
              ],
              if (_error != null) ...[
                const SizedBox(height: 4),
                Text(
                  _error!,
                  style: const TextStyle(
                    color: Color(0xFFA33B2E),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              YButton(
                key: const Key('add-plus-one-confirm-button'),
                label: _submitting ? 'Adding…' : 'Add +1',
                onTap: _submitting ? null : _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
