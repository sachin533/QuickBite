import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:quickbite/core/api_client.dart';
import 'package:quickbite/models/menu_item.dart';
import 'package:quickbite/models/restaurant.dart';
import 'package:quickbite/screens/cart_screen.dart';
import 'package:quickbite/state/auth_controller.dart';
import 'package:quickbite/state/cart_controller.dart';
import 'package:quickbite/state/checkout_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _restaurant = Restaurant(
  id: 'rest_1',
  name: 'Spice Route',
  description: '',
  cuisine: 'Indian',
  currency: 'INR',
  isOpen: true,
  rating: 4,
  etaMinutes: 25,
);

const _biryani = MenuItem(
  id: 'item_biryani',
  restaurantId: 'rest_1',
  name: 'Chicken Biryani',
  description: '',
  category: 'Mains',
  priceMinor: 1250,
  currency: 'INR',
  isAvailable: true,
);

http.Response _accepted(String orderId) => http.Response(
      jsonEncode({
        'order_id': orderId,
        'status': 'PENDING',
        'currency': 'INR',
        'total_amount_minor': 2500,
        'version': 1,
        'message': 'Order accepted for asynchronous processing.',
      }),
      202,
      headers: {'content-type': 'application/json'},
    );

Future<void> pumpCart(
  WidgetTester tester, {
  required MockClientHandler handler,
  bool withItem = true,
}) async {
  final client = ApiClient(
    baseUrl: 'http://test',
    client: MockClient((request) async {
      if (request.url.path.endsWith('/auth/login')) {
        return http.Response(
          jsonEncode({
            'access_token': 'tok',
            'token_type': 'bearer',
            'expires_in': 3600,
            'expires_at': '2026-10-15T11:00:00Z',
            'role': 'customer',
            'user': {
              'id': 'user_1',
              'email': 'maya@quickbite.dev',
              'full_name': 'Maya',
              'role': 'customer',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return handler(request);
    }),
  );
  // The checkout button is role/session gated: sign in first, as in the app.
  final auth = AuthController(client);
  await auth.signIn('maya@quickbite.dev', 'demo12345');

  final cart = CartController();
  if (withItem) {
    cart.add(_biryani, fromRestaurant: _restaurant);
  }
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: client),
        ChangeNotifierProvider<AuthController>.value(value: auth),
        ChangeNotifierProvider<CartController>.value(value: cart..restore()),
        ChangeNotifierProvider<CheckoutController>(
          create: (_) => CheckoutController(client)..restore(),
        ),
      ],
      child: MaterialApp(
        initialRoute: '/cart',
        onGenerateRoute: (settings) {
          if (settings.name == '/cart') {
            return MaterialPageRoute(
              settings: settings,
              builder: (_) => const CartScreen(),
            );
          }
          return MaterialPageRoute(
            settings: settings,
            builder: (_) => Scaffold(
              body: Text('DETAILS ${settings.name}'),
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('checkout validates the delivery address before sending',
      (tester) async {
    var posts = 0;
    await pumpCart(tester, handler: (_) async {
      posts++;
      return _accepted('order_1');
    });

    expect(find.text('Chicken Biryani'), findsOneWidget);
    expect(find.text('₹12.50'), findsWidgets);

    // Empty address -> validation error, no network call.
    await tester.ensureVisible(find.text('Checkout'));
    await tester.pump();
    await tester.tap(find.text('Checkout'));
    await tester.pump();
    expect(
      find.text('Enter a full delivery address (min 8 chars)'),
      findsOneWidget,
    );
    expect(posts, 0);

    // Short address is rejected too.
    await tester.enterText(find.byType(TextFormField), '12 Rd');
    await tester.ensureVisible(find.text('Checkout'));
    await tester.pump();
    await tester.tap(find.text('Checkout'));
    await tester.pump();
    expect(
      find.text('Enter a full delivery address (min 8 chars)'),
      findsOneWidget,
    );
    expect(posts, 0);
  });

  testWidgets(
      'network failure keeps the attempt; UI retry uses the SAME key',
      (tester) async {
    final sentKeys = <String>[];
    var posts = 0;
    await pumpCart(tester, handler: (request) async {
      posts++;
      sentKeys.add(request.headers['Idempotency-Key'] ?? '');
      if (posts == 1) throw http.ClientException('Connection reset');
      return _accepted('order_abc123');
    });

    await tester.enterText(
        find.byType(TextFormField), '12 Lake Road, Bengaluru');
    await tester.ensureVisible(find.text('Checkout'));
    await tester.pump();
    await tester.tap(find.text('Checkout'));
    await tester.pump();
    await tester.pump();

    // Explicit failure state + safe-retry affordance.
    expect(posts, 1);
    expect(find.text('Unconfirmed checkout attempt'), findsOneWidget);
    expect(find.text('Retry safely (same key)'), findsOneWidget);
    expect(find.text('Retry checkout (same key)'), findsOneWidget);

    // While pending, the plain checkout button must not fire a new request.
    expect(find.text('Checkout'), findsNothing);

    await tester.tap(find.text('Retry safely (same key)'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(posts, 2);
    expect(sentKeys, hasLength(2));
    expect(sentKeys[1], sentKeys[0],
        reason: 'timeout retry must reuse the idempotency key');
    expect(find.textContaining('DETAILS /orders/order_abc123?ack=1'),
        findsOneWidget,
        reason: 'lands on the acknowledgement/details screen');
  });

  testWidgets('submit button is disabled while a request is active',
      (tester) async {
    var posts = 0;
    final gate = Completer<http.Response>();
    await pumpCart(tester, handler: (_) {
      posts++;
      return gate.future;
    });

    await tester.enterText(
        find.byType(TextFormField), '12 Lake Road, Bengaluru');
    await tester.ensureVisible(find.text('Checkout'));
    await tester.pump();
    await tester.tap(find.text('Checkout'));
    await tester.pump();

    expect(posts, 1);
    expect(find.text('Placing order…'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    // A second tap cannot start another submission.
    final buttonFinder = find.byType(FilledButton);
    // The checkout button is replaced by a disabled progress state; tapping
    // anywhere must not add requests.
    await tester.tap(buttonFinder, warnIfMissed: false);
    await tester.pump();
    expect(posts, 1);

    gate.complete(_accepted('order_1'));
    await tester.pumpAndSettle();
  });

  testWidgets('empty cart shows the empty state', (tester) async {
    await pumpCart(tester, withItem: false, handler: (_) async {
      return _accepted('order_1');
    });
    expect(
      find.textContaining('Your cart is empty'),
      findsOneWidget,
    );
  });
}
