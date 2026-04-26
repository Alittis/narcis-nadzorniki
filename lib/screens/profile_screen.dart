import 'package:flutter/material.dart';
import 'package:narcis_nadzorniki/screens/record_list_screen.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:provider/provider.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profil')),
      body: Consumer<AppState>(
        builder: (context, state, _) {
          final email = state.currentUser ?? '';
          final initial = email.isNotEmpty ? email[0].toUpperCase() : '?';
          final total = state.records.length;
          final pendingPush = state.pendingPushCount;
          final missingLocal = state.missingLocalCount;

          return ListView(
            children: [
              const SizedBox(height: 16),
              Center(
                child: CircleAvatar(
                  radius: 40,
                  child: Text(
                    initial,
                    style: const TextStyle(fontSize: 32),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  email,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: _StatCard(
                        label: 'Zapisi',
                        value: total.toString(),
                        icon: Icons.list_alt,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _StatCard(
                        label: 'Za pošiljanje',
                        value: pendingPush.toString(),
                        icon: Icons.cloud_upload,
                        highlighted: pendingPush > 0,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _StatCard(
                        label: 'Za prenos',
                        value: missingLocal.toString(),
                        icon: Icons.cloud_download,
                        highlighted: missingLocal > 0,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Divider(height: 1),
              ListTile(
                leading: Icon(
                  state.isOutOfSync ? Icons.sync_problem : Icons.cloud_done,
                  color: state.isOutOfSync ? Colors.orange : Colors.green,
                ),
                title: Text(state.isSyncing
                    ? 'Sinhronizacija poteka…'
                    : (state.isOutOfSync
                        ? 'Sinhroniziraj zdaj'
                        : 'Vse je sinhronizirano')),
                subtitle: state.isOutOfSync
                    ? Text(_subtitleFor(pendingPush, missingLocal))
                    : null,
                trailing: state.isSyncing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : (state.isOutOfSync
                        ? const Icon(Icons.refresh)
                        : null),
                onTap: state.isSyncing || !state.isOnline || !state.canSync
                    ? null
                    : () => state.syncAll(),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.list_alt),
                title: const Text('Seznam zapisov'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => RecordListScreen(records: state.records),
                    ),
                  );
                },
              ),
              const Divider(height: 1),
              SwitchListTile(
                value: state.offlineOverride,
                onChanged: state.setOfflineOverride,
                secondary: const Icon(Icons.wifi_off),
                title: const Text('Offline način'),
                subtitle: const Text('Shranjuj lokalno in čakaj na sinhronizacijo.'),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Odjava'),
                subtitle: Text(email),
                onTap: () async {
                  final navigator = Navigator.of(context);
                  await state.logout();
                  if (navigator.canPop()) navigator.pop();
                },
              ),
            ],
          );
        },
      ),
    );
  }

  String _subtitleFor(int pendingPush, int missingLocal) {
    final parts = <String>[];
    if (pendingPush > 0) parts.add('$pendingPush za poslati');
    if (missingLocal > 0) parts.add('$missingLocal za prenesti');
    return parts.join(' · ');
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    this.highlighted = false,
  });

  final String label;
  final String value;
  final IconData icon;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = highlighted ? scheme.errorContainer : scheme.surfaceContainerHighest;
    final fg = highlighted ? scheme.onErrorContainer : scheme.onSurface;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: fg),
          const SizedBox(height: 8),
          Text(
            value,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(color: fg, fontWeight: FontWeight.bold),
          ),
          Text(label, style: TextStyle(color: fg)),
        ],
      ),
    );
  }
}
