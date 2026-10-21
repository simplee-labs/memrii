import 'dart:convert';

import 'package:omi/backend/preferences.dart';
import 'package:omi/integrations/automation/automation_policy.dart';
import 'package:omi/integrations/connector.dart';
import 'package:omi/integrations/integration_recording.dart';

/// How a destination is allowed to receive recordings. One per connector, derived by
/// [SharingPolicy.modeFor]. Manual/review authorization stays Free; unattended
/// automatic initiation additionally needs the automation policy's permission.
enum ApprovalMode {
  /// Nothing is sent until the user asks for a specific recording — tapping Upload/Save
  /// on a row, a day or a selection. The default for every configured destination.
  manual,

  /// Recordings that meet the destination's criteria are proposed as candidates, and
  /// each is sent only once the user approves it; a rejected one is never sent.
  /// Architecture-ready: the policy, the queue and their tests exist; no screen yet
  /// lets a user choose this mode or work the queue.
  reviewQueue,

  /// Eligible recordings are sent without asking. Only after the user explicitly opted
  /// in for this destination, and only recordings made after that moment.
  automatic,
}

/// Where a proposed send stands.
enum CandidateState { pending, approved, rejected }

/// Why a send was allowed. Carried by every [AuthorizedUpload].
enum AuthorizationBasis {
  /// The user asked for this recording to go to this destination.
  userRequest,

  /// The destination is in [ApprovalMode.automatic] and the recording is eligible.
  automaticOptIn,

  /// Explicitly confirmed archive discovery under the current automatic rules.
  automaticBackfill,

  /// The user approved this candidate in the review queue.
  reviewApproved,
}

/// One recording proposed for one destination: everything a person would need to decide
/// whether it should go there.
class UploadCandidate {
  const UploadCandidate({
    required this.recording,
    required this.destination,
    required this.sendsAudio,
    required this.sendsTranscript,
    required this.state,
    this.metadata = const {},
  });

  final IntegrationRecording recording;

  /// The connector's name.
  final String destination;

  final bool sendsAudio;
  final bool sendsTranscript;
  final CandidateState state;

  /// What the destination is told about the recording besides its content.
  final Map<String, Object?> metadata;

  DateTime get from => recording.startTime;
  DateTime get to => recording.endTime;

  /// Bookmarks inside the proposed span.
  List<DateTime> get markers => recording.markers;

  /// Identity of this proposal: one recording, one destination. Uses the recording's
  /// upload key, which survives a re-file, so a decision follows the recording.
  String get key => candidateKey(destination, recording);

  static String candidateKey(String destination, IntegrationRecording r) => '$destination|${r.id ?? r.audioPath}';

  UploadCandidate _withState(CandidateState s) => UploadCandidate(
        recording: recording,
        destination: destination,
        sendsAudio: sendsAudio,
        sendsTranscript: sendsTranscript,
        state: s,
        metadata: metadata,
      );
}

/// Permission to send exactly one recording to exactly one destination — what
/// [Connector.send] requires.
///
/// Only [SharingPolicy] can create one: the constructor is private to this library and
/// the class is `final`, so neither a connector nor anything else outside this file can
/// construct, extend or implement it. Holding a grant is therefore proof that the policy
/// said yes.
final class AuthorizedUpload {
  AuthorizedUpload._(this.candidate, this.basis, this.credentialGeneration);

  final UploadCandidate candidate;
  final AuthorizationBasis basis;
  final int credentialGeneration;

  IntegrationRecording get recording => candidate.recording;
  String get destination => candidate.destination;
}

/// Decides what may be sent where. Every [AuthorizedUpload] comes from here.
///
/// The rules, all per destination:
/// - **Manual** (default): a grant only for a recording the user explicitly asked to
///   send ([approveUserRequest]).
/// - **Automatic** (user opted in): [authorizeUnattended] grants eligible recordings
///   without asking; [isStillAuthorized] withdraws that the moment the user switches it
///   off or the recording stops being eligible.
/// - **Review queue**: [authorizeUnattended] records a pending candidate instead of
///   granting; a grant follows only an [approve], and never a [reject].
///
/// A user request always wins: asking for a recording is the approval, whatever mode the
/// destination is in. The automation policy supplies effective automatic permission;
/// this layer still exclusively mints grants. Privacy approval itself remains Free.
class SharingPolicy {
  SharingPolicy(this._prefs, {AutomationPolicy? automation}) : automation = automation ?? AutomationPolicy(_prefs);

  final SharedPreferencesUtil _prefs;
  final AutomationPolicy automation;

  static const _reviewModeKey = 'sharingReviewModeSince';
  static const _reviewQueueKey = 'sharingReviewQueue';
  static const _credentialBoundaryKey = 'sharingCredentialBoundaries';

  Map<String, dynamic> _boundary(String name) {
    final value = _readMap(_credentialBoundaryKey)[name];
    return value is Map ? Map<String, dynamic>.from(value) : {};
  }

