import 'dart:io';

/// Rewrites a state file so that a crash or kill mid-write never leaves it torn.
///
/// The new contents go to `<target>.tmp`, are flushed, and the temp file is renamed
/// over [target]. A rename replaces the destination in one step, so the file holds
/// either its old contents or the new ones — never a truncated mix. Callers that
/// share a target must already serialize their writes; two concurrent writers would
/// share the temp path.
class AtomicFile {
  static Future<void> writeString(File target, String contents) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(contents, flush: true);
    await tmp.rename(target.path);
  }

  static Future<void> writeBytes(File target, List<int> bytes) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);
  }
}
