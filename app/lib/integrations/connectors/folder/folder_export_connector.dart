import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/integrations/connector.dart';
import 'package:omi/integrations/connectors/folder/folder_export_service.dart';
import 'package:omi/integrations/integration_recording.dart';
import 'package:omi/integrations/sharing/upload_authorization.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/mutex.dart';

/// One copy Save to Folder made, in the current folder: where it went, the name it was asked
/// for, and the recording start it was named for — which is what
/// [FolderExportConnector.reconcile] compares, so a time-zone change on its own never
/// renames anything. No folder is recorded: changing or removing the folder clears the
/// ledger, under the same lock every copy holds, so no entry outlives its folder.
class _FolderCopy {
  final String uri;

  /// The name asked for, not necessarily the name in the folder: the channel saves as
  /// `name (2).ext` when that name is taken ("Save again", or a file of the user's), and only
  /// the URI comes back. Read for its extension, which that suffix leaves alone, and for logs.
  final String name;
  final int startMs;

  /// The user removed the copy from the folder. It still counts as delivered, so it is not
  /// put back; "Save again" makes a new one.
  final bool gone;

  const _FolderCopy({
    required this.uri,
    required this.name,
    required this.startMs,
    this.gone = false,
  });

  Map<String, Object> toJson() => {'uri': uri, 'name': name, 'startMs': startMs, if (gone) 'gone': true};

  static _FolderCopy? fromJson(Object? json) {
    if (json is! Map) return null;
    final uri = json['uri'], name = json['name'], startMs = json['startMs'];
    if (uri is! String || name is! String || startMs is! int) return null;
    return _FolderCopy(uri: uri, name: name, startMs: startMs, gone: json['gone'] == true);
  }
}

/// Save to Folder: copies each finished recording's audio into a folder the user picked,
/// named for when it was recorded — `2026-09-16 14.32.05.m4a`. The extension is the
/// recording file's own when it is copied, so one still awaiting its M4A conversion is
/// copied as `.wav`, and stays `.wav` through any later rename. The app sends nothing over
/// the network, so automatic Wi-Fi conditions does not apply.
///
/// This is memrii's local destination: a connector like the others, so it gets the same
/// queue, status and authorization, but nothing it does leaves the phone.
///
/// Once copied, a copy belongs to the folder:
/// - **Nothing the app deletes deletes it** — not the user deleting the recording, not
///   retention, passthrough or a stitch. A delete only makes the app forget it
///   ([forget]), the way HeyPocket's and Omi's delivered lists drop a deleted recording.
/// - **Re-files still rename it.** When the app corrects a recording's start, [reconcile]
///   renames the copy on the next sweep. Pulled, not pushed: what was copied is keyed by the
///   `.meta` upload key, which a re-file does not change, so nothing has to hook the rename,
///   and one missed while the app was killed is picked up the next time.
///
/// Residual: a finished recording a later stitch absorbs keeps its copy, and the merged
/// recording is copied under its own name, so that audio is in the folder twice — the same
/// duplicate the other connectors accept.
class FolderExportConnector extends Connector {
  FolderExportConnector(this._prefs, {FolderExportBackend? backend}) : _backend = backend ?? defaultBackend;

  final SharedPreferencesUtil _prefs;
  final FolderExportBackend _backend;

  static const connectorName = 'Folder';

  static FolderExportBackend defaultBackend = ChannelFolderExportBackend();

  /// Every folder operation, one at a time, across instances. A rename must never run
  /// against a copy being replaced, and a folder change must wait for a copy still being
  /// written into the old folder, or that copy would be recorded against the new one.
  static Mutex _lock = Mutex();

  /// Set when the folder cannot be reached at all. The lane pauses until then, rather than
  /// spending every recording's retries on something that is not their fault.
  static DateTime? _unavailableUntil;
  static const _unavailableRetry = Duration(minutes: 5);

  /// The ledger as last decoded, and the pref string it was decoded from. [hasDelivered] runs
  /// for every row on every repaint, and the ledger grows with every recording copied.
  static String? _ledgerRaw;
  static Map<String, _FolderCopy> _ledgerDecoded = const {};

  @visibleForTesting
  static void resetForTest() {
    _lock = Mutex();
    _unavailableUntil = null;
    _ledgerRaw = null;
    _ledgerDecoded = const {};
  }

  @override
  String get name => connectorName;

  @override
  String get automationSettingsKey => 'folderExport';

  @override
  ConnectorCapabilities get capabilities =>
      const ConnectorCapabilities(leavesDevice: false, sendsAudio: true, reconcilesDeliveries: true);

  // Prefixed: HeyPocket's retry key is the bare upload key.
  @override
  String retryKey(IntegrationRecording r) => 'folder_${r.id ?? r.audioPath}';

  @override
  bool get isConfigured => _prefs.folderExportEnabled && _prefs.folderExportTreeUri.isNotEmpty;

