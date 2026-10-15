class Restaurant {
  const Restaurant({
    required this.id,
    required this.name,
    required this.description,
    required this.cuisine,
    required this.currency,
    this.imageUrl,
    required this.isOpen,
    required this.rating,
    required this.etaMinutes,
  });

  final String id;
  final String name;
  final String description;
  final String cuisine;
  final String currency;
  final String? imageUrl;
  final bool isOpen;
  final int rating;
  final int etaMinutes;

  factory Restaurant.fromJson(Object? json) {
    final map = json as Map<String, dynamic>;
    return Restaurant(
      id: map['id'] as String,
      name: map['name'] as String? ?? '',
      description: map['description'] as String? ?? '',
      cuisine: map['cuisine'] as String? ?? '',
      currency: map['currency'] as String? ?? 'INR',
      imageUrl: map['image_url'] as String?,
      isOpen: map['is_open'] as bool? ?? true,
      rating: (map['rating'] as num?)?.toInt() ?? 3,
      etaMinutes: (map['eta_minutes'] as num?)?.toInt() ?? 0,
    );
  }
}
