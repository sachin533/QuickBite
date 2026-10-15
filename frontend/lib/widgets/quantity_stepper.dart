import 'package:flutter/material.dart';

/// Quantity stepper with labelled, keyboard-focusable buttons (a11y).
/// Range is 1..[max]; decrement at 1 removes the line via [onRemove].
class QuantityStepper extends StatelessWidget {
  const QuantityStepper({
    super.key,
    required this.value,
    required this.onChanged,
    this.max = 20,
    this.onRemove,
    this.label = 'quantity',
    this.itemName,
  });

  final int value;
  final ValueChanged<int> onChanged;
  final int max;
  final VoidCallback? onRemove;
  final String label;
  final String? itemName;

  @override
  Widget build(BuildContext context) {
    final name = itemName ?? label;
    final canRemove = value <= 1 && onRemove != null;
    return Semantics(
      label: '$name quantity, $value',
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outline),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: canRemove ? 'Remove $name' : 'Decrease $name quantity',
              onPressed: () {
                if (canRemove) {
                  onRemove!();
                } else {
                  onChanged(value - 1);
                }
              },
              visualDensity: VisualDensity.compact,
              icon: Icon(canRemove ? Icons.delete_outline : Icons.remove),
            ),
            Text(
              '$value',
              key: ValueKey('qty-$name'),
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            IconButton(
              tooltip: 'Increase $name quantity',
              onPressed: value >= max ? null : () => onChanged(value + 1),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ),
    );
  }
}
