import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:omi/services/wals.dart';
import 'package:omi/utils/atomic_file.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/mutex.dart';

class WalFileManager {
  static const String _walFileName = 'wals.json';
  static const String _walBackupFileName = 'wals_backup.json';

  static File? _walFile;
  static File? _walBackupFile;

  // Serializes all reads and writes so concurrent saveWals/loadWals calls can't
  // observe a mid-truncate empty file (which would silently drop other devices'
  // WALs during the merge step in saveWals).
  static final Mutex _lock = Mutex();

  static Future<void> init() async {
    final directory = await getApplicationDocumentsDirectory();
    _walFile = File('${directory.path}/$_walFileName');
    _walBackupFile = File('${directory.path}/$_walBackupFileName');
  }

  static Future<List<Wal>> loadWals() async {
    await _lock.acquire();
    try {
      return await _loadWalsUnlocked();
    } finally {
      _lock.release();
    }
  }

  static Future<List<Wal>> _loadWalsUnlocked() async {
    if (_walFile == null) {
      await init();
    }

    if (_walFile == null || !_walFile!.existsSync()) {
      Logger.debug('WAL file does not exist, returning empty list');
      return [];
    }

    try {
      return await _readWalFile(_walFile!);
    } catch (e) {
      // saveWals never writes an empty or malformed file, so this one was torn by an
      // older build's in-place write or damaged on disk. The backup is the copy taken
      // before the last save: one sync behind at worst, and its offsets still stop a
      // half-downloaded bin from restarting at 0.
      final backup = _walBackupFile;
      if (backup != null && backup.existsSync()) {
        try {
          final wals = await _readWalFile(backup);
          Logger.warning('WalFileManager: wals.json unreadable ($e) — restored ${wals.length} WALs from the backup');
          return wals;
        } catch (_) {}
      }
      if (e is _EmptyOrMalformedWalFile) {
        Logger.debug('WalFileManager: ${e.message}, returning empty list');
        return [];
      }
      rethrow;
    }
  }

  static Future<List<Wal>> _readWalFile(File file) async {
    final content = await file.readAsString();
    if (content.isEmpty) throw const _EmptyOrMalformedWalFile('WAL file is empty');

    final jsonData = jsonDecode(content);
    if (jsonData is! Map<String, dynamic> || jsonData['wals'] is! List) {
      throw const _EmptyOrMalformedWalFile('Invalid WAL file format');
    }

    final walsList = jsonData['wals'] as List;
    return Wal.fromJsonList(walsList);
  }

  static Future<bool> saveWals(List<Wal> wals, {String? deviceId}) async {
    await _lock.acquire();
    try {
      if (_walFile == null) {
        await init();
      }

      if (_walFile == null) {
        Logger.debug('WAL file is null, cannot save');
        return false;
      }

      // Merge: keep WALs for other devices so switching devices doesn't erase
      // their resume offsets.
      List<Wal> allWals = wals;
      if (deviceId != null) {
        try {
          final existing = await _loadWalsUnlocked();
          final others = existing.where((w) => w.device != deviceId).toList();
          if (others.isNotEmpty) allWals = [...others, ...wals];
        } catch (e) {
          Logger.debug('WalFileManager: Failed to merge existing WALs, saving current device only: $e');
        }
      }

      await _createBackup();

      final jsonData = {
        'version': 1,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'wals': allWals.map((wal) => wal.toJson()).toList(),
      };

      final jsonString = jsonEncode(jsonData);
      await AtomicFile.writeString(_walFile!, jsonString);

      return true;
    } finally {
      _lock.release();
    }
  }

  static Future<void> _createBackup() async {
    try {
      if (_walFile != null && _walFile!.existsSync() && _walBackupFile != null) {
        await _walFile!.copy(_walBackupFile!.path);
      }
    } on FileSystemException catch (e) {
      Logger.debug('WalFileManager: Failed to create backup: $e');
    }
  }

  static Future<void> clearAll() async {
    if (_walFile != null && _walFile!.existsSync()) {
      await _walFile!.delete();
    }
    if (_walBackupFile != null && _walBackupFile!.existsSync()) {
      await _walBackupFile!.delete();
    }
    Logger.debug('Cleared all WAL files');
  }

  static Future<Map<String, int>> getFileInfo() async {
    int mainFileSize = 0;
    int backupFileSize = 0;

    if (_walFile != null && _walFile!.existsSync()) {
      mainFileSize = await _walFile!.length();
    }

    if (_walBackupFile != null && _walBackupFile!.existsSync()) {
      backupFileSize = await _walBackupFile!.length();
    }

    return {
      'mainFileSize': mainFileSize,
      'backupFileSize': backupFileSize,
    };
  }
}

/// A WAL file with no parseable content — the shapes the loader has always answered
/// with an empty list when no backup can stand in.
class _EmptyOrMalformedWalFile implements Exception {
  final String message;
  const _EmptyOrMalformedWalFile(this.message);

  @override
  String toString() => message;
}
