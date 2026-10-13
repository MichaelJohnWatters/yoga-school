// Email-verification gate.
//
// The server rejects API tokens whose email isn't verified (identity is keyed
// on the email claim, so an unverified address can't be trusted — see the
// server's auth.Verify). This screen stands between sign-in and the app for a
// signed-in-but-unverified user: it (re)sends the verification link and lets
// them continue once they've clicked it.
//
// Only reached in release builds — in debug the app talks to the Firebase Auth
// emulator (emailVerified is false there) and the server skips the check, so
// main.dart gates this screen behind !kDebugMode to mirror that.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_state.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/yoga_primitives.dart';

class EmailVerificationScreen extends ConsumerStatefulWidget {
  final User user;
  const EmailVerificationScreen({super.key, required this.user});

  @override
  ConsumerState<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState
    extends ConsumerState<EmailVerificationScreen> with WidgetsBindingObserver {
  bool _sending = false;
  bool _checking = false;
  String? _error;
  String? _notice;

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
    // The user most likely clicked the verification link in a browser while the
    // app was backgrounded. Re-check on resume so they aren't stranded here
    // having to also remember to tap "continue".
    if (state == AppLifecycleState.resumed && !_checking) {
      _refreshVerified(silent: true);
    }
  }

  /// Reload the user and, if now verified, re-subscribe the auth stream so the
  /// root gate advances into the app. `silent` suppresses error/"still not
  /// verified" feedback for the automatic on-resume check.
  Future<void> _refreshVerified({required bool silent}) async {
    try {
      final verified = await ref.read(authServiceProvider).reloadUser();
      if (!mounted) return;
      if (verified) {
        // reloadUser already force-refreshed the ID token; invalidating the
        // provider re-subscribes authStateChanges, which replays the now-
        // verified user so the root gate moves on.
        ref.invalidate(firebaseUserProvider);
        return;
      }
      if (!silent) {
        setState(() => _error =
            "Still not verified — click the link in the email, then try again.");
      }
    } catch (_) {
      // Network / transient failure. Surface it only for an explicit tap; the
      // on-resume auto-check fails quietly and leaves the buttons for a retry.
      if (mounted && !silent) {
        setState(() => _error =
            'Could not reach the server — check your connection and try again.');
      }
    }
  }

  Future<void> _resend() async {
    setState(() {
      _sending = true;
      _error = null;
      _notice = null;
    });
    try {
      await ref.read(authServiceProvider).sendVerificationEmail();
      if (!mounted) return;
      setState(() => _notice = 'Verification email sent — check your inbox.');
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      // The common one here is too-many-requests; surface it plainly.
      setState(() => _error = e.message ?? 'Could not send the email.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
      _notice = null;
    });
    try {
      await _refreshVerified(silent: false);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _signOut() => ref.read(authServiceProvider).signOut();

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final busy = _sending || _checking;

    return Scaffold(
      backgroundColor: y.background,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Verify your email',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: y.primary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'We sent a verification link to',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: y.muted),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.user.email ?? 'your email',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: y.text,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Click it, then come back and continue.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: y.muted),
                  ),
                  const SizedBox(height: 22),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFA33B2E),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_notice != null) ...[
                    Text(
                      _notice!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: y.primary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  YButton(
                    label: _checking ? 'Checking…' : "I've verified — continue",
                    onTap: busy ? null : _check,
                  ),
                  const SizedBox(height: 10),
                  YButton(
                    label: _sending ? 'Sending…' : 'Resend email',
                    variant: YButtonVariant.outline,
                    onTap: busy ? null : _resend,
                  ),
                  const SizedBox(height: 22),
                  Center(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: busy ? null : _signOut,
                      child: Text(
                        'Sign out',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: y.muted,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
