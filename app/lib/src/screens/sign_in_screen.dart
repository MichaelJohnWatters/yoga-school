// Sign-in screen — Firebase Auth via the local emulator in dev.
// Mirrors yoga-onboard.jsx YSignInScreen at a high level.
//
// Dev affordance: a "Dev login" dropdown populates email + password for any
// of the seeded test users (Maya, Priya). It only renders in debug builds.

import 'package:firebase_auth/firebase_auth.dart';
import '../api/api_error.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_state.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/yoga_primitives.dart';

class _DevAccount {
  final String label;
  final String email;
  final String password;
  const _DevAccount(this.label, this.email, this.password);
}

// Test accounts that exercise different wallet / pass shapes — keep this
// list in sync with scripts/seed-firebase-users.sh. Each label describes
// what the student's wallet looks like after the seed, so picking a row
// puts you straight into a known scenario.
const _devAccounts = <_DevAccount>[
  _DevAccount('Priya · manager', 'priya@studio52.dev', 'dev123456'),
  _DevAccount(
    'Maya · unlimited (basic student)',
    'maya@studio52.dev',
    'dev123456',
  ),
  _DevAccount(
    'Aria · 10-pack + new unlimited',
    'aria.lin@studio52.dev',
    'dev123456',
  ),
  _DevAccount(
    'Ben · unlimited + reformer pack',
    'ben.carter@studio52.dev',
    'dev123456',
  ),
  _DevAccount(
    'Chen · reformer-only (2/5 credits)',
    'chen.wei@studio52.dev',
    'dev123456',
  ),
  _DevAccount(
    'Diego · no credits left',
    'diego.rivera@studio52.dev',
    'dev123456',
  ),
  _DevAccount(
    'Grace · yoga 5-pack (4/5)',
    'grace.okoye@studio52.dev',
    'dev123456',
  ),
  _DevAccount(
    'Ivy · 10-pack + reformer pack',
    'ivy.nakamura@studio52.dev',
    'dev123456',
  ),
  _DevAccount(
    'Kira · current + depleted history',
    'kira.walker@studio52.dev',
    'dev123456',
  ),
];

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

