// Bottom tab shell. Home is implemented; the rest are stubs until their
// endpoints come online.
//
// Tab structure: Home / Book / Buy / Profile / More.
// (The spec calls for 4 tabs but the design adds Home as leading 5th —
// flagged in the design README; reconcile before shipping.)

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/visible_tab.dart';
import '../widgets/polling.dart';
import 'book_screen.dart';
import 'buy_screen.dart';
import 'home_screen.dart';
import 'more_screen.dart';
import 'notifications_screen.dart';
import 'profile_screen.dart';

// Tab indices — keeping the magic numbers in named constants makes the
// OnTabVisible wrappers below skim like a config rather than a maze of
// 0/1/2/3/4 calls.
const _kTabHome = 0;
const _kTabBook = 1;
const _kTabBuy = 2;
const _kTabProfile = 3;
const _kTabMore = 4;

class RootShell extends ConsumerStatefulWidget {
  final Me me;
  final StudioConfig studio;
  const RootShell({super.key, required this.me, required this.studio});

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell>
    with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from an external hosted-Checkout flow (membership) or add-card
    // browser: refresh the money-side providers so a freshly-activated
    // membership / saved card appears without a manual pull-to-refresh. The
    // webhook is what actually fulfils server-side; this just re-reads it.
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(entitlementsProvider);
      ref.invalidate(paymentMethodsProvider);
    }
  }

  void _setTab(int i) {
    if (i == _index) return;
    setState(() => _index = i);
    // Mirror into the provider so any OnTabVisible wrapper hears about
    // the change. Done outside build so we don't mutate state mid-frame.
    ref.read(currentTabProvider.notifier).set(i);
  }

  static const _tabs = [
    (label: 'Home', icon: Icons.home_outlined),
    (label: 'Book', icon: Icons.calendar_today_outlined),
    (label: 'Buy', icon: Icons.shopping_bag_outlined),
    (label: 'Profile', icon: Icons.person_outline),
    (label: 'More', icon: Icons.more_horiz),
  ];

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    // Honour external tab navigation (e.g. the web checkout return handler
    // sends the student back to Book after a buy-and-book). _setTab mirrors
    // into the provider, so the guard stops this echoing back into a loop.
    ref.listen<int>(currentTabProvider, (_, next) {
      if (next != _index && mounted) setState(() => _index = next);
    });
    // Wires the YStudioTopBar avatar tap to "switch to the Profile tab".
    // ProfileScreen gets null so tapping the avatar there is a no-op
    // rather than a self-rebuild.
    void toProfile() => _setTab(3);
    // Each tab body wraps in OnTabVisible so it gets a refresh tick the
    // first time it becomes visible AND every time the user tabs back to
    // it. The shell is the only place that knows the tab→provider
    // mapping; pushing it down into each screen would mean every screen
    // re-invents the "am I visible" check.
    final pages = <Widget>[
      OnTabVisible(
        tabIndex: _kTabHome,
        onVisible: () => ref.invalidate(upcomingBookingsProvider),
        child: HomeScreen(
          me: widget.me,
          studio: widget.studio,
          onTapProfile: toProfile,
          onBrowseClasses: () => _setTab(_kTabBook),
          onSeePasses: () => _setTab(_kTabBuy),
        ),
      ),
      OnTabVisible(
        tabIndex: _kTabBook,
        // Book is a stateful screen with its own day cache + 10s polling,
        // so the wrapper has nothing to invalidate — the on-visible
        // event is harmless and keeps the wiring symmetric.
        onVisible: () {},
        child: BookScreen(
          me: widget.me,
          studio: widget.studio,
          onTapProfile: toProfile,
        ),
      ),
      OnTabVisible(
        tabIndex: _kTabBuy,
        // productsProvider is a `.family`, but Riverpod invalidates every
        // currently-cached parameterisation when you pass the bare family.
        onVisible: () => ref.invalidate(productsProvider),
        child: BuyScreen(
          buyLayout: widget.studio.buyLayout,
          me: widget.me,
          studio: widget.studio,
          onTapProfile: toProfile,
        ),
      ),
      OnTabVisible(
        tabIndex: _kTabProfile,
        onVisible: () {
          ref.invalidate(entitlementsProvider);
          ref.invalidate(purchasesProvider);
          ref.invalidate(attendanceProvider);
          ref.invalidate(myBookingsUpcomingProvider);
          ref.invalidate(myBookingsPastProvider);
        },
        child: ProfileScreen(me: widget.me, studio: widget.studio),
      ),
      OnTabVisible(
        tabIndex: _kTabMore,
        onVisible: () {},
        child: MoreScreen(
          me: widget.me,
          studio: widget.studio,
          onTapProfile: toProfile,
        ),
      ),
    ];
    return Scaffold(
      backgroundColor: y.background,
      body: SafeArea(
        bottom: false,
        // Background notification polling drives the bell badge on every
        // tab — without it the badge would only refresh when the user
        // opens the notifications screen, which defeats its purpose.
        // The polling cadence is the standard `PollingSurface.notifications`
        // so it picks up the manager's per-page override too.
        child: PollingRefresh(
          surface: PollingSurface.notifications,
          onPoll: () => ref.invalidate(notificationsProvider),
          child: IndexedStack(index: _index, children: pages),
        ),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: y.surface,
          border: Border(top: BorderSide(color: y.border)),
        ),
        padding: const EdgeInsets.only(top: 8, bottom: 26, left: 8, right: 8),
        child: Row(
          children: [
            for (var i = 0; i < _tabs.length; i++)
              Expanded(
                child: InkWell(
                  onTap: () => _setTab(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _tabs[i].icon,
                          size: 23,
                          color: i == _index ? y.primary : y.muted,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _tabs[i].label,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: i == _index
                                ? FontWeight.w700
                                : FontWeight.w600,
                            color: i == _index ? y.primary : y.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
