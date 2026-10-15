/// Order states and the terminal/success rules of the domain state machine.
///
/// PENDING -> PAID -> CONFIRMED -> DRIVER_ASSIGNED
/// PENDING -> PAYMENT_FAILED, PAID/CONFIRMED -> FAILED
const List<String> kOrderStatuses = [
  'PENDING',
  'PAID',
  'CONFIRMED',
  'DRIVER_ASSIGNED',
  'PAYMENT_FAILED',
  'FAILED',
];

/// DRIVER_ASSIGNED is successful completion; the two failures are terminal.
const Set<String> kTerminalStatuses = {'DRIVER_ASSIGNED', 'PAYMENT_FAILED', 'FAILED'};

bool isTerminalStatus(String status) => kTerminalStatuses.contains(status);

/// Human labels for status chips.
String statusLabel(String status) {
  switch (status) {
    case 'PENDING':
      return 'Pending';
    case 'PAID':
      return 'Paid';
    case 'CONFIRMED':
      return 'Confirmed';
    case 'DRIVER_ASSIGNED':
      return 'Driver assigned';
    case 'PAYMENT_FAILED':
      return 'Payment failed';
    case 'FAILED':
      return 'Failed';
    default:
      return status;
  }
}

/// Maps the stored `failure_code` to a readable explanation.
///
/// Payment, restaurant, delivery, and notification failures are distinct:
/// a notification problem never claims the payment failed.
String failureExplanation(String? code) {
  switch (code) {
    case null || '':
      return 'This order could not be completed.';
    case 'PAYMENT_DECLINED':
    case 'PAYMENT_ALWAYS_FAILING':
      return 'The payment was declined by the payment simulator after all '
          'retry attempts. No charge was completed for this order.';
    case 'RESTAURANT_UNAVAILABLE':
    case 'RESTAURANT_REJECTED':
      return "The restaurant couldn't confirm this order after all retry "
          'attempts, so it was cancelled.';
    case 'DELIVERY_UNAVAILABLE':
    case 'DRIVER_UNAVAILABLE':
      return 'No driver could be assigned after all retry attempts, so the '
          'order was cancelled.';
    default:
      return 'The order failed ($code). See the timeline and notifications '
          'for details.';
  }
}

// --- checkout ---------------------------------------------------------------

/// POST /api/v1/orders request. Only ids, quantity, and address — never
/// prices, customer ids, or totals (the server computes those).
class CheckoutRequest {
  const CheckoutRequest({
    required this.restaurantId,
    required this.deliveryAddress,
    required this.items,
  });

  final String restaurantId;
  final String deliveryAddress;
  final List<({String menuItemId, int quantity})> items;

  Map<String, dynamic> toJson() => {
        'restaurant_id': restaurantId,
        'delivery_address': deliveryAddress,
        'items': [
          for (final line in items)
            {'menu_item_id': line.menuItemId, 'quantity': line.quantity},
        ],
      };
}

/// 202 body — also the replayed body for an idempotent retry.
class CheckoutAccepted {
  const CheckoutAccepted({
    required this.orderId,
    required this.status,
    required this.currency,
    required this.totalAmountMinor,
    required this.version,
    required this.message,
  });

  final String orderId;
  final String status;
  final String currency;
  final int totalAmountMinor;
  final int version;
  final String message;

  factory CheckoutAccepted.fromJson(Map<String, dynamic> json) =>
      CheckoutAccepted(
        orderId: json['order_id'] as String,
        status: json['status'] as String? ?? 'PENDING',
        currency: json['currency'] as String? ?? 'INR',
        totalAmountMinor: (json['total_amount_minor'] as num).toInt(),
        version: (json['version'] as num?)?.toInt() ?? 1,
        message: json['message'] as String? ??
            'Order accepted for asynchronous processing.',
      );
}

// --- order reads ------------------------------------------------------------

