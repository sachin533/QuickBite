import 'dart:async';
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

http.Response envelope(int status, String code, String message) =>
    http.Response(
      jsonEncode(
          {'code': code, 'message': message, 'details': null,
           'request_id': 'req_1'}),
      status,
      headers: {'content-type': 'application/json'},
    );

const _loginOk = {
  'access_token': 'tok_123',
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
};

Future<void> pumpSignIn(
  WidgetTester tester,
  MockClientHandler handler, {
  String? pendingRoute,
}) async {
  final client = ApiClient(baseUrl: 'http://test', client: MockClient(handler));
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: client),
        ChangeNotifierProvider<AuthController>(
          create: (_) => AuthController(client),
        ),
      ],
      child: MaterialApp(
        initialRoute: '/signin',
        routes: {
          '/signin': (_) => SignInScreen(pendingRoute: pendingRoute),
          '/': (_) => const Scaffold(body: Text('HOME')),
          '/history': (_) => const Scaffold(body: Text('HISTORY')),
        },
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('validates empty email and password before any request',
      (tester) async {
    var calls = 0;
    await pumpSignIn(tester, (_) async {
      calls++;
      return http.Response('{}', 200);
    });

    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(find.text('Email is required'), findsOneWidget);
    expect(find.text('Password is required'), findsOneWidget);
    expect(calls, 0, reason: 'no request with an invalid form');
  });

  testWidgets('shows the loading state while the request is in flight',
      (tester) async {
    final gate = Completer<http.Response>();
    await pumpSignIn(tester, (_) => gate.future);

    await tester.enterText(find.byType(TextFormField).first,
        'maya@quickbite.dev');
    await tester.enterText(
        find.byType(TextFormField).last, 'demo12345');
    await tester.tap(find.text('Sign in'));
    await tester.pump();

    // Button replaced by a progress indicator and inputs are disabled.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField).first).enabled,
      isFalse,
    );

    gate.complete(http.Response(jsonEncode(_loginOk), 200,
        headers: {'content-type': 'application/json'}));
    await tester.pumpAndSettle();
    expect(find.text('HOME'), findsOneWidget,
        reason: 'lands on the home shell after sign-in');
  });

  testWidgets('invalid credentials show the explicit error state',
      (tester) async {
    await pumpSignIn(
        tester,
        (_) async =>
            envelope(401, 'invalid_credentials', 'Incorrect email or password'));

    await tester.enterText(find.byType(TextFormField).first,
        'maya@quickbite.dev');
    await tester.enterText(
        find.byType(TextFormField).last, 'wrong-password');
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    await tester.pump(); // let the error future land

    expect(find.text('Incorrect email or password.'), findsOneWidget);
    expect(find.text('HOME'), findsNothing);
  });

  testWidgets('network failure shows the offline/error state, then retry works',
      (tester) async {
    var calls = 0;
    await pumpSignIn(tester, (_) async {
      calls++;
      if (calls == 1) {
        throw http.ClientException('Connection refused');
      }
      return http.Response(jsonEncode(_loginOk), 200,
          headers: {'content-type': 'application/json'});
    });

    await tester.enterText(find.byType(TextFormField).first,
        'maya@quickbite.dev');
    await tester.enterText(
        find.byType(TextFormField).last, 'demo12345');
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    await tester.pump();

    expect(
      find.textContaining("Can't reach the server"),
      findsOneWidget,
    );
    expect(calls, 1);

    // Retry the same credentials; the second attempt succeeds.
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    await tester.pump();
    expect(find.text('HOME'), findsOneWidget);
    expect(calls, 2);
  });

  testWidgets(
      '401 expiry swaps the guarded route to sign-in with the banner',
      (tester) async {
    final client = ApiClient(
      baseUrl: 'http://test',
      client: MockClient((_) async => http.Response(jsonEncode(_loginOk), 200,
          headers: {'content-type': 'application/json'})),
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
          initialRoute: '/',
          onGenerateRoute: (settings) => MaterialPageRoute(
            settings: settings,
            builder: (context) => RouteGuard(
              routeName: settings.name ?? '/',
              child: const Scaffold(body: Text('PROTECTED')),
            ),
          ),
        ),
      ),
    );

    // Signed out -> guard shows sign-in, no expiry banner yet.
    expect(find.byType(SignInScreen), findsOneWidget);
    expect(find.textContaining('session expired'), findsNothing);

    // Sign in through the UI: guard swaps to the protected child in place.
    await tester.enterText(find.byType(TextFormField).first,
        'maya@quickbite.dev');
    await tester.enterText(
        find.byType(TextFormField).last, 'demo12345');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('PROTECTED'), findsOneWidget);

    // A protected 401 ends the session -> back on sign-in with the banner.
    final auth =
        tester.element(find.text('PROTECTED')).read<AuthController>();
    auth.sessionExpiredNow();
    await tester.pump();

    expect(find.byType(SignInScreen), findsOneWidget);
    expect(
      find.textContaining('session expired'),
      findsOneWidget,
    );
  });
}