  int _generation(String name) => (_boundary(name)['generation'] as int?) ?? 0;

  /// Existing unfinished recordings need a fresh explicit request/backfill
  /// confirmation. Future automatic recordings retain the user's opt-in/rules.
  bool allowsAutomaticRecording(Connector connector, IntegrationRecording recording) {
    final boundary = _boundary(connector.name);
    final since = (boundary['since'] as int?) ?? 0;
    final cancelled = (boundary['cancelled'] as List?) ?? const [];
    return !cancelled.contains(recording.id ?? recording.audioPath) &&
        !(connector.canSend(recording) && cancelled.contains(connector.retryKey(recording))) &&
        !recording.startTime.isBefore(DateTime.fromMillisecondsSinceEpoch(since));
  }

  bool hasPendingAuthorization(Connector connector) =>
      _readMap(_reviewQueueKey).entries.any((e) => e.key.startsWith('${connector.name}|') && e.value == 'approved') ||
      (automation.settingsFor(connector)?.backfillIds.isNotEmpty ?? false);

  /// Persistent authorization boundary, without account-scoped delivery history.
  /// Await all writes before installing replacement credentials.
  Future<void> beginCredentialTransition(Connector connector, DateTime now,
      {Iterable<IntegrationRecording> recordings = const []}) async {
    final boundaries = _readMap(_credentialBoundaryKey);
    boundaries[connector.name] = {
      'generation': _generation(connector.name) + 1,
      'since': now.millisecondsSinceEpoch,
      'cancelled': {
        ...(_boundary(connector.name)['cancelled'] as List? ?? const []).whereType<String>(),
        ...connector.incompleteDeliveryKeys,
        for (final recording in recordings)
          if (!connector.hasDelivered(recording)) recording.id ?? recording.audioPath,
      }.toList(),
    };
    await _prefs.saveString(_credentialBoundaryKey, jsonEncode(boundaries));
    await automation.settingsFor(connector)?.clearBackfill();
    final queue = _readMap(_reviewQueueKey);
    queue.removeWhere((key, value) => key.startsWith('${connector.name}|') && value != 'rejected');
    await _prefs.saveString(_reviewQueueKey, queue.isEmpty ? '' : jsonEncode(queue));
  }

  AuthorizedUpload _grant(UploadCandidate candidate, AuthorizationBasis basis) =>
      AuthorizedUpload._(candidate, basis, _generation(candidate.destination));

  ApprovalMode modeFor(Connector connector) {
    if (automation.isEffective(connector)) return ApprovalMode.automatic;
    if (_reviewModeSince(connector.name) != null) return ApprovalMode.reviewQueue;
    return ApprovalMode.manual;
  }

  /// Puts [connector] in (or takes it out of) review-queue mode. Nothing in the app calls
  /// this yet; it is the switch a review screen would use. Entering the mode proposes
  /// only recordings made from then on, as automatic sending does.
  void setReviewMode(Connector connector, bool on, {DateTime? now}) {
    final since = _readMap(_reviewModeKey);
    if (on) {
      since[connector.name] = (now ?? DateTime.now()).millisecondsSinceEpoch;
    } else {
      since.remove(connector.name);
    }
    _writeMap(_reviewModeKey, since);
  }

  /// The candidate for sending [recording] to [connector], carrying any decision the
  /// user already made on it in the review queue.
  UploadCandidate propose(Connector connector, IntegrationRecording recording) {
    final key = UploadCandidate.candidateKey(connector.name, recording);
    final decided = _readMap(_reviewQueueKey)[key];
    return UploadCandidate(
      recording: recording,
      destination: connector.name,
      sendsAudio: connector.capabilities.sendsAudio,
      sendsTranscript: connector.capabilities.sendsTranscript,
      state: switch (decided) {
        'approved' => CandidateState.approved,
        'rejected' => CandidateState.rejected,
        _ => CandidateState.pending,
      },
      metadata: {
        'startTime': recording.startTime.toIso8601String(),
        'durationSeconds': recording.duration.inSeconds,
        'audioFormat': recording.audioFormat,
        'captureMode': recording.captureMode.name,
        'timeUncertain': recording.timeUncertain,
        'hasPriorityMarker': recording.hasPriorityMarker,
      },
    );
  }

  /// The user asked for [candidate] to be sent. That request is the approval, in any
  /// mode — and it overrides an earlier rejection of the same recording.
  AuthorizedUpload approveUserRequest(UploadCandidate candidate) =>
      _grant(candidate._withState(CandidateState.approved), AuthorizationBasis.userRequest);

