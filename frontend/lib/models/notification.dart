/// A persisted, server-side notification row (PostgreSQL), served per order.
class AppNotification {
  const AppNotification({
    required this.id,
    required this.orderId,
    required this.eventType,
    required this.title,
    required this.body,
    required this.isRead,
    required this.createdAt,
  });

  final String id;
  final String? orderId;
  final String eventType;
  final String title;
  final String body;
  final bool isRead;
  final String createdAt;

  factory AppNotification.fromJson(Object? json) {
    final map = json as Map<String, dynamic>;
    return AppNotification(
      id: map['id'] as String? ?? '',
      orderId: map['order_id'] as String?,
      eventType: map['event_type'] as String? ?? '',
      title: map['title'] as String? ?? '',
      body: map['body'] as String? ?? '',
      isRead: map['is_read'] as bool? ?? false,
      createdAt: map['created_at'] as String? ?? '',
    );
  }
}
