import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/auth_controller.dart';
import '../state/cart_controller.dart';
import '../state/restaurants_controller.dart';
import 'admin_screen.dart';
import 'history_screen.dart';
import 'restaurants_screen.dart';

/// Adaptive navigation shell: NavigationRail on wide (desktop/web) layouts,
/// NavigationBar on narrow phone layouts. Content is width-constrained on
/// very wide screens so lines stay readable and nothing overflows.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.initialTab = 0});

  /// 0 browse, 1 history, 2 admin (admin only).
  final int initialTab;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late int _tab;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
    // Load restaurants once the signed-in shell exists (never pre-login).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<RestaurantsController>().ensureLoaded();
      }
    });
  }

  static const _titles = ['QuickBite', 'My orders', 'Admin overview'];

  void _goToCart() {
    Navigator.of(context).pushNamed('/cart');
  }

  void _signOut() {
    context.read<AuthController>().signOut();
  }

  List<Widget> _destinations({required bool admin}) => [
        const NavigationDestination(
          icon: Icon(Icons.restaurant_menu_outlined),
          selectedIcon: Icon(Icons.restaurant_menu),
          label: 'Restaurants',
        ),
        const NavigationDestination(
          icon: Icon(Icons.receipt_long_outlined),
          selectedIcon: Icon(Icons.receipt_long),
          label: 'Orders',
        ),
        if (admin)
          const NavigationDestination(
            icon: Icon(Icons.admin_panel_settings_outlined),
            selectedIcon: Icon(Icons.admin_panel_settings),
            label: 'Admin',
          ),
      ];

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final isAdmin = auth.isAdmin;
    final cart = context.watch<CartController>();
    final cartCount = cart.totalQuantity;

    if (!auth.isSignedIn) {
      // Root gate handles navigation; show sign-in directly to avoid a
      // flash of protected UI after sign-out/session expiry.
      return const SignInShell();
    }

    final destinations = _destinations(admin: isAdmin);
    if (_tab >= destinations.length) _tab = 0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;

        Widget body = IndexedStack(
          index: _tab,
          children: [
            const RestaurantsScreen(),
            const HistoryScreen(),
            if (isAdmin) const AdminScreen(),
          ],
        );
        if (wide) {
          body = Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: body,
            ),
          );
        }

        final actions = [
          Semantics(
            label: 'Cart, $cartCount items',
            button: true,
            child: IconButton(
              tooltip: 'Cart ($cartCount)',
              onPressed: _goToCart,
              icon: Badge(
                isLabelVisible: cartCount > 0,
                label: Text('$cartCount'),
                child: const Icon(Icons.shopping_cart_outlined),
              ),
            ),
          ),
          Semantics(
            label: 'Sign out',
            button: true,
            child: IconButton(
              tooltip: 'Sign out',
              onPressed: _signOut,
              icon: const Icon(Icons.logout),
            ),
          ),
        ];

        if (wide) {
          return Scaffold(
            appBar: AppBar(
              title: Text(_titles[_tab]),
              actions: actions,
            ),
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: _tab,
                  onDestinationSelected: (i) => setState(() => _tab = i),
                  labelType: NavigationRailLabelType.all,
                  leading: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Icon(Icons.fastfood, size: 32),
                  ),
                  destinations: [
                    for (final d in destinations)
                      NavigationRailDestination(
                        icon: (d as NavigationDestination).icon,
                        selectedIcon: d.selectedIcon,
                        label: Text(d.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(child: body),
              ],
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(_titles[_tab]),
            actions: actions,
          ),
          body: body,
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: destinations,
          ),
        );
      },
    );
  }
}

/// Minimal placeholder used while the root gate swaps to the sign-in screen.
class SignInShell extends StatelessWidget {
  const SignInShell({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
