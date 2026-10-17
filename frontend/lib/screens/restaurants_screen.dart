import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/money.dart';
import '../core/theme.dart';
import '../models/menu_category.dart';
import '../models/menu_item.dart';
import '../models/restaurant.dart';
import '../state/auth_controller.dart';
import '../state/cart_controller.dart';
import '../state/catalogue_controller.dart';
import '../state/restaurants_controller.dart';
import '../widgets/brand.dart';
import '../widgets/food_image.dart';
import '../widgets/state_views.dart';

/// Customer landing page (reference layout 2).
///
/// Renders as soon as the signed-in shell exists: the restaurant list comes
/// from the shell's own controller and the food catalogue loads in parallel
/// *behind* the page, so a slow or failing optional service can never hold up
/// the header, hero or restaurant list.
class RestaurantsScreen extends StatefulWidget {
  const RestaurantsScreen({super.key});

  @override
  State<RestaurantsScreen> createState() => _RestaurantsScreenState();
}

class _RestaurantsScreenState extends State<RestaurantsScreen> {
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  String _query = '';

  static final _heroKey = GlobalKey();
  static final _restaurantsKey = GlobalKey();
  static final _categoriesKey = GlobalKey();
  static final _offersKey = GlobalKey();
  static final _aboutKey = GlobalKey();

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _open(Restaurant restaurant) {
    Navigator.of(context).pushNamed('/restaurants/${restaurant.id}');
  }

  void _openFullMenu({String? category}) {
    final uri = category == null
        ? '/menu'
        : '/menu?category=${Uri.encodeQueryComponent(category)}';
    Navigator.of(context).pushNamed(uri);
  }

