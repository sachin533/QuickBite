import 'package:flutter/material.dart';

import '../core/api_exception.dart';
import '../state/restaurants_controller.dart';

/// Centered spinner with a label (explicit loading state).
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.label = 'Loading…'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

/// Explicit empty state with guidance.
class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: scheme.outline),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            if (action != null) ...[
              const SizedBox(height: 16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Explicit error/offline state with a retry affordance.
class ErrorView extends StatelessWidget {
  const ErrorView({
    super.key,
    required this.error,
    required this.onRetry,
    this.title = 'Something went wrong',
  });

  final ApiException error;
  final VoidCallback onRetry;
  final String title;

  @override
  Widget build(BuildContext context) {
    final offline = error.kind == ApiErrorKind.network ||
        error.kind == ApiErrorKind.timeout;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              offline ? Icons.cloud_off : Icons.error_outline,
              size: 56,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(title,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              error.userMessage,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (error.requestId != null) ...[
              const SizedBox(height: 8),
              Text(
                'Request ${error.requestId}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Chooses the right explicit state view for a [LoadState].
class StateView extends StatelessWidget {
  const StateView({
    super.key,
    required this.state,
    required this.error,
    required this.onRetry,
    required this.emptyMessage,
    required this.emptyIcon,
    required this.builder,
    this.loadingLabel,
  });

  final LoadState state;
  final ApiException? error;
  final VoidCallback onRetry;
  final String emptyMessage;
  final IconData emptyIcon;
  final WidgetBuilder builder;
  final String? loadingLabel;

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case LoadState.idle:
      case LoadState.loading:
        return LoadingView(label: loadingLabel ?? 'Loading…');
      case LoadState.error:
        return ErrorView(error: error!, onRetry: onRetry);
      case LoadState.empty:
        return EmptyView(icon: emptyIcon, message: emptyMessage);
      case LoadState.loaded:
        return builder(context);
    }
  }
}
