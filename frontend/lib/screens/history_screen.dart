import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/money.dart';
import '../state/history_controller.dart';
import '../widgets/state_views.dart';
import '../widgets/status_chip.dart';

/// Paginated order history with pull-to-refresh; each row opens details.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 300) {
      context.read<HistoryController>().loadMore();
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<HistoryController>(
      create: (context) => HistoryController(context.read())..load(),
      child: _HistoryView(scrollController: _scrollController),
    );
  }
}

class _HistoryView extends StatelessWidget {
  const _HistoryView({required this.scrollController});

  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    final history = context.watch<HistoryController>();
    final theme = Theme.of(context);

    return StateView(
      state: history.state,
      error: history.error,
      onRetry: () => history.load(refresh: true),
      emptyIcon: Icons.receipt_long_outlined,
      emptyMessage: 'No orders yet — your placed orders will appear here.',
      loadingLabel: 'Loading your orders…',
      builder: (context) => RefreshIndicator(
        onRefresh: () => history.load(refresh: true),
        child: ListView.separated(
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          itemCount: history.items.length + (history.hasMore ? 2 : 1),
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            if (index == history.items.length) {
              if (history.loadingMore) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (history.error != null) {
                return Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    children: [
                      Text(history.error!.userMessage,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall),
                      TextButton(
                        onPressed: history.loadMore,
                        child: const Text('Try loading more'),
                      ),
                    ],
                  ),
                );
              }
              return Center(
                child: TextButton.icon(
                  onPressed: history.loadMore,
                  icon: const Icon(Icons.expand_more),
                  label: const Text('Load more'),
                ),
              );
            }
            final order = history.items[index];
            return Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
              child: ListTile(
                onTap: () => Navigator.of(context)
                    .pushNamed('/orders/${order.id}'),
                leading: Icon(
                  order.status == 'DRIVER_ASSIGNED'
                      ? Icons.check_circle_outline
                      : order.status == 'PAYMENT_FAILED' ||
                              order.status == 'FAILED'
                          ? Icons.cancel_outlined
                          : Icons.hourglass_top,
                  color: theme.colorScheme.primary,
                ),
                title: Text(
                  order.restaurantName ?? order.id,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(order.id,
                        style: theme.textTheme.labelSmall),
                    Text('Placed ${order.createdAt}'),
                    const SizedBox(height: 6),
                    // Status + amount live in the subtitle (wraps cleanly at
                    // large text scales) — a trailing column overflows the
                    // tile at 1.5x scaling on narrow phones.
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        StatusChip(status: order.status, dense: true),
                        Text(
                          formatMoney(
                              order.totalAmountMinor, order.currency),
                          style: theme.textTheme.bodySmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