  void _scrollTo(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignment: 0.04,
    );
  }

  void _signOut() => context.read<AuthController>().signOut();

  @override
  Widget build(BuildContext context) {
    final restaurants = context.watch<RestaurantsController>();

    return ChangeNotifierProvider<CatalogueController>(
      create: (context) =>
          CatalogueController(context.read())..ensureLoaded(),
      child: StateView(
        state: restaurants.state,
        error: restaurants.error,
        onRetry: () => restaurants.load(refresh: true),
        emptyIcon: Icons.store_mall_directory_outlined,
        emptyMessage: 'No restaurants are available right now.',
        loadingLabel: 'Loading restaurants…',
        builder: (context) => _buildPage(context, restaurants),
      ),
    );
  }

  Widget _buildPage(BuildContext context, RestaurantsController controller) {
    final catalogue = context.watch<CatalogueController>();
    final cart = context.watch<CartController>();
    final auth = context.watch<AuthController>();
    final query = _query.trim().toLowerCase();

    final visibleRestaurants = query.isEmpty
        ? controller.items
        : controller.items
            .where((r) =>
                r.name.toLowerCase().contains(query) ||
                r.cuisine.toLowerCase().contains(query) ||
                r.description.toLowerCase().contains(query))
            .toList(growable: false);

    final dishHits = query.isEmpty
        ? const <MenuItem>[]
        : catalogue.items
            .where((i) =>
                i.isAvailable &&
                (i.name.toLowerCase().contains(query) ||
                    i.description.toLowerCase().contains(query)))
            .take(8)
            .toList(growable: false);

    return RefreshIndicator(
      onRefresh: () async {
        await Future.wait([
          controller.load(refresh: true),
          catalogue.load(refresh: true),
        ]);
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final wide = width >= 720;
          // In-page navigation and the header search box only appear when
          // there is genuinely room for them; below that the search lives
          // directly under the hero.
          final showNav = width >= 900;
          final showHeaderSearch = width >= 1000;
          final navItems = [
            _NavTarget('Home', _heroKey),
            _NavTarget('Restaurants', _restaurantsKey),
            _NavTarget('Categories', _categoriesKey),
            _NavTarget('Offers', _offersKey),
            _NavTarget('About', _aboutKey),
          ];
          return SingleChildScrollView(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(
                  wide: wide,
                  auth: auth,
                  cartCount: cart.totalQuantity,
                  navItems: showNav ? navItems : const [],
                  searchController: _searchController,
                  showSearch: showHeaderSearch,
                  onQueryChanged: (value) =>
                      setState(() => _query = value),
                  onNavigate: (key) => _scrollTo(key),
                  onOpenCart: () => Navigator.of(context).pushNamed('/cart'),
                  onSignOut: _signOut,
                ),
                KeyedSubtree(key: _heroKey, child: _Hero(wide: wide)),
                if (!showHeaderSearch)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                        wide ? 20 : 14, 14, wide ? 20 : 14, 0),
                    child: _SearchBar(
                      controller: _searchController,
                      onChanged: (value) => setState(() => _query = value),
                    ),
                  ),
                KeyedSubtree(
                  key: _restaurantsKey,
                  child: _Section(
                    title: query.isEmpty ? 'Popular restaurants' : 'Restaurants',
                    subtitle: query.isEmpty
                        ? 'Kitchens loved by customers near you'
                        : 'Matching “$_query”',
                    wide: wide,
                    child: visibleRestaurants.isEmpty
                        ? _InlineNote(
                            icon: Icons.search_off_rounded,
                            message:
                                'No kitchen matches “$_query”. Try another '
                                'dish or cuisine.',
                          )
                        : _RestaurantGrid(
                            restaurants: visibleRestaurants,
                            wide: wide,
                            onOpen: _open,
                          ),
                  ),
                ),
                if (query.isNotEmpty && dishHits.isNotEmpty)
                  _Section(
                    title: 'Dishes matching “$_query”',
                    wide: wide,
                    child: _DishGrid(items: dishHits, wide: wide),
                  )
                else ...[
                  KeyedSubtree(
                    key: _categoriesKey,
                    child: _CategoriesSection(
                      wide: wide,
                      categories: catalogue.categories,
                      onPick: (name) => _openFullMenu(category: name),
                    ),
                  ),
                  _FeaturedSection(
                    wide: wide,
                    items: catalogue.featured(),
                    onOpenFullMenu: () => _openFullMenu(),
                  ),
                  KeyedSubtree(
                    key: _offersKey,
                    child: _PromoBanner(
                      wide: wide,
                      restaurantCount: controller.items.length,
                      dishCount: catalogue.items.length,
                      onBrowse: () => _openFullMenu(),
                    ),
                  ),
                  _PopularSection(
                    wide: wide,
                    items: catalogue.popular(),
                    onOpenFullMenu: () => _openFullMenu(),
                  ),
                ],
                KeyedSubtree(
                  key: _aboutKey,
                  child: const _Footer(),
                ),
                const SizedBox(height: 28),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

/// An in-page anchor: the header links scroll the landing page to a section.
class _NavTarget {
  const _NavTarget(this.label, this.key);

  final String label;
  final GlobalKey key;
}

class _Header extends StatelessWidget {
  const _Header({
    required this.wide,
    required this.auth,
    required this.cartCount,
    required this.navItems,
    required this.searchController,
    required this.showSearch,
    required this.onQueryChanged,
    required this.onNavigate,
    required this.onOpenCart,
    required this.onSignOut,
  });

  final bool wide;
  final AuthController auth;
  final int cartCount;
  final List<_NavTarget> navItems;
  final TextEditingController searchController;
  final bool showSearch;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<GlobalKey> onNavigate;
  final VoidCallback onOpenCart;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = auth.user?.fullName ?? '';
    final initials = name.isEmpty
        ? (auth.user?.email.isNotEmpty ?? false ? auth.user!.email[0] : '?')
        : name[0].toUpperCase();

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border:
            Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      padding: EdgeInsets.symmetric(horizontal: wide ? 20 : 14, vertical: 10),
      child: Row(
        children: [
          // Cap the mark so the cart and account buttons always keep their
          // full tap target, even at raised text scales on a 360px phone.
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: wide ? 320 : 200),
            child: const QuickBiteLogo(),
          ),
          if (navItems.isNotEmpty) ...[
            const SizedBox(width: 16),
            Expanded(
              child: Wrap(
                spacing: 2,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final item in navItems)
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 36),
                      ),
                      onPressed: () => onNavigate(item.key),
                      child: Text(item.label),
                    ),
                ],
              ),
            ),
          ] else
            const Spacer(),
          if (showSearch) ...[
            const SizedBox(width: 12),
            SizedBox(
              width: 210,
              child: TextField(
                controller: searchController,
                onChanged: onQueryChanged,
                textInputAction: TextInputAction.search,
                style: theme.textTheme.bodyMedium,
                decoration: InputDecoration(
                  hintText: 'Search dishes…',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: searchController.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          onPressed: () {
                            searchController.clear();
                            onQueryChanged('');
                          },
                          icon: const Icon(Icons.close_rounded, size: 18),
                        ),
                ),
              ),
            ),
          ],
          Semantics(
            label: 'Cart, $cartCount items',
            button: true,
            child: IconButton(
              tooltip: 'Cart ($cartCount)',
              onPressed: onOpenCart,
              icon: Badge(
                isLabelVisible: cartCount > 0,
                label: Text('$cartCount'),
                child: const Icon(Icons.shopping_cart_outlined),
              ),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Account',
            onSelected: (value) {
              switch (value) {
                case 'orders':
                  Navigator.of(context).pushNamed('/history');
                case 'admin':
                  Navigator.of(context).pushNamed('/admin');
                case 'signout':
                  onSignOut();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                enabled: false,
                child: Text(
                  name.isEmpty ? (auth.user?.email ?? '') : name,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              const PopupMenuItem<String>(
                value: 'orders',
                child: Text('My orders'),
              ),
              if (auth.isAdmin)
                const PopupMenuItem<String>(
                  value: 'admin',
                  child: Text('Admin'),
                ),
              const PopupMenuItem<String>(
                value: 'signout',
                child: Text('Sign out'),
              ),
            ],
            child: CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              foregroundColor: theme.colorScheme.onPrimaryContainer,
              child: Text(
                initials,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hero
// ---------------------------------------------------------------------------

class _Hero extends StatelessWidget {
  const _Hero({required this.wide});

  final bool wide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scale = MediaQuery.textScalerOf(context)
        .scale(1.0)
        .clamp(1.0, 1.6)
        .toDouble();
    // The phone banner keeps a near-fixed height (type is sized down instead)
    // so the first restaurant card always lands inside the opening screen —
    // above the bottom navigation bar on phones.
    final height = wide ? 340.0 * scale : 244.0 + (scale - 1.0) * 90.0;

    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FoodImage(
            url: 'assets/food/rest_biryani_blues.jpg',
            icon: Icons.ramen_dining_rounded,
          ),
          // Scrim so text stays readable over any photograph.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: wide ? Alignment.centerLeft : Alignment.bottomCenter,
                end: wide ? Alignment.centerRight : Alignment.topCenter,
                colors: [
                  const Color(0xFF3B1600).withValues(alpha: 0.93),
                  const Color(0xFF7C2D12).withValues(alpha: 0.72),
                  const Color(0xFFC2410C).withValues(alpha: 0.30),
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: wide ? 32 : 18,
              vertical: wide ? 28 : 16,
            ),
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: _heroCopy(context, theme)),
                      const SizedBox(width: 24),
                      _heroPlate(),
                    ],
                  )
                : Align(
                    alignment: Alignment.bottomLeft,
                    child: _heroCopy(context, theme),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _heroPlate() {
    return Container(
      width: 220,
      height: 220,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 40,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      padding: const EdgeInsets.all(12),
      child: ClipOval(
        child: FoodImage(
          url: 'assets/food/chicken_dum_biryani.jpg',
          icon: Icons.ramen_dining_rounded,
        ),
      ),
    );
  }

  void _reveal(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _heroCopy(BuildContext context, ThemeData theme) {
    final white = Colors.white;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (wide) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const MetaPill(
              icon: Icons.bolt_rounded,
              label: 'Live order tracking from every kitchen',
              onDark: true,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
        ],
        Text(
          'Delicious Food, Delivered Fast',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: (wide
                  ? theme.textTheme.headlineMedium
                  : theme.textTheme.titleLarge)
              ?.copyWith(
            color: white,
            fontWeight: FontWeight.w800,
            height: 1.1,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Fresh biryani, pizza, dosas and more from trusted kitchens — hot '
          'at your door in 20–35 minutes.',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: (wide ? theme.textTheme.bodyMedium : theme.textTheme.bodySmall)
              ?.copyWith(color: white.withValues(alpha: 0.92)),
        ),
        const SizedBox(height: 14),
        Builder(builder: (context) {
          // Compact buttons on phones so the whole banner copy stays inside
          // the banner even at a raised text scale.
          final compactStyle = FilledButton.styleFrom(
            minimumSize: const Size(0, 42),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          );
          final compactOutline = OutlinedButton.styleFrom(
            minimumSize: const Size(0, 42),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            foregroundColor: white,
            side: const BorderSide(color: Colors.white70),
          );
          return Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FilledButton(
                style: wide ? null : compactStyle,
                onPressed: () =>
                    _reveal(_RestaurantsScreenState._restaurantsKey),
                child: const Text('Browse Food'),
              ),
              OutlinedButton(
                style: compactOutline,
                onPressed: () =>
                    _reveal(_RestaurantsScreenState._categoriesKey),
                child: const Text('Find Food'),
              ),
            ],
          );
        }),
      ],
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'Search dishes, cuisines or kitchens…',
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
                icon: const Icon(Icons.close_rounded),
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Generic section wrapper
// ---------------------------------------------------------------------------

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.child,
    required this.wide,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(wide ? 20 : 14, 22, wide ? 20 : 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: title,
            subtitle: subtitle,
            compact: !wide,
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Restaurants
// ---------------------------------------------------------------------------

class _RestaurantGrid extends StatelessWidget {
  const _RestaurantGrid({
    required this.restaurants,
    required this.wide,
    required this.onOpen,
  });

  final List<Restaurant> restaurants;
  final bool wide;
  final ValueChanged<Restaurant> onOpen;

  @override
  Widget build(BuildContext context) {
    if (!wide) {
      return Column(
        children: [
          for (var i = 0; i < restaurants.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            _RestaurantCard(
              restaurant: restaurants[i],
              compact: true,
              onTap: () => onOpen(restaurants[i]),
            ),
          ],
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 340).floor().clamp(1, 3);
        // Image (132) plus the copy block, which grows with the text scale.
        final scale = MediaQuery.textScalerOf(context)
            .scale(1.0)
            .clamp(1.0, 1.6)
            .toDouble();
        final extent = 132.0 + 200.0 * scale;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: extent,
            crossAxisSpacing: 14,
            mainAxisSpacing: 14,
          ),
          itemCount: restaurants.length,
          itemBuilder: (context, index) => _RestaurantCard(
            restaurant: restaurants[index],
            compact: false,
            onTap: () => onOpen(restaurants[index]),
          ),
        );
      },
    );
  }
}

class _RestaurantCard extends StatelessWidget {
  const _RestaurantCard({
    required this.restaurant,
    required this.onTap,
    required this.compact,
  });

  final Restaurant restaurant;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final badge = Positioned(
      top: 10,
      left: 10,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: restaurant.isOpen ? Brand.leaf : theme.colorScheme.error,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          restaurant.isOpen ? 'Open now' : 'Closed',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );

    final ratingBadge = Positioned(
      top: 10,
      right: 10,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.star_rounded, size: 15, color: Brand.gold),
            const SizedBox(width: 3),
            Text(
              '${restaurant.rating}.0',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );

    final openButton = SizedBox(
      width: compact ? null : double.infinity,
      child: FilledButton.tonalIcon(
        onPressed: onTap,
        icon: const Icon(Icons.restaurant_menu_rounded, size: 18),
        label: const Text('Open menu'),
      ),
    );

    final meta = Wrap(
      spacing: 12,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        MetaPill(
          icon: Icons.star_rounded,
          label: '${restaurant.rating}.0 rating',
          color: Brand.gold,
        ),
        MetaPill(
          icon: Icons.schedule_rounded,
          label: '${restaurant.etaMinutes} min',
        ),
        MetaPill(icon: Icons.storefront_outlined, label: restaurant.cuisine),
      ],
    );

    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: InkWell(
        onTap: onTap,
        child: compact
            ? Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: SizedBox(
                        width: 100,
                        height: 100,
                        child: FoodImage(url: restaurant.imageUrl),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            restaurant.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          meta,
                          const SizedBox(height: 10),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: openButton,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Stack(
                    children: [
                      SizedBox(
                        height: 132,
                        width: double.infinity,
                        child: FoodImage(url: restaurant.imageUrl),
                      ),
                      badge,
                      ratingBadge,
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          restaurant.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          restaurant.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: Brand.inkSoft),
                        ),
                        const SizedBox(height: 10),
                        meta,
                        const SizedBox(height: 12),
                        openButton,
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Categories
// ---------------------------------------------------------------------------

class _CategoriesSection extends StatelessWidget {
  const _CategoriesSection({
    required this.wide,
    required this.categories,
    required this.onPick,
  });

  final bool wide;
  final List<MenuCategory> categories;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    if (categories.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return _Section(
      title: 'Food categories',
      subtitle: 'Browse the full menu by what you are craving',
      wide: wide,
      child: SizedBox(
        height: 118,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: categories.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (context, index) {
            final category = categories[index];
            return InkWell(
              onTap: () => onPick(category.name),
              borderRadius: BorderRadius.circular(18),
              child: Container(
                width: 120,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: Brand.orangeSoft,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        categoryIcon(category.name),
                        color: Brand.orangeDeep,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      category.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '${category.itemCount} items',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Brand.inkSoft),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Featured / popular dishes
// ---------------------------------------------------------------------------

class _FeaturedSection extends StatelessWidget {
  const _FeaturedSection({
    required this.wide,
    required this.items,
    required this.onOpenFullMenu,
  });

  final bool wide;
  final List<MenuItem> items;
  final VoidCallback onOpenFullMenu;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return _Section(
      title: 'Featured items',
      subtitle: 'Hand-picked from kitchens that ship fastest today',
      wide: wide,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DishGrid(items: items, wide: wide),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: onOpenFullMenu,
              icon: const Icon(Icons.menu_book_rounded, size: 18),
              label: const Text('View full menu'),
            ),
          ),
        ],
      ),
    );
  }
}

class _PopularSection extends StatelessWidget {
  const _PopularSection({
    required this.wide,
    required this.items,
    required this.onOpenFullMenu,
  });

  final bool wide;
  final List<MenuItem> items;
  final VoidCallback onOpenFullMenu;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return _Section(
      title: 'Popular right now',
      subtitle: 'What everyone else is adding to their cart',
      wide: wide,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DishGrid(items: items, wide: wide),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: onOpenFullMenu,
              icon: const Icon(Icons.trending_up_rounded, size: 18),
              label: const Text('See all dishes'),
            ),
          ),
        ],
      ),
    );
  }
}

class _DishGrid extends StatelessWidget {
  const _DishGrid({required this.items, required this.wide});

  final List<MenuItem> items;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    if (!wide) {
      return Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            _DishTile(item: items[i]),
          ],
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 260).floor().clamp(2, 4);
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: 96,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) => _DishTile(item: items[index]),
        );
      },
    );
  }
}

