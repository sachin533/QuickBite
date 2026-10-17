import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/money.dart';
import '../state/auth_controller.dart';
import '../state/cart_controller.dart';
import '../state/checkout_controller.dart';
import '../widgets/quantity_stepper.dart';
import '../widgets/state_views.dart';

/// Cart: quantities, removal, subtotal, delivery address, and the validated
/// checkout flow with the persisted idempotency key:
///   * the submit button is disabled while a request is active,
///   * a timeout/offline failure keeps key + body and offers a *safe retry
///     with the same key* (never a fresh key),
///   * a pending attempt from a previous session is restored on launch.
class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  final _addressController = TextEditingController();
  bool _addressEdited = false;
  String? _addressError;
  late final CartController _cart;

  @override
  void initState() {
    super.initState();
    _cart = context.read<CartController>();
    _cart.addListener(_onCartChanged);
    _fillAddressFromDraft();
    context.read<CheckoutController>().restore();
  }

  void _onCartChanged() => _fillAddressFromDraft();

  /// Fill the address from the local draft once it is restored, unless the
  /// user already started typing.
  void _fillAddressFromDraft() {
    if (_cart.restored &&
        !_addressEdited &&
        _addressController.text.isEmpty &&
        _cart.deliveryAddress.isNotEmpty) {
      _addressController.text = _cart.deliveryAddress;
    }
  }

  @override
  void dispose() {
    _cart.removeListener(_onCartChanged);
    _addressController.dispose();
    super.dispose();
  }

  String? _validateAddress(String value) {
    final v = value.trim();
    if (v.length < 8) return 'Enter a full delivery address (min 8 chars)';
    if (v.length > 500) return 'Address is too long (max 500 chars)';
    return null;
  }

  Future<void> _checkout() async {
    final cart = context.read<CartController>();
    final checkout = context.read<CheckoutController>();

    final address = _addressController.text;
    final addressProblem = _validateAddress(address);
    setState(() => _addressError = addressProblem);
    if (addressProblem != null) return;
    if (cart.isEmpty || cart.restaurant == null) return;

    cart.setDeliveryAddress(address.trim());

    final accepted = await checkout.submit(
      restaurantId: cart.restaurant!.id,
      deliveryAddress: address.trim(),
      items: [
        for (final line in cart.lines)
          (menuItemId: line.item.id, quantity: line.quantity),
      ],
    );

    if (!mounted) return;
    if (accepted != null) {
      cart.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Order ${accepted.orderId} accepted')),
      );
      Navigator.of(context).pushNamedAndRemoveUntil(
        '/orders/${accepted.orderId}?ack=1',
        (route) => route.isFirst,
      );
    }
  }

  Future<void> _retry() async {
    final cart = context.read<CartController>();
    final checkout = context.read<CheckoutController>();
    final accepted = await checkout.retry();
    if (!mounted) return;
    if (accepted != null) {
      cart.clear();
      Navigator.of(context).pushNamedAndRemoveUntil(
        '/orders/${accepted.orderId}?ack=1',
        (route) => route.isFirst,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cart = context.watch<CartController>();
    final checkout = context.watch<CheckoutController>();
    final submitting = checkout.isSubmitting;

    final lines = cart.lines;
    final subtotal = cart.subtotalMinor;

    return Scaffold(
      appBar: AppBar(title: const Text('Your cart')),
      body: SafeArea(
        child: !cart.restored
            ? const LoadingView(label: 'Restoring cart draft…')
            : lines.isEmpty && !checkout.hasPending
                ? const EmptyView(
                    icon: Icons.shopping_cart_outlined,
                    message:
                        'Your cart is empty. Browse restaurants and add '
                        'something tasty.',
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth >= 900;
                      final orderPanel = _OrderSummaryPanel(
                        currency: cart.currency,
                        subtotalMinor: subtotal,
                        itemCount: cart.totalQuantity,
                        restaurantName:
                            cart.restaurant?.name ?? '—',
                      );

                      final itemsSection = Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (checkout.hasPending) ...[
                            _PendingAttemptBanner(checkout: checkout),
                            const SizedBox(height: 12),
                          ],
                          if (lines.isNotEmpty) ...[
                            Text(
                              cart.restaurant?.name ?? 'Cart',
                              style: theme.textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Each order contains items from one restaurant.',
                              style: theme.textTheme.bodySmall,
                            ),
                            const SizedBox(height: 12),
                          ],
                          for (final line in lines)
                            _CartLineTile(
                              line: line,
                              enabled: !submitting,
                              onSetQuantity: (q) =>
                                  cart.setQuantity(line.item.id, q),
                              onRemove: () => cart.remove(line.item.id),
                            ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _addressController,
                            enabled: !submitting,
                            minLines: 2,
                            maxLines: 4,
                            maxLength: 500,
                            decoration: InputDecoration(
                              labelText: 'Delivery address',
                              helperText:
                                  'At least 8 characters, e.g. '
                                  '"12 Lake Road, Bengaluru"',
                              errorText: _addressError,
                              border: const OutlineInputBorder(),
                              prefixIcon:
                                  const Icon(Icons.location_on_outlined),
                            ),
                            onChanged: (_) {
                              if (!_addressEdited) {
                                setState(() => _addressEdited = true);
                              }
                              if (_addressError != null) {
                                setState(() => _addressError = null);
                              }
                            },
                          ),
                          const SizedBox(height: 16),
                        ],
                      );

                      if (!wide) {
                        return SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              itemsSection,
                              orderPanel,
                            ],
                          ),
                        );
                      }

                      return SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 640),
                                child: itemsSection,
                              ),
                            ),
                            const SizedBox(width: 24),
                            SizedBox(
                              width: 320,
                              child: orderPanel,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}

