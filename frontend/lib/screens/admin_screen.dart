import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/money.dart';
import '../models/admin.dart';
import '../models/order.dart';
import '../state/admin_controller.dart';
import '../widgets/state_views.dart';
import '../widgets/status_chip.dart';

/// Read-only admin overview: aggregate counts (including operational
/// pending outbox / retry / quarantine counters) plus a cross-customer
/// order list with status filters and pagination.
class AdminScreen extends StatelessWidget {
  const AdminScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AdminController>(
      create: (context) => AdminController(context.read())..load(),
      child: const _AdminView(),
    );
  }
}

class _AdminView extends StatelessWidget {
  const _AdminView();

  @override
  Widget build(BuildContext context) {
    final admin = context.watch<AdminController>();
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (admin.summary != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: _SummaryCards(admin: admin.summary!),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilterChip(
                label: const Text('All'),
                selected: admin.statusFilter == null,
                onSelected: (_) => admin.setStatusFilter(null),
              ),
              for (final status in kOrderStatuses)
                FilterChip(
                  label: Text(statusLabel(status)),
                  selected: admin.statusFilter == status,
                  onSelected: (_) => admin.setStatusFilter(status),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: StateView(
            state: admin.state,
            error: admin.error,
            onRetry: () => admin.load(refresh: true),
            emptyIcon: Icons.inbox_outlined,
            emptyMessage: 'No orders match this filter.',
            loadingLabel: 'Loading orders…',
            builder: (context) => RefreshIndicator(
              onRefresh: () => admin.load(refresh: true),
              child: ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: admin.items.length + (admin.hasMore ? 2 : 1),
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  if (index == admin.items.length) {
                    if (admin.loadingMore) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child:
                            Center(child: CircularProgressIndicator()),
                      );
                    }
                    if (!admin.hasMore) {
                      return Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          '${admin.total} orders total',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall,
                        ),
                      );
                    }
                    return Center(
                      child: TextButton.icon(
                        onPressed: admin.loadMore,
                        icon: const Icon(Icons.expand_more),
                        label: const Text('Load more'),
                      ),
                    );
                  }
                  final order = admin.items[index];
                  return Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(
                          color: theme.colorScheme.outlineVariant),
                    ),
                    child: ListTile(
                      dense: true,
                      leading: StatusChip(
                          status: order.status, dense: true),
                      title: Text(
                        '${order.customerEmail ?? 'unknown'} · '
                        '${order.restaurantName ?? order.restaurantId}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 14),
                      ),
                      subtitle: Text(
                        '${order.id}\n${order.createdAt}',
                        style: theme.textTheme.labelSmall,
                      ),
                      isThreeLine: true,
                      trailing: Text(
                        formatMoney(
                            order.totalAmountMinor, order.currency),
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SummaryCards extends StatelessWidget {
  const _SummaryCards({required this.admin});
  final AdminSummary admin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final status in kOrderStatuses)
          _Stat(
            label: statusLabel(status),
            value: '${admin.ordersByStatus[status] ?? 0}',
            color: theme.colorScheme.primary,
          ),
        _Stat(
          label: 'Pending outbox',
          value: '${admin.pendingOutbox}',
          color: Colors.blueGrey,
        ),
        _Stat(
          label: 'Pending retries',
          value: '${admin.pendingRetries}',
          color: Colors.orange.shade800,
        ),
        _Stat(
          label: 'Open quarantine',
          value: '${admin.openQuarantine}',
          color: theme.colorScheme.error,
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          Text(label, style: theme(context).textTheme.labelSmall),
        ],
      ),
    );
  }

  ThemeData theme(BuildContext context) => Theme.of(context);
}
