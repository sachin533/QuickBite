import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/money.dart';
import '../models/notification.dart';
import '../models/order.dart';
import '../state/auth_controller.dart';
import '../state/order_details_controller.dart';
import '../widgets/state_views.dart';
import '../widgets/status_chip.dart';

/// Order details:
///   * acknowledgement card right after a 202 acceptance (`?ack=1`),
///   * status + version + driver + items + delivery address,
///   * append-only timeline, persisted notifications,
///   * readable failure explanation (payment vs restaurant vs delivery —
///     notification failures never claim a payment failure),
///   * ~2s polling while visible, stopped when terminal/backgrounded,
///   * backoff + offline notice while the network is down.
class OrderDetailsScreen extends StatefulWidget {
  const OrderDetailsScreen({
    super.key,
    required this.orderId,
    this.justAccepted = false,
  });

  final String orderId;
  final bool justAccepted;

  @override
  State<OrderDetailsScreen> createState() => _OrderDetailsScreenState();
}

class _OrderDetailsScreenState extends State<OrderDetailsScreen>
    with WidgetsBindingObserver {
  late final OrderDetailsController _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = OrderDetailsController(
      context.read<ApiClient>(),
      onAuthExpired: context.read<AuthController>().sessionExpiredNow,
    )..open(widget.orderId);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _controller.onAppResumed();
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _controller.onAppPaused();
    }
  }

  Future<void> _manualRefresh() => _controller.reload();

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<OrderDetailsController>.value(
      value: _controller,
      child: Builder(
        builder: (context) {
          final controller = context.watch<OrderDetailsController>();
          final theme = Theme.of(context);

          return Scaffold(
            appBar: AppBar(
              title: Text('Order ${widget.orderId}'),
              actions: [
                if (controller.order != null &&
                    !controller.isTerminal) ...[
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Semantics(
                        label: controller.polling
                            ? 'Live updates on, every 2 seconds'
                            : 'Live updates paused',
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              controller.polling
                                  ? Icons.wifi_tethering
                                  : Icons.pause_circle_outline,
                              size: 16,
                              color: controller.polling
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.outline,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              controller.polling ? 'Live' : 'Paused',
                              style: theme.textTheme.labelSmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                Semantics(
                  label: 'Refresh order',
                  button: true,
                  child: IconButton(
                    tooltip: 'Refresh',
                    onPressed: _manualRefresh,
                    icon: const Icon(Icons.refresh),
                  ),
                ),
              ],
            ),
            body: StateView(
              state: controller.state,
              error: controller.error,
              onRetry: () => controller.reload(),
              emptyIcon: Icons.receipt_long_outlined,
              emptyMessage: 'Order not found.',
              loadingLabel: 'Loading order…',
              builder: (context) => _OrderBody(
                controller: controller,
                justAccepted: widget.justAccepted,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _OrderBody extends StatelessWidget {
  const _OrderBody({required this.controller, required this.justAccepted});

  final OrderDetailsController controller;
  final bool justAccepted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final order = controller.order;
    if (order == null) {
      return const LoadingView(label: 'Loading order…');
    }

    final terminal = isTerminalStatus(order.status);
    final failed =
        order.status == 'PAYMENT_FAILED' || order.status == 'FAILED';

    return RefreshIndicator(
      onRefresh: controller.reload,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;

          final statusCard = _StatusCard(
            order: order,
            justAccepted: justAccepted,
            controller: controller,
          );
          final detailsColumn = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (failed) ...[
                _FailureCard(order: order),
                const SizedBox(height: 12),
              ],
              _ItemsCard(order: order),
              const SizedBox(height: 12),
              _TimelineCard(history: controller.history),
              const SizedBox(height: 12),
              _NotificationsCard(notifications: controller.notifications),
            ],
          );

          if (wide) {
            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 5,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        statusCard,
                        const SizedBox(height: 12),
                        if (failed) ...[
                          _FailureCard(order: order),
                          const SizedBox(height: 12),
                        ],
                        _ItemsCard(order: order),
                      ],
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    flex: 6,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _TimelineCard(history: controller.history),
                        const SizedBox(height: 12),
                        _NotificationsCard(
                            notifications: controller.notifications),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }

          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                statusCard,
                if (controller.offlineReason != null) ...[
                  const SizedBox(height: 12),
                  _OfflineNotice(reason: controller.offlineReason!),
                ],
                const SizedBox(height: 12),
                if (!terminal && controller.polling) ...[
                  Text(
                    'Refreshing every 2 seconds while you watch this screen.',
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                ],
                detailsColumn,
              ],
            ),
          );
        },
      ),
    );
  }
}

