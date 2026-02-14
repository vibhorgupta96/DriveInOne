import 'media_item_model.dart';

class SyncResultModel {
  final List<MediaItemModel> changedItems;
  final List<String> deletedRemoteIds;
  final String? newSyncToken;

  const SyncResultModel({
    required this.changedItems,
    required this.deletedRemoteIds,
    this.newSyncToken,
  });
}
