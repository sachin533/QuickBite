import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/menu_item.dart';
import '../models/restaurant.dart';

/// A cart line holds the menu snapshot displayed to the user; the server
/// re-derives authoritative prices from its own menu at checkout.
class CartLine {
  CartLine({required this.item, required this.quantity});

  final MenuItem item;
  int quantity;

  int get lineTotalMinor => item.priceMinor * quantity;
}

enum CartAddResult {
  added,
  differentRestaurant,
  quantityLimit,
  itemLimit,
  unavailable,
}

/// Single-restaurant cart with a locally persisted draft
/// (shared_preferences: web localStorage, Android/iOS prefs).
class CartController extends ChangeNotifier {
  static const prefsKey = 'quickbite.cart.v1';

  Restaurant? _restaurant;
  final Map<String, CartLine> _lines = {};
  String _deliveryAddress = '';
  bool _restored = false;

  Restaurant? get restaurant => _restaurant;
  String get deliveryAddress => _deliveryAddress;
  bool get restored => _restored;
  bool get isEmpty => _lines.isEmpty;
  int get distinctCount => _lines.length;
  int get totalQuantity =>
      _lines.values.fold(0, (sum, line) => sum + line.quantity);

  /// Display subtotal only — the server computes the accepted total.
  int get subtotalMinor =>
      _lines.values.fold(0, (sum, line) => sum + line.lineTotalMinor);

  String get currency => _restaurant?.currency ?? 'INR';

  List<CartLine> get lines {
    final list = _lines.values.toList()
      ..sort((a, b) => a.item.name.compareTo(b.item.name));
    return list;
  }

  int quantityOf(String menuItemId) => _lines[menuItemId]?.quantity ?? 0;

  bool contains(String menuItemId) => _lines.containsKey(menuItemId);

  /// Restore the local draft (cart contents + address) if one exists.
  Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw != null) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        final restJson = decoded['restaurant'];
        if (restJson is Map<String, dynamic>) {
          _restaurant = Restaurant.fromJson(restJson);
        }
        _deliveryAddress = decoded['address'] as String? ?? '';
        for (final rawLine
            in (decoded['lines'] as List<dynamic>? ?? const [])) {
          final line = rawLine as Map<String, dynamic>;
          final item = MenuItem.fromJson(line['item']);
          final quantity = (line['quantity'] as num?)?.toInt() ?? 1;
          if (quantity >= 1) {
            _lines[item.id] = CartLine(item: item, quantity: quantity);
          }
        }
      }
    } catch (_) {
      // A corrupt draft is discarded rather than crashing the app.
      await _clearPrefs();
    } finally {
      _restored = true;
      notifyListeners();
    }
  }

  CartAddResult add(MenuItem item, {Restaurant? fromRestaurant}) {
    if (!item.isAvailable) return CartAddResult.unavailable;
    if (_lines.isEmpty) {
      // New cart: remember the restaurant. Fallback keeps deep-linked menus
      // (restaurant list not loaded yet) checkout-capable.
      _restaurant = fromRestaurant ??
          _restaurant ??
          Restaurant(
            id: item.restaurantId,
            name: item.restaurantId,
            description: '',
            cuisine: '',
            currency: item.currency,
            isOpen: true,
            rating: 3,
            etaMinutes: 0,
          );
    }
    final existing = _lines[item.id];
    if (existing != null) {
      if (existing.quantity >= 20) return CartAddResult.quantityLimit;
      existing.quantity += 1;
      _persist();
      notifyListeners();
      return CartAddResult.added;
    }
    if (item.restaurantId != (_restaurant?.id ?? item.restaurantId)) {
      return CartAddResult.differentRestaurant;
    }
    if (_lines.length >= 20) return CartAddResult.itemLimit;
    _lines[item.id] = CartLine(item: item, quantity: 1);
    _persist();
    notifyListeners();
    return CartAddResult.added;
  }

  /// Used by the "start a new cart" flow after a different-restaurant add.
  void replaceWith(MenuItem item, Restaurant restaurant) {
    _lines.clear();
    _restaurant = restaurant;
    _lines[item.id] = CartLine(item: item, quantity: 1);
    _persist();
    notifyListeners();
  }

  /// Sets quantity in 1..20; 0 removes the line.
  void setQuantity(String menuItemId, int quantity) {
    final line = _lines[menuItemId];
    if (line == null) return;
    if (quantity <= 0) {
      _lines.remove(menuItemId);
    } else {
      line.quantity = quantity.clamp(1, 20);
    }
    if (_lines.isEmpty) _restaurant = null;
    _persist();
    notifyListeners();
  }

  void remove(String menuItemId) {
    _lines.remove(menuItemId);
    if (_lines.isEmpty) _restaurant = null;
    _persist();
    notifyListeners();
  }

  void setDeliveryAddress(String value) {
    _deliveryAddress = value;
    _persist();
    notifyListeners();
  }

  void clear() {
    _lines.clear();
    _restaurant = null;
    _deliveryAddress = '';
    _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_lines.isEmpty) {
        await prefs.remove(prefsKey);
        return;
      }
      await prefs.setString(
        prefsKey,
        jsonEncode({
          'restaurant': _restaurant == null
              ? null
              : {
                  'id': _restaurant!.id,
                  'name': _restaurant!.name,
                  'description': _restaurant!.description,
                  'cuisine': _restaurant!.cuisine,
                  'currency': _restaurant!.currency,
                  'image_url': _restaurant!.imageUrl,
                  'is_open': _restaurant!.isOpen,
                  'rating': _restaurant!.rating,
                  'eta_minutes': _restaurant!.etaMinutes,
                },
          'address': _deliveryAddress,
          'lines': [
            for (final line in _lines.values)
              {'item': line.item.toJson(), 'quantity': line.quantity},
          ],
        }),
      );
    } catch (_) {
      // Best effort; the in-memory cart still works.
    }
  }

  Future<void> _clearPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefsKey);
    } catch (_) {}
  }
}
