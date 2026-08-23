import 'package:flutter_test/flutter_test.dart';

import 'package:drive_in_one/domain/repositories/sync_repository.dart';

void main() {
  test('reports partial account failures explicitly', () {
    const result = SyncResult(
      itemsSynced: 4,
      itemsDeleted: 1,
      accountOutcomes: [
        AccountSyncOutcome.success(
          accountId: 'one',
          accountLabel: 'one@example.com',
          itemsSynced: 4,
          itemsDeleted: 1,
        ),
        AccountSyncOutcome.failure(
          accountId: 'two',
          accountLabel: 'two@example.com',
          error: 'expired token',
        ),
      ],
    );

    expect(result.isPartialSuccess, isTrue);
    expect(result.allFailed, isFalse);
    expect(result.successfulAccounts.single.accountId, 'one');
    expect(result.failedAccounts.single.errorMessage, 'expired token');
  });

  test('distinguishes complete failure from no linked accounts', () {
    const failed = SyncResult(
      itemsSynced: 0,
      itemsDeleted: 0,
      accountOutcomes: [
        AccountSyncOutcome.failure(
          accountId: 'one',
          accountLabel: 'one@example.com',
          error: 'offline',
        ),
      ],
    );
    const empty = SyncResult(itemsSynced: 0, itemsDeleted: 0);

    expect(failed.allFailed, isTrue);
    expect(empty.allFailed, isFalse);
    expect(empty.accountOutcomes, isEmpty);
  });
}
