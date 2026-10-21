import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A crop range with real, finger-sized handles and separate precision controls.
class RecordingCropSelector extends StatefulWidget {
  final Duration total;
  final Duration start;
  final Duration end;
  final bool cropping;
  final bool enabled;
  final Widget Function(double width) waveformBuilder;
  final void Function(Duration start, Duration end) onChanged;
  final ValueChanged<Duration> onSeek;

  const RecordingCropSelector({
    super.key,
    required this.total,
    required this.start,
    required this.end,
    required this.waveformBuilder,
    required this.onChanged,
    required this.onSeek,
    this.cropping = true,
    this.enabled = true,
  });

  @override
  State<RecordingCropSelector> createState() => _RecordingCropSelectorState();
}

class _RecordingCropSelectorState extends State<RecordingCropSelector> {
  static const _step = Duration(seconds: 1);
  static const _inset = 24.0;

  int get _minimumMs => widget.total.inMilliseconds.clamp(0, 100);
  int get _startMax => widget.end.inMilliseconds - _minimumMs;
  int get _endMin => widget.start.inMilliseconds + _minimumMs;

  Duration _changeStart(Duration value) {
    final bounded = Duration(milliseconds: value.inMilliseconds.clamp(0, _startMax));
    widget.onChanged(bounded, widget.end);
    return bounded;
  }

  Duration _changeEnd(Duration value) {
    final bounded = Duration(milliseconds: value.inMilliseconds.clamp(_endMin, widget.total.inMilliseconds));
    widget.onChanged(widget.start, bounded);
    return bounded;
  }

  String _format(Duration value) {
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
    final base = widget.total.inHours > 0 ? '${value.inHours}:$minutes:$seconds' : '${value.inMinutes}:$seconds';
    final millis = value.inMilliseconds % 1000;
    return millis == 0 ? base : '$base.${millis.toString().padLeft(3, '0')}';
  }

  Duration? _parse(String text) {
    final parts = text.trim().split(':');
    if (parts.isEmpty || parts.length > 3) return null;
    final seconds = double.tryParse(parts.last);
    if (seconds == null || !seconds.isFinite || seconds < 0 || (parts.length > 1 && seconds >= 60)) return null;
    final minutes = parts.length > 1 ? int.tryParse(parts[parts.length - 2]) : 0;
    final hours = parts.length > 2 ? int.tryParse(parts.first) : 0;
    if (minutes == null || hours == null || minutes < 0 || hours < 0 || (parts.length == 3 && minutes >= 60)) {
      return null;
    }
    final totalSeconds = hours * 3600.0 + minutes * 60.0 + seconds;
    if (!totalSeconds.isFinite || totalSeconds > widget.total.inMilliseconds / 1000) return null;
    return Duration(milliseconds: (totalSeconds * 1000).round());
  }

  Future<void> _editTime(bool start) async {
    final result = await showDialog<Duration>(
      context: context,
      builder: (_) => _CropTimeDialog(
        start: start,
        value: start ? widget.start : widget.end,
        minimum: start ? 0 : _endMin,
        maximum: start ? _startMax : widget.total.inMilliseconds,
        parse: _parse,
        format: _format,
      ),
    );
    if (result != null && mounted) (start ? _changeStart : _changeEnd)(result);
  }

