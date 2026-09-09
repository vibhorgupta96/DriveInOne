import 'dart:async';

import 'package:drive_in_one/domain/entities/media_item.dart';
import 'package:drive_in_one/domain/entities/sync_status.dart';
import 'package:drive_in_one/domain/repositories/face_repository.dart';
import 'package:drive_in_one/domain/repositories/media_repository.dart';
import 'package:drive_in_one/domain/repositories/sync_repository.dart';
import 'package:drive_in_one/presentation/providers/face_providers.dart';
import 'package:drive_in_one/presentation/providers/media_providers.dart';
import 'package:drive_in_one/presentation/providers/sync_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'successful catalog sync exposes automatic face scan failure separately',
    () async {
      const catalogResult = SyncResult(
        itemsSynced: 3,
        itemsDeleted: 0,
        accountOutcomes: [
          AccountSyncOutcome.success(
            accountId: 'account',
            accountLabel: 'Test account',
            itemsSynced: 3,
            itemsDeleted: 0,
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          syncRepositoryProvider.overrideWithValue(
            const _SuccessfulSyncRepository(catalogResult),
          ),
          mediaRepositoryProvider.overrideWithValue(_EmptyMediaRepository()),
          faceRepositoryProvider.overrideWith(
            (_) async => _FailingDiagnosticFaceRepository(),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(syncNotifierProvider.notifier)
          .syncAccount('account');

      final syncState = container.read(syncNotifierProvider);
      final faceState = container.read(faceScanNotifierProvider);
      expect(syncState, isA<AsyncData<SyncResult?>>());
      expect(syncState.requireValue, same(catalogResult));
      expect(syncState.requireValue!.hasSuccessfulAccounts, isTrue);
      expect(faceState, isA<AsyncError<void>>());
      expect(faceState.error, isA<StateError>());
      expect(faceState.error.toString(), contains('face scan failed'));
    },
  );
}

class _SuccessfulSyncRepository implements SyncRepository {
  const _SuccessfulSyncRepository(this.result);

  final SyncResult result;

  @override
  Future<void> refreshAllTokens({bool silentOnly = false}) async {}

  @override
  Future<SyncResult> syncAccount(String accountId) async => result;

  @override
  Future<SyncResult> syncAllAccounts() async => result;

  @override
  Stream<SyncStatus> watchSyncStatus() => const Stream.empty();
}

class _EmptyMediaRepository implements MediaRepository {
  @override
  Future<List<MediaItemEntity>> getTimelineAfter({
    required int limit,
    DateTime? beforeTimestamp,
    String? beforeId,
  }) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingDiagnosticFaceRepository implements FaceRepository {
  @override
  Future<Map<String, int>> getDiagnosticCounts() {
    return Future.error(StateError('automatic face scan failed'));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
