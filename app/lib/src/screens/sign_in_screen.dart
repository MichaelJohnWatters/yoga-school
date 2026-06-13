// Sign-in screen — Firebase Auth via the local emulator in dev.
// Mirrors yoga-onboard.jsx YSignInScreen at a high level.
//
// Dev affordance: a "Dev login" dropdown populates email + password for any
// of the seeded test users (Maya, Priya). It only renders in debug builds.

import 'package:firebase_auth/firebase_auth.dart';
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

const _devAccounts = <_DevAccount>[
  _DevAccount('Maya · student',  'maya@studio52.dev',  'dev123456'),
  _DevAccount('Priya · manager', 'priya@studio52.dev', 'dev123456'),
];

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authServiceProvider).signIn(
            email: _email.text,
            password: _password.text,
          );
      // auth state stream will fire and root will rebuild; nothing more to do.
    } on FirebaseAuthException catch (e) {
      setState(() {
        _busy = false;
        _error = _friendly(e);
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Something went wrong: $e';
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
                    'Welcome to Studio 52',
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
                  if (kDebugMode) ...[
                    _DevPicker(onPick: _useDevAccount),
                    const SizedBox(height: 14),
                  ],
                  _LabeledField(
                    label: 'EMAIL',
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    onSubmitted: (_) => _signIn(),
                  ),
                  const SizedBox(height: 10),
                  _LabeledField(
                    label: 'PASSWORD',
                    controller: _password,
                    obscure: true,
                    onSubmitted: (_) => _signIn(),
                  ),
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
                    label: _busy ? 'Signing in…' : 'Sign in',
                    onTap: _busy ? null : _signIn,
                  ),
                  const SizedBox(height: 22),
                  Center(
                    child: RichText(
                      text: TextSpan(
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: y.muted,
                        ),
                        children: [
                          const TextSpan(text: 'New to the studio? '),
                          TextSpan(
                            text: 'Create an account',
                            style: TextStyle(
                              color: y.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
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
