import 'package:flutter/foundation.dart';

/// Compile-time configuration.
///
/// `API_BASE_URL` is public build configuration (not a secret), supplied with
/// `--dart-define=API_BASE_URL=...`:
///
///   flutter run  -d chrome --dart-define=API_BASE_URL=http://localhost:8000
///   flutter run  -d emulator --dart-define=API_BASE_URL=http://10.0.2.2:8000
///   flutter build web --dart-define=API_BASE_URL=http://localhost:8000
///
/// **When it is omitted the API is called on the same origin that served the
/// app.** That keeps a single release build working everywhere — on
/// `localhost`, behind a tunnel (ngrok / Cloudflare), or deployed to a host —
/// without rebuilding per environment, and it makes the browser requests
/// same-origin so no CORS preflight is needed. Those requests are forwarded to
/// the FastAPI process by `serve_release.py`.
class ApiConfig {
  /// Explicit override from `--dart-define=API_BASE_URL=...`.
  /// Empty string means "no override" (see [apiBaseUrl]).
  static const String _override = String.fromEnvironment('API_BASE_URL');

  /// Resolved API origin, no trailing slash.
  static final String apiBaseUrl = _resolve();

  static String _resolve() {
    if (_override.isNotEmpty) return _stripSlash(_override);

    if (kIsWeb) {
      try {
        final origin = Uri.base.origin;
        if (origin.startsWith('http')) return _stripSlash(origin);
      } catch (_) {
        // Non-http origin (e.g. about:blank during tests) → fall through.
      }
    }
    return 'http://localhost:8000';
  }

  static String _stripSlash(String value) => value.replaceAll(RegExp(r'/+$'), '');
}
