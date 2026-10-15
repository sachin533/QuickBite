import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_config.dart';
import 'api_exception.dart';

/// Centralized HTTP client: base URL, auth header, timeouts, and the
/// versioned error envelope (`code`, `message`, `details`, `request_id`)
/// translated into typed [ApiException]s.
///
/// One instance lives for the whole app session (provided at the root).
/// The access token is held **in memory only** — the web target deliberately
/// does not persist tokens to browser storage.
class ApiClient {
  ApiClient({
    http.Client? client,
    String? baseUrl,
    this.timeout = const Duration(seconds: 12),
    this.checkoutTimeout = const Duration(seconds: 20),
  })  : _client = client ?? http.Client(),
        _baseUrl = (baseUrl ?? ApiConfig.apiBaseUrl).replaceAll(RegExp(r'/$'), '');

  final http.Client _client;
  final String _baseUrl;

  /// Default deadline for reads.
  final Duration timeout;

  /// Deadline for POST /api/v1/orders (server may be slow; still bounded).
  final Duration checkoutTimeout;

  /// In-memory access token (never persisted to browser storage).
  String? token;

  /// Invoked whenever a protected call fails with 401 so the app can drop
  /// the session and stop background work (polling halts on the same signal).
  void Function()? onAuthExpired;

  String get baseUrl => _baseUrl;

  Uri _uri(String path, [Map<String, String>? query]) {
    final uri = Uri.parse('$_baseUrl$path');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: {
      ...uri.queryParameters,
      ...query,
    });
  }

  Map<String, String> _headers({required bool auth}) {
    final headers = <String, String>{
      'Accept': 'application/json',
    };
    if (auth && token != null) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  // --- primitives -----------------------------------------------------------

  Future<dynamic> get(
    String path, {
    Map<String, String>? query,
    bool auth = true,
    Duration? requestTimeout,
  }) =>
      _send('GET', path,
          query: query, auth: auth, requestTimeout: requestTimeout);

  Future<dynamic> post(
    String path, {
    Object? body,
    Map<String, String>? query,
    String? idempotencyKey,
    bool auth = true,
    Duration? requestTimeout,
  }) =>
      _send(
        'POST',
        path,
        query: query,
        body: body,
        idempotencyKey: idempotencyKey,
        auth: auth,
        requestTimeout: requestTimeout,
      );

  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    String? idempotencyKey,
    required bool auth,
    Duration? requestTimeout,
  }) async {
    final headers = _headers(auth: auth);
    if (body != null) headers['Content-Type'] = 'application/json';
    if (idempotencyKey != null) headers['Idempotency-Key'] = idempotencyKey;

    final request = http.Request(method, _uri(path, query));
    request.headers.addAll(headers);
    if (body != null) {
      request.body = jsonEncode(body);
    }

    http.Response response;
    try {
      final streamed =
          await _client.send(request).timeout(requestTimeout ?? timeout);
      response = await http.Response.fromStream(streamed);
    } on TimeoutException {
      throw const ApiException(
        ApiErrorKind.timeout,
        message: 'Request timed out',
      );
    } on http.ClientException catch (e) {
      throw ApiException(ApiErrorKind.network, message: e.message);
    } on ApiException {
      rethrow;
    } catch (e) {
      // Socket/DNS/TLS failures surface differently per platform (and
      // dart:io types are unavailable on the web target).
      throw ApiException(ApiErrorKind.network, message: '$e');
    }

    return _handleResponse(response);
  }

  dynamic _handleResponse(http.Response response) {
    final bodyText = response.body;
    Object? decoded;
    try {
      decoded = bodyText.isEmpty ? null : jsonDecode(bodyText);
    } on FormatException {
      decoded = null;
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded;
    }

    final map = decoded is Map<String, dynamic> ? decoded : null;
    final code = map?['code'] as String?;
    final message = (map?['message'] as String?) ??
        'Request failed (HTTP ${response.statusCode})';
    final kind = _kindFor(response.statusCode, code);
    final exception = ApiException(
      kind,
      statusCode: response.statusCode,
      code: code,
      message: message,
      details: map?['details'],
      requestId: (map?['request_id'] as String?) ??
          response.headers['x-request-id'],
    );
    if (kind == ApiErrorKind.authExpired) {
      onAuthExpired?.call();
    }
    throw exception;
  }

  static ApiErrorKind _kindFor(int status, String? code) {
    if (status == 401) {
      return code == 'invalid_credentials'
          ? ApiErrorKind.invalidCredentials
          : ApiErrorKind.authExpired;
    }
    if (status == 403) return ApiErrorKind.forbidden;
    if (status == 404) return ApiErrorKind.notFound;
    if (status == 409) return ApiErrorKind.conflict;
    if (status == 400 || status == 422) return ApiErrorKind.validation;
    if (status >= 500) return ApiErrorKind.server;
    return ApiErrorKind.unknown;
  }

  void dispose() => _client.close();
}
