import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quickbite/core/api_client.dart';
import 'package:quickbite/state/order_details_controller.dart';

/// Polling behaviour: ~2s cadence (accelerated here), stop on terminal,
/// stop on auth expiry, backoff + offline notice on failures, stop on
/// dispose.
void main() {
  Map<String, dynamic> orderJson(String status, {int version = 1}) => {
        'id': 'order_1',
        'restaurant_id': 'rest_1',
        'restaurant_name': 'Spice Route',
        'status': status,
        'currency': 'INR',
        'total_amount_minor': 2900,
        'version': version,
        'failure_code': null,
        'created_at': '2026-10-15T10:00:00Z',
        'updated_at': '2026-10-15T10:00:00Z',
        'customer_id': 'user_1',
        'delivery_address': '12 Lake Road, Bengaluru',
        'driver_id': null,
        'correlation_id': 'req_1',
        'items': [],
      };

  http.Response jsonResponse(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status,
          headers: {'content-type': 'application/json'});

  test('polls while non-terminal and stops at a terminal status', () async {
    var orderCalls = 0;
    final client = ApiClient(
      baseUrl: 'http://test',
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/history')) {
          return jsonResponse({
            'items': [],
            'page': 1,
            'page_size': 100,
            'total': 0
          });
        }
        if (path.endsWith('/notifications')) {
          return jsonResponse({
            'items': [],
            'page': 1,
            'page_size': 100,
            'total': 0
          });
        }
        orderCalls++;
        // Two PENDING reads, then the terminal state.
        final status = orderCalls >= 3 ? 'DRIVER_ASSIGNED' : 'PENDING';
        return jsonResponse(orderJson(status, version: orderCalls));
      }),
    );

    final controller = OrderDetailsController(
      client,
      pollInterval: const Duration(milliseconds: 40),
    );
    await controller.open('order_1');
    expect(controller.state.name, 'loaded');
    expect(controller.polling, isTrue);
    expect(orderCalls, 1);

    // Wait for polls 2 and 3 (terminal) to happen.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(orderCalls, greaterThanOrEqualTo(3));
    expect(controller.order!.status, 'DRIVER_ASSIGNED');
    expect(controller.isTerminal, isTrue);
    expect(controller.polling, isFalse, reason: 'terminal stops polling');

    final callsAtStop = orderCalls;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(orderCalls, callsAtStop, reason: 'no polls after terminal');

    controller.dispose();
  });

  test('startPolling never starts for an already-terminal order', () async {
    final client = ApiClient(
      baseUrl: 'http://test',
      client: MockClient((request) async {
        if (request.url.path.endsWith('/history') ||
            request.url.path.endsWith('/notifications')) {
          return jsonResponse(
              {'items': [], 'page': 1, 'page_size': 100, 'total': 0});
        }
        return jsonResponse(orderJson('PAYMENT_FAILED'));
      }),
    );
    final controller = OrderDetailsController(
      client,
      pollInterval: const Duration(milliseconds: 30),
    );
    await controller.open('order_1');
    expect(controller.polling, isFalse);
    controller.dispose();
  });

  test('failures back off, surface an offline notice, and auth expiry stops',
      () async {
    var orderCalls = 0;
    var expired = false;
    final client = ApiClient(
      baseUrl: 'http://test',
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/history') || path.endsWith('/notifications')) {
          return jsonResponse(
              {'items': [], 'page': 1, 'page_size': 100, 'total': 0});
        }
        orderCalls++;
        if (orderCalls == 1) return jsonResponse(orderJson('PENDING'));
        if (orderCalls == 2) {
          throw http.ClientException('Connection refused');
        }
        return http.Response(
          jsonEncode({
            'code': 'unauthenticated',
            'message': 'expired',
            'details': null,
            'request_id': 'req_1',
          }),
          401,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final controller = OrderDetailsController(
      client,
      pollInterval: const Duration(milliseconds: 30),
      maxBackoff: const Duration(milliseconds: 80),
      onAuthExpired: () => expired = true,
    );
    await controller.open('order_1');
    expect(controller.polling, isTrue);

    // Poll #2 fails with a network error -> backoff scheduled, notice shown.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(controller.offlineReason, isNotNull);
    expect(controller.polling, isTrue, reason: 'keeps polling with backoff');

    // Poll #3 gets 401 -> polling stops and the session signal fires.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(expired, isTrue);
    expect(controller.polling, isFalse);

    controller.dispose();
  });

  test('dispose cancels the poll timer', () async {
    var orderCalls = 0;
    final client = ApiClient(
      baseUrl: 'http://test',
      client: MockClient((request) async {
        if (request.url.path.endsWith('/history') ||
            request.url.path.endsWith('/notifications')) {
          return jsonResponse(
              {'items': [], 'page': 1, 'page_size': 100, 'total': 0});
        }
        orderCalls++;
        return jsonResponse(orderJson('PENDING'));
      }),
    );
    final controller = OrderDetailsController(
      client,
      pollInterval: const Duration(milliseconds: 30),
    );
    await controller.open('order_1');
    expect(controller.polling, isTrue);
    controller.dispose();
    final after = orderCalls;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(orderCalls, after, reason: 'no polls after dispose');
  });
}