  Widget _timeControl(bool start) {
    final value = start ? widget.start : widget.end;
    final change = start ? _changeStart : _changeEnd;
    final color = start ? Colors.amber : Colors.lightBlueAccent;
    final label = start ? 'start' : 'end';
    final canDecrease = value.inMilliseconds > (start ? 0 : _endMin);
    final canIncrease = value.inMilliseconds < (start ? _startMax : widget.total.inMilliseconds);
    final time = Expanded(
      child: TextButton(
        key: ValueKey('crop-$label-time'),
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: widget.enabled ? () => _editTime(start) : null,
        child: Semantics(
          label: 'Edit crop $label time',
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(child: Text(_format(value), style: const TextStyle(color: Colors.white, fontSize: 15))),
            const SizedBox(width: 6),
            const Icon(Icons.edit_outlined, size: 16, color: Colors.white54),
          ]),
        ),
      ),
    );
    final decrease = TextButton(
      key: ValueKey('crop-$label-decrease'),
      style: TextButton.styleFrom(
          minimumSize: const Size(56, 48), foregroundColor: color, disabledForegroundColor: Colors.white24),
      onPressed: widget.enabled && canDecrease ? () => change(value - _step) : null,
      child: Semantics(label: 'Move crop $label back one second', child: const Text('−1s')),
    );
    final increase = TextButton(
      key: ValueKey('crop-$label-increase'),
      style: TextButton.styleFrom(
          minimumSize: const Size(56, 48), foregroundColor: color, disabledForegroundColor: Colors.white24),
      onPressed: widget.enabled && canIncrease ? () => change(value + _step) : null,
      child: Semantics(label: 'Move crop $label forward one second', child: const Text('+1s')),
    );
    final labelAndTime = [
      Text(start ? 'Start' : 'End', style: TextStyle(color: color, fontWeight: FontWeight.w600)),
      const SizedBox(width: 8),
      time,
    ];
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(12)),
      child: LayoutBuilder(builder: (context, constraints) {
        final stacked = constraints.maxWidth < 300 || MediaQuery.textScalerOf(context).scale(14) > 18;
        if (stacked) {
          return Column(children: [
            Row(children: labelAndTime),
            Row(children: [Expanded(child: decrease), const SizedBox(width: 8), Expanded(child: increase)]),
          ]);
        }
        return Row(children: [...labelAndTime, decrease, increase]);
      }),
    );
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        LayoutBuilder(builder: (context, constraints) {
          final width = constraints.maxWidth - _inset * 2;
          final totalMs = widget.total.inMilliseconds;
          double x(Duration time) => _inset + (totalMs > 0 ? time.inMilliseconds / totalMs : 0) * width;
          final splitHandles = x(widget.end) - x(widget.start) < 48;
          return SizedBox(
            height: 140,
            child: AbsorbPointer(
              absorbing: !widget.enabled,
              child: Stack(children: [
                Positioned(
                  left: _inset,
                  right: _inset,
                  top: 20,
                  height: 100,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) => widget.onSeek(
                        Duration(milliseconds: (details.localPosition.dx / width * totalMs).round().clamp(0, totalMs))),
                    onHorizontalDragUpdate: (details) => widget.onSeek(
                        Duration(milliseconds: (details.localPosition.dx / width * totalMs).round().clamp(0, totalMs))),
                    child: widget.waveformBuilder(width),
                  ),
                ),
                if (widget.cropping) ...[
                  Positioned(
                    left: x(widget.start) - 24,
                    top: 0,
                    bottom: splitHandles ? 70 : 0,
                    child: _CropHandle(
                      key: const ValueKey('crop-start-handle'),
                      start: true,
                      value: widget.start,
                      label: _format(widget.start),
                      total: widget.total,
                      width: width,
                      onChanged: _changeStart,
                      enabled: widget.enabled,
                      minimum: 0,
                      maximum: _startMax,
                      format: _format,
                      compact: splitHandles,
                    ),
                  ),
                  Positioned(
                    left: x(widget.end) - 24,
                    top: splitHandles ? 70 : 0,
                    bottom: 0,
                    child: _CropHandle(
                      key: const ValueKey('crop-end-handle'),
                      start: false,
                      value: widget.end,
                      label: _format(widget.end),
                      total: widget.total,
                      width: width,
                      onChanged: _changeEnd,
                      enabled: widget.enabled,
                      minimum: _endMin,
                      maximum: widget.total.inMilliseconds,
                      format: _format,
                      compact: splitHandles,
                    ),
                  ),
                ],
              ]),
            ),
          );
        }),
        if (widget.cropping) ...[
          _timeControl(true),
          _timeControl(false),
          const SizedBox(height: 12),
          Text('Selected ${_format(widget.end - widget.start)}', style: const TextStyle(color: Colors.white70)),
        ],
      ]);
}

class _CropTimeDialog extends StatefulWidget {
  final bool start;
  final Duration value;
  final int minimum;
  final int maximum;
  final Duration? Function(String) parse;
  final String Function(Duration) format;

  const _CropTimeDialog(
      {required this.start,
      required this.value,
      required this.minimum,
      required this.maximum,
      required this.parse,
      required this.format});

