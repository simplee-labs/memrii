// RECORDINGS_PIPELINE_REDESIGN.md §6: raw files are deleted only by the gate (and the
// debug reset), and written only by sealing. A tripwire over lib/: a new writer or
// deleter of raw audio fails here until it is looked at.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _rawRoot = RegExp(r'''['"/](raw_segments|discarded_segments|adjustment_mode_segments)''');
final _mutation =
    RegExp(r'\.delete\(|\.rename\(|writeAs(Bytes|String)\(|openWrite\(|FileMode\.(write|append)|truncate\(');

/// lib/ files, relative, with their non-comment lines.
Map<String, List<String>> _sources() => {
      for (final f
          in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')))
        f.path.replaceAll('\\', '/'): [
          for (final line in f.readAsLinesSync())
            if (!line.trimLeft().startsWith('//')) line
        ]
    };

void main() {
  final sources = _sources();

  test('only sealing, the pipeline and the debug tools write or delete under the raw roots', () {
    final writers = {
      for (final MapEntry(key: path, value: lines) in sources.entries)
        if (lines.any(_rawRoot.hasMatch) && lines.any(_mutation.hasMatch)) path
    };
    expect(writers, {
      'lib/services/raw/raw_chunks.dart', // parts, sealing, recovery, deleteLogicalFile
      'lib/services/raw/actions.dart', // Delete Phone Segments; Save original file writes elsewhere
      'lib/services/raw/legacy_update.dart', // the update: discarded_segments back to raw_segments, once
      'lib/services/raw/app_pipeline.dart', // Reprocess all: Adjustment Mode copies of released files back
      // Names a raw root and writes other files: the recordings list and the archive edits.
      'lib/services/recordings_manager.dart',
      'lib/services/wals/sdcard_wal_sync.dart', // downloads into part files; Adjustment Mode's copies
      'lib/pages/settings/sync_page.dart', // the debug tools
    });
  });

  test('a logical file is deleted only by the gate\'s journal op, and the raw roots only by the debug reset', () {
    final callers = {
      for (final MapEntry(key: path, value: lines) in sources.entries)
        if (lines.any((l) => l.contains('deleteLogicalFile('))) path
    };
    expect(callers, {'lib/services/raw/raw_chunks.dart', 'lib/services/raw/coordinator.dart'});
    final deleteRaw = {
      for (final MapEntry(key: path, value: lines) in sources.entries)
        if (lines.any((l) =>
            l.contains('DeleteRawOp(') &&
            !l.contains('const DeleteRawOp(this') &&
            !l.contains('case DeleteRawOp(') &&
            !l.contains('DeleteRawOp(:') && // a pattern reads an op; it makes none
            !l.contains("'deleteRaw' =>")))
          path
    };
    expect(deleteRaw, {'lib/services/raw/gate.dart'});
    final rootDeletes = [
      for (final MapEntry(key: path, value: lines) in sources.entries)
        for (final l in lines)
          if (l.contains('DeletePathsOp(') && l.contains('raw_segments')) path
    ];
    expect(rootDeletes, ['lib/services/raw/actions.dart'], reason: 'Delete Phone Segments');
  });
}
