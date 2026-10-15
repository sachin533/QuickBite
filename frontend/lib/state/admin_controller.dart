import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/api_exception.dart';
import '../models/admin.dart';
import '../models/page.dart';
import '../state/restaurants_controller.dart' show LoadState;

/// Read-only admin overview: aggregate summary + cross-customer orders with
/// a status filter and pagination.
class AdminController extends ChangeNotifier {
  AdminController(this._client, {this.pageSize = 20});

  final ApiClient _client;
  final int pageSize;

  LoadState _state = LoadState.loading;
  AdminSummary? _summary;
  final List<AdminOrder> _items = [];
  ApiException? _error;
  String? _statusFilter; // null == All
  int _page = 1;
  int _total = 0;
  bool _loadingMore = false;

  LoadState get state => _state;
  AdminSummary? get summary => _summary;
  List<AdminOrder> get items => List.unmodifiable(_items);
  ApiException? get error => _error;
  String? get statusFilter => _statusFilter;
  int get total => _total;
  bool get hasMore => _items.length < _total;
  bool get loadingMore => _loadingMore;

  Future<void> load({bool refresh = false}) async {
    if (_loadingMore) return;
    if (!refresh && _state != LoadState.error && _items.isNotEmpty) return;
    if (_items.isEmpty) _state = LoadState.loading;
    _error = null;
    notifyListeners();
    try {
      final query = <String, String>{
        'page': '1',
        'page_size': '$pageSize',
      };
      final filter = _statusFilter;
      if (filter != null) query['status'] = filter;
      final futures = <Future<dynamic>>[
        _client.get('/api/v1/admin/summary'),
        _client.get('/api/v1/admin/orders', query: query),
      ];
      final results = await Future.wait(futures);
      _summary = AdminSummary.fromJson(results[0] as Map<String, dynamic>);
      final page =
          Page.fromJson(results[1], AdminOrder.fromJson);
      _items
        ..clear()
        ..addAll(page.items);
      _page = page.page;
      _total = page.total;
      _state = page.isEmpty ? LoadState.empty : LoadState.loaded;
    } on ApiException catch (e) {
      _error = e;
      _state = LoadState.error;
    }
    notifyListeners();
  }

  Future<void> setStatusFilter(String? status) async {
    if (_statusFilter == status) return;
    _statusFilter = status;
    _items.clear();
    _total = 0;
    _page = 1;
    notifyListeners();
    await load(refresh: true);
  }

  Future<void> loadMore() async {
    if (_loadingMore || !hasMore) return;
    _loadingMore = true;
    notifyListeners();
    try {
      final query = <String, String>{
        'page': '${_page + 1}',
        'page_size': '$pageSize',
      };
      final filter = _statusFilter;
      if (filter != null) query['status'] = filter;
      final json = await _client.get(
        '/api/v1/admin/orders',
        query: query,
      );
      final page = Page.fromJson(json, AdminOrder.fromJson);
      _items.addAll(page.items);
      _page = page.page;
      _total = page.total;
    } on ApiException catch (e) {
      _error = e;
    } finally {
      _loadingMore = false;
      notifyListeners();
    }
  }
}
