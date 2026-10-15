/// A menu row. Prices are authoritative server minor units — the client
/// never sends prices to the API, only menu ids and quantities.
class MenuItem {
  const MenuItem({
    required this.id,
    required this.restaurantId,
    required this.name,
    required this.description,
    required this.category,
    required this.priceMinor,
    required this.currency,
    required this.isAvailable,
  });

  final String id;
  final String restaurantId;
  final String name;
  final String description;
  final String category;
  final int priceMinor;
  final String currency;
  final bool isAvailable;

  factory MenuItem.fromJson(Object? json) {
    final map = json as Map<String, dynamic>;
    return MenuItem(
      id: map['id'] as String,
      restaurantId: map['restaurant_id'] as String? ?? '',
      name: map['name'] as String? ?? '',
      description: map['description'] as String? ?? '',
      category: map['category'] as String? ?? 'Other',
      priceMinor: (map['price_minor'] as num).toInt(),
      currency: map['currency'] as String? ?? 'INR',
      isAvailable: map['is_available'] as bool? ?? true,
    );
  }

  /// Snapshot used for the locally persisted cart draft only.
  Map<String, dynamic> toJson() => {
        'id': id,
        'restaurant_id': restaurantId,
        'name': name,
        'description': description,
        'category': category,
        'price_minor': priceMinor,
        'currency': currency,
        'is_available': isAvailable,
      };
}