class OrderSummary {
  const OrderSummary({
    required this.id,
    required this.restaurantId,
    required this.restaurantName,
    required this.status,
    required this.currency,
    required this.totalAmountMinor,
    required this.version,
    required this.failureCode,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String restaurantId;
  final String? restaurantName;
  final String status;
  final String currency;
  final int totalAmountMinor;
  final int version;
  final String? failureCode;
  final String createdAt;
  final String updatedAt;

  bool get isTerminal => isTerminalStatus(status);

  factory OrderSummary.fromJson(Object? json) {
    final map = json as Map<String, dynamic>;
    return OrderSummary(
      id: map['id'] as String,
      restaurantId: map['restaurant_id'] as String? ?? '',
      restaurantName: map['restaurant_name'] as String?,
      status: map['status'] as String? ?? 'PENDING',
      currency: map['currency'] as String? ?? 'INR',
      totalAmountMinor: (map['total_amount_minor'] as num).toInt(),
      version: (map['version'] as num?)?.toInt() ?? 1,
      failureCode: map['failure_code'] as String?,
      createdAt: map['created_at'] as String? ?? '',
      updatedAt: map['updated_at'] as String? ?? '',
    );
  }
}

class OrderItemLine {
  const OrderItemLine({
    required this.menuItemId,
    required this.itemName,
    required this.quantity,
    required this.unitPriceMinor,
    required this.lineTotalMinor,
  });

  final String menuItemId;
  final String itemName;
  final int quantity;
  final int unitPriceMinor;
  final int lineTotalMinor;

  factory OrderItemLine.fromJson(Object? json) {
    final map = json as Map<String, dynamic>;
    return OrderItemLine(
      menuItemId: map['menu_item_id'] as String? ?? '',
      itemName: map['item_name'] as String? ?? '',
      quantity: (map['quantity'] as num?)?.toInt() ?? 0,
      unitPriceMinor: (map['unit_price_minor'] as num?)?.toInt() ?? 0,
      lineTotalMinor: (map['line_total_minor'] as num?)?.toInt() ?? 0,
    );
  }
}

class OrderDetail extends OrderSummary {
  const OrderDetail({
    required super.id,
    required super.restaurantId,
    required super.restaurantName,
    required super.status,
    required super.currency,
    required super.totalAmountMinor,
    required super.version,
    required super.failureCode,
    required super.createdAt,
    required super.updatedAt,
    required this.customerId,
    required this.deliveryAddress,
    required this.driverId,
    required this.items,
    required this.correlationId,
  });

  final String customerId;
  final String deliveryAddress;
  final String? driverId;
  final List<OrderItemLine> items;
  final String? correlationId;

  factory OrderDetail.fromJson(Object? json) {
    final map = json as Map<String, dynamic>;
    final summary = OrderSummary.fromJson(json);
    return OrderDetail(
      id: summary.id,
      restaurantId: summary.restaurantId,
      restaurantName: summary.restaurantName,
      status: summary.status,
      currency: summary.currency,
      totalAmountMinor: summary.totalAmountMinor,
      version: summary.version,
      failureCode: summary.failureCode,
      createdAt: summary.createdAt,
      updatedAt: summary.updatedAt,
      customerId: map['customer_id'] as String? ?? '',
      deliveryAddress: map['delivery_address'] as String? ?? '',
      driverId: map['driver_id'] as String?,
      correlationId: map['correlation_id'] as String?,
      items: [
        for (final raw in (map['items'] as List<dynamic>? ?? const []))
          OrderItemLine.fromJson(raw),
      ],
    );
  }
}

/// One append-only transition row of the order timeline.
class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.fromStatus,
    required this.toStatus,
    required this.version,
    required this.source,
    required this.reason,
    required this.createdAt,
  });

  final String id;
  final String? fromStatus;
  final String toStatus;
  final int version;
  final String source;
  final String? reason;
  final String createdAt;

  factory HistoryEntry.fromJson(Object? json) {
    final map = json as Map<String, dynamic>;
    return HistoryEntry(
      id: map['id'] as String? ?? '',
      fromStatus: map['from_status'] as String?,
      toStatus: map['to_status'] as String? ?? '',
      version: (map['version'] as num?)?.toInt() ?? 0,
      source: map['source'] as String? ?? '',
      reason: map['reason'] as String?,
      createdAt: map['created_at'] as String? ?? '',
    );
  }
}
