import 'package:flutter_test/flutter_test.dart';
import 'package:quickbite/core/money.dart';

void main() {
  group('formatMoney (integer minor units)', () {
    test('formats INR with symbol, grouping, and 2 decimals', () {
      expect(formatMoney(1250, 'INR'), '₹12.50');
      expect(formatMoney(0, 'INR'), '₹0.00');
      expect(formatMoney(5, 'INR'), '₹0.05');
      expect(formatMoney(100000, 'INR'), '₹1,000.00');
      expect(formatMoney(123456789, 'INR'), '₹1,234,567.89');
    });

    test('supports other currencies and negatives', () {
      expect(formatMoney(1250, 'USD'), r'$12.50');
      expect(formatMoney(-250, 'INR'), '-₹2.50');
      expect(formatMoney(99, 'XYZ'), 'XYZ 0.99');
    });
  });
}
