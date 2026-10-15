import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/restaurant.dart';
import '../state/restaurants_controller.dart';
import '../widgets/state_views.dart';

/// Restaurant list: grid on wide layouts, list on phones; explicit
/// loading / empty / error states and pull-to-refresh.
class RestaurantsScreen extends StatelessWidget {
  const RestaurantsScreen({super.key});

  void _open(BuildContext context, Restaurant restaurant) {
    Navigator.of(context).pushNamed('/restaurants/${restaurant.id}');
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<RestaurantsController>();

    return StateView(
      state: controller.state,
      error: controller.error,
      onRetry: () => controller.load(refresh: true),
      emptyIcon: Icons.store_mall_directory_outlined,
      emptyMessage: 'No restaurants are available right now.',
      loadingLabel: 'Loading restaurants…',
      builder: (context) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 720;
            final refresh = RefreshIndicator(
              onRefresh: () => controller.load(refresh: true),
              child: wide
                  ? GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 360,
                        mainAxisExtent: 210,
                        crossAxisSpacing: 16,
                        mainAxisSpacing: 16,
                      ),
                      itemCount: controller.items.length,
                      itemBuilder: (context, index) => _RestaurantCard(
                        restaurant: controller.items[index],
                        onTap: () =>
                            _open(context, controller.items[index]),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: controller.items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) => _RestaurantCard(
                        restaurant: controller.items[index],
                        onTap: () =>
                            _open(context, controller.items[index]),
                      ),
                    ),
            );
            return refresh;
          },
        );
      },
    );
  }
}

class _RestaurantCard extends StatelessWidget {
  const _RestaurantCard({required this.restaurant, required this.onTap});

  final Restaurant restaurant;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Text(
                      restaurant.name.isEmpty
                          ? '?'
                          : restaurant.name[0].toUpperCase(),
                      style: TextStyle(
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          restaurant.name,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          restaurant.cuisine,
                          style: theme.textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(
                      restaurant.isOpen ? 'Open' : 'Closed',
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    backgroundColor: restaurant.isOpen
                        ? Colors.green.shade100
                        : theme.colorScheme.errorContainer,
                    side: BorderSide.none,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                restaurant.description,
                style: theme.textTheme.bodyMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _Meta(icon: Icons.star_outline, text: '${restaurant.rating}/5'),
                  _Meta(
                    icon: Icons.schedule,
                    text: '${restaurant.etaMinutes} min',
                  ),
                  _Meta(
                    icon: Icons.payments_outlined,
                    text: restaurant.currency,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: Theme.of(context).colorScheme.outline),
        const SizedBox(width: 4),
        Text(text, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
