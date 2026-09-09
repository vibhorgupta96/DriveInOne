import 'package:drift/drift.dart';
import '../app_database.dart';
import '../tables/accounts_table.dart';
import '../tables/media_items_table.dart';

part 'media_items_dao.g.dart';

@DriftAccessor(tables: [MediaItems])
class MediaItemsDao extends DatabaseAccessor<AppDatabase>
    with _$MediaItemsDaoMixin {
  MediaItemsDao(super.db);

  Future<List<MediaItem>> getTimelinePage(int limit, int offset) =>
      (select(mediaItems)
            ..where((m) => m.isDeleted.equals(false))
            ..orderBy([
              (m) => OrderingTerm.desc(m.timestamp),
              (m) => OrderingTerm.desc(m.id),
            ])
            ..limit(limit, offset: offset))
          .get();

  Future<List<MediaItem>> getTimelinePageAfter({
    required int limit,
    DateTime? beforeTimestamp,
    String? beforeId,
  }) {
    final query = select(mediaItems)
      ..where((m) {
        var predicate = m.isDeleted.equals(false);
        if (beforeTimestamp != null && beforeId != null) {
          predicate =
              predicate &
              (m.timestamp.isSmallerThanValue(beforeTimestamp) |
                  (m.timestamp.equals(beforeTimestamp) &
                      m.id.isSmallerThanValue(beforeId)));
        }
        return predicate;
      })
      ..orderBy([
        (m) => OrderingTerm.desc(m.timestamp),
        (m) => OrderingTerm.desc(m.id),
      ])
      ..limit(limit);
    return query.get();
  }

  Stream<List<MediaItem>> watchTimeline() =>
      (select(mediaItems)
            ..where((m) => m.isDeleted.equals(false))
            ..orderBy([
              (m) => OrderingTerm.desc(m.timestamp),
              (m) => OrderingTerm.desc(m.id),
            ]))
          .watch();

  Future<List<MediaItem>> getMediaByDateRange(DateTime start, DateTime end) =>
      (select(mediaItems)
            ..where(
              (m) =>
                  m.isDeleted.equals(false) &
                  m.timestamp.isBiggerOrEqualValue(start) &
                  m.timestamp.isSmallerOrEqualValue(end),
            )
            ..orderBy([(m) => OrderingTerm.desc(m.timestamp)]))
          .get();

  Future<List<MediaItem>> getMediaByAccount(String accountId) =>
      (select(mediaItems)
            ..where(
              (m) => m.isDeleted.equals(false) & m.accountId.equals(accountId),
            )
            ..orderBy([(m) => OrderingTerm.desc(m.timestamp)]))
          .get();

  Future<List<MediaItem>> searchMedia(
    String query, {
    int limit = 100,
    int offset = 0,
  }) async {
    final term = query.trim();
    if (term.isEmpty) return const [];

    final accountsTable = attachedDatabase.accounts;
    final providerIndexes = ProviderTypeEnum.values
        .where((provider) => provider.name.contains(term.toLowerCase()))
        .map((provider) => provider.index)
        .toList();
    var accountPredicate =
        accountsTable.id.contains(term) |
        accountsTable.email.contains(term) |
        accountsTable.displayName.contains(term);
    if (providerIndexes.isNotEmpty) {
      accountPredicate =
          accountPredicate | accountsTable.providerType.isIn(providerIndexes);
    }
    final matchingAccounts = await (select(
      accountsTable,
    )..where((_) => accountPredicate)).get();

    final matchingAccountIds = matchingAccounts
        .map((account) => account.id)
        .toList();
    return (select(mediaItems)
          ..where((m) {
            var metadataMatches =
                m.fileName.contains(term) |
                m.mimeType.contains(term) |
                m.remotePath.contains(term) |
                m.accountId.contains(term);
            if (matchingAccountIds.isNotEmpty) {
              metadataMatches =
                  metadataMatches | m.accountId.isIn(matchingAccountIds);
            }
            return m.isDeleted.equals(false) & metadataMatches;
          })
          ..orderBy([
            (m) => OrderingTerm.desc(m.timestamp),
            (m) => OrderingTerm.desc(m.id),
          ])
          ..limit(limit, offset: offset))
        .get();
  }

  Future<void> upsertMediaItem(MediaItemsCompanion item) =>
      transaction(() => _upsertMediaItem(item));

  Future<void> batchUpsert(List<MediaItemsCompanion> items) {
    return transaction(() async {
      for (final item in items) {
        await _upsertMediaItem(item);
      }
    });
  }

  Future<void> _upsertMediaItem(MediaItemsCompanion item) async {
    if (!item.id.present || !item.accountId.present || !item.remoteId.present) {
      throw ArgumentError('Media upserts require id, accountId, and remoteId');
    }

    final existing =
        await (select(mediaItems)..where(
              (m) =>
                  m.accountId.equals(item.accountId.value) &
                  m.remoteId.equals(item.remoteId.value),
            ))
            .getSingleOrNull();

    if (existing == null) {
      await into(mediaItems).insert(item);
      return;
    }

    final facesProcessed = existing.isDeleted || _contentChanged(existing, item)
        ? false
        : existing.facesProcessed;
    final updateItem = item.copyWith(
      id: Value(existing.id),
      isDeleted: const Value(false),
      facesProcessed: Value(facesProcessed),
      syncedAt: Value(DateTime.now()),
    );
    await (update(
      mediaItems,
    )..where((m) => m.id.equals(existing.id))).write(updateItem);
  }

  bool _contentChanged(MediaItem existing, MediaItemsCompanion incoming) {
    final incomingHash = incoming.fileHash.present
        ? incoming.fileHash.value
        : null;
    final existingHash = existing.fileHash;
    if (existingHash != null &&
        existingHash.isNotEmpty &&
        incomingHash != null &&
        incomingHash.isNotEmpty) {
      return existingHash != incomingHash;
    }

    if (incoming.mimeType.present &&
        incoming.mimeType.value != existing.mimeType) {
      return true;
    }
    if (incoming.mediaType.present &&
        incoming.mediaType.value != existing.mediaType) {
      return true;
    }
    if (incoming.fileSize.present &&
        incoming.fileSize.value != null &&
        existing.fileSize != null &&
        incoming.fileSize.value != existing.fileSize) {
      return true;
    }
    if (incoming.width.present &&
        incoming.width.value != null &&
        existing.width != null &&
        incoming.width.value != existing.width) {
      return true;
    }
    if (incoming.height.present &&
        incoming.height.value != null &&
        existing.height != null &&
        incoming.height.value != existing.height) {
      return true;
    }
    if (incoming.durationSeconds.present &&
        incoming.durationSeconds.value != null &&
        existing.durationSeconds != null &&
        incoming.durationSeconds.value != existing.durationSeconds) {
      return true;
    }
    return false;
  }

  Future<void> markDeleted(String accountId, String remoteId) =>
      (update(mediaItems)..where(
            (m) => m.accountId.equals(accountId) & m.remoteId.equals(remoteId),
          ))
          .write(const MediaItemsCompanion(isDeleted: Value(true)));

  Future<int> markDeletedByRemoteKey(String accountId, String remoteKey) {
    final isPathKey = remoteKey.startsWith('path:');
    final value = isPathKey ? remoteKey.substring('path:'.length) : remoteKey;
    final normalizedPath = value.toLowerCase();
    return (update(mediaItems)..where((m) {
          final accountMatches =
              m.accountId.equals(accountId) & m.isDeleted.equals(false);
          if (isPathKey) {
            // Dropbox folder tombstones cover the folder and every true
            // path descendant, but not a sibling such as /album-archive.
            final descendantPrefix = normalizedPath.endsWith('/')
                ? normalizedPath
                : '$normalizedPath/';
            return accountMatches &
                (m.remotePath.equals(normalizedPath) |
                    m.remotePath.like(
                      '${_escapeLike(descendantPrefix)}%',
                      escapeChar: '\\',
                    ));
          }
          return accountMatches &
              (m.remoteId.equals(value) | m.remotePath.equals(normalizedPath));
        }))
        .write(const MediaItemsCompanion(isDeleted: Value(true)));
  }

  Future<int> batchMarkDeleted(String accountId, List<String> remoteIds) {
    return transaction(() async {
      final deletedMediaIds = <String>{};
      var deletedCount = 0;
      for (final remoteId in remoteIds) {
        deletedMediaIds.addAll(
          await _mediaIdsForRemoteKey(accountId, remoteId),
        );
        deletedCount += await markDeletedByRemoteKey(accountId, remoteId);
      }
      await attachedDatabase.facesDao.deleteFacesForMediaIds(deletedMediaIds);
      return deletedCount;
    });
  }

  /// Reconciles a successful provider root enumeration. This is intentionally
  /// separate from failed/partial deltas: callers invoke it only when the
  /// provider confirms the entire snapshot was fetched.
  Future<int> reconcileFullSnapshot(
    String accountId,
    Iterable<String> presentRemoteIds,
  ) async {
    final present = presentRemoteIds.toSet();
    final current =
        await (select(mediaItems)..where(
              (m) => m.accountId.equals(accountId) & m.isDeleted.equals(false),
            ))
            .get();
    final missing = current
        .where((media) => !present.contains(media.remoteId))
        .map((media) => media.remoteId)
        .toList();
    if (missing.isEmpty) return 0;
    return batchMarkDeleted(accountId, missing);
  }

  Future<List<String>> _mediaIdsForRemoteKey(
    String accountId,
    String remoteKey,
  ) {
    final isPathKey = remoteKey.startsWith('path:');
    final value = isPathKey ? remoteKey.substring('path:'.length) : remoteKey;
    final normalizedPath = value.toLowerCase();
    final query = selectOnly(mediaItems)
      ..addColumns([mediaItems.id])
      ..where(() {
        final accountMatches = mediaItems.accountId.equals(accountId);
        if (isPathKey) {
          final descendantPrefix = normalizedPath.endsWith('/')
              ? normalizedPath
              : '$normalizedPath/';
          return accountMatches &
              (mediaItems.remotePath.equals(normalizedPath) |
                  mediaItems.remotePath.like(
                    '${_escapeLike(descendantPrefix)}%',
                    escapeChar: '\\',
                  ));
        }
        return accountMatches &
            (mediaItems.remoteId.equals(value) |
                mediaItems.remotePath.equals(normalizedPath));
      }());
    return query.map((row) => row.read(mediaItems.id)!).get();
  }

  Future<void> deleteByAccount(String accountId) =>
      (delete(mediaItems)..where((m) => m.accountId.equals(accountId))).go();

  Future<MediaItem?> getMediaItemById(String id) =>
      (select(mediaItems)..where((m) => m.id.equals(id))).getSingleOrNull();

  Future<List<MediaItem>> getMediaItemsWithoutFaces(int limit) =>
      (select(mediaItems)
            ..where(
              (m) => m.isDeleted.equals(false) & m.facesProcessed.equals(false),
            )
            ..limit(limit))
          .get();

  Future<void> markFacesProcessed(String id) =>
      (update(mediaItems)..where((m) => m.id.equals(id))).write(
        const MediaItemsCompanion(facesProcessed: Value(true)),
      );

  Future<int> getMediaCount() async {
    final count = countAll();
    final query = selectOnly(mediaItems)
      ..where(mediaItems.isDeleted.equals(false))
      ..addColumns([count]);
    final result = await query.getSingle();
    return result.read(count) ?? 0;
  }

  Future<List<MediaItem>> getMediaItemsByIds(List<String> ids) {
    if (ids.isEmpty) return Future.value(const []);
    return (select(
      mediaItems,
    )..where((m) => m.isDeleted.equals(false) & m.id.isIn(ids))).get();
  }

  Future<int> getProcessedFacesCount() async {
    final count = countAll();
    final query = selectOnly(mediaItems)
      ..where(
        mediaItems.isDeleted.equals(false) &
            mediaItems.facesProcessed.equals(true),
      )
      ..addColumns([count]);
    final result = await query.getSingle();
    return result.read(count) ?? 0;
  }

  Future<Map<String, ({int photos, int videos})>>
  getMediaStatsByAccount() async {
    final results = await customSelect(
      'SELECT account_id, media_type, COUNT(*) as cnt '
      'FROM media_items '
      'WHERE is_deleted = 0 '
      'GROUP BY account_id, media_type',
    ).get();

    final stats = <String, ({int photos, int videos})>{};
    for (final row in results) {
      final accountId = row.read<String>('account_id');
      final mediaType = row.read<int>('media_type');
      final count = row.read<int>('cnt');
      final existing = stats[accountId] ?? (photos: 0, videos: 0);
      if (mediaType == MediaTypeEnum.photo.index) {
        stats[accountId] = (photos: count, videos: existing.videos);
      } else {
        stats[accountId] = (photos: existing.photos, videos: count);
      }
    }
    return stats;
  }

  Future<void> resetAllFacesProcessed() =>
      (update(mediaItems)..where((m) => m.facesProcessed.equals(true))).write(
        const MediaItemsCompanion(facesProcessed: Value(false)),
      );

  static String _escapeLike(String value) => value
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');
}
