import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Renders a food/restaurant photograph from either a bundled asset path
/// (`assets/food/….jpg`) or an absolute http(s) URL.
///
/// Guarantees something sensible is always on screen:
///  * a warm skeleton while the bytes load — never a blank box, and never a
///    spinner (so screens that have their own explicit loading state are not
///    polluted with extra progress indicators),
///  * a warm placeholder when the reference is null,
///  * an explicit "image unavailable" fallback if decoding or the network
///    fails, so a broken link never shows as a torn-image glyph.
class FoodImage extends StatelessWidget {
  const FoodImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.borderRadius,
    this.icon = Icons.restaurant_rounded,
  });

  final String? url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final IconData icon;

  static bool isNetwork(String url) =>
      url.startsWith('http://') || url.startsWith('https://');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Widget child;
    if (url == null || url!.isEmpty) {
      child = _Placeholder(icon: icon, color: scheme.outline);
    } else if (isNetwork(url!)) {
      child = Image.network(
        url!,
        width: width,
        height: height,
        fit: fit,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : const _Skeleton(),
        errorBuilder: (context, error, stack) =>
            _Placeholder(icon: icon, color: scheme.outline),
      );
    } else {
      // Bundled asset: available offline, no round trip to a CDN.
      child = Image.asset(
        url!,
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (context, error, stack) =>
            _Placeholder(icon: icon, color: scheme.outline),
      );
    }

    if (borderRadius == null) return child;
    return ClipRRect(borderRadius: borderRadius!, child: child);
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Brand.orangeSoft.withValues(alpha: 0.55),
      alignment: Alignment.center,
      child: Icon(
        Icons.restaurant_rounded,
        color: Brand.orange.withValues(alpha: 0.3),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    // Fills whatever box the parent provides (grid cells, banners, rows).
    return Container(
      color: color.withValues(alpha: 0.08),
      alignment: Alignment.center,
      child: Icon(icon, color: color.withValues(alpha: 0.7)),
    );
  }
}
