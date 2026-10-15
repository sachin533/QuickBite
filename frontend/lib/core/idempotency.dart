import 'dart:math';

/// Generates an Idempotency-Key the API accepts: 1-64 chars of
/// `[A-Za-z0-9_-]`.
///
/// One key is created per checkout *attempt chain* and persisted together
/// with the exact request body until the outcome is known, so a timeout can
/// only ever be retried with the same key (never silently re-keyed).
String generateIdempotencyKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(12, (_) => random.nextInt(256));
  final stamp = DateTime.now().toUtc().millisecondsSinceEpoch.toRadixString(36);
  final suffix = bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return 'qb_$stamp$suffix';
}
