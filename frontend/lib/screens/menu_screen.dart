import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../models/menu_item.dart';
import '../models/restaurant.dart';
import '../state/cart_controller.dart';
import '../state/catalogue_controller.dart';
import '../state/restaurants_controller.dart';
import '../widgets/brand.dart';
import '../widgets/food_image.dart';
import '../widgets/quantity_stepper.dart';
import '../widgets/state_views.dart';

/// Food menu (reference layout 3).
///
/// Two data sources behind one layout:
///  * `/restaurants/{id}` — a single kitchen's menu (promo banner is that
///    kitchen's hero shot, categories are its own menu sections),
///  * `/menu` — the full catalogue across every open kitchen, optionally
///    narrowed by `?category=` / `?q=`.
///
/// Search and category filters run against the loaded page, so they respond
/// instantly; the Add button writes to the real cart.
class MenuScreen extends StatelessWidget {
  const MenuScreen({
    super.key,
    this.restaurantId,
    this.initialCategory,
    this.initialQuery,
  });

  final String? restaurantId;
  final String? initialCategory;
  final String? initialQuery;

  @override
  Widget build(BuildContext context) {
    if (restaurantId != null) {
      return ChangeNotifierProvider<RestaurantMenuController>(
        create: (context) =>
            RestaurantMenuController(context.read())..load(restaurantId!),
        child: _MenuView(restaurantId: restaurantId),
      );
    }
    return ChangeNotifierProvider<GlobalMenuController>(
      create: (context) => GlobalMenuController(context.read())..ensureLoaded(),
      child: _MenuView(
        initialCategory: initialCategory,
        initialQuery: initialQuery,
      ),
    );
  }
}

class _MenuView extends StatefulWidget {
  const _MenuView({this.restaurantId, this.initialCategory, this.initialQuery});

  final String? restaurantId;
  final String? initialCategory;
  final String? initialQuery;

  @override
  State<_MenuView> createState() => _MenuViewState();
}

class _MenuViewState extends State<_MenuView> {
  final _searchController = TextEditingController();
  String _search = '';
  String? _category;

