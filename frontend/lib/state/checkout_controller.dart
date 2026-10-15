import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api_client.dart';
import '../core/api_exception.dart';
import '../core/idempotency.dart';
import '../models/order.dart';

/// The pending checkout submission: idempotency key + the exact request
/// body, persisted until the outcome is known. A timeout or network drop
/// can therefore only ever be retried with the **same key**, never re-keyed
/// (which could create a second order if the first one actually landed).
class PendingCheckout {
  const PendingCheckout({
    required this.idempotencyKey,
    required this.body,
    required this.createdAt,
  });

  final String idempotencyKey;
  final Map<String, dynamic> body;
  final String createdAt;

  Map<String, dynamic> toJson() => {
        'idempotency_key': idempotencyKey,
        'body': body,
        'created_at': createdAt,
      };

  factory PendingCheckout.fromJson(Map<String, dynamic> json) =>
      PendingCheckout(
        idempotencyKey: json['idempotency_key'] as String,
        body: jsonDecode(jsonEncode(json['body'])) as Map<String, dynamic>,
        createdAt: json['created_at'] as String? ?? '',
      );
}

enum CheckoutPhase {
  idle,
  submitting,
  /// Last attempt failed transiently; retry is offered with the same key.
  needsRetry,
}

class CheckoutController extends ChangeNotifier {
  static const prefsKey = 'quickbite.pending_checkout.v1';

  CheckoutController(this._client);

  final ApiClient _client;

  PendingCheckout? _pending;
  CheckoutPhase _phase = CheckoutPhase.idle;
  ApiException? _lastError;
  CheckoutAccepted? _lastAccepted;
  bool _restored = false;

  PendingCheckout? get pending => _pending;
  CheckoutPhase get phase => _phase;
  ApiException? get lastError => _lastError;
  CheckoutAccepted? get lastAccepted => _lastAccepted;
  bool get isSubmitting => _phase == CheckoutPhase.submitting;
  bool get needsRetry => _phase == CheckoutPhase.needsRetry;
  bool get hasPending => _pending != null;
  bool get restored => _restored;

  Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw != null) {
        _pending = PendingCheckout.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        _phase = CheckoutPhase.needsRetry;
      }
    } catch (_) {
      await _clearPendingPrefs();
      _pending = null;
    } finally {
      _restored = true;
      notifyListeners();
    }
  }

  /// Submit (or safely retry) a checkout.
  ///
  /// * While a request is active, further submissions are ignored
  ///   (the UI also disables the button).
  /// * If a pending attempt exists, its key **and exact body** are reused.
  /// * Transient failures (network/timeout/5xx) keep the pending attempt so
  ///   the user can retry with the same key.
  /// * Definitive rejections (409/422) clear it — retrying the identical
  ///   request cannot succeed and the user must change the cart instead.
  Future<CheckoutAccepted?> submit({
    required String restaurantId,
    required String deliveryAddress,
    required List<({String menuItemId, int quantity})> items,
  }) async {
    if (_phase == CheckoutPhase.submitting) return null;

    // Block repeat submissions immediately (even before persistence).
    _phase = CheckoutPhase.submitting;
    _lastError = null;
    _lastAccepted = null;
    notifyListeners();

    final pendingAttempt = _pending;
    final Map<String, dynamic> body;
    final String key;
    if (pendingAttempt != null) {
      body = pendingAttempt.body;
      key = pendingAttempt.idempotencyKey;
    } else {
      body = CheckoutRequest(
        restaurantId: restaurantId,
        deliveryAddress: deliveryAddress,
        items: items,
      ).toJson();
      key = generateIdempotencyKey();
      _pending = PendingCheckout(
        idempotencyKey: key,
        body: body,
        createdAt: DateTime.now().toUtc().toIso8601String(),
      );
      // Persist *before* the request goes out: even an app kill between
      // persist and response leaves the key recoverable for a safe retry.
      await _persistPending();
    }

    try {
      final json = await _client.post(
        '/api/v1/orders',
        body: body,
        idempotencyKey: key,
        requestTimeout: _client.checkoutTimeout,
      ) as Map<String, dynamic>;
      final accepted = CheckoutAccepted.fromJson(json);
      _lastAccepted = accepted;
      _phase = CheckoutPhase.idle;
      await _clearPending();
      notifyListeners();
      return accepted;
    } on ApiException catch (e) {
      _lastError = e;
      if (e.kind == ApiErrorKind.network ||
          e.kind == ApiErrorKind.timeout ||
          e.kind == ApiErrorKind.server ||
          e.kind == ApiErrorKind.authExpired) {
        // Outcome still unknown (or session must be restored first):
        // keep key + body so the retry is provably the same request.
        _phase = CheckoutPhase.needsRetry;
      } else {
        // validation / conflict: the same request can never succeed.
        await _clearPending();
        _phase = CheckoutPhase.idle;
      }
      notifyListeners();
      return null;
    } finally {
      if (_phase == CheckoutPhase.submitting) {
        _phase = CheckoutPhase.idle;
      }
      notifyListeners();
    }
  }

  /// Retry the persisted attempt (same key, same body).
  Future<CheckoutAccepted?> retry() {
    final pendingAttempt = _pending;
    if (pendingAttempt == null) return Future.value(null);
    final bodyMap = pendingAttempt.body;
    return submit(
      restaurantId: bodyMap['restaurant_id'] as String? ?? '',
      deliveryAddress: bodyMap['delivery_address'] as String? ?? '',
      items: [
        for (final raw in (bodyMap['items'] as List<dynamic>? ?? const []))
          (
            menuItemId: (raw as Map<String, dynamic>)['menu_item_id'] as String,
            quantity: (raw['quantity'] as num).toInt(),
          ),
      ],
    );
  }

  /// Discard an unconfirmed attempt. The UI warns that an order may already
  /// exist server-side if the original request landed.
  Future<void> discardPending() async {
    if (_phase == CheckoutPhase.submitting) return;
    await _clearPending();
    _lastError = null;
    _phase = CheckoutPhase.idle;
    notifyListeners();
  }

  Future<void> _persistPending() async {
    final attempt = _pending;
    if (attempt == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, jsonEncode(attempt.toJson()));
    } catch (_) {}
  }

  Future<void> _clearPending() async {
    _pending = null;
    await _clearPendingPrefs();
  }

  Future<void> _clearPendingPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefsKey);
    } catch (_) {}
  }
}
