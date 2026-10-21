import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/audio/recording_cropper.dart';
import 'package:omi/pages/recordings/recording_player_page.dart';
import 'package:omi/pages/recordings/recordings_controller.dart';
import 'package:omi/pages/recordings/recording_crop_selector.dart';
import 'package:omi/utils/other/time_utils.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:omi/pages/recordings/waveform_utils.dart';

class MarkerConversationPlayerPage extends StatefulWidget {
  final MarkerConversation? markerConversation;
  final Conversation? conversation;
  final RecordingsController controller;

  const MarkerConversationPlayerPage({super.key, required this.markerConversation, required this.controller})
      : conversation = null;

  const MarkerConversationPlayerPage.forRecording({super.key, required this.conversation, required this.controller})
      : markerConversation = null;

  @override
  State<MarkerConversationPlayerPage> createState() => _MarkerConversationPlayerPageState();
}

class _MarkerConversationPlayerPageState extends State<MarkerConversationPlayerPage> {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _playerStateSub;

  File? _segment;
  Conversation? _sourceConversation;
  late Duration _markerOffset;
  late Duration _cropStart;
  late Duration _cropEnd;
  Duration _totalDuration = Duration.zero;

  List<double> _waveform = [];
  bool _loadingWaveform = true;
  bool _loadingAudio = true;
  bool _isExporting = false;
  bool _isSaving = false;

  Duration _position = Duration.zero;
  bool _isPlaying = false;
  bool _preparingPlayback = false;
  Duration _playbackStart = Duration.zero;
  Duration _playbackEnd = Duration.zero;
  String? _playbackPath;

  late bool _userSaved;
  bool _isCropMode = false;

  @override
  void initState() {
    super.initState();
    // Pending markers can legitimately reach this page (e.g. deep links or
    // future entry points); guard against a null segment and fall back to a
    // read-only "no audio yet" state instead of crashing (B11).
    _segment = widget.conversation?.file ?? widget.markerConversation?.segment;
    // Capture the stable metadata identity while the original path still
    // exists. Parsing a missing marker segment at save time loses that key.
    _sourceConversation = widget.conversation ?? (_segment == null ? null : Conversation.fromFile(_segment!));
    _markerOffset = Duration(milliseconds: widget.markerConversation?.markerOffsetMs ?? 0);
    _cropStart = Duration(milliseconds: widget.markerConversation?.cropStartMs ?? 0);
    _cropEnd = Duration(milliseconds: widget.markerConversation?.cropEndMs ?? 0);
    _userSaved = widget.markerConversation?.userSaved ?? false;
    _isCropMode = widget.conversation != null;
    if (_segment == null) {
      _loadingAudio = false;
      _loadingWaveform = false;
      return;
    }
    _init();
  }