  @override
  void initState() {
    super.initState();
    _category = widget.initialCategory;
    _search = widget.initialQuery ?? '';
    _searchController.text = _search;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _showCartConflict(BuildContext context, MenuItem item) {
    final cart = context.read<CartController>();
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

  void _addToCart(BuildContext context, MenuItem item) {
    final cart = context.read<CartController>();
    final restaurants = context.read<RestaurantsController>();
    final restaurant = restaurants.items
        .where((r) => r.id == item.restaurantId)
        .firstOrNull;
    final result = cart.add(item, fromRestaurant: restaurant);
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
        _showCartConflict(context, item);
      case CartAddResult.quantityLimit:
        messenger.showSnackBar(
          const SnackBar(content: Text('Maximum quantity per item is 20.')),
        );
      case CartAddResult.itemLimit:
        messenger.showSnackBar(
          const SnackBar(
            content: Text('An order can contain at most 20 distinct items.'),
          ),
        );
      case CartAddResult.unavailable:
        messenger.showSnackBar(
          SnackBar(content: Text('${item.name} is currently unavailable.')),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartController>();
    final restaurants = context.watch<RestaurantsController>();

    final LoadState state;
    final List<MenuItem> items;
    final ApiException? error;
    final VoidCallback retry;
    if (widget.restaurantId == null) {
      final catalogue = context.watch<GlobalMenuController>();
      state = catalogue.state;
      items = catalogue.all;
      error = catalogue.error;
      retry = () {
        catalogue.load(refresh: true);
      };
    } else {
      final restaurantMenu = context.watch<RestaurantMenuController>();
      state = restaurantMenu.state;
      items = restaurantMenu.items;
      error = restaurantMenu.error;
      retry = () {
        restaurantMenu.load(widget.restaurantId!);
      };
    }

    // Restaurant row for the banner (list already loaded in the shell;
    // recover it if a previous load failed, e.g. arriving via deep link).
    Restaurant? restaurant;
    if (widget.restaurantId != null) {
      if (restaurants.items.isEmpty && restaurants.state == LoadState.error) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (restaurants.items.isEmpty &&
              restaurants.state == LoadState.error) {
            restaurants.load(refresh: true);
          }
        });
      }
      try {
        restaurant = restaurants.items
            .firstWhere((r) => r.id == widget.restaurantId);
      } on StateError {
        restaurant = null;
      }
    }

    return Scaffold(
      backgroundColor: Brand.warmBg,
      appBar: AppBar(
        title: Text(restaurant?.name ?? 'Full menu'),
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
        state: state,
        error: error,
        onRetry: retry,
        emptyIcon: Icons.no_food_outlined,
        emptyMessage: widget.restaurantId == null
            ? 'No dishes are available right now.'
            : 'This restaurant has no menu items yet.',
        loadingLabel: 'Loading menu…',
        builder: (context) => _buildBody(context, items, restaurant),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    List<MenuItem> items,
    Restaurant? restaurant,
  ) {
    final filtering =
        _search.trim().isNotEmpty || (_category?.isNotEmpty ?? false);
    var visible = items;
    if (_category != null && _category!.isNotEmpty) {
      visible = visible
          .where((item) => item.category == _category)
          .toList(growable: false);
    }
    final needle = _search.trim().toLowerCase();
    if (needle.isNotEmpty) {
      visible = visible
          .where((item) =>
              item.name.toLowerCase().contains(needle) ||
              item.description.toLowerCase().contains(needle))
          .toList(growable: false);
    }

    final sellable = visible.where((item) => item.isAvailable).toList();
    // A featured strip only makes sense once a kitchen has a real menu, and
    // never alongside an active filter (which would repeat dishes).
    final showFeatured = !filtering && sellable.length >= 6;
    final featured = showFeatured ? _spread(sellable, 4) : const <MenuItem>[];
    final grid = showFeatured
        ? visible.where((item) => !featured.contains(item)).toList()
        : visible;

    final categories = _categoryCounts(items);

    return RefreshIndicator(
      onRefresh: () async {
        if (widget.restaurantId != null) {
          await context
              .read<RestaurantMenuController>()
              .load(widget.restaurantId!);
        } else {
          await context.read<GlobalMenuController>().load(refresh: true);
        }
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final columns = width >= 1080
              ? 4
              : width >= 860
                  ? 3
                  : width >= 560
                      ? 2
                      : 1;
          final compact = width < 560;
          final scale = MediaQuery.textScalerOf(context)
              .scale(1.0)
              .clamp(1.0, 1.6)
              .toDouble();

          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PromoBanner(restaurant: restaurant, compact: compact),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 14 : 20,
                    14,
                    compact ? 14 : 20,
                    0,
                  ),
                  child: TextField(
                    controller: _searchController,
                    onChanged: (value) => setState(() => _search = value),
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Search dishes on this menu…',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _search.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _search = '');
                              },
                              icon: const Icon(Icons.close_rounded),
                            ),
                    ),
                  ),
                ),
                if (categories.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                        compact ? 8 : 14, 12, compact ? 8 : 14, 0),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: Row(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: ChoiceChip(
                              label: const Text('All'),
                              selected: _category == null,
                              onSelected: (_) =>
                                  setState(() => _category = null),
                            ),
                          ),
                          for (final category in categories)
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              child: ChoiceChip(
                                label: Text(category),
                                selected: _category == category,
                                onSelected: (_) => setState(
                                  () => _category =
                                      _category == category ? null : category,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (featured.isNotEmpty) ...[
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      compact ? 14 : 20,
                      22,
                      compact ? 14 : 20,
                      0,
                    ),
                    child: SectionHeader(
                      title: 'Featured items',
                      subtitle: 'The kitchen’s most ordered dishes',
                      compact: compact,
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      compact ? 14 : 20,
                      12,
                      compact ? 14 : 20,
                      0,
                    ),
                    child: _MenuGrid(
                      items: featured,
                      columns: columns,
                      compact: compact,
                      scale: scale,
                      onAdd: _addToCart,
                    ),
                  ),
                ],
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 14 : 20,
                    featured.isEmpty ? 20 : 22,
                    compact ? 14 : 20,
                    0,
                  ),
                  child: SectionHeader(
                    title: filtering
                        ? 'Results'
                        : (featured.isEmpty ? 'All dishes' : 'The rest of the menu'),
                    subtitle: filtering
                        ? '${visible.length} matching ${visible.length == 1 ? 'dish' : 'dishes'}'
                        : '${visible.length} ${visible.length == 1 ? 'dish' : 'dishes'} on this menu',
                    compact: compact,
                  ),
                ),
                const SizedBox(height: 12),
                if (grid.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                    child: _InlineNote(
                      icon: Icons.search_off_rounded,
                      message: _search.trim().isEmpty
                          ? 'Nothing matches the selected category.'
                          : 'No dish matches “$_search”. Try another word '
                              'or clear the filters.',
                    ),
                  )
                else
                  _MenuGrid(
                    items: grid,
                    columns: columns,
                    compact: compact,
                    scale: scale,
                    onAdd: _addToCart,
                  ),
                const SizedBox(height: 28),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Distinct categories present in the loaded menu, most populated first.
  List<String> _categoryCounts(List<MenuItem> items) {
    final counts = <String, int>{};
    for (final item in items) {
      if (!item.isAvailable) continue;
      counts[item.category] = (counts[item.category] ?? 0) + 1;
    }
    final entries = counts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });
    return [for (final entry in entries) entry.key];
  }

  /// Picks [count] dishes spread across the menu's categories.
  static List<MenuItem> _spread(List<MenuItem> items, int count) {
    final buckets = <String, List<MenuItem>>{};
    for (final item in items) {
      buckets.putIfAbsent(item.category, () => <MenuItem>[]).add(item);
    }
    final out = <MenuItem>[];
    var progressed = true;
    while (out.length < count && progressed) {
      progressed = false;
      for (final bucket in buckets.values) {
        if (out.length >= count) break;
        if (bucket.isEmpty) continue;
        out.add(bucket.removeAt(0));
        progressed = true;
      }
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// Promo banner
// ---------------------------------------------------------------------------

class _PromoBanner extends StatelessWidget {
  const _PromoBanner({required this.restaurant, required this.compact});

  final Restaurant? restaurant;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final image = restaurant?.imageUrl ?? 'assets/food/rest_pizza_parlour.jpg';
    final title = restaurant?.cuisine.isNotEmpty ?? false
        ? '${restaurant!.cuisine} kitchen'
        : 'The full QuickBite menu';
    final subtitle = restaurant?.description.isNotEmpty ?? false
        ? restaurant!.description
        : 'Every open kitchen on QuickBite, in one searchable menu — real '
            'prices in INR and live availability.';

    // The banner grows with the text scale so the title, description and
    // rating pills always fit inside it on a phone.
    final scale = MediaQuery.textScalerOf(context)
        .scale(1.0)
        .clamp(1.0, 1.6)
        .toDouble();

    return SizedBox(
      height: (compact ? 172.0 : 224.0) + (scale - 1.0) * 60.0,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FoodImage(url: image, icon: Icons.ramen_dining_rounded),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  const Color(0xFF3B1600).withValues(alpha: 0.92),
                  const Color(0xFF7C2D12).withValues(alpha: 0.62),
                  const Color(0xFFC2410C).withValues(alpha: 0.22),
                ],
              ),
            ),
          ),
          Positioned(
            top: -40,
            right: -30,
            child: Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.16),
                  width: 14,
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 16 : 24,
              vertical: compact ? 16 : 22,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: (compact
                          ? theme.textTheme.titleLarge
                          : theme.textTheme.headlineSmall)
                      ?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  maxLines: compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: Colors.white.withValues(alpha: 0.92)),
                ),
                if (restaurant != null) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 14,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      MetaPill(
                        icon: Icons.star_rounded,
                        label: '${restaurant!.rating}.0 rating',
                        onDark: true,
                        color: const Color(0xFFFCD34D),
                      ),
                      MetaPill(
                        icon: Icons.schedule_rounded,
                        label: '${restaurant!.etaMinutes} min',
                        onDark: true,
                        color: Colors.white,
                      ),
                      MetaPill(
                        icon: Icons.storefront_outlined,
                        label: restaurant!.isOpen ? 'Open now' : 'Closed',
                        onDark: true,
                        color: Colors.white,
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Grid + cards
// ---------------------------------------------------------------------------

class _MenuGrid extends StatelessWidget {
  const _MenuGrid({
    required this.items,
    required this.columns,
    required this.compact,
    required this.scale,
    required this.onAdd,
  });

  final List<MenuItem> items;
  final int columns;
  final bool compact;
  final double scale;
  final void Function(BuildContext context, MenuItem item) onAdd;

  @override
  Widget build(BuildContext context) {
    if (compact || columns == 1) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Column(
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              _MenuItemCard(
                item: items[i],
                compact: true,
                scale: scale,
                onAdd: () => onAdd(context, items[i]),
              ),
            ],
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 14.0;
        final cardWidth =
            (constraints.maxWidth - (columns - 1) * spacing) / columns;
        final imageHeight = cardWidth * 10 / 16;
        final extent = imageHeight + 190 * scale;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 20),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: extent,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) => _MenuItemCard(
            item: items[index],
            compact: false,
            scale: scale,
            onAdd: () => onAdd(context, items[index]),
          ),
        );
      },
    );
  }
}

