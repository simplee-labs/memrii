import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:omi/integrations/automation/automation_policy.dart';
import 'package:omi/integrations/connectors/folder/folder_export_connector.dart';
import 'package:omi/integrations/connectors/heypocket/heypocket_connector.dart';
import 'package:omi/integrations/connectors/omi_cloud/omi_cloud_connector.dart';
import 'package:omi/pages/settings/integration_settings_model.dart';
import 'package:omi/pages/settings/omi_login_webview.dart';

class IntegrationSettingsPage extends StatefulWidget {
  const IntegrationSettingsPage(
      {super.key,
      required this.id,
      required this.model,
      this.onPreviewBackfill,
      this.onStartBackfill,
      this.onStopBackfill});
  final IntegrationId id;
  final IntegrationSettingsModel model;
  final List<String> Function(String connectorName)? onPreviewBackfill;
  final int Function(String connectorName, List<String> confirmedIds)? onStartBackfill;
  final void Function(String connectorName)? onStopBackfill;

  @override
  State<IntegrationSettingsPage> createState() => _IntegrationSettingsPageState();
}

class _IntegrationSettingsPageState extends State<IntegrationSettingsPage> {
  IntegrationSettingsModel get model => widget.model;
  late final _heypocketAutomation = AutomationSettings(model.prefs, 'heypocket');

  @override
  void initState() {
    super.initState();
    model.confirmCredentialChange = _confirmCredentialChange;
  }

  @override
  void dispose() {
    if (model.confirmCredentialChange == _confirmCredentialChange) model.confirmCredentialChange = null;
    super.dispose();
  }

