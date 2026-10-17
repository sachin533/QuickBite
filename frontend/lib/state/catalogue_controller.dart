import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/api_exception.dart';
import '../models/menu_item.dart';
import '../models/menu_category.dart';
import '../models/page.dart';
import 'restaurants_controller.dart';

/// Global catalogue behind the home page (featured items, popular dishes,
/// food categories) and the full-menu page.
///
/// Deliberately loaded *after* the shell renders: the sign-in screen and the
/// restaurant list never wait on it, so a slow or failing catalogue can never
/// hold up first paint.
class CatalogueController extends ChangeNotifier {
  CatalogueController(this._client);

  final ApiClient _client;

  LoadState _state = LoadState.idle;
  List<MenuItem> _items = const [];
  List<MenuCategory> _categories = const [];
  ApiException? _error;
  bool _loadedOnce = false;

  LoadState get state => _state;
  List<MenuItem> get items => _items;
  List<MenuCategory> get categories => _categories;
  ApiException? get error => _error;

  /// Idempotent first load (safe to call from any screen mount).
  Future<void> ensureLoaded() async {
    if (_loadedOnce) return;
    _loadedOnce = true;
    await load();
  }

  Future<void> load({bool refresh = false}) async {
    if (_state == LoadState.loading && !refresh) return;
    _state = LoadState.loading;
    _error = null;
    notifyListeners();
    try {
      final results = await Future.wait<dynamic>([
        _client.get('/api/v1/menu', query: {'page': '1', 'page_size': '100'}),
        _client.get('/api/v1/menu/categories'),
      ]);
      _items = Page.fromJson(results[0], MenuItem.fromJson).items;
      _categories = MenuCategory.listFromJson(results[1]);
      _state = _items.isEmpty ? LoadState.empty : LoadState.loaded;
    } on ApiException catch (e) {
      _error = e;
      _state = LoadState.error;
    }
    notifyListeners();
  }

  List<MenuItem> get _sellable =>
      _items.where((item) => item.isAvailable).toList(growable: false);

  /// Round-robin across kitchens so a strip never repeats a single restaurant.
  /// [skip] items from the front are dropped (used to build a second strip
  /// without repeating the first).
  List<MenuItem> _spread(int skip, int count) {
    final buckets = <String, List<MenuItem>>{};
    for (final item in _sellable) {
      buckets.putIfAbsent(item.restaurantId, () => <MenuItem>[]).add(item);
    }
    final out = <MenuItem>[];
    var seen = 0;
    var progressed = true;
    while (out.length < count && progressed) {
      progressed = false;
      for (final bucket in buckets.values) {
        if (out.length >= count) break;
        if (bucket.isEmpty) continue;
        final item = bucket.removeAt(0);
        if (seen >= skip) out.add(item);
        seen++;
        progressed = true;
      }
    }
    return out;
  }

  /// First pick across kitchens — the "Featured items" strip.
  List<MenuItem> featured({int count = 6}) => _spread(0, count);

  /// Second pick — the "Popular right now" strip on the home page.
  List<MenuItem> popular({int start = 6, int count = 6}) =>
      _spread(start, count);
}

/// Full-menu page data: every dish across every open kitchen.
///
/// The complete sellable catalogue fits in a single page (the API caps
/// `page_size` at 100 and the demo seeds 66 dishes), so search and category
/// filters are applied locally and respond instantly — no round trip per
/// keystroke, and no dependency on the home page having loaded first.
class GlobalMenuController extends ChangeNotifier {
  GlobalMenuController(this._client);

  final ApiClient _client;

  LoadState _state = LoadState.loading;
  List<MenuItem> _all = const [];
  ApiException? _error;
  bool _loadedOnce = false;

  LoadState get state => _state;
  List<MenuItem> get all => _all;
  ApiException? get error => _error;

  /// Every distinct category present in the loaded catalogue, ordered by
  /// the server's own popularity ordering (item count).
  List<String> get categories {
    final counts = <String, int>{};
    for (final item in _all) {
      if (!item.isAvailable) continue;
      counts[item.category] = (counts[item.category] ?? 0) + 1;
    }
    final entries = counts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });
    return [for (final e in entries) e.key];
  }

  Future<void> ensureLoaded() async {
    if (_loadedOnce) return;
    _loadedOnce = true;
    await load();
  }

  Future<void> load({bool refresh = false}) async {
    if (_state == LoadState.loading && !refresh) return;
    _state = LoadState.loading;
    _error = null;
    notifyListeners();
    try {
      final json = await _client.get(
        '/api/v1/menu',
        query: {'page': '1', 'page_size': '100'},
      );
      _all = Page.fromJson(json, MenuItem.fromJson).items;
      _state = _all.isEmpty ? LoadState.empty : LoadState.loaded;
    } on ApiException catch (e) {
      _error = e;
      _state = LoadState.error;
    }
    notifyListeners();
  }

  List<MenuItem> query({String search = '', String? category}) {
    var result = _all;
    if (category != null && category.isNotEmpty) {
      result =
          result.where((item) => item.category == category).toList(growable: false);
    }
    final needle = search.trim().toLowerCase();
    if (needle.isEmpty) return result;
    return result
        .where((item) =>
            item.name.toLowerCase().contains(needle) ||
            item.description.toLowerCase().contains(needle))
        .toList(growable: false);
  }
}
