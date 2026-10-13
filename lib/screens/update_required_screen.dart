import 'package:flutter/material.dart';

/// The title and text of [UpdateRequiredScreen], for tests.
const updateRequiredTitle = 'Potrebna je posodobitev';
const updateRequiredText =
    'Ta različica Terenske beležnice ni več podprta. Posodobite aplikacijo v '
    'Trgovini Play in jo znova odprite.\n\n'
    'Neposlani zapisi, fotografije in obhodi ostanejo na napravi in se '
    'pošljejo po posodobitvi.';

/// Shown at the root when the server answered 426: this build is below its
/// minimum (TB-46). Sync has stopped; nothing on the device is touched.
/// There is no store button — opening a URL would need a new plugin.
class UpdateRequiredScreen extends StatelessWidget {
  const UpdateRequiredScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF2E7D32),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.system_update, size: 64, color: Colors.white),
                const SizedBox(height: 16),
                Text(
                  updateRequiredTitle,
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                const Text(
                  updateRequiredText,
                  style: TextStyle(color: Colors.white, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
