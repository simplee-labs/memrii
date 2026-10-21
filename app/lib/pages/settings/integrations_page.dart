import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/pages/settings/integration_settings_model.dart';
import 'package:omi/pages/settings/integration_settings_page.dart';
import 'package:omi/integrations/integration_upload_manager.dart';

class IntegrationsPage extends StatefulWidget {
  const IntegrationsPage(
      {super.key,
      this.onCancelUploads,
      this.onPreviewBackfill,
      this.onStartBackfill,
      this.onStopBackfill,
      this.uploads,
      this.onAutomationChanged,
      this.integrationChanges});

  /// Invoked with a connector's name when the user turns off its Enabled or
  /// Auto-Upload toggle. [autoOnly] true (Auto-Upload off) cancels only automatic
  /// uploads, leaving the ones the user asked for alone; false (Enabled off) cancels
  /// everything for that connector. Save to Folder also calls it when the folder is
  /// changed or removed, since queued copies were headed for the old one.
  final void Function(String connectorName, {bool autoOnly})? onCancelUploads;
  final List<String> Function(String connectorName)? onPreviewBackfill;
  final int Function(String connectorName, List<String> confirmedIds)? onStartBackfill;
  final void Function(String connectorName)? onStopBackfill;

  final Listenable? integrationChanges;
  final IntegrationUploadManager? uploads;
  final VoidCallback? onAutomationChanged;

  @override
  State<IntegrationsPage> createState() => _IntegrationsPageState();
}

class _IntegrationsPageState extends State<IntegrationsPage> {
  late final _model = IntegrationSettingsModel(
      onCancelUploads: widget.onCancelUploads,
      integrationChanges: widget.integrationChanges,
      uploads: widget.uploads,
      onAutomationChanged: widget.onAutomationChanged);
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _model.start();
  }

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  Future<void> _open(IntegrationId id) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => IntegrationSettingsPage(
            id: id,
            model: _model,
            onPreviewBackfill: widget.onPreviewBackfill,
            onStartBackfill: widget.onStartBackfill,
            onStopBackfill: widget.onStopBackfill)));
    if (mounted) _model.refreshPresentation();
  }

  Widget _row(IntegrationId id, {int? index}) => Padding(
        key: ValueKey(id.storageKey),
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(12),
          child: ListTile(
            title: Text(id.title,
                style: TextStyle(
                    color: _model.hidden(id) ? Colors.grey : Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            onTap: () => _open(id),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IntegrationStatusIndicator(model: _model, id: id),
              if (_editing) ...[
                IconButton(
                  key: ValueKey('visibility-${id.storageKey}'),
                  tooltip: _model.enabled(id)
                      ? 'Turn off in settings to hide'
                      : _model.hidden(id)
                          ? 'Show ${id.title}'
                          : 'Hide ${id.title}',
                  icon: Icon(_model.hidden(id) ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                  onPressed: _model.enabled(id) ? null : () => _model.setHidden(id, !_model.hidden(id)),
                ),
                ReorderableDragStartListener(
                    index: index!,
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Semantics(
                            label: 'Reorder ${id.title}', child: const Icon(Icons.drag_handle, color: Colors.grey)))),
              ] else ...[
                const SizedBox(width: 12),
                const Icon(Icons.chevron_right, color: Colors.grey),
              ],
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: _model,
      builder: (context, _) => Scaffold(
            backgroundColor: const Color(0xFF0D0D0D),
            appBar: AppBar(
              backgroundColor: const Color(0xFF0D0D0D),
              elevation: 0,
              leading: IconButton(
                  icon: const FaIcon(FontAwesomeIcons.chevronLeft, size: 18),
                  tooltip: 'Back',
                  onPressed: () => Navigator.pop(context)),
              title: const Text('Integrations',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
              centerTitle: true,
              actions: [
                TextButton(
                    onPressed: () => setState(() => _editing = !_editing), child: Text(_editing ? 'Done' : 'Edit'))
              ],
            ),
            body: _editing
                ? ReorderableListView(
                    padding: const EdgeInsets.all(16),
                    buildDefaultDragHandles: false,
                    onReorder: _model.reorder,
                    children: [for (var i = 0; i < _model.order.length; i++) _row(_model.order[i], index: i)],
                  )
                : ListView(padding: const EdgeInsets.all(16), children: [
                    for (final id in _model.visible) _row(id),
                    if (_model.visible.isEmpty)
                      const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('No integrations shown', textAlign: TextAlign.center)),
                    if (_model.hiddenCount > 0)
                      TextButton(
                          onPressed: () => setState(() => _editing = true),
                          child: Text('Hidden integrations (${_model.hiddenCount})')),
                  ]),
          ));
}