  Future<bool> _confirmCredentialChange(IntegrationId id) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Change account?'),
            content: Text('Changing accounts will cancel pending uploads for ${id.title}. '
                'Recordings that already finished uploading will remain marked as uploaded. '
                'Unfinished recordings will need a new upload request or backfill confirmation.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Change Account')),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _openOmiLogin({bool fallback = false}) async {
    final result = await Navigator.of(context)
        .push<Map<String, String>>(MaterialPageRoute(builder: (_) => OmiLoginWebView(startFallback: fallback)));
    if (result != null && mounted) await model.acceptOmiLogin(result);
  }

  Future<void> _chooseFolder() async {
    try {
      await model.chooseFolder();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Could not use that folder. Please try again.')));
      }
    }
  }

  Future<void> _confirmDisconnect() async {
    final action = switch (widget.id) {
      IntegrationId.heypocket => 'Disconnect HeyPocket',
      IntegrationId.omiCloud => 'Log out of Omi',
      IntegrationId.folderExport => 'Remove folder',
    };
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text('$action?'),
              content: const Text('This removes the saved connection and stops its uploads. '
                  'Recordings and copies already saved are kept.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
              ],
            ));
    if (confirmed != true || !mounted) return;
    try {
      await model.disconnect(widget.id);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Could not remove the connection. Please try again.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: model,
        builder: (context, _) => Scaffold(
          backgroundColor: const Color(0xFF0D0D0D),
          appBar: AppBar(
            backgroundColor: const Color(0xFF0D0D0D),
            elevation: 0,
            leading: IconButton(
                icon: const FaIcon(FontAwesomeIcons.chevronLeft, size: 18),
                tooltip: 'Back',
                onPressed: () => Navigator.pop(context)),
            title: Row(children: [
              Expanded(
                  child: Text(widget.id.title,
                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600))),
              IntegrationStatusIndicator(model: model, id: widget.id),
            ]),
            actions: [
              if (model.hasRemovableConfiguration(widget.id))
                IconButton(
                  tooltip: switch (widget.id) {
                    IntegrationId.heypocket => 'Disconnect HeyPocket',
                    IntegrationId.omiCloud => 'Log out of Omi',
                    IntegrationId.folderExport => 'Remove folder',
                  },
                  icon: const Icon(Icons.delete_outline),
                  onPressed:
                      model.connection(widget.id) == IntegrationConnectionState.checking ? null : _confirmDisconnect,
                )
            ],
          ),
          body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: _section()),
        ),
      );

  Widget _section() => switch (widget.id) {
        IntegrationId.omiCloud => _buildIntegrationSection(
            subtitle: 'Upload recordings to Omi Cloud',
            automationSubtitle: 'Automatically upload new recordings to Omi Cloud',
            state: model.connection(IntegrationId.omiCloud),
            enabled: model.prefs.omiEnabled,
            onEnabledChanged: (v) {
              model.prefs.omiEnabled = v;
              if (!v) model.onCancelUploads?.call(OmiCloudConnector.connectorName);
              model.updateAutomation(() {});
            },
            autoUpload: model.prefs.omiAutoUpload,
            autoUploadSinceMs: model.prefs.omiAutoUploadAt,
            onAutoUploadChanged: (v) {
              model.prefs.omiAutoUpload = v;
              if (!v) model.onCancelUploads?.call(OmiCloudConnector.connectorName, autoOnly: true);
              model.updateAutomation(() {});
            },
            trailingWidget: model.connection(IntegrationId.omiCloud) == IntegrationConnectionState.connected
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade800,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      model.prefs.omiConnectedViaFallback ? 'Web App' : 'Direct',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 11),
                    ),
                  )
                : null,
            fields: [
              Text('Unofficial integration. May stop working without notice.',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
              const SizedBox(height: 8),
              if (model.connection(IntegrationId.omiCloud) != IntegrationConnectionState.connected) ...[
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: model.connection(IntegrationId.omiCloud) == IntegrationConnectionState.checking
                        ? null
                        : _openOmiLogin,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.deepPurpleAccent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('Log in with Omi',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: model.connection(IntegrationId.omiCloud) == IntegrationConnectionState.checking
                        ? null
                        : () => _openOmiLogin(fallback: true),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Colors.grey.shade600),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: Text('Log in via app.omi.me',
                        style: TextStyle(color: Colors.grey.shade400, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 4),
                Center(
                  child: TextButton(
                    onPressed: () => model.update(() => model.showOmiManual = !model.showOmiManual),
                    child: Text(
                      model.showOmiManual ? 'Hide manual entry' : 'Enter manually',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                    ),
                  ),
                ),
              ],
              if (model.connection(IntegrationId.omiCloud) == IntegrationConnectionState.connected) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2C2C2E),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.account_circle_outlined, color: Colors.grey, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          model.prefs.omiAuthEmail.isNotEmpty ? model.prefs.omiAuthEmail : 'Omi Account',
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _confirmDisconnect,
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.redAccent),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child:
                        const Text('Log out', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                  ),
                ),
                Center(
                  child: TextButton(
                    onPressed: () => model.update(() => model.showOmiManual = !model.showOmiManual),
                    child: Text(
                      model.showOmiManual ? 'Hide credentials' : 'Enter manually',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                    ),
                  ),
                ),
              ],
              if (model.showOmiManual) ...[
                _buildField(
                  controller: model.omiRefreshTokenController,
                  hint: 'Refresh Token',
                  obscured: model.omiObscured,
                  onToggleObscure: () => model.update(() => model.omiObscured = !model.omiObscured),
                ),
                const SizedBox(height: 12),
                _buildField(
                  controller: model.omiFirebaseApiKeyController,
                  hint: 'Firebase API Key',
                  obscured: model.omiObscured,
                  onToggleObscure: () => model.update(() => model.omiObscured = !model.omiObscured),
                ),
              ],
            ],
          ),
        IntegrationId.heypocket => _buildIntegrationSection(
            subtitle: 'Upload recordings to HeyPocket',
            automationSubtitle: 'Automatically upload matching new recordings to HeyPocket',
            automationControls: _buildHeyPocketAutomation(),
            state: model.connection(IntegrationId.heypocket),
            enabled: model.prefs.heypocketEnabled,
            onEnabledChanged: (v) {
              model.prefs.heypocketEnabled = v;
              if (!v) model.onCancelUploads?.call(HeyPocketConnector.connectorName);
              model.updateAutomation(() {});
            },
            autoUpload: model.prefs.heypocketAutoUpload,
            autoUploadSinceMs: model.prefs.heypocketKeySetAt,
            onAutoUploadChanged: (v) {
              model.prefs.heypocketAutoUpload = v;
              // Turning auto-upload off cancels in-progress/queued *auto* uploads
              // only; an explicit manual upload keeps running.
              if (!v) model.onCancelUploads?.call(HeyPocketConnector.connectorName, autoOnly: true);
              model.updateAutomation(() {});
            },
            fields: [
              _buildField(
                controller: model.heypocketController,
                hint: 'API key (pk_...)',
                obscured: model.heypocketObscured,
                onToggleObscure: () => model.update(() => model.heypocketObscured = !model.heypocketObscured),
              ),
            ],
          ),
        IntegrationId.folderExport => _buildIntegrationSection(
            subtitle: 'Save recordings to a folder you choose',
            automationSubtitle: 'Automatically copy new recordings into this folder as they finish',
            autoTitle: 'Auto-Save',
            // Passthrough counts it: with delete-after-upload on, local audio is removed only
            // once every enabled integration, this one included, has the recording.
            enabledSubtitle: 'Use this folder for saving and passthrough',
            local: true,
            state: model.connection(IntegrationId.folderExport),
            enabled: model.prefs.folderExportEnabled,
            onEnabledChanged: (v) {
              model.prefs.folderExportEnabled = v;
              if (!v) model.onCancelUploads?.call(FolderExportConnector.connectorName);
              model.updateAutomation(() {});
            },
            autoUpload: model.prefs.folderExportAutoUpload,
            autoUploadSinceMs: model.prefs.folderExportAutoUploadAt,
            onAutoUploadChanged: (v) {
              model.prefs.folderExportAutoUpload = v;
              if (!v) model.onCancelUploads?.call(FolderExportConnector.connectorName, autoOnly: true);
              model.updateAutomation(() {});
            },
            fields: [
              if (model.prefs.folderExportTreeUri.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2C2C2E),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.folder_outlined, color: Colors.grey, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          model.prefs.folderExportLabel.isNotEmpty ? model.prefs.folderExportLabel : 'Chosen folder',
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                if (model.connection(IntegrationId.folderExport) == IntegrationConnectionState.error)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'The app can no longer write to this folder — it may have been deleted, or be on an SD card '
                      'that is not inserted. Choose it again to carry on.',
                      style: TextStyle(color: Colors.redAccent.shade100, fontSize: 12, height: 1.3),
                    ),
                  ),
                const SizedBox(height: 10),
              ],
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: model.connection(IntegrationId.folderExport) == IntegrationConnectionState.checking
                      ? null
                      : _chooseFolder,
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Colors.grey.shade600),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: Text(model.prefs.folderExportTreeUri.isEmpty ? 'Choose folder' : 'Change folder',
                      style: TextStyle(color: Colors.grey.shade300, fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Recordings are copied, named by when they were recorded, in the format they are saved in '
                '(e.g. "2026-09-16 14.32.05.wav", or .m4a with M4A selected), and stay on the phone too. A copy is renamed if the app corrects its recording\'s date. Once saved, '
                'a copy is never deleted by the app, even when you delete the recording. Android does not allow '
                'the top of internal storage or Download itself; make a folder inside one.',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 11, height: 1.3),
              ),
            ],
          ),
      };

  Widget _buildIntegrationSection({
    required String subtitle,
    String? automationSubtitle,
    required IntegrationConnectionState state,
    required bool enabled,
    required ValueChanged<bool> onEnabledChanged,
    bool autoUpload = false,
    int autoUploadSinceMs = 0,
    ValueChanged<bool>? onAutoUploadChanged,
    required List<Widget> fields,
    Widget? trailingWidget,
    String autoTitle = 'Auto-Upload',
    String enabledSubtitle = 'Use this integration for uploads and passthrough',
    bool local = false,
    bool showAutomation = true,
    Widget? automationControls,
  }) {
    final isChecking = state == IntegrationConnectionState.checking;
    final isConnected = state == IntegrationConnectionState.connected;
    // Visibility is a product choice; AutomationPolicy and SharingPolicy still
    // enforce permission independently of these controls and saved preferences.
    final automationVisible = showAutomation && model.entitlements.isPro;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (trailingWidget != null) Align(alignment: Alignment.centerRight, child: trailingWidget),
          if (!automationVisible) ...[
            Text(subtitle, style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
            const SizedBox(height: 8),
          ],
          ...fields,
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enabled', style: TextStyle(color: Colors.white, fontSize: 14)),
            subtitle: Text(
              enabledSubtitle,
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
            value: enabled,
            activeThumbColor: Colors.deepPurpleAccent,
            onChanged: isChecking || (!isConnected && !enabled) ? null : onEnabledChanged,
          ),
          if (automationVisible)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: _proTitle(autoTitle),
              subtitle: Text(
                automationSubtitle ?? subtitle,
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
              ),
              value: autoUpload && model.entitlements.isPro && enabled && isConnected,
              activeThumbColor: Colors.deepPurpleAccent,
              onChanged:
                  !model.entitlements.isPro || isChecking || !isConnected || !enabled ? null : onAutoUploadChanged,
            ),
          if (automationVisible && autoUpload && enabled && isConnected && autoUploadSinceMs > 0)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.schedule, size: 13, color: Colors.grey.shade500),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      local
                          ? 'Auto-saving recordings started after ${_formatCutoff(autoUploadSinceMs)}. '
                              'Earlier recordings aren\'t copied automatically — open one and tap Save next to Folder.'
                          : 'Auto-uploading recordings started after ${_formatCutoff(autoUploadSinceMs)}. '
                              'Earlier recordings aren\'t sent automatically — open one and tap the cloud icon to upload it.',
                      style: TextStyle(color: Colors.grey.shade500, fontSize: 11, height: 1.3),
                    ),
                  ),
                ],
              ),
            ),
          if (automationVisible && automationControls != null) automationControls,
        ],
      ),
    );
  }

  Widget _proTitle(String title) => Row(children: [
        Expanded(child: Text(title, style: const TextStyle(color: Colors.white, fontSize: 14))),
        const Text('Pro', style: TextStyle(color: Colors.deepPurpleAccent, fontSize: 11, fontWeight: FontWeight.w600)),
      ]);

  Widget _buildHeyPocketAutomation() {
    final editable = model.entitlements.isPro;
    final settings = _heypocketAutomation;
    final durations = {0, 30, 60, 120, 300, settings.minimumSeconds}.toList()..sort();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Divider(color: Color(0xFF3C3C43)),
      _proTitle('Upload Rules'),
      const SizedBox(height: 8),
      DropdownButtonFormField<AutomaticRecordingScope>(
        initialValue: settings.scope,
        decoration: const InputDecoration(labelText: 'Recording scope'),
        items: [
          for (final scope in AutomaticRecordingScope.values)
            DropdownMenuItem(
                value: scope,
                child: Text(switch (scope) {
                  AutomaticRecordingScope.all => 'All recordings',
                  AutomaticRecordingScope.marked => 'Marked recordings',
                  AutomaticRecordingScope.priority => 'Priority Recordings',
                })),
        ],
        onChanged: editable
            ? (scope) {
                if (scope != null) model.updateAutomation(() => settings.scope = scope);
              }
            : null,
      ),
      const SizedBox(height: 8),
      Text('Marked includes Priority markers. The core recording filter also applies.',
          style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
      DropdownButtonFormField<int>(
        initialValue: settings.minimumSeconds,
        decoration: const InputDecoration(labelText: 'Automatic minimum duration'),
        items: [
          for (final seconds in durations)
            DropdownMenuItem(value: seconds, child: Text(seconds == 0 ? 'No additional minimum' : '$seconds seconds'))
        ],
        onChanged: editable
            ? (seconds) {
                if (seconds != null) model.updateAutomation(() => settings.minimumSeconds = seconds);
              }
            : null,
      ),
      const SizedBox(height: 16),
      _proTitle('Automatic Conditions'),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Wi-Fi only', style: TextStyle(fontSize: 14)),
        subtitle: const Text('Automatic uploads wait for Wi-Fi. Manual uploads can use cellular.',
            style: TextStyle(fontSize: 12)),
        value: settings.wifiOnly,
        onChanged: editable ? (value) => model.updateAutomation(() => settings.wifiOnly = value) : null,
      ),
      const SizedBox(height: 8),
      _proTitle('Archive Backfill'),
      const SizedBox(height: 8),
      OutlinedButton(
        onPressed: editable &&
                model.prefs.heypocketEnabled &&
                model.connection(IntegrationId.heypocket) == IntegrationConnectionState.connected &&
                widget.onPreviewBackfill != null &&
                widget.onStartBackfill != null
            ? _confirmBackfill
            : null,
        child: const Text('Upload existing matching recordings'),
      ),
      if (settings.backfillIds.isNotEmpty) ...[
        Text('${settings.backfillIds.length} recordings in the saved backfill selection.',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
        TextButton(
            onPressed: widget.onStopBackfill == null
                ? null
                : () {
                    widget.onStopBackfill!(HeyPocketConnector.connectorName);
                    model.updateAutomation(() {});
                  },
            child: const Text('Stop backfill')),
      ],
    ]);
  }

  Future<void> _confirmBackfill() async {
    final ids = widget.onPreviewBackfill!(HeyPocketConnector.connectorName);
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Upload existing recordings?'),
              content: Text(
                  '${ids.length} matching recordings will be sent to HeyPocket. Current rules and Wi-Fi conditions apply. '
                  'Already delivered recordings are skipped.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                TextButton(
                    onPressed: ids.isEmpty ? null : () => Navigator.pop(context, true), child: const Text('Upload')),
              ],
            ));
    if (confirmed != true || !mounted) return;
    final count = widget.onStartBackfill!(HeyPocketConnector.connectorName, ids);
    model.updateAutomation(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$count recordings selected for backfill')));
  }

  /// Formats the auto-upload cutoff timestamp (epoch ms) for display, honoring
  /// the user's 12/24-hour preference.
  String _formatCutoff(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final pattern = model.prefs.use24HourTime ? 'MMM d, yyyy · HH:mm' : 'MMM d, yyyy · h:mm a';
    return DateFormat(pattern).format(dt);
  }

  Widget _buildField({
    required TextEditingController controller,
    required String hint,
    required bool obscured,
    required VoidCallback onToggleObscure,
  }) {
    return TextField(
      enabled: !model.isDisconnecting(widget.id) && !model.isChangingCredentials(widget.id),
      controller: controller,
      obscureText: obscured,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Colors.grey.shade600, fontSize: 14),
        filled: true,
        fillColor: const Color(0xFF2C2C2E),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        suffixIcon: IconButton(
          icon: FaIcon(
            obscured ? FontAwesomeIcons.eye : FontAwesomeIcons.eyeSlash,
            size: 14,
            color: Colors.grey,
          ),
          onPressed: onToggleObscure,
          tooltip: obscured ? 'Show API key' : 'Hide API key',
        ),
      ),
    );
  }
}
