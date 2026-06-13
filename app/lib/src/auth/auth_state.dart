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

  Future<void> signOut() => _auth.signOut();

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