  Future<void> _init() async {
    if (_segment == null) return;
    try {
      final seg = await _resolveSource();
      if (!mounted) return;
      await Future.wait([_loadWaveform(seg), _setupAudio(seg)]);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingAudio = false;
        _loadingWaveform = false;
      });
      _showPlaybackError();
    }
  }

  Future<File> _resolveSource() async {
    final source = await widget.controller.resolveConversation(_sourceConversation!);
    _sourceConversation = source;
    return _segment = source.file;
  }

  // ── Waveform ───────────────────────────────────────────────────────────────

  Future<void> _loadWaveform(File seg) async {
    final bars = _readMetaWaveform(seg);
    if (mounted) {
      setState(() {
        _waveform = bars;
        _loadingWaveform = false;
      });
    }
  }

  List<double> _readMetaWaveform(File seg) {
    try {
      final base = seg.path.substring(0, seg.path.lastIndexOf('.'));
      final meta = File('$base.meta');
      if (!meta.existsSync()) return List.filled(200, 0.05);
      final bytes = meta.readAsBytesSync();
      if (bytes.length < 408) return List.filled(200, 0.05);
      final bd = ByteData.sublistView(bytes);
      final raw = List.generate(200, (i) => bd.getUint16(8 + i * 2, Endian.little) / 65535.0);
      return normalizeAmplitudes(raw);
    } catch (_) {
      return List.filled(200, 0.05);
    }
  }

  // ── Audio setup ────────────────────────────────────────────────────────────

  Future<void> _setupAudio(File seg) async {
    await _player.setAudioSource(AudioSource.file(seg.path), initialPosition: _cropStart);

    _totalDuration = _player.duration ?? Duration(milliseconds: _readSegmentDurationMs(seg));
    if (_cropEnd <= Duration.zero || _cropEnd > _totalDuration) _cropEnd = _totalDuration;
    if (_cropStart < Duration.zero || _cropStart >= _cropEnd) _cropStart = Duration.zero;
    if (!mounted) return;
    await _applyPlaybackRange();
    if (!mounted) return;
    final initialPosition = _markerOffset >= _cropStart && _markerOffset < _cropEnd ? _markerOffset : _cropStart;
    await _player.seek(initialPosition - _playbackStart);
    if (!mounted) return;
    setState(() {
      _position = initialPosition;
      _loadingAudio = false;
    });

    _positionSub = _player.positionStream.listen((pos) {
      if (mounted && !_preparingPlayback) {
        setState(() => _position = _boundPosition(_playbackStart + pos));
      }
    });
    _playerStateSub = _player.playerStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state.playing && state.processingState != ProcessingState.completed;
          if (state.processingState == ProcessingState.completed) _position = _cropEnd;
        });
      }
      // just_audio keeps playing=true after completion. Pause so a later seek
      // cannot unexpectedly restart the preview.
      if (state.playing && state.processingState == ProcessingState.completed) unawaited(_player.pause());
    });
  }

  int _readSegmentDurationMs(File seg) {
    try {
      final base = seg.path.substring(0, seg.path.lastIndexOf('.'));
      final meta = File('$base.meta');
      if (!meta.existsSync()) return 0;
      final bytes = meta.readAsBytesSync();
      if (bytes.length < 8) return 0;
      return ByteData.sublistView(bytes).getUint32(4, Endian.little);
    } catch (_) {
      return 0;
    }
  }

  Future<void> _saveEdl() async {
    final originalMarker = widget.markerConversation;
    if (originalMarker == null) return;
    final seg = await _resolveSource();
    var marker = originalMarker;
    if (!await marker.edlFile.exists()) {
      // Date correction moves the EDL as well as its audio. The controller
      // reloaded after the crop save, so find the marker at its new location.
      final matches = widget.controller.markerConversations
          .where((m) => m.segment?.path == seg.path && m.markerOffsetMs == originalMarker.markerOffsetMs);
      if (matches.isEmpty) throw FileSystemException('Marker is no longer available.', marker.edlFile.path);
      marker = matches.first;
    }
    Map<String, dynamic> existing = {};
    if (await marker.edlFile.exists()) {
      try {
        final decoded = jsonDecode(await marker.edlFile.readAsString());
        if (decoded is Map<String, dynamic>) existing = decoded;
      } on FormatException {
        // Saving can repair an old malformed EDL, just as it can create a missing one.
      }
    }
    final edlData = {
      ...existing,
      'markerTimestampMs': marker.markerTime.millisecondsSinceEpoch,
      'segmentFilename': seg.uri.pathSegments.last,
      'markerOffsetMs': _markerOffset.inMilliseconds,
      'cropStartMs': _cropStart.inMilliseconds,
      'cropEndMs': _cropEnd.inMilliseconds,
      'userSaved': true,
      // Keep the marker's priority when remembering the selected crop range.
      'isHighPriority': marker.isHighPriority,
    };
    // Atomic (tmp + rename) so a concurrent getMarkerConversations() refresh
    // never reads a half-written EDL, and an app kill mid-save can't corrupt it.
    await RecordingsManager.writeJsonAtomic(marker.edlFile, edlData);
  }

  // ── Save ───────────────────────────────────────────────────────────────────

  /// Pulls the epoch-ms timestamp from a recording filename, tolerating both
  /// `recording_<ts>.<ext>` and `recording_<ts>_draft.<ext>` shapes (and any
  /// future trailing segment) by scanning components for the first plausible
  /// numeric epoch (B12).
  int _extractTimestampMsFromFilename(String filename) {
    final nameNoExt = filename.contains('.') ? filename.substring(0, filename.lastIndexOf('.')) : filename;
    for (final part in nameNoExt.split('_')) {
      final n = int.tryParse(part);
      if (n != null && n > 946684800000) return n;
    }
    return 0;
  }

  String get _liveTimeRangeLabel {
    final seg = _segment;
    if (seg == null) {
      // Orphan / pending marker: anchor the range label on the marker tap itself.
      final m = widget.markerConversation!.markerTime;
      return '${fmtHourMin(m)} – ${fmtHourMin(m)}';
    }
    final firstMs = _extractTimestampMsFromFilename(seg.uri.pathSegments.last);
    final origin = DateTime.fromMillisecondsSinceEpoch(firstMs);
    return '${fmtHourMin(origin.add(_cropStart))} – ${fmtHourMin(origin.add(_cropEnd))}';
  }

  Future<void> _saveConversation() async {
    final seg = _segment;
    if (seg == null || _isSaving || _loadingAudio || _preparingPlayback) return;
    setState(() => _isSaving = true);
    try {
      await _player.pause();
      final saved = await widget.controller.saveCroppedConversation(_sourceConversation!, _cropStart, _cropEnd);
      var rememberedRange = true;
      try {
        await _saveEdl();
      } catch (_) {
        // The audio copy is already saved; a marker-settings failure must not
        // report that the recording itself failed to save.
        rememberedRange = false;
      }
      if (!mounted) return;
      setState(() {
        _userSaved = true;
        _isCropMode = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          rememberedRange
              ? 'Cropped copy saved to Conversations'
              : 'Cropped copy saved. Could not remember the marker range.',
          style: const TextStyle(color: Colors.white),
        ),
        duration: const Duration(seconds: 5),
        backgroundColor: const Color(0xFF303030),
        action: SnackBarAction(
          label: 'Open',
          textColor: Colors.white,
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ConversationPlayerPage(conversation: saved, controller: widget.controller),
          )),
        ),
      ));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Could not save the cropped recording. Please try again.', style: TextStyle(color: Colors.white)),
          backgroundColor: Color(0xFF303030),
        ));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _toggleCropMode() {
    if (_isCropMode) {
      _saveConversation();
    } else {
      setState(() {
        _isCropMode = true;
      });
    }
  }

  Future<void> _exportConversation() async {
    final seg = _segment;
    if (seg == null || _isExporting) return;
    setState(() => _isExporting = true);

    try {
      final current = await _resolveSource();
      final dir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final output = File('${dir.path}/export_$timestamp.wav');
      await RecordingCropper.crop(current, output, _cropStart, _cropEnd);
      await SharePlus.instance.share(ShareParams(files: [XFile(output.path)], subject: 'Conversation Export'));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  // ── Playback controls ──────────────────────────────────────────────────────

  bool get _canControlPlayback => !_loadingAudio && !_isSaving && !_preparingPlayback && _totalDuration > Duration.zero;

  Duration _boundPosition(Duration position) =>
      position < _cropStart ? _cropStart : (position > _cropEnd ? _cropEnd : position);

  Future<void> _applyPlaybackRange() async {
    final seg = await _resolveSource();
    if (_playbackStart == _cropStart && _playbackEnd == _cropEnd && _playbackPath == seg.path) return;
    await _player.pause();
    if (!mounted) return;
    _playbackStart = _cropStart;
    _playbackEnd = _cropEnd;
    _playbackPath = seg.path;
    // Native clipping enforces the end without relying on position polling.
    // Positions in the clipped source are relative to the selection's start.
    await _player.setAudioSource(
      ClippingAudioSource(child: AudioSource.file(seg.path), start: _playbackStart, end: _playbackEnd),
      initialPosition: Duration.zero,
    );
  }

  void _showPlaybackError() {
    _playbackEnd = Duration.zero; // Force the range to reload on retry.
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Could not play the crop preview. Please try again.', style: TextStyle(color: Colors.white)),
      backgroundColor: Color(0xFF303030),
    ));
  }

  void _changeCropRange(Duration start, Duration end) {
    if (!_canControlPlayback || (start == _cropStart && end == _cropEnd)) return;
    unawaited(_player.pause());
    setState(() {
      _cropStart = start;
      _cropEnd = end;
      _isPlaying = false;
      _position = _boundPosition(_position);
    });
  }

  Future<void> _togglePlay() async {
    if (!_canControlPlayback) return;
    setState(() => _preparingPlayback = true);
    try {
      if (_isPlaying) {
        await _player.pause();
      } else {
        await _applyPlaybackRange();
        if (!mounted) return;
        // Each crop preview starts at the selected start, even if the playhead
        // was left at a marker or the preview was paused midway through.
        final start = _isCropMode || _position < _cropStart || _position >= _cropEnd ? _cropStart : _position;
        await _player.seek(start - _playbackStart);
        if (!mounted) return;
        setState(() => _position = start);
        unawaited(_player.play().catchError((Object _) => _showPlaybackError()));
      }
    } catch (_) {
      _showPlaybackError();
    } finally {
      if (mounted) setState(() => _preparingPlayback = false);
    }
  }

  Future<void> _seekTo(Duration target) async {
    if (!_canControlPlayback) return;
    setState(() => _preparingPlayback = true);
    try {
      await _applyPlaybackRange();
      if (!mounted) return;
      final position = _boundPosition(target);
      await _player.seek(position - _playbackStart);
      if (mounted) setState(() => _position = position);
    } catch (_) {
      _showPlaybackError();
    } finally {
      if (mounted) setState(() => _preparingPlayback = false);
    }
  }

  Future<void> _seekRelative(int seconds) => _seekTo(_position + Duration(seconds: seconds));

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ── Dispose ────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _positionSub?.cancel();
    _playerStateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final totalMs = _totalDuration.inMilliseconds;
    final progressRatio = totalMs > 0 ? (_position.inMilliseconds / totalMs).clamp(0.0, 1.0) : 0.0;
    final visibleStartRatio = totalMs > 0 ? (_cropStart.inMilliseconds / totalMs).clamp(0.0, 1.0) : 0.0;
    final visibleEndRatio = totalMs > 0 ? (_cropEnd.inMilliseconds / totalMs).clamp(0.0, 1.0) : 1.0;
    final markerOffsetRatio = totalMs > 0 ? (_markerOffset.inMilliseconds / totalMs).clamp(0.0, 1.0) : 0.0;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        // Discard changes logic: we just don't call _saveEdl()
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0D0D0D),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0D0D0D),
          foregroundColor: Colors.white,
          elevation: 0,
          title: Text(
            widget.markerConversation == null
                ? 'Crop recording'
                : 'Marker at ${widget.markerConversation!.markerTimeLabel}',
            style: const TextStyle(color: Colors.white, fontSize: 18),
          ),
          actions: [
            if (_isExporting || _isSaving)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                ),
              ),
            if (widget.markerConversation != null)
              IconButton(
                icon: const FaIcon(FontAwesomeIcons.trashCan, color: Colors.redAccent, size: 20),
                tooltip: 'Delete marker',
                onPressed: _isSaving || _preparingPlayback
                    ? null
                    : () async {
                        bool? confirm = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            backgroundColor: Colors.grey.shade900,
                            title: const Text('Delete Marker', style: TextStyle(color: Colors.white)),
                            content: const Text('This will permanently delete this marker.',
                                style: TextStyle(color: Colors.white70)),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(c).pop(false),
                                child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
                              ),
                              TextButton(
                                onPressed: () => Navigator.of(c).pop(true),
                                child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
                              ),
                            ],
                          ),
                        );
                        if (confirm == true) {
                          await _player.stop();
                          await RecordingsManager.deleteMarkerConversation(widget.markerConversation!);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text('Deleted Marker at ${widget.markerConversation!.markerTimeLabel}')),
                            );
                            Navigator.of(context).pop();
                          }
                        }
                      },
              ),
            // Hide Export and Crop buttons when there's no audio attached —
            // tapping them was a no-op that misleadingly flipped _userSaved
            // in memory without persisting anything (E6).
            if (_segment != null)
              IconButton(
                icon: const FaIcon(FontAwesomeIcons.shareFromSquare, size: 20, color: Colors.white),
                onPressed: !_canControlPlayback ? null : _exportConversation,
                tooltip: 'Export',
              ),
            if (_segment != null)
              IconButton(
                icon: FaIcon(
                  _isCropMode
                      ? FontAwesomeIcons.floppyDisk
                      : (_userSaved ? FontAwesomeIcons.circleCheck : FontAwesomeIcons.scissors),
                  size: 20,
                  color: _isCropMode ? Colors.amber : (_userSaved ? Colors.green : Colors.white),
                ),
                onPressed: !_canControlPlayback ? null : _toggleCropMode,
                tooltip: _isCropMode ? 'Save cropped copy' : (_userSaved ? 'Edit crop' : 'Crop'),
              ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: _segment == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const FaIcon(FontAwesomeIcons.solidBookmark, color: Colors.amber, size: 32),
                        const SizedBox(height: 16),
                        Text(
                          'Marker recorded at ${widget.markerConversation!.markerTimeLabel}',
                          style: const TextStyle(color: Colors.white, fontSize: 16),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'No audio is attached to this marker. The surrounding audio was either silence or has not yet been processed.',
                          style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : _loadingAudio
                  ? const Center(child: CircularProgressIndicator(color: Colors.deepPurpleAccent))
                  : SingleChildScrollView(
                      child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // Time range label (live — updates during crop drag)
                              Text(
                                _liveTimeRangeLabel,
                                style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                              ),
                              if (_isCropMode) ...[
                                const SizedBox(height: 12),
                                const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 24),
                                  child: Text(
                                      'Drag Start and End, or tap a time for precision. Saved copies are priority recordings.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: Colors.white70, fontSize: 12)),
                                ),
                              ],
                              const SizedBox(height: 32),

                              // Waveform and crop controls
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                child: _loadingWaveform
                                    ? const SizedBox(
                                        height: 140,
                                        child: Center(
                                            child: CircularProgressIndicator(
                                                color: Colors.deepPurpleAccent, strokeWidth: 2)))
                                    : RecordingCropSelector(
                                        total: _totalDuration,
                                        start: _cropStart,
                                        end: _cropEnd,
                                        cropping: _isCropMode,
                                        enabled: _canControlPlayback,
                                        onChanged: _changeCropRange,
                                        onSeek: _seekTo,
                                        waveformBuilder: (width) => CustomPaint(
                                          key: const ValueKey('recording-crop-waveform'),
                                          painter: _MarkerWaveformPainter(
                                            amplitudes: _waveform,
                                            progress: progressRatio,
                                            visibleStartRatio: visibleStartRatio,
                                            visibleEndRatio: visibleEndRatio,
                                            markerRatio: widget.markerConversation == null ? null : markerOffsetRatio,
                                            isCropMode: _isCropMode,
                                          ),
                                          size: Size(width, 100),
                                        ),
                                      ),
                              ),
                              const SizedBox(height: 12),

                              // Time labels
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 24),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(_fmt(_position), style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                                    Text(_fmt(_totalDuration),
                                        style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 4),

                              // Progress slider
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                    trackHeight: 3,
                                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                                    activeTrackColor: Colors.deepPurpleAccent,
                                    inactiveTrackColor: Colors.grey.shade800,
                                    thumbColor: Colors.deepPurpleAccent,
                                    overlayColor: Colors.deepPurpleAccent.withValues(alpha: 0.2),
                                  ),
                                  child: Slider(
                                    value: progressRatio,
                                    onChanged: _canControlPlayback
                                        ? (v) => _seekTo(Duration(milliseconds: (v * totalMs).round()))
                                        : null,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 24),

                              // Transport controls
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _SeekBtn(
                                      icon: FontAwesomeIcons.rotateLeft,
                                      seconds: 30,
                                      isForward: false,
                                      onTap: _canControlPlayback ? () => _seekRelative(-30) : null),
                                  const SizedBox(width: 40),
                                  Semantics(
                                    button: true,
                                    label: _isPlaying ? 'Pause' : 'Play',
                                    child: Tooltip(
                                      message: _isPlaying ? 'Pause' : 'Play',
                                      child: Material(
                                        color: Colors.deepPurpleAccent,
                                        shape: const CircleBorder(),
                                        clipBehavior: Clip.antiAlias,
                                        child: InkWell(
                                          onTap: _canControlPlayback ? _togglePlay : null,
                                          child: SizedBox(
                                            width: 72,
                                            height: 72,
                                            child: Center(
                                              child: FaIcon(
                                                _isPlaying ? FontAwesomeIcons.pause : FontAwesomeIcons.play,
                                                color: Colors.white,
                                                size: 26,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 40),
                                  _SeekBtn(
                                      icon: FontAwesomeIcons.rotateRight,
                                      seconds: 30,
                                      isForward: true,
                                      onTap: _canControlPlayback ? () => _seekRelative(30) : null),
                                ],
                              ),
                              const SizedBox(height: 32),
                            ],
                          )),
                    ),
        ),
      ),
    );
  }
}

