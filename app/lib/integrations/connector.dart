import 'package:omi/integrations/integration_recording.dart';
import 'package:omi/integrations/sharing/upload_authorization.dart';

/// What a destination does with what it is sent. Declared once per connector, so the
/// upload engine, the sharing policy and the UI read the same facts instead of each
/// special-casing a destination by name.
class ConnectorCapabilities {
  const ConnectorCapabilities({
    required this.leavesDevice,
    required this.sendsAudio,
    this.sendsTranscript = false,
    this.chunked = false,
    this.needsOpusFrameSidecar = false,
    this.reconcilesDeliveries = false,
    this.supportsAutomaticSending = true,
  });

  /// Sends data over the network. False for a destination that only copies within the
  /// phone (Save to Folder), which automatic Wi-Fi-only therefore does not hold back and
  /// which the UI words as Save/Saved rather than Upload/Uploaded.
  final bool leavesDevice;

  /// Receives the recording's audio (as its file or its frames).
  final bool sendsAudio;

  /// Receives a transcript. No connector does today — memrii makes none — but a
  /// candidate says so explicitly rather than leaving the reader to assume.
  final bool sendsTranscript;

  /// Sends one recording as several requests and can stop between them, so a cancel
  /// takes effect mid-recording. A single-shot connector can only stop before it starts.
  final bool chunked;

  /// Needs the recording layer to write an Opus frame sidecar at processing time (see
  /// `RecordingSidecars.opusFramesPathFor`). Asked of the connector while it is enabled,
  /// through [Connector.wantsOpusFrameSidecar]; the processor never checks a destination.
  final bool needsOpusFrameSidecar;

  /// Keeps records that must follow a recording's current name or start, so each sweep
  /// hands [Connector.reconcile] the recordings it has delivered (Save to Folder renames
  /// its copies). Off, the sweep skips it: working out what a connector has delivered
  /// means asking about every finished recording, and a connector whose reconcile does
  /// nothing should not cost that.
  final bool reconcilesDeliveries;

  /// Whether unattended sending is offered at all. This is a transport/product
  /// capability, never an entitlement decision.
  final bool supportsAutomaticSending;
}

/// A recording on disk moved from [fromAudioPath] to [toAudioPath] — a clock correction,
/// an undo of one, or a date set by hand. Its `.meta`, markers and Opus frame sidecar have
/// already moved with it; the upload key did not change. Sent to every connector so one
/// that keys its own state by path can follow.
class RecordingMove {
  const RecordingMove(this.fromAudioPath, this.toAudioPath);
  final String fromAudioPath;
  final String toAudioPath;
}

/// One external destination for recordings — the boundary between memrii and anything
/// that is not the user's own archive on the phone.
///
/// **A connector receives only what memrii has authorized for it.** The single way to
/// hand it audio is [send], and [send] takes an [AuthorizedUpload], which only the
/// [SharingPolicy] can create: when the user approved that recording for this
/// destination, or when the user switched this destination to automatic sending and the
/// recording is eligible. A connector is never given the library to scan. It is shown
/// individual recordings, as [IntegrationRecording]s, to answer status questions about
/// them ([hasDelivered], [canSend], …), and the ones it already holds, for bookkeeping
/// ([reconcile], [forget]).
///
/// Connectors are first-party code in the same process, so this is a design boundary,
/// not a sandbox: it makes every path from the archive to a destination go through the
/// policy, and makes a new path that skips it stand out in review.
///
/// Lanes, retries, wifi gating, backoff pauses, cancellation and status derivation are
/// the upload engine's (`IntegrationUploadManager`), not the connector's. A connector
/// answers questions about its own state and performs one send at a time.
abstract class Connector {
  const Connector();

  /// Shown to the user, and the key its lane, its cancel actions and its status rows
  /// are filed under. Never persisted — renaming one is free.
  String get name;

  ConnectorCapabilities get capabilities;

  /// Set up enough to send: turned on, and holding whatever credential or folder it
  /// needs. An unconfigured connector is invisible to status and to every sweep.
  bool get isConfigured;

  /// Stable preference namespace for automation above this connector. Null means
  /// there are no additional rules or archive backfill for this destination.
  String? get automationSettingsKey => null;

