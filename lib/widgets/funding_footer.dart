import 'package:flutter/material.dart';

class FundingFooter extends StatelessWidget {
  const FundingFooter({super.key});

  static const _text =
      'Ta aplikacija je bila izdelana v okviru projekta LIFE Tršca '
      '(št. 101114184 — LIFE22-NAT-SI-LIFE TRSCA), ki ga sofinancirata '
      'Evropska unija iz programa LIFE in Ministrstvo za naravne vire in prostor.';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      child: Column(
        children: [
          Image.asset(
            'assets/images/funding_logos.png',
            fit: BoxFit.contain,
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
