/// Filename parsing shared by the archive, its sidecars and upload clients.
class RecordingFilename {
  RecordingFilename._();

  static String basename(String path) => path.replaceAll('\\', '/').split('/').last;

  static String stem(String path) {
    final name = basename(path);
    final dot = name.lastIndexOf('.');
    return dot < 0 ? name : name.substring(0, dot);
  }

  /// The timestamp precedes optional draft/crop suffixes. Never parse a directory.
  static int? timestamp(String path) {
    for (final part in stem(path).split('_')) {
      final value = int.tryParse(part);
      if (value != null && value >= 0) return value;
    }
    return null;
  }

  /// A copy keeps this suffix when its timestamp changes.
  static String cropSuffix(String path) {
    final name = stem(path);
    final index = name.indexOf('_crop');
    return index < 0 ? '' : name.substring(index);
  }
}