  /// Desired legacy opt-in ("Auto-Upload" / "Auto-Save"), not effective permission.
  /// Entitlement and additional rules are evaluated above the connector.
  bool get isAutomaticSendingEnabled;

  /// Whether automatic sending may take [r]: configured, and [r] recorded after the
  /// user switched automatic sending on. Fails closed when that time is unknown, so
  /// turning automatic sending on never sweeps up the back catalogue.
  bool isEligibleForAutomatic(IntegrationRecording r);

  /// Whether this connector can send [r] at all if asked explicitly — the source it
  /// needs still exists — whatever the automatic-sending cutoff says.
  bool canSend(IntegrationRecording r);

  /// Why [canSend] is false, in words the user can act on.
  String get unavailableReason;

  bool hasDelivered(IntegrationRecording r);

  /// The automatic-retry budget for [r] is spent.
  bool hasExhaustedRetries(IntegrationRecording r);

  /// The key [r]'s retry count and last failure are stored under. Unique across
  /// connectors, since the store is shared.
  String retryKey(IntegrationRecording r);

  /// `(delivered, total)` chunks for a chunked send in progress or stopped part-way;
  /// null when there is nothing meaningful to count.
  (int delivered, int total)? chunkProgress(IntegrationRecording r) => null;

  /// When a server-requested (or, for a local folder, an unreachable-destination)
  /// pause for [r] ends; null when there is none.
  DateTime? backingOffUntil(IntegrationRecording r) => null;

  bool isBackingOff(IntegrationRecording r) => backingOffUntil(r) != null;

  /// Sends the one recording [upload] authorizes. Invoked by the upload engine only.
  ///
  /// Reports progress through [onProgress]. Polls [isCancelled] at safe checkpoints and,
  /// when it is true, returns without delivering and without throwing. Records delivery
  /// itself (so [hasDelivered] turns true); throws on a failure that should count against
  /// the retry budget; returns without delivering for a pending or backed-off outcome.
  Future<void> send(AuthorizedUpload upload, {void Function()? onProgress, bool Function()? isCancelled});

  /// Brings this connector's own records in line with [delivered] — the finished
  /// recordings, as they are now named, that it has already delivered. Only those: a
  /// connector is not shown recordings it was never given. Never throws.
  Future<void> reconcile(List<IntegrationRecording> delivered) async {}

  /// [deleted] are gone from the phone; drop any record of them. What was delivered
  /// stays delivered at the destination — nothing is recalled.
  Future<void> forget(List<IntegrationRecording> deleted) async {}

  /// A recording moved on disk. Called by the recording layer after the move; never
  /// throws.
  Future<void> onRecordingMoved(RecordingMove move) async {}

  /// Debug Tools cleared the phone's recordings: forget what was sent so a re-processed
  /// recording can be sent again, where doing so cannot duplicate the user's own files.
  Future<void> forgetDeliveryHistory() async {}

  /// Whether the recording layer should write Opus frame sidecars for recordings
  /// processed from now on. Only meaningful when [ConnectorCapabilities.needsOpusFrameSidecar].
  bool get wantsOpusFrameSidecar => false;

  /// A one-line message for the user when [error] from [send] means the connector's
  /// credentials are no longer valid; null for an ordinary failure.
  String? credentialFailureMessage(Object error) => null;

  /// Changes whenever the user sets a new credential. The application integration owner runs a sweep
  /// when one appears, so recordings waiting on the credential go without another tap.
  String get credentialFingerprint => '';

  /// Persisted unfinished transport state, including retries, even if the source
  /// is absent from the current archive snapshot. Completed delivery is separate.
  bool get hasIncompleteDelivery => false;

  /// Retry/transport identities of unfinished work, including absent sources.
  Iterable<String> get incompleteDeliveryKeys => const [];

  /// Called only after the upload lane has settled, before replacing credentials.
  /// Must retain completed-delivery history.
  Future<void> clearIncompleteDelivery() async {}

  /// Once per process, after services start: refresh anything time-limited.
  Future<void> onServicesStarted() async {}

  /// Each meaningful UI foreground open, including a cached-engine re-attach.
  /// The application owner serializes hooks after service initialization and
  /// deduplicates native generations; widget rebuilds do not invoke this hook.
  /// Implementations must preserve saved credentials on temporary failures.
  Future<void> onAppOpened() async {}
}
