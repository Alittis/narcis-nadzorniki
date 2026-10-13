import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';

/// TB-52: tells the user, once, that photos were dropped because their file
/// was gone before they could upload, and which records they belonged to.
/// The rest of each record is kept.
Future<void> showLostPhotosDialog(BuildContext context, LostPhotos lost) {
  final one = lost.photos == 1;
  final dateFormat = DateFormat('dd.MM.yyyy HH:mm');
  final records = lost.records
      .map((r) {
        final types = r.types.isEmpty
            ? 'Brez tipa'
            : r.types.map((t) => t.typeName).join(', ');
        return '• ${dateFormat.format(r.observedAt.toLocal())} · $types';
      })
      .join('\n');
  final kept = lost.records.length == 1
      ? 'Zapis je shranjen'
      : 'Zapisi so shranjeni';

  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(
        one
            ? 'Fotografije ni bilo mogoče poslati'
            : 'Fotografij ni bilo mogoče poslati',
      ),
      content: Text(
        one
            ? 'Fotografije ni bilo več v telefonu, ko jo je aplikacija '
                  'poskušala poslati, zato je ni mogoče obnoviti. '
                  '$kept brez nje:\n\n$records'
            : 'Nekaj fotografij ni bilo več v telefonu, ko jih je '
                  'aplikacija poskušala poslati, zato jih ni mogoče obnoviti. '
                  '$kept brez njih:\n\n$records',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Razumem'),
        ),
      ],
    ),
  );
}