  @override
  State<_CropTimeDialog> createState() => _CropTimeDialogState();
}

class _CropTimeDialogState extends State<_CropTimeDialog> {
  late final TextEditingController _input = TextEditingController(text: widget.format(widget.value));
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: const Color(0xFF202020),
        title: Text(widget.start ? 'Set crop start' : 'Set crop end', style: const TextStyle(color: Colors.white)),
        content: TextField(
          controller: _input,
          autofocus: true,
          keyboardType: TextInputType.datetime,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            labelText: 'Time',
            labelStyle: const TextStyle(color: Colors.white70),
            helperText: 'mm:ss or hh:mm:ss, e.g. 02:15.5',
            helperStyle: const TextStyle(color: Colors.white70),
            errorText: _error,
            errorStyle: const TextStyle(color: Colors.redAccent),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel', style: TextStyle(color: Colors.white70))),
          TextButton(
            onPressed: () {
              final value = widget.parse(_input.text);
              if (value == null || value.inMilliseconds < widget.minimum || value.inMilliseconds > widget.maximum) {
                setState(() => _error = 'Choose a time from ${widget.format(Duration(milliseconds: widget.minimum))} '
                    'to ${widget.format(Duration(milliseconds: widget.maximum))}.');
                return;
              }
              Navigator.of(context).pop(value);
            },
            child: const Text('Set', style: TextStyle(color: Colors.amber)),
          ),
        ],
      );
}

class _CropHandle extends StatefulWidget {
  final bool start;
  final Duration value;
  final String label;
  final Duration total;
  final double width;
  final Duration Function(Duration) onChanged;
  final bool enabled;
  final int minimum;
  final int maximum;
  final String Function(Duration) format;
  final bool compact;

  const _CropHandle(
      {super.key,
      required this.start,
      required this.value,
      required this.label,
      required this.total,
      required this.width,
      required this.onChanged,
      required this.enabled,
      required this.minimum,
      required this.maximum,
      required this.format,
      required this.compact});

  @override
  State<_CropHandle> createState() => _CropHandleState();
}

class _CropHandleState extends State<_CropHandle> {
  bool _dragging = false;
  double _dragMs = 0;

  bool get _canIncrease => widget.enabled && widget.value.inMilliseconds < widget.maximum;
  bool get _canDecrease => widget.enabled && widget.value.inMilliseconds > widget.minimum;
  Duration _shift(int milliseconds) =>
      Duration(milliseconds: (widget.value.inMilliseconds + milliseconds).clamp(widget.minimum, widget.maximum));

  @override
  Widget build(BuildContext context) => Semantics(
        slider: true,
        label: widget.start ? 'Crop start handle' : 'Crop end handle',
        value: widget.label,
        increasedValue: _canIncrease ? widget.format(_shift(1000)) : null,
        decreasedValue: _canDecrease ? widget.format(_shift(-1000)) : null,
        onIncrease: _canIncrease ? () => widget.onChanged(_shift(1000)) : null,
        onDecrease: _canDecrease ? () => widget.onChanged(_shift(-1000)) : null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onHorizontalDragDown: (_) => _dragMs = widget.value.inMilliseconds.toDouble(),
          onHorizontalDragStart: (_) => setState(() => _dragging = true),
          onHorizontalDragUpdate: (details) {
            _dragMs += details.delta.dx / widget.width * widget.total.inMilliseconds;
            _dragMs = widget.onChanged(Duration(milliseconds: _dragMs.round())).inMilliseconds.toDouble();
          },
          onHorizontalDragEnd: (_) => setState(() => _dragging = false),
          onHorizontalDragCancel: () => setState(() => _dragging = false),
          child: SizedBox(
            width: 48,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: _dragging ? 40 : 36,
                height: widget.compact ? (_dragging ? 60 : 56) : (_dragging ? 80 : 72),
                decoration: BoxDecoration(
                  color: _dragging ? Colors.white : (widget.start ? Colors.amber : Colors.lightBlueAccent),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 6, offset: Offset(0, 2))],
                ),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.drag_indicator, color: Colors.black87, size: 24),
                  Icon(widget.start ? Icons.chevron_right : Icons.chevron_left, color: Colors.black87, size: 22),
                ]),
              ),
            ),
          ),
        ),
      );
}