class _MenuItemCard extends StatelessWidget {
  const _MenuItemCard({
    required this.item,
    required this.compact,
    required this.scale,
    required this.onAdd,
  });

  final MenuItem item;
  final bool compact;
  final double scale;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cart = context.watch<CartController>();
    final quantity = cart.quantityOf(item.id);

    final price = Text(
      formatMoney(item.priceMinor, item.currency),
      maxLines: 1,
      style: theme.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w800,
        color: Brand.orangeDeep,
      ),
    );

    final action = quantity > 0
        ? QuantityStepper(
            value: quantity,
            itemName: item.name,
            onChanged: (q) => cart.setQuantity(item.id, q),
            onRemove: () => cart.remove(item.id),
          )
        : FilledButton.tonalIcon(
            onPressed: item.isAvailable ? onAdd : null,
            icon: const Icon(Icons.add_shopping_cart, size: 18),
            label: const Text('Add'),
          );

    final heading = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            item.name,
            maxLines: compact ? 1 : 2,
            overflow: TextOverflow.ellipsis,
            style: compact
                ? theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)
                : theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        if (!item.isAvailable) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              'Sold out',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ],
    );

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        heading,
        const SizedBox(height: 2),
        Text(
          item.category,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style:
              theme.textTheme.bodySmall?.copyWith(color: Brand.orangeDeep),
        ),
        const SizedBox(height: 4),
        Text(
          item.description.isEmpty ? '—' : item.description,
          maxLines: compact ? 2 : 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(color: Brand.inkSoft),
        ),
      ],
    );

    if (compact) {
      return Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: theme.colorScheme.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      width: 104,
                      height: 104,
                      child: FoodImage(url: item.imageUrl),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: details),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Flexible(child: price),
                  const SizedBox(width: 8),
                  action,
                ],
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 10,
            child: FoodImage(url: item.imageUrl),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  details,
                  action,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineNote extends StatelessWidget {
  const _InlineNote({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Icon(icon, color: Brand.inkSoft),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style:
                  theme.textTheme.bodyMedium?.copyWith(color: Brand.inkSoft),
            ),
          ),
        ],
      ),
    );
  }
}