enum _AuthMode { signIn, signUp }

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _fullName = TextEditingController();
  _AuthMode _mode = _AuthMode.signIn;
  bool _busy = false;
  String? _error;

  bool get _isSignUp => _mode == _AuthMode.signUp;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _fullName.dispose();
    super.dispose();
  }

  void _toggleMode() {
    setState(() {
      _mode = _isSignUp ? _AuthMode.signIn : _AuthMode.signUp;
      _error = null;
    });
  }

  Future<void> _submit() async {
    // Pre-flight validation — Firebase's own errors are useful but slow
    // (network roundtrip). Catch the obvious cases up front.
    if (_email.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() => _error = 'Email and password are required.');
      return;
    }
    if (_isSignUp && _fullName.text.trim().isEmpty) {
      setState(() => _error = 'Tell us your name so we can greet you.');
      return;
    }
    if (_isSignUp && _password.text.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final auth = ref.read(authServiceProvider);
      if (_isSignUp) {
        await auth.createAccount(
          email: _email.text,
          password: _password.text,
          fullName: _fullName.text,
        );
      } else {
        await auth.signIn(email: _email.text, password: _password.text);
      }
      // auth state stream will fire and root will rebuild; nothing more to do.
    } on FirebaseAuthException catch (e) {
      setState(() {
        _busy = false;
        _error = _friendly(e);
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Something went wrong: ${ApiError.fromAny(e).message}';
      });
    }
  }

  String _friendly(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
        return "That email doesn't look right.";
      case 'user-not-found':
      case 'invalid-credential':
      case 'wrong-password':
        return "Email and password don't match.";
      case 'email-already-in-use':
        return 'An account with that email already exists. Try signing in.';
      case 'weak-password':
        return 'Password is too weak — use at least 6 characters.';
      case 'network-request-failed':
        return 'Network error — is the auth emulator running?';
      default:
        return e.message ?? e.code;
    }
  }

  void _useDevAccount(_DevAccount a) {
    setState(() {
      _email.text = a.email;
      _password.text = a.password;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Scaffold(
      backgroundColor: y.background,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 30),
                  Center(child: const YLogo(size: 52)),
                  const SizedBox(height: 24),
                  Text(
                    _isSignUp ? 'Create your account' : 'Welcome to Studio 52',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 27,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                      color: y.text,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'Sign in to book classes and manage your passes.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                      color: y.muted,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Dev picker only makes sense for sign-in — the seeded
                  // users already exist on the emulator.
                  if (kDebugMode && !_isSignUp) ...[
                    _DevPicker(onPick: _useDevAccount),
                    const SizedBox(height: 14),
                  ],
                  if (_isSignUp) ...[
                    _LabeledField(
                      label: 'FULL NAME',
                      controller: _fullName,
                      keyboardType: TextInputType.name,
                    ),
                    const SizedBox(height: 10),
                  ],
                  _LabeledField(
                    label: 'EMAIL',
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 10),
                  _LabeledField(
                    label: 'PASSWORD',
                    controller: _password,
                    obscure: true,
                    onSubmitted: (_) => _submit(),
                  ),
                  if (!_isSignUp) ...[
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerRight,
                      child: GestureDetector(
                        onTap: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Password reset not wired in dev.'),
                            ),
                          );
                        },
                        child: Text(
                          'Forgot password?',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: y.primary,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: const TextStyle(
                        color: Color(0xFFA33B2E),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  YButton(
                    label: _busy
                        ? (_isSignUp ? 'Creating…' : 'Signing in…')
                        : (_isSignUp ? 'Create account' : 'Sign in'),
                    onTap: _busy ? null : _submit,
                  ),
                  const SizedBox(height: 22),
                  Center(
                    child: GestureDetector(
                      key: const Key('auth-toggle-mode'),
                      behavior: HitTestBehavior.opaque,
                      onTap: _busy ? null : _toggleMode,
                      child: RichText(
                        textAlign: TextAlign.center,
                        text: TextSpan(
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: y.muted,
                          ),
                          children: [
                            TextSpan(
                              text: _isSignUp
                                  ? 'Already have an account? '
                                  : 'New here? ',
                            ),
                            TextSpan(
                              text: _isSignUp ? 'Sign in' : 'Create an account',
                              style: TextStyle(
                                color: y.primary,
                                fontWeight: FontWeight.w800,
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
          ),
        ),
      ),
    );
  }
}

class _DevPicker extends StatelessWidget {
  final ValueChanged<_DevAccount> onPick;
  const _DevPicker({required this.onPick});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(y.radiusCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bolt_outlined, size: 14, color: y.muted),
              const SizedBox(width: 6),
              Text(
                'DEV LOGIN',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: y.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          PopupMenuButton<_DevAccount>(
            onSelected: onPick,
            itemBuilder: (context) => [
              for (final a in _devAccounts)
                PopupMenuItem(
                  value: a,
                  child: Text(
                    a.label,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: y.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: y.border),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Pick a test user…',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: y.text,
                      ),
                    ),
                  ),
                  Icon(Icons.arrow_drop_down, size: 18, color: y.muted),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LabeledField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final bool obscure;
  final TextInputType keyboardType;
  final ValueChanged<String>? onSubmitted;
  const _LabeledField({
    required this.label,
    required this.controller,
    this.obscure = false,
    this.keyboardType = TextInputType.text,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: y.borderStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: y.muted,
            ),
          ),
          const SizedBox(height: 2),
          TextField(
            controller: controller,
            obscureText: obscure,
            keyboardType: keyboardType,
            onSubmitted: onSubmitted,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: y.text,
            ),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(vertical: 4),
            ),
          ),
        ],
      ),
    );
  }
}
