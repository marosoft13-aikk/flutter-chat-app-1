// lib/providers/auth_provider.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../utils/diagnostics_store.dart';

class AppUser {
  final String uid;
  final String? email;
  final String? name;
  final String? avatarUrl;

  AppUser({required this.uid, this.email, this.name, this.avatarUrl});
}

class AuthProvider extends ChangeNotifier {
  final fb.FirebaseAuth _auth = fb.FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  // Use constructor (compatible with google_sign_in 5.x)
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: <String>['email', 'profile', 'openid'],
  );

  StreamSubscription<fb.User?>? _authSub;
  StreamSubscription<String>? _fcmTokenSub;

  AppUser? user;
  bool loading = true;
  bool googleSignInAvailable = true;

  Future<void> init() async {
    _authSub = _auth.userChanges().listen(
      _onAuthStateChanged,
      onError: (e) {
        debugPrint('Auth state listener error: $e');
        DiagnosticsStore.addError('Auth state listener error: $e');
      },
    );

    // Non-blocking probe of signInSilently
    try {
      if (!kIsWeb) {
        try {
          final account = await _googleSignIn.signInSilently();
          debugPrint('google signInSilently probe result: $account');
        } catch (e) {
          debugPrint('Silent probe failed (non-fatal): $e');
        }
      }
    } catch (e) {
      debugPrint('Error during google sign-in probe: $e');
    }

    try {
      await _messaging.requestPermission();
    } catch (e) {
      debugPrint('FCM permission request failed: $e');
    }

    _fcmTokenSub = _messaging.onTokenRefresh.listen(
      (token) async {
        if (_auth.currentUser != null && token.isNotEmpty) {
          try {
            await _db.collection('users').doc(_auth.currentUser!.uid).update({
              'fcmTokens': FieldValue.arrayUnion([token]),
            });
          } catch (e) {
            debugPrint('Failed to update refreshed token: $e');
          }
        }
      },
      onError: (e) {
        debugPrint('FCM token refresh error: $e');
      },
    );

    loading = false;
    notifyListeners();
  }

  Future<void> _onAuthStateChanged(fb.User? fbUser) async {
    if (fbUser == null) {
      user = null;
      notifyListeners();
      return;
    }

    final docRef = _db.collection('users').doc(fbUser.uid);
    try {
      final snap = await docRef.get();
      if (!snap.exists) {
        await docRef.set({
          'email': fbUser.email ?? '',
          'name': fbUser.displayName ?? '',
          'avatarUrl': fbUser.photoURL ?? '',
          'fcmTokens': [],
          'lastSeen': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } else {
        await docRef.set({
          'lastSeen': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (e) {
      debugPrint('Error ensuring user doc exists: $e');
      DiagnosticsStore.addError('Error ensuring user doc exists: $e');
    }

    try {
      final token = await _messaging.getToken();
      if (token != null && token.isNotEmpty) {
        await docRef.update({
          'fcmTokens': FieldValue.arrayUnion([token]),
        });
      }
    } catch (e) {
      debugPrint('Failed to save FCM token for user ${fbUser.uid}: $e');
    }

    user = AppUser(
      uid: fbUser.uid,
      email: fbUser.email,
      name: fbUser.displayName,
      avatarUrl: fbUser.photoURL,
    );
    notifyListeners();
  }

  Future<String?> signUpWithEmail(
    String email,
    String password,
    String displayName,
  ) async {
    try {
      final cred = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      await cred.user?.updateDisplayName(displayName);
      return null;
    } on fb.FirebaseAuthException catch (e) {
      debugPrint('signUp error: ${e.code} - ${e.message}');
      DiagnosticsStore.addError('signUp error: ${e.code} - ${e.message}');
      return e.message ?? e.code;
    } catch (e) {
      debugPrint('General signUp error: $e');
      DiagnosticsStore.addError('General signUp error: $e');
      return e.toString();
    }
  }

  Future<String?> signInWithEmail(String email, String password) async {
    try {
      await _auth.signInWithEmailAndPassword(email: email, password: password);
      return null;
    } on fb.FirebaseAuthException catch (e) {
      debugPrint('signInWithEmail error: ${e.code} - ${e.message}');
      DiagnosticsStore.addError(
        'signInWithEmail FirebaseAuthException: ${e.code} - ${e.message}',
      );
      return e.message ?? e.code;
    } catch (e) {
      debugPrint('General signInWithEmail error: $e');
      DiagnosticsStore.addError('signInWithEmail general error: $e');
      return e.toString();
    }
  }

  Future<String?> signInWithGoogle() async {
    try {
      debugPrint('Google sign-in (5.x flow) start. kIsWeb=$kIsWeb');

      if (kIsWeb) {
        final provider = fb.GoogleAuthProvider();
        provider.addScope('email');
        try {
          await _auth.signInWithPopup(provider);
          return null;
        } catch (e) {
          debugPrint('Web google sign-in popup error: $e');
          return 'Google sign-in failed on web: ${e.toString()}';
        }
      }

      // Mobile flow using 5.x API
      GoogleSignInAccount? googleUser;
      try {
        googleUser = await _googleSignIn.signIn();
      } catch (e) {
        debugPrint('google_sign_in.signIn() threw: $e');
        try {
          googleUser = await _googleSignIn.signInSilently();
        } catch (e2) {
          debugPrint('signInSilently also threw: $e2');
          return 'Google sign-in not available on this environment (sign-in UI failed).';
        }
      }

      if (googleUser == null) {
        debugPrint('googleUser is null (user cancelled or UI not available)');
        return 'Sign in cancelled or not available';
      }

      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;
      final String? idToken = googleAuth.idToken;
      final String? accessToken = googleAuth.accessToken;
      final String? serverAuthCode = googleAuth.serverAuthCode;

      debugPrint(
        'Google tokens -> idToken: ${idToken != null}, accessToken: ${accessToken != null}, serverAuthCode: ${serverAuthCode != null}',
      );

      if ((idToken == null || idToken.isEmpty) &&
          (accessToken == null || accessToken.isEmpty)) {
        if (serverAuthCode != null && serverAuthCode.isNotEmpty) {
          return 'Google returned serverAuthCode (needs backend exchange). Check OAuth client settings.';
        }
        return 'Failed to obtain tokens from Google';
      }

      final credential = fb.GoogleAuthProvider.credential(
        idToken: idToken,
        accessToken: accessToken,
      );
      await _auth.signInWithCredential(credential);
      debugPrint('Firebase signInWithCredential succeeded');
      return null;
    } on fb.FirebaseAuthException catch (e) {
      debugPrint(
        'Google sign-in FirebaseAuthException: ${e.code} - ${e.message}',
      );
      DiagnosticsStore.addError(
        'Google sign-in FirebaseAuthException: ${e.code} - ${e.message}',
      );
      return e.message ?? e.code;
    } catch (e, st) {
      debugPrint('Google sign-in unexpected error: $e\n$st');
      DiagnosticsStore.addError('Google sign-in error: $e\n$st');
      final msg = e.toString().toLowerCase();
      if (msg.contains('play services') ||
          msg.contains('google play') ||
          msg.contains('no auth')) {
        return 'Google sign-in not available on this environment';
      }
      return e.toString();
    }
  }

  Future<void> signOut() async {
    final uid = _auth.currentUser?.uid;
    try {
      final token = await _messaging.getToken();
      if (uid != null && token != null && token.isNotEmpty) {
        await _db.collection('users').doc(uid).update({
          'fcmTokens': FieldValue.arrayRemove([token]),
        });
      }
    } catch (e) {
      debugPrint('Failed to remove FCM token on signOut: $e');
    }

    try {
      await _auth.signOut();
    } catch (e) {
      debugPrint('Error signing out from Firebase: $e');
    }

    try {
      await _googleSignIn.signOut();
    } catch (e) {
      debugPrint('Error signing out from GoogleSignIn: $e');
    }

    user = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _fcmTokenSub?.cancel();
    super.dispose();
  }
}
