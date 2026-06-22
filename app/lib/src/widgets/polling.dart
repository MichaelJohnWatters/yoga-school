// Polling surfaces + the widget that ticks them.
//
// Each surface in the app (dashboard, schedule, audit log, …) gets its
// own [PollingSurface] enum entry carrying a base interval and a human
// label. Screens opt in by wrapping their body in [PollingRefresh] and
// naming their surface — never the raw Duration — so every place the
// manager can tune cadence shares the same identity.
//
// User-facing controls live under Settings → Advanced and let the
// manager pick:
//   * A global default speed (Off/Slow/Normal/Fast) that scales the base
//     interval, AND
//   * An optional per-surface override that bypasses the global default.
//
// Pick a base interval roughly by how fast the surface's data moves:
//   * 15-30s  things that change as students interact (roster, check-in)
//   * 30-60s  things that change as the studio operates (dashboard,
//             schedule, notifications)
//   * 2-5min  slow-moving aggregates (reports, audit, students list)
//   * none    catalogue data that only changes via manager edits in the
//             same session (themes, products) — those don't get a
//             PollingSurface at all and rely on direct invalidation.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// All surfaces the app polls. Add a new entry when introducing a new
/// background-refresh screen; the Settings UI lists every value in
/// declaration order, so place new entries somewhere meaningful.
enum PollingSurface {
  dashboard(
    label: 'Manager · Dashboard',
    description: "Today's bookings + revenue summary",
    base: Duration(seconds: 45),
  ),
  schedule(
    label: 'Manager · Schedule',
    description: 'Calendar / sections / timeline views',
    base: Duration(seconds: 60),
  ),
  audit(
    label: 'Manager · Audit log',
    description: 'Cash grants, refunds, cancellations',
    base: Duration(seconds: 90),
  ),
  students(
    label: 'Manager · Students',
    description: 'Member directory list',
    base: Duration(minutes: 2),
  ),
  reports(
    label: 'Manager · Reports',
    description: 'Revenue, attendance, instructor pay',
    base: Duration(minutes: 3),
  ),
  roster(
    label: 'Staff · Class roster',
    description: 'Attendance + waitlist for an open class',
    base: Duration(seconds: 20),
  ),
  checkIn(
    label: 'Staff · Check-in',
    description: 'Door scanner reconciliation',
    base: Duration(seconds: 20),
  ),
  notifications(
    label: 'Student · Notifications',
    description: 'The bell feed',
    base: Duration(seconds: 45),
  ),
  upcomingBookings(
    label: 'Student · Home bookings',
    description: 'Next-up classes on the Home screen',
    base: Duration(seconds: 60),
  ),
  studentBook(
    label: 'Student · Book',
    description: 'Live class list — seat counts, waitlist, fullness',
    base: Duration(seconds: 10),
  ),
  chatList(
    label: 'Chat · Conversations',
    description: 'Inbox list — unread counts + last message',
    base: Duration(seconds: 30),
  ),
  chatThread(
    label: 'Chat · Open conversation',
    description: 'New messages in the thread you have open',
    base: Duration(seconds: 5),
  );

  const PollingSurface({
    required this.label,
    required this.description,
    required this.base,
  });

  /// Human-readable name shown in the Settings UI.
  final String label;

  /// One-line subtitle so the manager knows what each row controls.
  final String description;

  /// Default cadence before global speed + per-surface override apply.
  final Duration base;
}

/// User-controlled polling cadence. Multiplies the base interval; "off"
/// disables periodic polling entirely (the initial post-frame refresh on
/// mount still fires).
enum PollingSpeed {
  off, // no polling, only on-mount refresh
  slow, // 2× the base interval
  normal, // 1×, default
  fast, // 0.5×, dev / busy-studio use
}

/// A per-surface override. Either a [PollingSpeed] preset (which scales
/// the surface's base interval the same way the global default does) or
/// a [CustomInterval] with an absolute duration the manager typed in.
sealed class PollingOverride {
  const PollingOverride();
}

class SpeedOverride extends PollingOverride {
  final PollingSpeed speed;
  const SpeedOverride(this.speed);
}

class CustomInterval extends PollingOverride {
  final Duration interval;
  const CustomInterval(this.interval);
}

class PollingPrefs {
  /// Global default — applied to every surface that doesn't have a
  /// per-surface override.
  final PollingSpeed global;

  /// Per-surface overrides. A surface present here ignores [global];
  /// absent means "use global". A [SpeedOverride] of `off` here is
  /// meaningful — it silences just that one surface.
  final Map<PollingSurface, PollingOverride> overrides;

  const PollingPrefs({
    this.global = PollingSpeed.normal,
    this.overrides = const {},
  });

  PollingPrefs copyWith({
    PollingSpeed? global,
    Map<PollingSurface, PollingOverride>? overrides,
  }) =>
      PollingPrefs(
        global: global ?? this.global,
        overrides: overrides ?? this.overrides,
      );

  /// True iff the surface has a per-surface override (i.e. not following
  /// the global default). Used by the Settings UI to highlight the
  /// "Default" pill differently when it's the active choice.
  bool hasOverride(PollingSurface s) => overrides.containsKey(s);

