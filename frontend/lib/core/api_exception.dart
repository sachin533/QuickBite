/// Typed failures produced by [ApiClient].
///
/// The UI maps each kind onto an explicit state: validation, auth-expired,
/// offline/network, timeout, conflict, and so on.
enum ApiErrorKind {
  /// No response at all (DNS, connection refused, cable pulled).
  network,

  /// The request was sent but no response arrived before the deadline.
  timeout,

  /// 401 with the stable code `invalid_credentials` (sign-in screen case).
  invalidCredentials,

  /// 401 for an expired/absent token on a protected call -> re-authenticate.
  authExpired,

  /// 403 — role not allowed (e.g. customer hitting admin endpoints).
  forbidden,

  /// 404 — unknown or not-owned resource.
  notFound,

  /// 409 — idempotency key reused with a different payload.
  conflict,

  /// 400/422 — request rejected before any side effect.
  validation,

  /// 5xx — server-side failure, safe to retry with the same key.
  server,

  /// Anything else.
  unknown,
}

class ApiException implements Exception {
  const ApiException(
    this.kind, {
    this.statusCode,
    this.code,
    required this.message,
    this.details,
    this.requestId,
  });

  final ApiErrorKind kind;
  final int? statusCode;
  final String? code;
  final String message;
  final Object? details;
  final String? requestId;

  /// Transient failures where retrying the *same* request is safe.
  bool get isRetryable =>
      kind == ApiErrorKind.network ||
      kind == ApiErrorKind.timeout ||
      kind == ApiErrorKind.server;

  /// User-facing wording for the explicit error state each kind maps to.
  String get userMessage {
    switch (kind) {
      case ApiErrorKind.network:
        return "Can't reach the server. Check your connection and try again.";
      case ApiErrorKind.timeout:
        return 'The server took too long to respond. Your request may or may '
            'not have been received — retry safely with the same order key.';
      case ApiErrorKind.invalidCredentials:
        return 'Incorrect email or password.';
      case ApiErrorKind.authExpired:
        return 'Your session has expired. Please sign in again.';
      case ApiErrorKind.forbidden:
        return "You don't have permission to do that.";
      case ApiErrorKind.notFound:
        return 'Not found.';
      case ApiErrorKind.conflict:
        return 'This request conflicts with an earlier one (idempotency key '
            'reused with a different payload).';
      case ApiErrorKind.validation:
        return message;
      case ApiErrorKind.server:
        return 'The server had a problem. Retrying with the same request is '
            'safe.';
      case ApiErrorKind.unknown:
        return message;
    }
  }

  @override
  String toString() =>
      'ApiException($kind, status=$statusCode, code=$code): $message';
}