  /// For a sweep that runs without the user present. Returns a grant only when
  /// [connector] is in automatic mode and the recording is eligible, or when it is in
  /// review mode and the user already approved this candidate. In review mode an
  /// undecided candidate is recorded as pending (and gets null); a rejected one gets null
  /// forever. In manual mode only a confirmed eligible archive snapshot can receive a grant.
  AuthorizedUpload? authorizeUnattended(Connector connector, UploadCandidate candidate) {
    // A persisted, confirmed archive snapshot can run without enabling future auto-upload.
    // It must still respect review mode and a saved rejection of this recording.
    if (canBackfill(connector, candidate.recording) && automation.requestedBackfill(connector, candidate.recording)) {
      return _grant(candidate._withState(CandidateState.approved), AuthorizationBasis.automaticBackfill);
    }
    switch (modeFor(connector)) {
      case ApprovalMode.manual:
        return null;
      case ApprovalMode.automatic:
        if (!allowsAutomaticRecording(connector, candidate.recording)) return null;
        if (!automation.eligible(connector, candidate.recording)) return null;
        return _grant(candidate._withState(CandidateState.approved), AuthorizationBasis.automaticOptIn);
      case ApprovalMode.reviewQueue:
        if (!allowsAutomaticRecording(connector, candidate.recording)) return null;
        if (!_proposableForReview(connector, candidate.recording)) return null;
        switch (candidate.state) {
          case CandidateState.approved:
            return _grant(candidate, AuthorizationBasis.reviewApproved);
          case CandidateState.rejected:
            return null;
          case CandidateState.pending:
            final queue = _readMap(_reviewQueueKey);
            if (!queue.containsKey(candidate.key)) {
              queue[candidate.key] = 'pending';
              _writeMap(_reviewQueueKey, queue);
            }
            return null;
        }
    }
  }

  /// Re-checked by the upload engine just before a queued grant is used, because the
  /// user can change their mind while it waits. A user request stays valid; an
  /// automatic grant lapses when automatic sending is switched off or the recording is
  /// no longer eligible; a review approval lapses if it was since rejected.
  bool isStillAuthorized(Connector connector, AuthorizedUpload grant) {
    if (grant.credentialGeneration != _generation(connector.name)) return false;
    switch (grant.basis) {
      case AuthorizationBasis.userRequest:
        return true;
      case AuthorizationBasis.automaticOptIn:
        return allowsAutomaticRecording(connector, grant.recording) && automation.eligible(connector, grant.recording);
      case AuthorizationBasis.automaticBackfill:
        return canBackfill(connector, grant.recording) && automation.requestedBackfill(connector, grant.recording);
      case AuthorizationBasis.reviewApproved:
        return _readMap(_reviewQueueKey)[grant.candidate.key] == 'approved';
    }
  }

  /// Archive selection cannot bypass a destination's review requirement or saved rejection.
  bool canBackfill(Connector connector, IntegrationRecording recording) =>
      automation.eligibleForBackfill(connector, recording) &&
      modeFor(connector) != ApprovalMode.reviewQueue &&
      propose(connector, recording).state != CandidateState.rejected;

  /// The user approved a pending (or previously rejected) candidate in the review queue.
  void approve(UploadCandidate candidate) => _decide(candidate.key, 'approved');

  /// The user rejected a candidate. It is never sent unattended; only an explicit user
  /// request for that recording can still send it.
  void reject(UploadCandidate candidate) => _decide(candidate.key, 'rejected');

  /// Candidate keys waiting for a decision, oldest first.
  List<String> pendingReview() => [
        for (final e in _readMap(_reviewQueueKey).entries)
          if (e.value == 'pending') e.key
      ];

  /// A grant was used and the recording delivered: its queue entry has done its job.
  void noteDelivered(AuthorizedUpload grant) {
    final queue = _readMap(_reviewQueueKey);
    if (queue.remove(grant.candidate.key) != null) _writeMap(_reviewQueueKey, queue);
  }

  bool _proposableForReview(Connector connector, IntegrationRecording r) {
    final since = _reviewModeSince(connector.name);
    if (since == null) return false;
    if (r.startTime.isBefore(DateTime.fromMillisecondsSinceEpoch(since))) return false;
    return connector.canSend(r);
  }

  int? _reviewModeSince(String name) {
    final v = _readMap(_reviewModeKey)[name];
    return v is int ? v : null;
  }

  void _decide(String key, String state) {
    final queue = _readMap(_reviewQueueKey);
    queue[key] = state;
    _writeMap(_reviewQueueKey, queue);
  }

  Map<String, Object?> _readMap(String key) {
    final raw = _prefs.getString(key);
    if (raw.isEmpty) return {};
    try {
      return Map<String, Object?>.from(jsonDecode(raw) as Map);
    } catch (_) {
      // An unreadable store is treated as empty: nothing pending, nothing approved.
      // Failing toward "not approved" is the safe direction.
      return {};
    }
  }

  void _writeMap(String key, Map<String, Object?> value) =>
      _prefs.saveString(key, value.isEmpty ? '' : jsonEncode(value));
}
