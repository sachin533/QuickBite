import 'order.dart';

/// GET /api/v1/admin/orders row: an order summary plus the customer email.
class AdminOrder extends OrderSummary {
  const AdminOrder({
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
    required this.customerEmail,
  });

  final String? customerEmail;

  factory AdminOrder.fromJson(Object? json) {
    final summary = OrderSummary.fromJson(json);
    final map = json as Map<String, dynamic>;
    return AdminOrder(
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
      customerEmail: map['customer_email'] as String?,
    );
  }
}

/// GET /api/v1/admin/summary — read-only operational overview.
class AdminSummary {
  const AdminSummary({
    required this.ordersByStatus,
    required this.totalOrders,
    required this.pendingOutbox,
    required this.pendingRetries,
    required this.openQuarantine,
  });

  final Map<String, int> ordersByStatus;
  final int totalOrders;
  final int pendingOutbox;
  final int pendingRetries;
  final int openQuarantine;

  factory AdminSummary.fromJson(Map<String, dynamic> json) {
    final raw = json['orders_by_status'] as Map<String, dynamic>? ?? const {};
    return AdminSummary(
      ordersByStatus: {
        for (final entry in raw.entries)
          entry.key: (entry.value as num).toInt(),
      },
      totalOrders: (json['total_orders'] as num?)?.toInt() ?? 0,
      pendingOutbox: (json['pending_outbox'] as num?)?.toInt() ?? 0,
      pendingRetries: (json['pending_retries'] as num?)?.toInt() ?? 0,
      openQuarantine: (json['open_quarantine'] as num?)?.toInt() ?? 0,
    );
  }
}
