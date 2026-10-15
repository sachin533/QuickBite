/// Money formatting for integer minor units (1250 == INR 12.50).
///
/// The API never sends floats for money; every amount is an int in minor
/// units plus an ISO currency code.
const Map<String, String> _symbols = {
  'INR': '₹',
  'USD': '\$',
  'EUR': '€',
  'GBP': '£',
};

String _group(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// Formats [minor] as e.g. `₹1,250.00` for currency `INR`.
String formatMoney(int minor, String currency) {
  final symbol = _symbols[currency] ?? '$currency ';
  final negative = minor < 0;
  final abs = minor.abs();
  final major = abs ~/ 100;
  final cents = (abs % 100).toString().padLeft(2, '0');
  return '${negative ? '-' : ''}$symbol${_group(major)}.$cents';
}