  /// The polling [Duration] for [s], or null when the effective setting
  /// is "off" (callers treat null as "only refresh on mount").
  Duration? intervalFor(PollingSurface s) {
    final ov = overrides[s];
    if (ov is CustomInterval) return ov.interval;
    final speed = ov is SpeedOverride ? ov.speed : global;
    return _scale(s.base, speed);
  }

  static Duration? _scale(Duration base, PollingSpeed speed) {
    switch (speed) {
      case PollingSpeed.off:
        return null;
      case PollingSpeed.slow:
        return base * 2;
      case PollingSpeed.normal:
        return base;
      case PollingSpeed.fast:
        return base ~/ 2;
    }
  }

  static String speedLabel(PollingSpeed s) => switch (s) {
        PollingSpeed.off => 'Off',
        PollingSpeed.slow => 'Slow',
        PollingSpeed.normal => 'Normal',
        PollingSpeed.fast => 'Fast',
      };
}

/// Format a Duration concisely for the Settings UI — "15s", "1m 30s",
/// "3m". Caller passes null to render "Off".
String formatPollInterval(Duration? d) {
  if (d == null) return 'Off';
  final secs = d.inSeconds;
  if (secs < 60) return '${secs}s';
  final m = secs ~/ 60;
  final r = secs % 60;
  return r == 0 ? '${m}m' : '${m}m ${r}s';
}

/// In-memory polling settings. Survives sidebar nav (provider isn't
/// autoDispose) but resets on a full app restart. Wire a persistence
/// layer (SharedPreferences) when we pull in that dependency — for now,
/// changes are session-local. Adjusted from Settings → Advanced.
class PollingPrefsNotifier extends Notifier<PollingPrefs> {
  @override
  PollingPrefs build() => const PollingPrefs();

  void setGlobal(PollingSpeed s) => state = state.copyWith(global: s);

  /// Apply (or clear) a per-surface override.
  ///
  /// Pass `null` to clear — the surface falls back to the global default.
  /// Pass a [SpeedOverride] for a preset, or a [CustomInterval] for an
  /// absolute duration. Use [setCustomSeconds] when accepting raw user
  /// input so the validation lives in one place.
  void setOverride(PollingSurface s, PollingOverride? override) {
    final next =
        Map<PollingSurface, PollingOverride>.from(state.overrides);
    if (override == null) {
      next.remove(s);
    } else {
      next[s] = override;
    }
    state = state.copyWith(overrides: next);
  }

  /// Convenience for the Settings number field — validates [seconds] and
  /// installs a [CustomInterval] override. Throws [ArgumentError] when
  /// the value is zero or negative; the caller (the text field) should
  /// reject the input rather than swallow the error.
  void setCustomSeconds(PollingSurface s, int seconds) {
    if (seconds <= 0) {
      throw ArgumentError('seconds must be > 0, got $seconds');
    }
    setOverride(s, CustomInterval(Duration(seconds: seconds)));
  }
}

final pollingPrefsProvider =
    NotifierProvider<PollingPrefsNotifier, PollingPrefs>(
        PollingPrefsNotifier.new);

/// Fires [onPoll] once on the frame after this widget is first inserted
/// in the tree (so the cache shows up immediately on a return visit),
/// then again every effective interval for [surface] until disposed.
/// When the surface is configured to `off` the periodic tick is skipped
/// but the on-mount refresh still fires.
///
/// The wrapped child is rebuilt by its own listeners (via `ref.watch`),
/// so this widget never needs to call setState on itself.
class PollingRefresh extends ConsumerStatefulWidget {
  final PollingSurface surface;
  final VoidCallback onPoll;
  final Widget child;
  const PollingRefresh({
    super.key,
    required this.surface,
    required this.onPoll,
    required this.child,
  });

  @override
  ConsumerState<PollingRefresh> createState() => _PollingRefreshState();
}

class _PollingRefreshState extends ConsumerState<PollingRefresh> {
  Timer? _timer;
  Duration? _activeInterval;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onPoll();
      _restartTimer();
    });
  }

  @override
  void didUpdateWidget(PollingRefresh old) {
    super.didUpdateWidget(old);
    if (old.surface != widget.surface) _restartTimer();
  }

  @override
  Widget build(BuildContext context) {
    // Watching the prefs here means a speed change in Settings restarts
    // every active polling timer next frame, no global plumbing needed.
    final prefs = ref.watch(pollingPrefsProvider);
    final scaled = prefs.intervalFor(widget.surface);
    if (scaled != _activeInterval) {
      // Schedule the restart for after build — calling _restartTimer
      // inside build would mutate state mid-frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _restartTimer(override: scaled);
      });
    }
    return widget.child;
  }

  void _restartTimer({Duration? override}) {
    _timer?.cancel();
    final prefs = ref.read(pollingPrefsProvider);
    final i = override ?? prefs.intervalFor(widget.surface);
    _activeInterval = i;
    if (i == null) {
      _timer = null;
      return;
    }
    _timer = Timer.periodic(i, (_) {
      if (mounted) widget.onPoll();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
