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
    this.imageUrl,
    this.restaurantName,
    this.restaurantCuisine,
    this.restaurantIsOpen = true,
  });

  final String id;
  final String restaurantId;
  final String name;
  final String description;
  final String category;
  final int priceMinor;
  final String currency;
  final bool isAvailable;

  /// Image reference: an absolute http(s) URL, or a bundled asset path such as
  /// `assets/food/chicken_dum_biryani.jpg`. Null when a dish has no photo yet.
  final String? imageUrl;

  /// Filled by the global catalogue endpoint (`/api/v1/menu`) only.
  final String? restaurantName;
  final String? restaurantCuisine;
  final bool restaurantIsOpen;

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
      imageUrl: map['image_url'] as String?,
      restaurantName: map['restaurant_name'] as String?,
      restaurantCuisine: map['restaurant_cuisine'] as String?,
      restaurantIsOpen: map['restaurant_is_open'] as bool? ?? true,
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
        'image_url': imageUrl,
      };
}