  @override
  bool get isAutomaticSendingEnabled => _prefs.folderExportAutoUpload;

  @override
  bool isEligibleForAutomatic(IntegrationRecording r) {
    if (!isConfigured || r.id == null) return false;
    final enabledAt = _prefs.folderExportAutoUploadAt;
    // Fail closed when no auto-save time is recorded (see HeyPocket).
    if (enabledAt <= 0) return false;
    return !r.startTime.isBefore(DateTime.fromMillisecondsSinceEpoch(enabledAt));
  }

  @override
  bool canSend(IntegrationRecording r) => isConfigured && r.id != null && r.audioExists;

  @override
  String get unavailableReason => 'Audio file is no longer available';

  @override
  bool hasDelivered(IntegrationRecording r) => r.id != null && _ledger().containsKey(r.id);

  @override
  bool hasExhaustedRetries(IntegrationRecording r) => _prefs.getAutoUploadRetries(retryKey(r)) >= 3;

  @override
  DateTime? backingOffUntil(IntegrationRecording r) {
    final until = _unavailableUntil;
    return until != null && until.isAfter(DateTime.now()) ? until : null;
  }

  /// `2026-09-16 14.32.05.m4a`, in local time. Dots, not colons: SD cards, and most
  /// computers the folder is later copied to, reject a colon in a name. [ext] defaults to the
  /// recording file's own.
  static String exportNameFor(IntegrationRecording r, {String? ext}) {
    final t = r.startTime.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    ext ??= r.audioPath.split('.').last;
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}.${two(t.minute)}.${two(t.second)}.$ext';
  }

  static String _mimeTypeFor(IntegrationRecording r) => switch (r.audioPath.split('.').last.toLowerCase()) {
        'm4a' => 'audio/mp4',
        'wav' => 'audio/x-wav',
        'ogg' => 'audio/ogg',
        _ => 'application/octet-stream',
      };

  /// The ledger, read-only. Decoded again only when the pref has changed.
  Map<String, _FolderCopy> _ledger() {
    final raw = _prefs.folderExportLedger;
    if (raw == _ledgerRaw) return _ledgerDecoded;
    final ledger = <String, _FolderCopy>{};
    if (raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        for (final e in decoded.entries) {
          final copy = _FolderCopy.fromJson(e.value);
          if (copy != null) ledger[e.key] = copy;
        }
      } catch (e) {
        Logger.error('Save to Folder: unreadable copy ledger ($e) — treating nothing as copied');
      }
    }
    _ledgerRaw = raw;
    _ledgerDecoded = Map.unmodifiable(ledger);
    return _ledgerDecoded;
  }

  /// A copy of the ledger to change and write back. Read it after the last await: another
  /// writer ([forgetCopiesOf]) does not take the lock.
  Map<String, _FolderCopy> _readLedger() => Map.of(_ledger());

  void _writeLedger(Map<String, _FolderCopy> ledger) {
    final raw = ledger.isEmpty ? '' : jsonEncode({for (final e in ledger.entries) e.key: e.value.toJson()});
    _prefs.folderExportLedger = raw;
    _ledgerRaw = raw;
    _ledgerDecoded = Map.unmodifiable(ledger);
  }

  @override
  Future<void> send(AuthorizedUpload upload, {void Function()? onProgress, bool Function()? isCancelled}) async {
    if (isCancelled?.call() ?? false) return;
    final r = upload.recording;
    final key = r.id;
    if (key == null) throw Exception('this recording has no upload key');
    await _lock.acquire();
    try {
      if (isCancelled?.call() ?? false) return; // cancelled while waiting its turn
      final tree = _prefs.folderExportTreeUri;
      if (tree.isEmpty) throw Exception('no folder chosen');
      final name = exportNameFor(r);
      final String uri;
      try {
        // "Save again" adds a copy beside the earlier one rather than replacing it: whatever
        // is already in the folder is the user's. The ledger follows the newest.
        uri = await _backend.copyInto(tree, r.audioPath, name, _mimeTypeFor(r));
      } on FolderExportException catch (e) {
        switch (e.kind) {
          case FolderExportError.noAccess:
            // Neither delivered nor failed: the manager reads the backoff and pauses the
            // lane, and the recording is tried again once it lifts.
            _unavailableUntil = DateTime.now().add(_unavailableRetry);
            await _prefs.clearAutoUploadRetry(retryKey(r));
            Logger.debug('Save to Folder: folder unreachable ($e) — retrying in ${_unavailableRetry.inMinutes}m');
            return;
          case FolderExportError.sourceGone:
            // Deleted, or folded into another recording, since it was queued.
            await _prefs.clearAutoUploadRetry(retryKey(r));
            return;
          default:
            rethrow;
        }
      }
      _unavailableUntil = null;
      final ledger = _readLedger();
      ledger[key] = _FolderCopy(uri: uri, name: name, startMs: r.startTime.millisecondsSinceEpoch);
      _writeLedger(ledger);
      await _prefs.clearAutoUploadRetry(retryKey(r));
      onProgress?.call();
    } finally {
      _lock.release();
    }
  }

  @override
  Future<void> reconcile(List<IntegrationRecording> delivered) async {
    if (_prefs.folderExportTreeUri.isEmpty) return;
    await _lock.acquire();
    try {
      final tree = _prefs.folderExportTreeUri;
      final snapshot = _ledger();
      for (final r in delivered) {
        final key = r.id;
        final copy = key == null ? null : snapshot[key];
        if (key == null || copy == null || copy.gone) continue;
        final startMs = r.startTime.millisecondsSinceEpoch;
        if (copy.startMs == startMs) continue;
        // The copy's own extension, not the recording's: a copy made before its recording was
        // converted to M4A still holds WAV audio.
        final name = exportNameFor(r, ext: copy.name.split('.').last);
        _FolderCopy renamed;
        try {
          renamed = _FolderCopy(uri: await _backend.rename(tree, copy.uri, name), name: name, startMs: startMs);
        } on FolderExportException catch (e) {
          if (e.kind == FolderExportError.noAccess) break; // the next sweep tries again
          if (e.kind == FolderExportError.unsupported) {
            // The folder cannot rename at all, so asking again every sweep would only fail
            // again. The copy keeps its name; the new start is recorded so this is not retried.
            Logger.debug('Save to Folder: this folder cannot rename files — ${copy.name} keeps its name');
            renamed = _FolderCopy(uri: copy.uri, name: copy.name, startMs: startMs);
          } else if (e.kind == FolderExportError.gone) {
            renamed = _FolderCopy(uri: copy.uri, name: name, startMs: startMs, gone: true);
          } else {
            Logger.error('Save to Folder: could not rename ${copy.name} to $name: $e');
            continue;
          }
        }
        // Re-read after the await: a delete may have forgotten this recording meanwhile, and
        // writing the snapshot back would bring it back.
        final ledger = _readLedger();
        if (!ledger.containsKey(key)) continue;
        ledger[key] = renamed;
        _writeLedger(ledger);
      }
    } catch (e) {
      Logger.error('Save to Folder: reconcile failed: $e');
    } finally {
      _lock.release();
    }
  }

  @override
  Future<void> forget(List<IntegrationRecording> deleted) async => forgetCopiesOf(deleted);

  /// Forgets the copies of [recordings], which have been deleted from the phone. The copies
  /// themselves stay in the folder: once saved there, they are the user's. This only keeps
  /// the ledger from growing with recordings that no longer exist.
  ///
  /// Synchronous and lock-free, so a delete never waits on a long copy. A copy of one of
  /// these still being written records itself afterwards and stays as a stale entry, which
  /// costs nothing but its bytes.
  void forgetCopiesOf(Iterable<IntegrationRecording> recordings) {
    final keys = recordings.map((r) => r.id).whereType<String>().toSet();
    final ledger = _readLedger();
    final before = ledger.length;
    ledger.removeWhere((key, _) => keys.contains(key));
    if (ledger.length != before) _writeLedger(ledger);
  }

  /// Deliberately keeps the ledger. The copies are the user's files; forgetting them would
  /// only make a re-processed recording land in the folder a second time.
  @override
  Future<void> forgetDeliveryHistory() async {}

  /// Makes [folder] the export folder. A different folder starts fresh: copies already in
  /// the old one stay there, untouched, and access to it is given back. Choosing the same
  /// folder again keeps everything.
  Future<void> useFolder(PickedFolder folder) async {
    await _lock.acquire();
    try {
      final old = _prefs.folderExportTreeUri;
      if (old != folder.treeUri) {
        if (old.isNotEmpty) await _releaseQuietly(old);
        _prefs.folderExportLedger = '';
        await _prefs.clearAllAutoUploadRetries(keyPrefix: 'folder_');
      }
      _prefs.folderExportTreeUri = folder.treeUri;
      _prefs.folderExportLabel = folder.label;
      _prefs.folderExportEnabled = true;
      _unavailableUntil = null;
    } finally {
      _lock.release();
    }
  }

  /// Forgets the export folder. Copies already in it stay there.
  Future<void> removeFolder() async {
    await _lock.acquire();
    try {
      final old = _prefs.folderExportTreeUri;
      if (old.isNotEmpty) await _releaseQuietly(old);
      _prefs.folderExportTreeUri = '';
      _prefs.folderExportLabel = '';
      _prefs.folderExportEnabled = false;
      _prefs.folderExportLedger = '';
      await _prefs.clearAllAutoUploadRetries(keyPrefix: 'folder_');
      _unavailableUntil = null;
    } finally {
      _lock.release();
    }
  }

  Future<void> _releaseQuietly(String treeUri) async {
    try {
      await _backend.releaseFolder(treeUri);
    } catch (e) {
      Logger.error('Save to Folder: could not release access to the old folder: $e');
    }
  }
}
