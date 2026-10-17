import 'package:flutter/material.dart';

/// A real menu category derived from the seeded catalogue
/// (`GET /api/v1/menu/categories`), with its available-item count.
class MenuCategory {
  const MenuCategory({required this.name, required this.itemCount});

  final String name;
  final int itemCount;

  /// Tolerant parser: an empty body or a non-list payload yields no chips
  /// instead of throwing, so a degraded response never breaks the screen.
  static List<MenuCategory> listFromJson(Object? json) {
    if (json is! List) return const [];
    final out = <MenuCategory>[];
    for (final raw in json) {
      if (raw is! Map) continue;
      final name = raw['name'];
      if (name is! String || name.trim().isEmpty) continue;
      out.add(MenuCategory(
        name: name.trim(),
        itemCount: (raw['item_count'] as num?)?.toInt() ?? 0,
      ));
    }
    return out;
  }
}

/// A food icon that matches each seeded category, so category cards read as
/// food categories rather than generic labels.
IconData categoryIcon(String name) {
  switch (name.toLowerCase()) {
    case 'pizza':
      return Icons.local_pizza_rounded;
    case 'burgers':
      return Icons.lunch_dining_rounded;
    case 'sandwiches':
      return Icons.dining_rounded;
    case 'main':
    case 'mains':
      return Icons.ramen_dining_rounded;
    case 'starters':
      return Icons.tapas_rounded;
    case 'snacks':
      return Icons.cookie_rounded;
    case 'sides':
      return Icons.rice_bowl_rounded;
    case 'desserts':
      return Icons.icecream_rounded;
    case 'beverages':
      return Icons.local_cafe_rounded;
    case 'soups':
      return Icons.soup_kitchen_rounded;
    case 'bowls':
      return Icons.soup_kitchen_rounded;
    case 'salads':
      return Icons.spa_rounded;
    case 'pasta':
      return Icons.dinner_dining_rounded;
    case 'breakfast':
      return Icons.free_breakfast_rounded;
    case 'bakery':
      return Icons.bakery_dining_rounded;
    default:
      return Icons.restaurant_rounded;
  }
}
