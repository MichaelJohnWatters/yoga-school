// Firebase Auth wiring + Riverpod providers.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Stream of FirebaseAuth state changes — emits `null` when signed out.
final firebaseUserProvider = StreamProvider<User?>((ref) {
  return FirebaseAuth.instance.authStateChanges();
});

/// Wraps the common sign-in / sign-out calls and exposes them via a provider
/// so the UI doesn't need to import FirebaseAuth directly.
class AuthService {
  final FirebaseAuth _auth;
  AuthService(this._auth);

  Future<UserCredential> signIn({
    required String email,
    required String password,
  }) {
    return _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  /// Create a Firebase Auth account and stamp the display name on it so
  /// the server's /me handler can read it from the token's `name` claim
  /// when it auto-provisions the student row. The auth-state stream fires
  /// on success and the rest of the bootstrap takes over.
  ///
  /// We immediately send a verification email: the server rejects tokens whose
  /// email isn't verified (identity is keyed on the email claim, so an
  /// unverified address can't be trusted), so the user must confirm the link
  /// before the API will serve them.
  Future<UserCredential> createAccount({
    required String email,
    required String password,
    required String fullName,
  }) async {
    final cred = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final name = fullName.trim();
    if (name.isNotEmpty) {
      await cred.user?.updateDisplayName(name);
      // updateDisplayName mutates the local user but the ID token still
      // carries the old (empty) name claim until refresh — force one so
      // the very first /me request after sign-up sees the new name.
      await cred.user?.getIdToken(true);
    }
    await cred.user?.sendEmailVerification();
    return cred;
  }

  Future<void> signOut() => _auth.signOut();

  /// Whether the signed-in user has confirmed their email. False when signed
  /// out. The UI gates entry to the app on this (the server does too, with a
  /// 403), and offers [sendVerificationEmail] + [reloadUser] to recover.
  bool get emailVerified => _auth.currentUser?.emailVerified ?? false;

  /// (Re)send the verification link to the current user's email. Safe to call
  /// from a "resend" button; Firebase rate-limits repeated sends.
  Future<void> sendVerificationEmail() =>
      _auth.currentUser?.sendEmailVerification() ?? Future.value();

  /// Reload the user from Firebase and return whether the email is now
  /// verified. Call after the user says they've clicked the link; on a true
  /// result force-refresh the ID token so the next request carries the
  /// verified bit, then let the auth-state stream drive the app forward.
  Future<bool> reloadUser() async {
    final u = _auth.currentUser;
    if (u == null) return false;
    await u.reload();
    final verified = _auth.currentUser?.emailVerified ?? false;
    if (verified) {
      await _auth.currentUser?.getIdToken(true);
    }
    return verified;
  }

  /// Fetch a fresh ID token. Used by the Dio interceptor for every request.
  /// Returns null if the user signed out between the request being queued
  /// and reaching the interceptor.
  Future<String?> currentIdToken({bool forceRefresh = false}) async {
    final u = _auth.currentUser;
    if (u == null) return null;
    return u.getIdToken(forceRefresh);
  }
}

final authServiceProvider =
    Provider<AuthService>((_) => AuthService(FirebaseAuth.instance));
