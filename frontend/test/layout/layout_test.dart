import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:quickbite/app.dart';
import 'package:quickbite/core/api_client.dart';
import 'package:quickbite/screens/sign_in_screen.dart';
import 'package:quickbite/state/auth_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Responsive layout checks: narrow phone and desktop sizes, plus a raised
/// text scale — no overflow exceptions anywhere in the main flows.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  http.Response jsonResponseOf(Object body) =>
      http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});

  MockClientHandler buildHandler({bool admin = false}) => (request) async {
        final path = request.url.path;
        if (path.endsWith('/auth/login')) {
          return jsonResponseOf({
            'access_token': 'tok',
            'token_type': 'bearer',
            'expires_in': 3600,
            'expires_at': '2026-10-15T11:00:00Z',
            'role': admin ? 'admin' : 'customer',
            'user': {
              'id': 'user_1',
              'email': admin ? 'admin@quickbite.dev' : 'maya@quickbite.dev',
              'full_name': admin ? 'Admin' : 'Maya',
              'role': admin ? 'admin' : 'customer',
            },
          });
        }
        if (path.endsWith('/restaurants') && !path.contains('/menu')) {
          return jsonResponseOf({
            'items': [
              {
                'id': 'rest_1',
                'name': 'Spice Route Kitchen with a Very Long Name',
                'description':
                    'Classic Indian comfort food, slow-cooked biryanis and '
                        'regional thalis.',
                'cuisine': 'Indian',
                'currency': 'INR',
                'image_url': null,
                'is_open': true,
                'rating': 4,
                'eta_minutes': 25,
              },
            ],
            'page': 1,
            'page_size': 50,
            'total': 1,
          });
        }
        if (path.endsWith('/menu')) {
          return jsonResponseOf({
            'items': [
              {
                'id': 'item_biryani',
                'restaurant_id': 'rest_1',
                'name': 'Chicken Biryani',
                'description': 'Aromatic basmati rice cooked with chicken.',
                'category': 'Mains',
                'price_minor': 1250,
                'currency': 'INR',
                'is_available': true,
              },
            ],
            'page': 1,
            'page_size': 100,
            'total': 1,
          });
        }
        if (path.endsWith('/admin/summary')) {
          return jsonResponseOf({
            'orders_by_status': {
              'PENDING': 1,
              'PAID': 0,
              'CONFIRMED': 0,
              'DRIVER_ASSIGNED': 2,
              'PAYMENT_FAILED': 1,
              'FAILED': 0,
            },
            'total_orders': 4,
            'pending_outbox': 0,
            'pending_retries': 1,
            'open_quarantine': 0,
          });
        }
        if (path.endsWith('/admin/orders') || path.endsWith('/orders')) {
          return jsonResponseOf({
            'items': [
              {
                'id': 'order_1',
                'restaurant_id': 'rest_1',
                'restaurant_name': 'Spice Route',
                'status': 'DRIVER_ASSIGNED',
                'currency': 'INR',
                'total_amount_minor': 2900,
                'version': 3,
                'failure_code': null,
                'created_at': '2026-10-15T10:00:00Z',
                'updated_at': '2026-10-15T10:00:05Z',
                if (path.endsWith('/admin/orders')) 'customer_email': 'a@b.c',
              },
            ],
            'page': 1,
            'page_size': 20,
            'total': 1,
          });
        }
        if (path.endsWith('/orders/order_1')) {
          // Terminal on purpose: no polling timers during layout checks.
          return jsonResponseOf({
            'id': 'order_1',
            'restaurant_id': 'rest_1',
            'restaurant_name': 'Spice Route',
            'status': 'DRIVER_ASSIGNED',
            'currency': 'INR',
            'total_amount_minor': 2900,
            'version': 3,
            'failure_code': null,
            'created_at': '2026-10-15T10:00:00Z',
            'updated_at': '2026-10-15T10:00:05Z',
            'customer_id': 'user_1',
            'delivery_address': '12 Lake Road, Bengaluru',
            'driver_id': 'drv_1',
            'correlation_id': 'req_1',
            'items': [
              {
                'menu_item_id': 'item_biryani',
                'item_name': 'Chicken Biryani',
                'quantity': 1,
                'unit_price_minor': 1250,
                'line_total_minor': 1250,
              },
            ],
          });
        }
        if (path.endsWith('/history')) {
          return jsonResponseOf({
            'items': [
              {
                'id': 'hist_1',
                'from_status': null,
                'to_status': 'PENDING',
                'version': 1,
                'source': 'api.checkout',
                'reason': null,
                'created_at': '2026-10-15T10:00:00Z',
              },
              {
                'id': 'hist_2',
                'from_status': 'PENDING',
                'to_status': 'DRIVER_ASSIGNED',
                'version': 3,
                'source': 'delivery.worker',
                'reason': null,
                'created_at': '2026-10-15T10:00:05Z',
              },
            ],
            'page': 1,
            'page_size': 100,
            'total': 2,
          });
        }
        if (path.endsWith('/notifications')) {
          return jsonResponseOf({
            'items': [
              {
                'id': 'notif_1',
                'order_id': 'order_1',
                'event_type': 'order.created',
                'title': 'Order received',
                'body': 'We got your order.',
                'is_read': false,
                'created_at': '2026-10-15T10:00:01Z',
              },
            ],
            'page': 1,
            'page_size': 100,
            'total': 1,
          });
        }
        return jsonResponseOf({});
      };

  Future<void> pumpSignedInApp(
    WidgetTester tester, {
    required Size size,
    double textScale = 1.0,
    bool admin = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    if (textScale != 1.0) {
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(
          tester.platformDispatcher.clearAllTestValues);
    }

    await tester.pumpWidget(
      QuickBiteApp(
        apiClient: ApiClient(
          baseUrl: 'http://test',
          client: MockClient(buildHandler(admin: admin)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Sign in through the UI (in-memory session, as on the web target).
    final auth =
        tester.element(find.byType(SignInScreen)).read<AuthController>();
    await auth.signIn(
        admin ? 'admin@quickbite.dev' : 'maya@quickbite.dev', 'demo12345');
    await tester.pumpAndSettle();
  }

  /// Walks the main flows and asserts nothing overflows/throws.
  Future<void> walkThrough(WidgetTester tester,
      {required bool admin}) async {
    expect(find.text('Spice Route Kitchen with a Very Long Name'),
        findsOneWidget);

    // Menu route (pushed).
    await tester.tap(find.text('Spice Route Kitchen with a Very Long Name'));
    await tester.pumpAndSettle();
    expect(find.text('Chicken Biryani'), findsOneWidget);

    // Add to cart, then open the cart route.
    await tester.tap(find.text('Add'));
    await tester.pump();
    await tester.tap(find.byTooltip('Cart (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Your cart'), findsOneWidget);
    expect(find.text('Order summary'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    // History tab (orders list).
    await tester.tap(find.text('Orders'));
    await tester.pumpAndSettle();
    expect(find.text('Spice Route'), findsOneWidget);

    // Order details route from history.
    await tester.tap(find.text('Spice Route'));
    await tester.pumpAndSettle();
    expect(find.text('Timeline'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    if (admin) {
      await tester.tap(find.text('Admin'));
      await tester.pumpAndSettle();
      expect(find.text('Pending retries'), findsOneWidget);
      expect(find.text('Open quarantine'), findsOneWidget);
    }
  }

  testWidgets('narrow phone layout (360x690) has no overflow', (tester) async {
    await pumpSignedInApp(tester, size: const Size(360, 690));
    await walkThrough(tester, admin: false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow phone at 1.5x text scaling has no overflow',
      (tester) async {
    await pumpSignedInApp(
      tester,
      size: const Size(360, 690),
      textScale: 1.5,
    );
    await walkThrough(tester, admin: false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop layout (1440x900) has no overflow', (tester) async {
    await pumpSignedInApp(tester, size: const Size(1440, 900), admin: true);
    await walkThrough(tester, admin: true);
    expect(tester.takeException(), isNull);
  });
}
