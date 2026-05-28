import 'package:flutter/material.dart';

class FundingFooter extends StatelessWidget {
  const FundingFooter({super.key, this.compact = false});

  final bool compact;

  static const _text =
      'Ta aplikacija je bila izdelana v okviru projekta LIFE Tršca '
      '(št. 101114184 — LIFE22-NAT-SI-LIFE TRSCA), ki ga sofinancirata '
      'Evropska unija iz programa LIFE in Ministrstvo za naravne vire in prostor.';

  @override
  Widget build(BuildContext context) {
    final logoHeight = compact ? 32.0 : 44.0;
    final spacing = compact ? 14.0 : 20.0;

    final logoRow = SizedBox(
      height: logoHeight,
      child: FittedBox(
        fit: BoxFit.contain,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Image.asset('assets/images/funding_life.png', height: logoHeight),
            SizedBox(width: spacing),
            Image.asset(
              'assets/images/funding_natura2000.png',
              height: logoHeight,
            ),
            SizedBox(width: spacing),
            Image.asset(
              'assets/images/funding_life_trsca.png',
              height: logoHeight,
            ),
          ],
        ),
      ),
    );

    if (compact) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(12),
        ),
        child: logoRow,
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      child: Column(
        children: [
          logoRow,
          const SizedBox(height: 16),
          Text(
            _text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
