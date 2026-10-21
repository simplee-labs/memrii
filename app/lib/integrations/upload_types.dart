import 'package:omi/integrations/connector.dart';
import 'package:omi/integrations/sharing/upload_authorization.dart';
import 'package:omi/models/recordings/recordings_models.dart';

enum UploadStatus { none, partial, all, failed, unavailable }

/// Per-connector upload state for one recording, surfaced in the detail sheet.
enum IntegrationUploadState {
  /// Upload in flight right now.
  uploading,

  /// Confirmed delivered to this connector.
  delivered,

  /// Available but the last attempt failed — either a manual upload failed, or
  /// the auto-upload retry budget is exhausted.
  failed,

  /// Available, not delivered, no upload in flight — actionable.
  pending,

  /// Enqueued for upload, waiting its turn behind the single sequential worker.
  /// Not actionable — it's already on its way.
  queued,

  /// This connector cannot upload this recording at all (e.g. Omi with no
  /// Opus frame sidecar, or HeyPocket with the audio file gone).
  unavailable,
}

class IntegrationStatus {
  final String name;
  final IntegrationUploadState state;

  /// When [state] is `failed`, the time of the most recent failed attempt (for
  /// the "Last Upload Failed at" label). Null otherwise or if no time recorded.
  final DateTime? failedAt;

  /// For chunked connectors (Omi Cloud), how many segments have been delivered
  /// and the total — drives the "X/Total chunks" label so a partial/failed-midway
  /// upload shows its progress. Null for single-shot connectors or ≤1 chunk.
  final int? deliveredSegments;
  final int? totalSegments;

  /// The connector keeps its copy on the phone (Save to Folder), so the row says
  /// "Saved"/"Save" rather than "Uploaded"/"Upload".
  final bool local;

  /// Why the connector cannot take this recording, in its own words — shown when
  /// [state] is `unavailable`.
  final String unavailableReason;

  const IntegrationStatus(this.name, this.state,
      {this.failedAt,
      this.deliveredSegments,
      this.totalSegments,
      this.local = false,
      this.unavailableReason = 'Not available for this recording'});

  bool get isActionable => state == IntegrationUploadState.pending || state == IntegrationUploadState.failed;
}

class UploadFailure {
  final String integration;
  final Object error;
  UploadFailure(this.integration, this.error);
}

/// One enqueued upload: a specific [conversation] to a specific [connector], carrying the
/// [grant] that allows it. Drained one at a time within that connector's lane
/// (`IntegrationUploadManager._pumpLane`) so we never fan parallel jobs at a server.
/// [force] re-uploads an already-delivered recording; [manual] jobs (explicit user taps)
/// are drained ahead of auto-sweep jobs and ignore server backoff.
class UploadJob {
  final Connector connector;
  final Conversation conversation;
  final AuthorizedUpload grant;
  final bool force;
  final bool manual;
  UploadJob(this.connector, this.conversation, this.grant, {this.force = false, this.manual = false});

  /// Matches the `_syncingKeys` registry so in-flight and queued jobs dedup
  /// against each other across every entry point.
  String get key => '${connector.name}_${conversation.file.path}';
}
