import 'package:flutter_test/flutter_test.dart';
import 'package:quickbite/models/menu_item.dart';
import 'package:quickbite/models/restaurant.dart';
import 'package:quickbite/state/cart_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const restaurant = Restaurant(
    id: 'rest_1',
    name: 'Spice Route',
    description: 'Indian',
    cuisine: 'Indian',
    currency: 'INR',
    isOpen: true,
    rating: 4,
    etaMinutes: 25,
  );

  const biryani = MenuItem(
    id: 'item_biryani',
    restaurantId: 'rest_1',
    name: 'Chicken Biryani',
    description: '',
    category: 'Mains',
    priceMinor: 1250,
    currency: 'INR',
    isAvailable: true,
  );

  const lassi = MenuItem(
    id: 'item_lassi',
    restaurantId: 'rest_1',
    name: 'Sweet Lassi',
    description: '',
    category: 'Drinks',
    priceMinor: 400,
    currency: 'INR',
    isAvailable: true,
  );

  const otherRestaurantItem = MenuItem(
    id: 'item_pizza',
    restaurantId: 'rest_2',
    name: 'Margherita',
    description: '',
    category: 'Mains',
    priceMinor: 900,
    currency: 'INR',
    isAvailable: true,
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('add, quantity, removal, subtotal', () {
    final cart = CartController();
    expect(cart.add(biryani, fromRestaurant: restaurant),
        CartAddResult.added);
    expect(cart.add(biryani, fromRestaurant: restaurant),
        CartAddResult.added);
    expect(cart.quantityOf(biryani.id), 2);
    expect(cart.add(lassi, fromRestaurant: restaurant),
        CartAddResult.added);
    expect(cart.distinctCount, 2);
    expect(cart.subtotalMinor, 1250 * 2 + 400);

    cart.setQuantity(biryani.id, 5);
    expect(cart.subtotalMinor, 1250 * 5 + 400);

    cart.remove(lassi.id);
    expect(cart.distinctCount, 1);

    cart.setQuantity(biryani.id, 0);
    expect(cart.isEmpty, isTrue);
    expect(cart.restaurant, isNull);
  });

  test('quantity is clamped to 1..20', () {
    final cart = CartController();
    cart.add(biryani, fromRestaurant: restaurant);
    cart.setQuantity(biryani.id, 999);
    expect(cart.quantityOf(biryani.id), 20);
    expect(cart.add(biryani), CartAddResult.quantityLimit);
    cart.setQuantity(biryani.id, -5);
    expect(cart.isEmpty, isTrue);
  });

  test('items from another restaurant are rejected while cart is active',
      () {
    final cart = CartController();
    cart.add(biryani, fromRestaurant: restaurant);
    expect(cart.add(otherRestaurantItem),
        CartAddResult.differentRestaurant);
    expect(cart.contains(otherRestaurantItem.id), isFalse);

    // Explicit "start a new cart" replaces contents.
    cart.replaceWith(otherRestaurantItem, const Restaurant(
      id: 'rest_2',
      name: 'Napoli Pizza',
      description: '',
      cuisine: 'Italian',
      currency: 'INR',
      isOpen: true,
      rating: 4,
      etaMinutes: 30,
    ));
    expect(cart.restaurant!.id, 'rest_2');
    expect(cart.distinctCount, 1);
  });

  test('unavailable items cannot be added', () {
    const soldOut = MenuItem(
      id: 'item_x',
      restaurantId: 'rest_1',
      name: 'Sold out',
      description: '',
      category: 'Mains',
      priceMinor: 100,
      currency: 'INR',
      isAvailable: false,
    );
    final cart = CartController();
    expect(cart.add(soldOut, fromRestaurant: restaurant),
        CartAddResult.unavailable);
  });

  test('cart draft (contents + address) is persisted and restored',
      () async {
    final cart = CartController();
    cart.add(biryani, fromRestaurant: restaurant);
    cart.add(lassi, fromRestaurant: restaurant);
    cart.setDeliveryAddress('12 Lake Road, Bengaluru');
    await Future<void>.delayed(Duration.zero);

    final restored = CartController();
    await restored.restore();
    expect(restored.restored, isTrue);
    expect(restored.restaurant!.id, 'rest_1');
    expect(restored.quantityOf(biryani.id), 1);
    expect(restored.quantityOf(lassi.id), 1);
    expect(restored.deliveryAddress, '12 Lake Road, Bengaluru');
    expect(restored.subtotalMinor, 1250 + 400);
  });
}
