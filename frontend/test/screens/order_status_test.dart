import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:quickbite/core/api_client.dart';
import 'package:quickbite/screens/order_details_screen.dart';
import 'package:quickbite/state/auth_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _order({
  String status = 'PENDING',
  String? failureCode,
  String? driverId,
}) =>
    {
      'id': 'order_abc123',
      'restaurant_id': 'rest_1',
      'restaurant_name': 'Spice Route',
      'status': status,
      'currency': 'INR',
      'total_amount_minor': 2900,
      'version': 3,
      'failure_code': failureCode,
      'created_at': '2026-10-15T10:00:00Z',
      'updated_at': '2026-10-15T10:00:05Z',
      'customer_id': 'user_1',
      'delivery_address': '12 Lake Road, Bengaluru',
      'driver_id': driverId,
      'correlation_id': 'req_1',
      'items': [
        {
          'menu_item_id': 'item_biryani',
          'item_name': 'Chicken Biryani',
          'quantity': 2,
          'unit_price_minor': 1250,
          'line_total_minor': 2500,
        },
        {
          'menu_item_id': 'item_lassi',
          'item_name': 'Sweet Lassi',
          'quantity': 1,
          'unit_price_minor': 400,
          'line_total_minor': 400,
        },
      ],
    };

List<Map<String, dynamic>> _historyFor(String status) => [
      {
        'id': 'hist_1',
        'from_status': null,
        'to_status': 'PENDING',
        'version': 1,
        'source': 'api.checkout',
        'reason': null,
        'created_at': '2026-10-15T10:00:00Z',
      },
      if (status != 'PENDING')
        {
          'id': 'hist_2',
          'from_status': 'PENDING',
          'to_status': status == 'PAYMENT_FAILED' ? 'PAYMENT_FAILED' : status,
          'version': 3,
          'source': 'payment.worker',
          'reason': status == 'PAYMENT_FAILED' ? 'PAYMENT_DECLINED' : null,
          'created_at': '2026-10-15T10:00:05Z',
        },
    ];

List<Map<String, dynamic>> _notificationsFor(String status) => [
      {
        'id': 'notif_1',
        'order_id': 'order_abc123',
        'event_type': 'order.created',
        'title': 'Order received',
        'body': 'We got your order — processing payment.',
        'is_read': false,
        'created_at': '2026-10-15T10:00:01Z',
      },
      if (status == 'PAYMENT_FAILED')
        {
          'id': 'notif_2',
          'order_id': 'order_abc123',
          'event_type': 'order.payment.failed',
          'title': 'Payment failed',
          'body': 'The payment could not be completed.',
          'is_read': false,
          'created_at': '2026-10-15T10:00:05Z',
        },
    ];

Future<void> pumpDetails(
  WidgetTester tester, {
  required String status,
  String? failureCode,
  String? driverId,
  bool justAccepted = false,
}) async {
  final client = ApiClient(
    baseUrl: 'http://test',
    client: MockClient((request) async {
      final path = request.url.path;
      http.Response respond(Object body) => http.Response(jsonEncode(body),
          200,
          headers: {'content-type': 'application/json'});
      if (path.endsWith('/history')) {
        return respond({
          'items': _historyFor(status),
          'page': 1,
          'page_size': 100,
          'total': _historyFor(status).length,
        });
      }
      if (path.endsWith('/notifications')) {
        return respond({
          'items': _notificationsFor(status),
          'page': 1,
          'page_size': 100,
          'total': _notificationsFor(status).length,
        });
      }
      return respond(_order(status: status, failureCode: failureCode, driverId: driverId));
    }),
  );

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: client),
        ChangeNotifierProvider<AuthController>(
          create: (_) => AuthController(client),
        ),
      ],
      child: MaterialApp(
        home: OrderDetailsScreen(
          orderId: 'order_abc123',
          justAccepted: justAccepted,
        ),
      ),
    ),
  );
  // Let open() complete (order + history + notifications).
  for (var i = 0; i < 5; i++) {
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('acknowledgement, timeline, items and notifications render',
      (tester) async {
    await pumpDetails(tester, status: 'PAID', justAccepted: true);

    // 202 acknowledgement card.
    expect(find.text('Order accepted (HTTP 202)'), findsOneWidget);
    expect(find.textContaining('Accepted total ₹29.00'), findsOneWidget);

    // Status + version + timeline.
    expect(find.text('Paid'), findsWidgets);
    expect(find.text('v3'), findsOneWidget);
    expect(find.text('Timeline'), findsOneWidget);
    expect(find.textContaining('Pending → Paid'), findsOneWidget);

    // Items with server totals.
    expect(find.text('2 × Chicken Biryani'), findsOneWidget);
    expect(find.text('₹25.00'), findsOneWidget);
    expect(find.text('₹4.00'), findsOneWidget);

    // Persisted notifications.
    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('Order received'), findsOneWidget);

    // Live polling indicator is visible for a non-terminal order.
    expect(find.text('Live'), findsOneWidget);

    // Unmount so the poll timer is cancelled.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('payment failure shows a payment-specific explanation',
      (tester) async {
    await pumpDetails(tester,
        status: 'PAYMENT_FAILED', failureCode: 'PAYMENT_DECLINED');

    expect(find.text('Payment failed'), findsWidgets);
    expect(
      find.textContaining(
          'payment was declined by the payment simulator'),
      findsOneWidget,
    );
    expect(find.textContaining('Failure code: PAYMENT_DECLINED'),
        findsOneWidget);
    // Terminal: no live indicator.
    expect(find.text('Live'), findsNothing);
    // The payment-failed notification is persisted and distinct from the
    // client-side explanation card.
    expect(find.text('The payment could not be completed.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('restaurant failure never claims a payment failure',
      (tester) async {
    await pumpDetails(tester,
        status: 'FAILED', failureCode: 'RESTAURANT_REJECTED');

    expect(
      find.textContaining("restaurant couldn't confirm"),
      findsOneWidget,
    );
    expect(
      find.textContaining('payment was declined'),
      findsNothing,
      reason: 'notification/restaurant failures are not payment failures',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('driver assignment is shown when present (terminal state)',
      (tester) async {
    await pumpDetails(tester,
        status: 'DRIVER_ASSIGNED', driverId: 'drv_123');

    expect(find.text('Driver assigned'), findsWidgets);
    expect(find.text('Driver reference: drv_123'), findsOneWidget);
    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('Live'), findsNothing,
        reason: 'terminal stops polling');

    await tester.pumpWidget(const SizedBox());
  });
}