/// Compact dish tile used on the landing page. Adding here is a real cart
/// action — it is rejected with an explicit message if the cart already holds
/// items from another kitchen.
class _DishTile extends StatelessWidget {
  const _DishTile({required this.item});

  final MenuItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cart = context.read<CartController>();
    final restaurants = context.read<RestaurantsController>();
    final restaurant = restaurants.items
        .where((r) => r.id == item.restaurantId)
        .firstOrNull;

    void add() {
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
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                'Your cart holds dishes from ${cart.restaurant?.name ?? 'another kitchen'}. '
                'Each order must come from one restaurant.',
              ),
              action: SnackBarAction(
                label: 'Start new cart',
                onPressed: () {
                  if (restaurant != null) cart.replaceWith(item, restaurant);
                },
              ),
            ),
          );
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

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context)
            .pushNamed('/restaurants/${item.restaurantId}'),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  width: 72,
                  height: 72,
                  child: FoodImage(url: item.imageUrl),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      item.category,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Brand.inkSoft),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      formatMoney(item.priceMinor, item.currency),
                      maxLines: 1,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: Brand.orangeDeep,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton.filledTonal(
                tooltip: 'Add ${item.name} to cart',
                onPressed: item.isAvailable ? add : null,
                icon: const Icon(Icons.add_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Promo + footer
// ---------------------------------------------------------------------------

class _PromoBanner extends StatelessWidget {
  const _PromoBanner({
    required this.wide,
    required this.restaurantCount,
    required this.dishCount,
    required this.onBrowse,
  });

  final bool wide;
  final int restaurantCount;
  final int dishCount;
  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dishLine = dishCount > 0 ? '$dishCount dishes' : 'dozens of dishes';
    final restLine =
        restaurantCount > 0 ? '$restaurantCount kitchens' : 'trusted kitchens';

    return Padding(
      padding: EdgeInsets.fromLTRB(wide ? 20 : 14, 22, wide ? 20 : 14, 0),
      child: Container(
        decoration: BoxDecoration(
          gradient: Brand.heroGradient,
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: Brand.orange.withValues(alpha: 0.28),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned(
              right: -40,
              top: -60,
              child: Container(
                width: 190,
                height: 190,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.18),
                    width: 16,
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(wide ? 24 : 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'One app, $restLine, $dishLine',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Every kitchen on QuickBite is a real seeded store with '
                    'live prices, availability and order tracking.',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: Colors.white.withValues(alpha: 0.92)),
                  ),
                  const SizedBox(height: 14),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Brand.orangeDeep,
                    ),
                    onPressed: onBrowse,
                    child: const Text('Explore the menu'),
                  ),
                ],
              ),
            ),
          ],
        ),
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
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: Brand.inkSoft),
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: EdgeInsets.only(top: 28),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 26),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const QuickBiteLogo(),
          const SizedBox(height: 10),
          Text(
            'QuickBite is a demo ordering platform: FastAPI, RabbitMQ and '
            'PostgreSQL on the back end, Flutter on the front end.',
            style: theme.textTheme.bodySmall?.copyWith(color: Brand.inkSoft),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 18,
            runSpacing: 8,
            children: const [
              Text('Menu', style: TextStyle(fontWeight: FontWeight.w700)),
              Text('Restaurants', style: TextStyle(fontWeight: FontWeight.w700)),
              Text('Offers', style: TextStyle(fontWeight: FontWeight.w700)),
              Text('About', style: TextStyle(fontWeight: FontWeight.w700)),
              Text('Support', style: TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '© ${DateTime.now().year} QuickBite · All dishes, prices and '
            'kitchens are seeded demo data in INR.',
            style: theme.textTheme.bodySmall?.copyWith(color: Brand.inkSoft),
          ),
        ],
      ),
    );
  }
}
