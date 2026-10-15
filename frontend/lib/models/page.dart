/// Uniform list envelope from the API:
/// `{items, page, page_size, total}` with page starting at 1.
class Page<T> {
  const Page({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.total,
  });

  final List<T> items;
  final int page;
  final int pageSize;
  final int total;

  bool get hasMore => page * pageSize < total;

  bool get isEmpty => items.isEmpty;

  factory Page.fromJson(
    Object? json,
    T Function(Object? json) parseItem,
  ) {
    final map = json as Map<String, dynamic>;
    final rawItems = (map['items'] as List<dynamic>? ?? const []);
    return Page<T>(
      items: rawItems.map(parseItem).toList(),
      page: (map['page'] as num?)?.toInt() ?? 1,
      pageSize: (map['page_size'] as num?)?.toInt() ?? rawItems.length,
      total: (map['total'] as num?)?.toInt() ?? rawItems.length,
    );
  }
}
