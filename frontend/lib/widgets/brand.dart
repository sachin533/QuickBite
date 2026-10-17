import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Compact QuickBite brand mark: gradient tile + optional wordmark.
class QuickBiteLogo extends StatelessWidget {
  const QuickBiteLogo({super.key, this.tileSize = 38, this.showWordmark = true});

  final double tileSize;
  final bool showWordmark;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // On phones the wordmark steps down a size so the mark still fits next to
    // the cart and account buttons at raised text scales.
    final narrow = MediaQuery.sizeOf(context).width < 520;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: tileSize,
          height: tileSize,
          decoration: BoxDecoration(
            gradient: Brand.heroGradient,
            borderRadius: BorderRadius.circular(tileSize * 0.32),
            boxShadow: [
              BoxShadow(
                color: Brand.orange.withValues(alpha: 0.35),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Icon(
            Icons.ramen_dining_rounded,
            size: tileSize * 0.6,
            color: Colors.white,
          ),
        ),
        if (showWordmark) ...[
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              'QuickBite',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (narrow
                      ? theme.textTheme.titleMedium
                      : theme.textTheme.titleLarge)
                  ?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
                color: Brand.ink,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Section heading used across the home and menu pages.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.compact = false,
  });

  final String title;
  final String? subtitle;
  final Widget? action;

  /// true → a single-line title with no room cost, for phone layouts where
  /// the first card must stay inside the opening screen.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: compact ? 1 : null,
          overflow: compact ? TextOverflow.ellipsis : null,
          style: (compact
                  ? theme.textTheme.titleLarge
                  : theme.textTheme.headlineSmall)
              ?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.4,
          ),
        ),
        if (subtitle != null && !compact) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: Brand.inkSoft),
          ),
        ],
      ],
    );

    if (action == null) return heading;
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 8,
      children: [heading, action!],
    );
  }
}

/// Small pill used for ratings, delivery estimates and cuisine tags.
class MetaPill extends StatelessWidget {
  const MetaPill({
    super.key,
    required this.icon,
    required this.label,
    this.onDark = false,
    this.color,
  });

  final IconData icon;
  final String label;
  final bool onDark;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? (onDark ? Colors.white : Brand.inkSoft);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: tint),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: tint,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
      ],
    );
  }
}