// ── Waveform painter ──────────────────────────────────────────────────────────

class _MarkerWaveformPainter extends CustomPainter {
  final List<double> amplitudes;
  final double progress;
  final double visibleStartRatio;
  final double visibleEndRatio;
  final double? markerRatio;
  final bool isCropMode;

  const _MarkerWaveformPainter({
    required this.amplitudes,
    required this.progress,
    required this.visibleStartRatio,
    required this.visibleEndRatio,
    required this.markerRatio,
    required this.isCropMode,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (amplitudes.isEmpty) return;

    final barCount = amplitudes.length;
    final spacing = size.width / barCount;
    final barWidth = spacing * 0.55;
    final playedUpTo = (progress * barCount).floor();
    final visStartBar = (visibleStartRatio * barCount).floor();
    final visEndBar = (visibleEndRatio * barCount).ceil();

    final playedInWindow = Paint()
      ..color = Colors.deepPurpleAccent
      ..strokeCap = StrokeCap.round;
    final unplayedInWindow = Paint()
      ..color = const Color(0xFF8E8E93)
      ..strokeCap = StrokeCap.round;
    final outsideWindow = Paint()
      ..color = const Color(0xFF232323)
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < barCount; i++) {
      final x = i * spacing + spacing / 2;
      final amplitude = amplitudes[i].clamp(0.04, 1.0);
      final barHeight = amplitude * size.height;
      final top = (size.height - barHeight) / 2;

      final inWindow = !isCropMode || (i >= visStartBar && i < visEndBar);
      final Paint paint;
      if (!inWindow) {
        paint = outsideWindow;
      } else if (i < playedUpTo) {
        paint = playedInWindow;
      } else {
        paint = unplayedInWindow;
      }
      paint.strokeWidth = barWidth;
      canvas.drawLine(Offset(x, top), Offset(x, top + barHeight), paint);
    }

    // Marker position line (amber)
    if (markerRatio != null) {
      final markerX = markerRatio! * size.width;
      canvas.drawLine(
        Offset(markerX, 0),
        Offset(markerX, size.height),
        Paint()
          ..color = Colors.amber
          ..strokeWidth = 2,
      );
    }

    if (isCropMode) {
      _drawHandle(canvas, size, visibleStartRatio * size.width, Colors.amber);
      _drawHandle(canvas, size, visibleEndRatio * size.width, Colors.lightBlueAccent);
    }
  }

  void _drawHandle(Canvas canvas, Size size, double x, Color color) {
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()
        ..color = color
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_MarkerWaveformPainter old) =>
      old.progress != progress ||
      old.amplitudes != amplitudes ||
      old.visibleStartRatio != visibleStartRatio ||
      old.visibleEndRatio != visibleEndRatio ||
      old.isCropMode != isCropMode;
}

// ── Seek button ───────────────────────────────────────────────────────────────

class _SeekBtn extends StatelessWidget {
  final IconData icon;
  final int seconds;
  final bool isForward;
  final VoidCallback? onTap;

  const _SeekBtn({required this.icon, required this.seconds, required this.isForward, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final label = 'Seek ${isForward ? 'forward' : 'backward'} ${seconds.abs()} seconds';
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FaIcon(icon, color: Colors.grey.shade300, size: 32),
                  const SizedBox(height: 5),
                  Text('${seconds}s',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 11, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
