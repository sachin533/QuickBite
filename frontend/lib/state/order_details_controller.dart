import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/api_exception.dart';
import '../models/order.dart';
import '../models/page.dart';
import '../state/restaurants_controller.dart' show LoadState;
import '../models/notification.dart';

/// Order-details state with ~2s polling while the screen is visible.
///
/// * Polls only while subscribed and the status is non-terminal.
/// * Stops when the screen is disposed, the app is backgrounded, or a
///   terminal status is reached.
/// * Backs off exponentially after consecutive failures (2s → 4s → 8s …
///   capped at [maxBackoff]) and resets on success.
/// * A 401 stops polling and signals the app to end the session.
class OrderDetailsController extends ChangeNotifier {
  OrderDetailsController(
    this._client, {
    this.pollInterval = const Duration(seconds: 2),
    this.maxBackoff = const Duration(seconds: 30),
    this.onAuthExpired,
  });

  final ApiClient _client;
  final Duration pollInterval;
  final Duration maxBackoff;
  final void Function()? onAuthExpired;

  String? _orderId;
  LoadState _state = LoadState.loading;
  OrderDetail? _order;
  List<HistoryEntry> _history = const [];
  List<AppNotification> _notifications = const [];
  ApiException? _error;
  String? _offlineReason;

  Timer? _timer;
  int _consecutiveFailures = 0;
  int _tickCount = 0;
  bool _polling = false;
  bool _disposed = false;

  String? get orderId => _orderId;
  LoadState get state => _state;
  OrderDetail? get order => _order;
  List<HistoryEntry> get history => _history;
  List<AppNotification> get notifications => _notifications;
  ApiException? get error => _error;
  bool get polling => _polling;
  String? get offlineReason => _offlineReason;
  bool get isTerminal =>
      _order != null && isTerminalStatus(_order!.status);

  /// First full load: order + timeline + notifications.
  Future<void> open(String orderId) async {
    _orderId = orderId;
    _state = LoadState.loading;
    _error = null;
    notifyListeners();
    try {
      await _fetchOrder();
      await _fetchSideData(force: true);
      _state = LoadState.loaded;
    } on ApiException catch (e) {
      _error = e;
      _state = LoadState.error;
    }
    if (!_disposed) notifyListeners();
    startPolling();
  }

  Future<void> reload() async {
    if (_orderId == null) return;
    _error = null;
    try {
      await _fetchOrder();
      await _fetchSideData(force: true);
      _state = LoadState.loaded;
      _consecutiveFailures = 0;
      _offlineReason = null;
    } on ApiException catch (e) {
      if (_state != LoadState.loaded) {
        _error = e;
        _state = LoadState.error;
      } else {
        _offlineReason = e.userMessage;
      }
    }
    if (!_disposed) notifyListeners();
    startPolling();
  }

  // --- polling -------------------------------------------------------------

  void startPolling() {
    if (_disposed || _orderId == null || _order == null) return;
    if (isTerminal) return; // terminal → stop for good
    _polling = true;
    _scheduleNext(pollInterval);
    notifyListeners();
  }

  void stopPolling() {
    _timer?.cancel();
    _timer = null;
    if (_polling) {
      _polling = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// App lifecycle hooks (screen is an observer).
  Future<void> onAppPaused() async => stopPolling();

  Future<void> onAppResumed() async {
    if (_disposed) return;
    await reload(); // refresh immediately on resume
    startPolling();
  }

  void _scheduleNext(Duration delay) {
    _timer?.cancel();
    if (_disposed || isTerminal) return;
    _timer = Timer(delay, _tick);
  }

  Future<void> _tick() async {
    if (_disposed) return;
    _tickCount++;
    try {
      await _fetchOrder();
      _consecutiveFailures = 0;
      _offlineReason = null;
      await _fetchSideData(force: _tickCount % 3 == 0);
      if (isTerminal) {
        stopPolling();
        return;
      }
      _scheduleNext(pollInterval);
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.authExpired) {
        stopPolling();
        onAuthExpired?.call();
        _offlineReason = e.userMessage;
        notifyListeners();
        return;
      }
      _consecutiveFailures++;
      // Exponential backoff, capped; polling continues while visible.
      final multiplier =
          1 << _consecutiveFailures.clamp(1, 5); // 2,4,8,16,32
      var delayMs = pollInterval.inMilliseconds * multiplier;
      if (delayMs > maxBackoff.inMilliseconds) {
        delayMs = maxBackoff.inMilliseconds;
      }
      _offlineReason = e.userMessage;
      _scheduleNext(Duration(milliseconds: delayMs));
      notifyListeners();
    }
  }

  // --- fetching ------------------------------------------------------------

  Future<void> _fetchOrder() async {
    final json = await _client.get('/api/v1/orders/$_orderId');
    _order = OrderDetail.fromJson(json);
    if (!_disposed) notifyListeners();
  }

  Future<void> _fetchSideData({bool force = false}) async {
    // History only changes when the version does; refresh on version bump
    // or on every third tick (notifications arrive on every relevant event).
    final needsHistory = force ||
        _history.isEmpty ||
        (_order != null && _history.last.version != _order!.version);
    if (needsHistory) {
      final json = await _client.get(
        '/api/v1/orders/$_orderId/history',
        query: {'page': '1', 'page_size': '100'},
      );
      _history = Page.fromJson(json, HistoryEntry.fromJson).items;
    }
    if (force || _tickCount % 3 == 0) {
      final json = await _client.get(
        '/api/v1/orders/$_orderId/notifications',
        query: {'page': '1', 'page_size': '100'},
      );
      _notifications = Page.fromJson(json, AppNotification.fromJson).items;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
