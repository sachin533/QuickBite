import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/money.dart';
import '../models/menu_item.dart';
import '../models/restaurant.dart';
import '../state/cart_controller.dart';
import '../state/restaurants_controller.dart';
import '../widgets/quantity_stepper.dart';
import '../widgets/state_views.dart';

/// Restaurant menu: names, prices (server minor units), currency,
/// availability, an explicit empty state, and add-to-cart with
/// single-restaurant enforcement.
class MenuScreen extends StatelessWidget {
  const MenuScreen({super.key, required this.restaurantId});

  final String restaurantId;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<RestaurantMenuController>(
      create: (context) =>
          RestaurantMenuController(context.read())..load(restaurantId),
      child: _MenuView(restaurantId: restaurantId),
    );
  }
}

class _MenuView extends StatelessWidget {
  const _MenuView({required this.restaurantId});

  final String restaurantId;

  void _showCartConflict(
    BuildContext context,
    MenuItem item,
    CartController cart,
  ) {
    final currentName = cart.restaurant?.name ?? 'another restaurant';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Your cart contains items from $currentName. Each order must come '
          'from one restaurant.',
        ),
        action: SnackBarAction(
          label: 'Start new cart',
          onPressed: () {
            final restaurants = context.read<RestaurantsController>();
            final restaurant = restaurants.items
                .where((r) => r.id == item.restaurantId)
                .firstOrNull;
            if (restaurant != null) {
              cart.replaceWith(item, restaurant);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Cart now contains only ${item.name} from '
                    '${restaurant.name}.',
                  ),
                ),
              );
            }
          },
        ),
      ),
    );
  }

  void _addToCart(
    BuildContext context,
    MenuItem item,
    Restaurant? restaurant,
  ) {
    final cart = context.read<CartController>();
    final result =
        cart.add(item, fromRestaurant: restaurant);
    final messenger = ScaffoldMessenger.of(context);
    switch (result) {
      case CartAddResult.added:
        messenger.showSnackBar(
          SnackBar(
            content: Text('${item.name} added to cart'),
            duration: const Duration(seconds: 1),
          ),
        );
      case CartAddResult.differentRestaurant:
        _showCartConflict(context, item, cart);
      case CartAddResult.quantityLimit:
        messenger.showSnackBar(
          const SnackBar(
              content: Text('Maximum quantity per item is 20.')),
        );
      case CartAddResult.itemLimit:
        messenger.showSnackBar(
          const SnackBar(
              content:
                  Text('An order can contain at most 20 distinct items.')),
        );
      case CartAddResult.unavailable:
        messenger.showSnackBar(
          SnackBar(content: Text('${item.name} is currently unavailable.')),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final menu = context.watch<RestaurantMenuController>();
    final cart = context.watch<CartController>();

    // Restaurant row for the header (list already loaded in the shell;
    // recover it if a previous load failed, e.g. arriving via deep link).
    Restaurant? restaurant;
    final restaurants = context.watch<RestaurantsController>();
    if (restaurants.items.isEmpty &&
        restaurants.state == LoadState.error) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (restaurants.items.isEmpty &&
            restaurants.state == LoadState.error) {
          restaurants.load(refresh: true);
        }
      });
    }
    try {
      restaurant =
          restaurants.items.firstWhere((r) => r.id == restaurantId);
    } on StateError {
      restaurant = null;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(restaurant?.name ?? 'Menu'),
        actions: [
          Semantics(
            label: 'Cart, ${cart.totalQuantity} items',
            button: true,
            child: IconButton(
              tooltip: 'Cart (${cart.totalQuantity})',
              onPressed: () => Navigator.of(context).pushNamed('/cart'),
              icon: Badge(
                isLabelVisible: cart.totalQuantity > 0,
                label: Text('${cart.totalQuantity}'),
                child: const Icon(Icons.shopping_cart_outlined),
              ),
            ),
          ),
        ],
      ),
      body: StateView(
        state: menu.state,
        error: menu.error,
        onRetry: () => menu.load(restaurantId),
        emptyIcon: Icons.no_food_outlined,
        emptyMessage: 'This restaurant has no menu items yet.',
        loadingLabel: 'Loading menu…',
        builder: (context) => LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 720;
            if (wide) {
              return GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 420,
                  mainAxisExtent: 240,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                ),
                itemCount: menu.items.length,
                itemBuilder: (context, index) => _MenuItemCard(
                  item: menu.items[index],
                  quantity: cart.quantityOf(menu.items[index].id),
                  onAdd: () => _addToCart(context, menu.items[index], restaurant),
                  onSetQuantity: (q) => cart.setQuantity(menu.items[index].id, q),
                  onRemove: () => cart.remove(menu.items[index].id),
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: menu.items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) => _MenuItemCard(
                item: menu.items[index],
                quantity: cart.quantityOf(menu.items[index].id),
                onAdd: () => _addToCart(context, menu.items[index], restaurant),
                onSetQuantity: (q) => cart.setQuantity(menu.items[index].id, q),
                onRemove: () => cart.remove(menu.items[index].id),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _MenuItemCard extends StatelessWidget {
  const _MenuItemCard({
    required this.item,
    required this.quantity,
    required this.onAdd,
    required this.onSetQuantity,
    required this.onRemove,
  });

  final MenuItem item;
  final int quantity;
  final VoidCallback onAdd;
  final ValueChanged<int> onSetQuantity;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item.category,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.primary),
                      ),
                    ],
                  ),
                ),
                if (!item.isAvailable)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: const Text('Unavailable',
                        style: TextStyle(fontSize: 12)),
                    backgroundColor: theme.colorScheme.errorContainer,
                    side: BorderSide.none,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              item.description.isEmpty ? '—' : item.description,
              style: theme.textTheme.bodyMedium,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text(
                  formatMoney(item.priceMinor, item.currency),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const Spacer(),
                if (quantity > 0)
                  QuantityStepper(
                    value: quantity,
                    itemName: item.name,
                    onChanged: onSetQuantity,
                    onRemove: onRemove,
                  )
                else
                  FilledButton.tonalIcon(
                    onPressed:
                        item.isAvailable ? onAdd : null,
                    icon: const Icon(Icons.add_shopping_cart, size: 18),
                    label: const Text('Add'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
