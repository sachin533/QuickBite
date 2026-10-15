import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/api_exception.dart';
import '../models/user.dart';

enum AuthStatus {
  signedOut,
  signingIn,
  signedIn,
  /// Token was rejected on a protected call — prompt for sign-in again and
  /// stop protected background requests.
  sessionExpired,
}

/// Authentication state. The access token lives in memory only
/// (web requires sign-in after reload; mobile could add secure storage).
class AuthController extends ChangeNotifier {
  AuthController(this._client) {
    // Any protected 401 -> stop background work (polling) and swap to the
    // sign-in screen through the route guard.
    _client.onAuthExpired = sessionExpiredNow;
  }

  final ApiClient _client;

  AuthStatus _status = AuthStatus.signedOut;
  UserSummary? _user;

  AuthStatus get status => _status;
  UserSummary? get user => _user;
  bool get isSignedIn => _status == AuthStatus.signedIn;
  bool get isAdmin => _user?.isAdmin ?? false;
  bool get signingIn => _status == AuthStatus.signingIn;
  bool get sessionExpired => _status == AuthStatus.sessionExpired;

  /// Sign in; rethrows [ApiException] so the screen can render the explicit
  /// invalid-credential vs network-error vs server states.
  Future<void> signIn(String email, String password) async {
    _status = AuthStatus.signingIn;
    notifyListeners();
    try {
      final json = await _client.post(
        '/api/v1/auth/login',
        body: {'email': email.trim(), 'password': password},
        auth: false,
      ) as Map<String, dynamic>;
      final session = LoginSession.fromJson(json);
      _client.token = session.accessToken;
      _user = session.user;
      _status = AuthStatus.signedIn;
      notifyListeners();
    } on ApiException {
      _status = _status == AuthStatus.sessionExpired
          ? AuthStatus.sessionExpired
          : AuthStatus.signedOut;
      notifyListeners();
      rethrow;
    }
  }

  /// Called by ApiClient when any protected call returns 401.
  void sessionExpiredNow() {
    if (_status == AuthStatus.signedIn) {
      _client.token = null;
      _user = null;
      _status = AuthStatus.sessionExpired;
      notifyListeners();
    }
  }

  void signOut() {
    _client.token = null;
    _user = null;
    _status = AuthStatus.signedOut;
    notifyListeners();
  }
}
