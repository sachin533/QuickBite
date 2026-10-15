import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quickbite/core/api_client.dart';
import 'package:quickbite/core/api_exception.dart';

void main() {
  late List<http.Request> requests;

  MockClient clientWith(MockClientHandler handler) {
    requests = [];
    return MockClient((request) async {
      requests.add(request);
      return handler(request);
    });
  }

  http.Response envelope(int status, String code, String message,
          {Object? details, String requestId = 'req_test'}) =>
      http.Response(
        jsonEncode({
          'code': code,
          'message': message,
          'details': details,
          'request_id': requestId,
        }),
        status,
        headers: {'content-type': 'application/json'},
      );

  group('ApiClient error mapping', () {
    test('401 invalid_credentials maps to invalidCredentials, not expiry',
        () async {
      final api = ApiClient(
        client: clientWith(
            (_) async => envelope(401, 'invalid_credentials', 'nope')),
        baseUrl: 'http://test',
      );
      var expired = false;
      api.onAuthExpired = () => expired = true;

      await expectLater(
        api.post('/api/v1/auth/login',
            body: {'email': 'a@b.c', 'password': 'x'}, auth: false),
        throwsA(isA<ApiException>()
            .having((e) => e.kind, 'kind', ApiErrorKind.invalidCredentials)
            .having((e) => e.statusCode, 'status', 401)
            .having((e) => e.requestId, 'requestId', 'req_test')),
      );
      expect(expired, isFalse, reason: 'sign-in 401 is not a session expiry');
    });

    test('401 on a protected call fires onAuthExpired exactly once per call',
        () async {
      final api = ApiClient(
        client: clientWith(
            (_) async => envelope(401, 'unauthenticated', 'expired')),
        baseUrl: 'http://test',
      );
      var expired = 0;
      api.onAuthExpired = () => expired++;

      await expectLater(api.get('/api/v1/orders'),
          throwsA(isA<ApiException>().having((e) => e.kind, 'kind',
              ApiErrorKind.authExpired)));
      expect(expired, 1);
    });

    test('409/422/403/404/500 map to their kinds', () async {
      final cases = <(int, String, ApiErrorKind)>[
        (409, 'conflict', ApiErrorKind.conflict),
        (422, 'validation_error', ApiErrorKind.validation),
        (403, 'forbidden', ApiErrorKind.forbidden),
        (404, 'not_found', ApiErrorKind.notFound),
        (500, 'internal_error', ApiErrorKind.server),
      ];
      for (final (status, code, kind) in cases) {
        final api = ApiClient(
          client: clientWith((_) async => envelope(status, code, 'msg')),
          baseUrl: 'http://test',
        );
        await expectLater(api.get('/x'),
            throwsA(isA<ApiException>().having((e) => e.kind, 'kind', kind)),
            reason: 'HTTP $status');
      }
    });

    test('connection failure surfaces as network kind', () async {
      final api = ApiClient(
        client: clientWith((_) async =>
            throw http.ClientException('Connection refused')),
        baseUrl: 'http://test',
      );
      await expectLater(api.get('/x'),
          throwsA(isA<ApiException>().having((e) => e.kind, 'kind',
              ApiErrorKind.network)));
    });

    test('timeout surfaces as timeout kind', () async {
      final api = ApiClient(
        client: MockClient((_) => Completer<http.Response>().future),
        baseUrl: 'http://test',
        timeout: const Duration(milliseconds: 40),
      );
      await expectLater(api.get('/x'),
          throwsA(isA<ApiException>().having((e) => e.kind, 'kind',
              ApiErrorKind.timeout)));
    });

    test('retryable classification', () async {
      const network = ApiException(ApiErrorKind.network, message: 'x');
      const timeout = ApiException(ApiErrorKind.timeout, message: 'x');
      const server = ApiException(ApiErrorKind.server, message: 'x');
      const validation =
          ApiException(ApiErrorKind.validation, message: 'x');
      expect(network.isRetryable, isTrue);
      expect(timeout.isRetryable, isTrue);
      expect(server.isRetryable, isTrue);
      expect(validation.isRetryable, isFalse);
    });
  });

  group('ApiClient requests', () {
    test('checkout sends Idempotency-Key and Authorization headers',
        () async {
      final api = ApiClient(
        client: clientWith((_) async => http.Response(
            '{"order_id":"order_1","status":"PENDING","currency":"INR",'
            '"total_amount_minor":2900,"version":1,"message":"ok"}',
            202,
            headers: {'content-type': 'application/json'})),
        baseUrl: 'http://test',
      );
      api.token = 'token-123';

      final json = await api.post(
        '/api/v1/orders',
        body: {'restaurant_id': 'rest_1'},
        idempotencyKey: 'qb_key_1',
      ) as Map<String, dynamic>;

      expect(json['order_id'], 'order_1');
      final request = requests.single;
      expect(request.headers['Idempotency-Key'], 'qb_key_1');
      expect(request.headers['Authorization'], 'Bearer token-123');
      expect(request.url.toString(), 'http://test/api/v1/orders');
    });

    test('query parameters are appended', () async {
      final api = ApiClient(
        client: clientWith(
            (_) async => http.Response('{"items":[]}', 200,
                headers: {'content-type': 'application/json'})),
        baseUrl: 'http://test',
      );
      api.token = 't';
      await api.get('/api/v1/orders', query: {'page': '2'});
      expect(requests.single.url.queryParameters,
          {'page': '2'});
    });
  });
}
