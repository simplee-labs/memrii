import 'dart:async';

import 'package:flutter/services.dart';
import 'package:omi/utils/logger.dart';

/// Routes the engine's native UI events independently of widget construction.
/// Attachment work is serialized behind startup recovery; foreground validation
/// is dispatched independently and never holds a native channel reply/readiness.
class AppUiLifecycle {
  AppUiLifecycle({
    required this.channel,
    required Future<void> Function() onAttached,
    required Future<void> Function(int? generation) onForegrounded,
    Future<void>? startupWork,
    int? initialAttachmentGeneration,
  })  : _onAttached = onAttached,
        _onForegrounded = onForegrounded,
        _attachmentTail = startupWork ?? Future.value(),
        _lastAttachmentGeneration = initialAttachmentGeneration;

  final MethodChannel channel;
  final Future<void> Function() _onAttached;
  final Future<void> Function(int?) _onForegrounded;
  Future<void> _attachmentTail;
  int? _lastAttachmentGeneration;

  void listen() => channel.setMethodCallHandler((call) async {
        switch (call.method) {
          case 'uiAttached':
            _attached(call.arguments as int);
          case 'uiForegrounded':
            _foregrounded(call.arguments as int);
        }
        return null;
      });

  void _attached(int generation) {
    if (_lastAttachmentGeneration != null && generation <= _lastAttachmentGeneration!) return;
    _lastAttachmentGeneration = generation;
    _attachmentTail = _attachmentTail.then((_) => _onAttached()).catchError((Object e) {
      Logger.error('UI attachment work failed: $e');
    });
  }

  void _foregrounded(int? generation) {
    unawaited(_onForegrounded(generation).catchError((Object e) {
      Logger.error('UI foreground checks failed: $e');
    }));
  }

  /// Recover events native emitted before subscription. Do not await the work:
  /// permission dialogs and network checks must not delay native readiness.
  Future<void> recover({bool assumeUiOnUnsupportedPlatform = false}) async {
    try {
      final attachment = await channel.invokeMethod<int>('uiAttachmentGeneration');
      if (attachment != null) _attached(attachment);
    } catch (_) {
      // Other platforms retain startup permission/recovery behavior.
    }
    try {
      final foreground = await channel.invokeMethod<int>('uiOpenGeneration');
      if (foreground != null) _foregrounded(foreground);
    } catch (_) {
      if (assumeUiOnUnsupportedPlatform) _foregrounded(null);
    }
  }
}
