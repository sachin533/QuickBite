import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/api_exception.dart';
import '../models/menu_item.dart';
import '../models/page.dart';
import '../models/restaurant.dart';

/// Explicit async states shared by the browsing screens.
enum LoadState { idle, loading, loaded, empty, error }

class RestaurantsController extends ChangeNotifier {
  RestaurantsController(this._client);

  final ApiClient _client;

  LoadState _state = LoadState.idle;
  List<Restaurant> _items = const [];
  ApiException? _error;
  bool _refreshing = false;

  LoadState get state => _state;
  List<Restaurant> get items => _items;
  ApiException? get error => _error;
  bool get refreshing => _refreshing;

  bool _loadedOnce = false;

  /// Idempotent first load (safe to call from any screen mount).
  Future<void> ensureLoaded() async {
    if (_loadedOnce) return;
    _loadedOnce = true;
    await load();
  }

  Future<void> load({bool refresh = false}) async {
    if (_state == LoadState.loading && !refresh) return;
    _refreshing = refresh;
    if (!refresh) _state = LoadState.loading;
    _error = null;
    notifyListeners();
    try {
      final json = await _client.get(
        '/api/v1/restaurants',
        query: {'page': '1', 'page_size': '50'},
      );
      final page = Page.fromJson(json, Restaurant.fromJson);
      _items = page.items;
      _state = page.isEmpty ? LoadState.empty : LoadState.loaded;
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.authExpired) {
        // ApiClient already signalled the session; keep the error visible.
      }
      _error = e;
      _state = LoadState.error;
    } finally {
      _refreshing = false;
      notifyListeners();
    }
  }
}

class RestaurantMenuController extends ChangeNotifier {
  RestaurantMenuController(this._client);

  final ApiClient _client;

  LoadState _state = LoadState.loading;
  String? _restaurantId;
  List<MenuItem> _items = const [];
  ApiException? _error;

  LoadState get state => _state;
  String? get restaurantId => _restaurantId;
  List<MenuItem> get items => _items;
  ApiException? get error => _error;

  Future<void> load(String restaurantId) async {
    _restaurantId = restaurantId;
    _state = LoadState.loading;
    _error = null;
    notifyListeners();
    try {
      final json = await _client.get(
        '/api/v1/restaurants/$restaurantId/menu',
        query: {'page': '1', 'page_size': '100'},
      );
      final page = Page.fromJson(json, MenuItem.fromJson);
      _items = page.items;
      _state = page.isEmpty ? LoadState.empty : LoadState.loaded;
    } on ApiException catch (e) {
      _error = e;
      _state = LoadState.error;
    }
    notifyListeners();
  }
}
