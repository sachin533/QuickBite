import 'package:flutter/material.dart';

import '../models/order.dart';

/// Color pairs chosen for readable contrast on both light and dark themes.
Color statusColor(String status) {
  switch (status) {
    case 'PENDING':
      return Colors.blueGrey.shade700;
    case 'PAID':
      return Colors.teal.shade700;
    case 'CONFIRMED':
      return Colors.green.shade700;
    case 'DRIVER_ASSIGNED':
      return Colors.green.shade900;
    case 'PAYMENT_FAILED':
      return Colors.red.shade700;
    case 'FAILED':
      return Colors.orange.shade900;
    default:
      return Colors.blueGrey.shade700;
  }
}

/// Status pill used across lists, details, and admin views.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status, this.dense = false});

  final String status;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = statusColor(status);
    final terminal = isTerminalStatus(status);
    final success = status == 'DRIVER_ASSIGNED';
    final failed =
        status == 'PAYMENT_FAILED' || status == 'FAILED';
    return Semantics(
      label: 'Order status: ${statusLabel(status)}',
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 8 : 12,
          vertical: dense ? 3 : 5,
        ),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (success || failed) ...[
              Icon(
                success ? Icons.check_circle : Icons.cancel,
                size: dense ? 13 : 15,
                color: Colors.white,
              ),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                statusLabel(status),
                maxLines: 1,
                // Shrink (never overflow) when a large text scale squeezes the
                // pill inside a Row at a narrow width.
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: dense ? 11.5 : 13,
                ),
              ),
            ),
            if (terminal && !success && !failed) ...[
              const SizedBox(width: 4),
              Icon(Icons.stop_circle, size: dense ? 13 : 15, color: Colors.white),
            ],
          ],
        ),
      ),
    );
  }
}
