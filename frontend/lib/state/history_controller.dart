import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/api_exception.dart';
import '../models/order.dart';
import '../models/page.dart';
import '../state/restaurants_controller.dart' show LoadState;

/// Paginated order history for the signed-in customer.
/// Refreshes independently of order-details polling.
class HistoryController extends ChangeNotifier {
  HistoryController(this._client, {this.pageSize = 10});

  final ApiClient _client;
  final int pageSize;

  LoadState _state = LoadState.loading;
  final List<OrderSummary> _items = [];
  ApiException? _error;
  int _page = 0;
  int _total = 0;
  bool _loadingMore = false;
  bool _refreshing = false;

  LoadState get state => _state;
  List<OrderSummary> get items => List.unmodifiable(_items);
  ApiException? get error => _error;
  int get total => _total;
  bool get hasMore => _items.length < _total;
  bool get loadingMore => _loadingMore;
  bool get refreshing => _refreshing;

  Future<void> load({bool refresh = false}) async {
    if (_loadingMore || _refreshing) return;
    if (refresh) {
      _refreshing = true;
    } else if (_state != LoadState.error && _items.isNotEmpty) {
      return; // already loaded; refresh explicitly to update
    } else {
      _state = LoadState.loading;
    }
    _error = null;
    notifyListeners();
    try {
      final json = await _client.get(
        '/api/v1/orders',
        query: {'page': '1', 'page_size': '$pageSize'},
      );
      final page = Page.fromJson(json, OrderSummary.fromJson);
      _items
        ..clear()
        ..addAll(page.items);
      _page = page.page;
      _total = page.total;
      _state = page.isEmpty ? LoadState.empty : LoadState.loaded;
    } on ApiException catch (e) {
      _error = e;
      _state = LoadState.error;
    } finally {
      _refreshing = false;
      notifyListeners();
    }
  }

  Future<void> loadMore() async {
    if (_loadingMore || !hasMore) return;
    _loadingMore = true;
    _error = null;
    notifyListeners();
    try {
      final json = await _client.get(
        '/api/v1/orders',
        query: {'page': '${_page + 1}', 'page_size': '$pageSize'},
      );
      final page = Page.fromJson(json, OrderSummary.fromJson);
      _items.addAll(page.items);
      _page = page.page;
      _total = page.total;
      _state = _items.isEmpty ? LoadState.empty : LoadState.loaded;
    } on ApiException catch (e) {
      // Keep already-loaded pages visible; surface the error as a footer.
      _error = e;
    } finally {
      _loadingMore = false;
      notifyListeners();
    }
  }
}
