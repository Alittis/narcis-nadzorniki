import 'package:flutter/material.dart';

class FundingFooter extends StatelessWidget {
  const FundingFooter({super.key});

  static const _text =
      'Ta aplikacija je bila izdelana v okviru projekta LIFE Tršca '
      '(št. 101114184 — LIFE22-NAT-SI-LIFE TRSCA), ki ga sofinancirata '
      'Evropska unija iz programa LIFE in Ministrstvo za naravne vire in prostor.';

  static Widget _logoCell(String asset) =>
      Expanded(child: Image.asset(asset, fit: BoxFit.contain));

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      child: Column(
        children: [
          SizedBox(
            height: 56,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _logoCell('assets/images/funding_life.png'),
                const SizedBox(width: 12),
                _logoCell('assets/images/funding_natura2000.png'),
                const SizedBox(width: 12),
                _logoCell('assets/images/funding_life_trsca.png'),
              ],
            ),
          ),
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
