import 'media_item_model.dart';

/// A provider delta is an ordered stream. Keeping this information avoids
/// changing final state when one cursor contains a tombstone and a restore.
class SyncDeltaEvent {
  final MediaItemModel? changedItem;
  final String? deletedRemoteId;

  const SyncDeltaEvent.changed(this.changedItem) : deletedRemoteId = null;
  const SyncDeltaEvent.deleted(this.deletedRemoteId) : changedItem = null;
}

class SyncResultModel {
  final List<MediaItemModel> changedItems;
  final List<String> deletedRemoteIds;
  final String? newSyncToken;
  final List<SyncDeltaEvent> orderedEvents;

  /// True only after a provider completed an enumeration from its root.
  final bool isFullSnapshot;

  const SyncResultModel({
    required this.changedItems,
    required this.deletedRemoteIds,
    this.newSyncToken,
    this.orderedEvents = const [],
    this.isFullSnapshot = false,
  });
}
