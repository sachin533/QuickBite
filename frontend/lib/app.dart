import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/api_client.dart';
import 'core/theme.dart';
import 'screens/cart_screen.dart';
import 'screens/home_shell.dart';
import 'screens/menu_screen.dart';
import 'screens/order_details_screen.dart';
import 'screens/sign_in_screen.dart';
import 'state/auth_controller.dart';
import 'state/cart_controller.dart';
import 'state/checkout_controller.dart';
import 'state/restaurants_controller.dart';

/// App root: providers, theming, route table, and the authentication gate.
///
/// Routing is path-based friendly (deep links survive a page reload):
///   /                      home shell (browse tab)
///   /history               home shell (orders tab)
///   /admin                 home shell (admin tab, admin role only in UI)
///   /restaurants/{id}      menu
///   /cart                  cart + checkout
///   /orders/{id}?ack=1     order details (+ 202 acknowledgement card)
///   /signin                sign-in
class QuickBiteApp extends StatelessWidget {
  const QuickBiteApp({super.key, required this.apiClient});

  final ApiClient apiClient;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: apiClient),
        ChangeNotifierProvider<AuthController>(
          create: (_) => AuthController(apiClient),
        ),
        ChangeNotifierProvider<CartController>(
          create: (_) => CartController()..restore(),
        ),
        ChangeNotifierProvider<CheckoutController>(
          create: (_) => CheckoutController(apiClient)..restore(),
        ),
        ChangeNotifierProvider<RestaurantsController>(
          create: (_) => RestaurantsController(apiClient),
        ),
      ],
      child: Builder(
        builder: (context) => MaterialApp(
          title: 'QuickBite',
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          themeMode: ThemeMode.system,
          onGenerateRoute: (settings) {
            final route = _buildRoute(settings);
            return route;
          },
          onGenerateInitialRoutes: _initialRoutes,
        ),
      ),
    );
  }

  static ThemeData _theme(Brightness brightness) =>
      quickbiteTheme(brightness);

  /// Deep link: home shell underneath + the target screen on top.
  static List<Route<dynamic>> _initialRoutes(String initialRoute) {
    final uri = Uri.parse(initialRoute.isEmpty ? '/' : initialRoute);
    final path = uri.path.isEmpty ? '/' : uri.path;

    if (path == '/signin') {
      return [
        _wrap(RouteSettings(name: '/signin'),
            const SignInScreen(pendingRoute: '/')),
      ];
    }

    final routes = <Route<dynamic>>[
      _wrap(
        RouteSettings(name: _shellPath(path)),
        HomeShell(initialTab: _tabFor(path)),
      ),
    ];

    final target = _targetFor(uri);
    if (target != null) {
      routes.add(_wrap(RouteSettings(name: initialRoute), target));
    }
    return routes;
  }

  static Route<dynamic> _buildRoute(RouteSettings settings) {
    final uri = Uri.parse(settings.name ?? '/');
    final path = uri.path.isEmpty ? '/' : uri.path;

    if (path == '/signin') {
      return _wrap(
        settings,
        const SignInScreen(pendingRoute: '/'),
      );
    }

    final target = _targetFor(uri) ??
        HomeShell(initialTab: _tabFor(path));
    return _wrap(settings, target);
  }

  /// The screen for a path (null → the shell itself).
  static Widget? _targetFor(Uri uri) {
    final path = uri.path;
    final segments =
        path.split('/').where((s) => s.isNotEmpty).toList(growable: false);

    if (segments.length == 2 && segments[0] == 'restaurants') {
      return MenuScreen(restaurantId: segments[1]);
    }
    if (path == '/menu') {
      // Full catalogue across every open kitchen; the home page's category
      // cards and "view full menu" actions land here.
      return MenuScreen(
        initialCategory: uri.queryParameters['category'],
        initialQuery: uri.queryParameters['q'],
      );
    }
    if (segments.length == 2 && segments[0] == 'orders') {
      return OrderDetailsScreen(
        orderId: segments[1],
        justAccepted: uri.queryParameters['ack'] == '1',
      );
    }
    if (path == '/cart') return const CartScreen();
    return null;
  }

  static String _shellPath(String path) => path;

  static int _tabFor(String path) {
    switch (path) {
      case '/history' || '/orders':
        return 1;
      case '/admin':
        return 2;
      default:
        return 0;
    }
  }

  static Route<dynamic> _wrap(RouteSettings settings, Widget child) {
    return MaterialPageRoute(
      settings: settings,
      builder: (context) => RouteGuard(
        routeName: settings.name ?? '/',
        child: child,
      ),
    );
  }
}

/// Authentication gate for every protected route.
///
/// Watches [AuthController]: when the session ends (sign-out or 401 expiry)
/// the protected child is replaced by the sign-in screen *in place*, keeping
/// the route (and thus the deep link) as the post-login destination, and
/// background polling stops because the API client signals expiry once.
class RouteGuard extends StatelessWidget {
  const RouteGuard({
    super.key,
    required this.routeName,
    required this.child,
  });

  final String routeName;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    if (!auth.isSignedIn) {
      final pending =
          routeName == '/' || routeName.isEmpty ? null : routeName;
      return SignInScreen(pendingRoute: pending);
    }
    return child;
  }
}
