// Tab-visibility refresh primitive.
//
// IndexedStack-based shells keep every tab's State alive — handy for
// scroll position, painful for "show me fresh data when I tab back."
// initState fires once per session; tab switches don't re-run it.
//
// This file gives screens a way to hook the becomes-visible event:
//   * The shell drives [currentTabProvider] on every tab change.
//   * Screens wrap their body in [OnTabVisible] (or call the static
//     listener helper) and provide an onVisible callback that runs every
//     time their tab becomes the active one — typically a few
//     `ref.invalidate(...)` calls to refresh providers.
//
// The first build counts as a "becomes visible" event so the wrapper can
// also stand in for the addPostFrameCallback initial-refresh pattern.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Index of the visible tab in the surrounding shell. The shell owns
/// this; screens read it. Defaults to 0 so reads before the shell mounts
/// (e.g. a screen that's rendered standalone in a test) don't crash.
class CurrentTabNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void set(int i) {
    if (state != i) state = i;
  }
}

final currentTabProvider =
    NotifierProvider<CurrentTabNotifier, int>(CurrentTabNotifier.new);

/// Fires [onVisible] whenever this widget's [tabIndex] becomes the
/// current tab according to [currentTabProvider]. Also fires once on the
/// frame after first mount when the tab is already the visible one — so
/// the first paint of a screen still gets a refresh tick without the
/// caller having to wire a separate initState hook.
class OnTabVisible extends ConsumerStatefulWidget {
  final int tabIndex;
  final VoidCallback onVisible;
  final Widget child;
  const OnTabVisible({
    super.key,
    required this.tabIndex,
    required this.onVisible,
    required this.child,
  });

  @override
  ConsumerState<OnTabVisible> createState() => _OnTabVisibleState();
}

class _OnTabVisibleState extends ConsumerState<OnTabVisible> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(currentTabProvider) == widget.tabIndex) {
        widget.onVisible();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(currentTabProvider, (prev, next) {
      // Edge-trigger on becomes-visible. If we were the visible tab and
      // still are, no-op (the provider didn't actually transition).
      if (next == widget.tabIndex && prev != widget.tabIndex) {
        widget.onVisible();
      }
    });
    return widget.child;
  }
}
