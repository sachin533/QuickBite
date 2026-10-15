import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quickbite/core/api_client.dart';
import 'package:quickbite/core/api_exception.dart';
import 'package:quickbite/state/checkout_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const items = [(menuItemId: 'item_a', quantity: 2)];

  http.Response accepted(String orderId) => http.Response(
        jsonEncode({
          'order_id': orderId,
          'status': 'PENDING',
          'currency': 'INR',
          'total_amount_minor': 2900,
          'version': 1,
          'message': 'Order accepted for asynchronous processing.',
        }),
        202,
        headers: {'content-type': 'application/json'},
      );

  http.Response envelope(int status, String code, String message) =>
      http.Response(
        jsonEncode(
            {'code': code, 'message': message, 'details': null,
             'request_id': 'req_1'}),
        status,
        headers: {'content-type': 'application/json'},
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('timeout keeps the SAME idempotency key for the safe retry',
      () async {
    final sentKeys = <String>[];
    var call = 0;
    final client = ApiClient(
      baseUrl: 'http://test',
      checkoutTimeout: const Duration(milliseconds: 100),
      client: MockClient((request) async {
        sentKeys.add(request.headers['Idempotency-Key'] ?? '');
        call++;
        if (call == 1) {
          // Simulate a dropped connection / server timeout.
          throw http.ClientException('Network timeout');
        }
        return accepted('order_abc');
      }),
    );

    final checkout = CheckoutController(client);
    await checkout.restore();
    expect(checkout.hasPending, isFalse);

    // Attempt 1: transient failure -> pending kept, phase needsRetry.
    final first = await checkout.submit(
      restaurantId: 'rest_1',
      deliveryAddress: '12 Lake Road, Bengaluru',
      items: items,
    );
    expect(first, isNull);
    expect(checkout.phase, CheckoutPhase.needsRetry);
    expect(checkout.hasPending, isTrue);
    expect(checkout.lastError!.kind, ApiErrorKind.network);

    // The key was persisted BEFORE the request went out.
    final prefs = await SharedPreferences.getInstance();
    final stored = jsonDecode(prefs.getString(CheckoutController.prefsKey)!)
        as Map<String, dynamic>;
    expect(stored['idempotency_key'], sentKeys.first);

    // Attempt 2: retry reuses key + exact body, order lands.
    final second = await checkout.retry();
    expect(second, isNotNull);
    expect(second!.orderId, 'order_abc');
    expect(sentKeys, hasLength(2));
    expect(sentKeys[1], sentKeys[0], reason: 'retry must reuse the key');
    expect(checkout.pending, isNull);
    expect(checkout.phase, CheckoutPhase.idle);
    expect(prefs.getString(CheckoutController.prefsKey), isNull);
  });

  test('while submitting, repeat submissions are ignored', () async {
    var calls = 0;
    final gate = Completer<http.Response>();
    final client = ApiClient(
      baseUrl: 'http://test',
      client: MockClient((_) {
        calls++;
        return gate.future;
      }),
    );
    final checkout = CheckoutController(client);
    await checkout.restore();

    final firstSubmit = checkout.submit(
        restaurantId: 'rest_1',
        deliveryAddress: '12 Lake Road, Bengaluru',
        items: items);
    expect(checkout.isSubmitting, isTrue,
        reason: 'phase flips synchronously, before any I/O');

    final second = await checkout.submit(
        restaurantId: 'rest_1',
        deliveryAddress: '12 Lake Road, Bengaluru',
        items: items);
    expect(second, isNull, reason: 'no double submission while active');
    await Future<void>.delayed(Duration.zero); // let the persist+POST start
    expect(calls, 1);

    gate.complete(accepted('order_1'));
    final result = await firstSubmit;
    expect(result!.orderId, 'order_1');
    expect(calls, 1);
  });

  test('validation rejection (422) clears the pending attempt', () async {
    final client = ApiClient(
      baseUrl: 'http://test',
      client: MockClient(
          (_) async => envelope(422, 'validation_error', 'bad address')),
    );
    final checkout = CheckoutController(client);
    await checkout.restore();

    final result = await checkout.submit(
      restaurantId: 'rest_1',
      deliveryAddress: 'short',
      items: items,
    );
    expect(result, isNull);
    expect(checkout.hasPending, isFalse,
        reason: 'identical request can never succeed; free the key');
    expect(checkout.phase, CheckoutPhase.idle);
    expect(checkout.lastError!.kind, ApiErrorKind.validation);
  });

  test('a persisted attempt survives a fresh controller (app restart)',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      CheckoutController.prefsKey,
      jsonEncode({
        'idempotency_key': 'qb_restored_key',
        'body': {
          'restaurant_id': 'rest_9',
          'delivery_address': '9 Restart Lane, Bengaluru',
          'items': [
            {'menu_item_id': 'item_z', 'quantity': 3},
          ],
        },
        'created_at': '2026-10-15T09:00:00Z',
      }),
    );

    final checkout = CheckoutController(ApiClient(baseUrl: 'http://test'));
    await checkout.restore();
    expect(checkout.hasPending, isTrue);
    expect(checkout.needsRetry, isTrue);
    expect(checkout.pending!.idempotencyKey, 'qb_restored_key');

    await checkout.discardPending();
    expect(checkout.hasPending, isFalse);
    final prefsAfter = await SharedPreferences.getInstance();
    expect(
        prefsAfter.getString(CheckoutController.prefsKey), isNull);
  });

  test('5xx keeps the attempt (safe retry with same key)', () async {
    var calls = 0;
    final client = ApiClient(
      baseUrl: 'http://test',
      client: MockClient((_) async {
        calls++;
        if (calls == 1) {
          return envelope(503, 'service_unavailable', 'down');
        }
        return accepted('order_ok');
      }),
    );
    final checkout = CheckoutController(client);
    await checkout.restore();

    await checkout.submit(
        restaurantId: 'rest_1',
        deliveryAddress: '12 Lake Road, Bengaluru',
        items: items);
    expect(checkout.needsRetry, isTrue);
    expect(checkout.hasPending, isTrue);

    final result = await checkout.retry();
    expect(result!.orderId, 'order_ok');
  });
}