class _OfflineNotice extends StatelessWidget {
  const _OfflineNotice({required this.reason});
  final String reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Material(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.cloud_off, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Live updates interrupted — retrying with backoff. '
                  '($reason)',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.order,
    required this.justAccepted,
    required this.controller,
  });

  final OrderDetail order;
  final bool justAccepted;
  final OrderDetailsController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final terminal = isTerminalStatus(order.status);

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (justAccepted) ...[
              Material(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_outline,
                          color: theme.colorScheme.onPrimaryContainer),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Order accepted (HTTP 202)',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                color:
                                    theme.colorScheme.onPrimaryContainer,
                              ),
                            ),
                            Text(
                              'Accepted total '
                              '${formatMoney(order.totalAmountMinor, order.currency)} '
                              '— processing continues in the background.',
                              style:
                                  theme.textTheme.bodySmall?.copyWith(
                                color:
                                    theme.colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
            ],
            // Wrap (not Row+Spacer): chip + version + outcome must reflow
            // on narrow phones and at large text scales.
            Wrap(
              spacing: 10,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StatusChip(status: order.status),
                Text(
                  'v${order.version}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                if (terminal)
                  Text(
                    order.status == 'DRIVER_ASSIGNED'
                        ? 'Completed'
                        : 'Final outcome',
                    style: theme.textTheme.labelMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            if (order.driverId != null) ...[
              Material(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(10),
                child: ListTile(
                  leading: const Icon(Icons.two_wheeler),
                  title: const Text('Driver assigned'),
                  subtitle: Text('Driver reference: ${order.driverId}'),
                  dense: true,
                ),
              ),
              const SizedBox(height: 12),
            ],
            _InfoRow(label: 'Order ID', value: order.id),
            _InfoRow(
                label: 'Restaurant', value: order.restaurantName ?? '—'),
            _InfoRow(label: 'Address', value: order.deliveryAddress),
            _InfoRow(
              label: 'Total (server)',
              value: formatMoney(
                  order.totalAmountMinor, order.currency),
            ),
            _InfoRow(label: 'Placed', value: order.createdAt),
            _InfoRow(label: 'Updated', value: order.updatedAt),
          ],
        ),
      ),
    );
  }
}

class _FailureCard extends StatelessWidget {
  const _FailureCard({required this.order});
  final OrderDetail order;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final payment = order.status == 'PAYMENT_FAILED';
    return Semantics(
      container: true,
      label: 'Failure explanation',
      child: Material(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    payment ? Icons.credit_card_off : Icons.cancel_outlined,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      payment
                          ? 'Payment failed'
                          : 'Order could not be completed',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                failureExplanation(order.failureCode),
                style: TextStyle(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
              if (order.failureCode != null) ...[
                const SizedBox(height: 6),
                Text(
                  'Failure code: ${order.failureCode}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ItemsCard extends StatelessWidget {
  const _ItemsCard({required this.order});
  final OrderDetail order;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Items',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            for (final item in order.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${item.quantity} × ${item.itemName}',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    Text(
                      formatMoney(
                          item.lineTotalMinor, order.currency),
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            if (order.items.isEmpty)
              Text('No items.', style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _TimelineCard extends StatelessWidget {
  const _TimelineCard({required this.history});
  final List<HistoryEntry> history;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Timeline',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            if (history.isEmpty)
              Text('No transitions recorded yet.',
                  style: theme.textTheme.bodySmall)
            else
              for (var i = 0; i < history.length; i++)
                _TimelineTile(entry: history[i], isLast: i == history.length - 1),
          ],
        ),
      ),
    );
  }
}

class _TimelineTile extends StatelessWidget {
  const _TimelineTile({required this.entry, required this.isLast});

  final HistoryEntry entry;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = entry.toStatus == 'PAYMENT_FAILED' ||
        entry.toStatus == 'FAILED';
    final color = failed
        ? theme.colorScheme.error
        : isLast
            ? statusColor(entry.toStatus)
            : theme.colorScheme.outline;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              Container(
                width: 12,
                height: 12,
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    color: theme.colorScheme.outlineVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry.fromStatus == null
                              ? statusLabel(entry.toStatus)
                              : '${statusLabel(entry.fromStatus!)} → '
                                  '${statusLabel(entry.toStatus)}',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      StatusChip(status: entry.toStatus, dense: true),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${entry.source}${entry.reason != null ? ' · ${entry.reason}' : ''}',
                    style: theme.textTheme.bodySmall,
                  ),
                  Text(
                    '${entry.createdAt} · v${entry.version}',
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NotificationsCard extends StatelessWidget {
  const _NotificationsCard({required this.notifications});
  final List<AppNotification> notifications;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.notifications_none,
                    size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text('Notifications',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Persisted on the server — they survive reloads and restarts.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            if (notifications.isEmpty)
              Text('No notifications for this order yet.',
                  style: theme.textTheme.bodySmall)
            else
              for (final notification in notifications)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        _iconFor(notification.eventType),
                        size: 18,
                        color: theme.colorScheme.outline,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              notification.title,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            Text(
                              notification.body,
                              style: theme.textTheme.bodySmall,
                            ),
                            Text(
                              notification.createdAt,
                              style: theme.textTheme.labelSmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(String eventType) {
    if (eventType.contains('payment.failed')) return Icons.error_outline;
    if (eventType.contains('driver')) return Icons.two_wheeler;
    if (eventType.contains('failed')) return Icons.cancel_outlined;
    return Icons.mail_outline;
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