class _PendingAttemptBanner extends StatelessWidget {
  const _PendingAttemptBanner({required this.checkout});

  final CheckoutController checkout;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pending = checkout.pending;
    if (pending == null) return const SizedBox.shrink();
    final transientError = checkout.lastError?.isRetryable ?? false;
    final busy = checkout.isSubmitting;

    return Semantics(
      liveRegion: true,
      container: true,
      child: Material(
        color: transientError
            ? theme.colorScheme.tertiaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    transientError
                        ? Icons.cloud_off
                        : Icons.pending_actions_outlined,
                    size: 20,
                    color: transientError
                        ? theme.colorScheme.onTertiaryContainer
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      busy
                          ? 'Submitting your order…'
                          : 'Unconfirmed checkout attempt',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                busy
                    ? 'Please don’t close the app — the request is in flight.'
                    : (checkout.lastError?.userMessage ??
                        'Your order may or may not have been placed. Retrying '
                        'is safe: the same idempotency key and request are '
                        'reused, so no duplicate order can be created.'),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              if (busy)
                const LinearProgressIndicator()
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: () {
                        final state = context
                            .findAncestorStateOfType<_CartScreenState>();
                        state?._retry();
                      },
                      icon: const Icon(Icons.restart_alt, size: 18),
                      label: const Text('Retry safely (same key)'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _confirmDiscard(context, checkout),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Discard attempt'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDiscard(
    BuildContext context,
    CheckoutController checkout,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard the pending attempt?'),
        content: const Text(
          'Only discard if you are sure the order was NOT placed. If the '
          'original request reached the server, an order already exists and '
          'discarding will not cancel it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await checkout.discardPending();
    }
  }
}

class _CartLineTile extends StatelessWidget {
  const _CartLineTile({
    required this.line,
    required this.enabled,
    required this.onSetQuantity,
    required this.onRemove,
  });

  final CartLine line;
  final bool enabled;
  final ValueChanged<int> onSetQuantity;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = line.item;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${formatMoney(item.priceMinor, item.currency)} each',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            QuantityStepper(
              value: line.quantity,
              itemName: item.name,
              onChanged: enabled ? onSetQuantity : (_) {},
              onRemove: enabled ? onRemove : null,
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 96,
              child: Text(
                formatMoney(line.lineTotalMinor, item.currency),
                textAlign: TextAlign.end,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrderSummaryPanel extends StatelessWidget {
  const _OrderSummaryPanel({
    required this.currency,
    required this.subtotalMinor,
    required this.itemCount,
    required this.restaurantName,
  });

  final String currency;
  final int subtotalMinor;
  final int itemCount;
  final String restaurantName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final checkout = context.watch<CheckoutController>();
    final submitting = checkout.isSubmitting;
    final needsRetry = checkout.needsRetry;
    final auth = context.watch<AuthController>();

    final apiError = checkout.lastError;
    final showApiError =
        apiError != null && !submitting && checkout.pending == null;
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Order summary',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            _Row(label: 'Restaurant', value: restaurantName),
            _Row(label: 'Items', value: '$itemCount'),
            const Divider(height: 20),
            // Flexible (not just spaceBetween): both sides must be allowed to
            // shrink at large text scales or the row overflows on a phone.
            Row(
              children: [
                Flexible(
                  child: Text('Subtotal',
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    formatMoney(subtotalMinor, currency),
                    textAlign: TextAlign.end,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            Text(
              'Final total is computed server-side from menu prices.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            if (showApiError) ...[
              Builder(builder: (context) {
                final err = checkout.lastError!;
                final definiteRejection = err.kind ==
                        ApiErrorKind.validation ||
                    err.kind == ApiErrorKind.conflict;
                return Material(
                  color: definiteRejection
                      ? theme.colorScheme.errorContainer
                      : theme.colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(
                      err.kind == ApiErrorKind.validation
                          ? 'Order rejected: ${err.message}'
                          : err.userMessage,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                );
              }),
              const SizedBox(height: 12),
            ],
            FilledButton.icon(
              onPressed: submitting || !auth.isSignedIn
                  ? null
                  : needsRetry
                      ? () => _retryFromPanel(context)
                      : () => _submitFromPanel(context),
              icon: submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(needsRetry ? Icons.restart_alt : Icons.send, size: 18),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              label: Text(
                submitting
                    ? 'Placing order…'
                    : needsRetry
                        ? 'Retry checkout (same key)'
                        : 'Checkout',
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _submitFromPanel(BuildContext context) {
    // Reuse the screen's validation flow via the nearest CartScreen state.
    final state = context.findAncestorStateOfType<_CartScreenState>();
    state?._checkout();
  }

  void _retryFromPanel(BuildContext context) {
    final state = context.findAncestorStateOfType<_CartScreenState>();
    state?._retry();
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Flexible(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
