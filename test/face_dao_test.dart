import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:drive_in_one/data/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  FacesCompanion face({
    required String id,
    required String mediaId,
    String? clusterId,
  }) {
    return FacesCompanion.insert(
      id: id,
      mediaItemId: mediaId,
      boundingBox: '{}',
      embedding: Uint8List(8),
      clusterId: Value(clusterId),
    );
  }

  test(
    'replaceFacesForMedia never accumulates results from an earlier run',
    () async {
      await database.facesDao.insertFace(face(id: 'old', mediaId: 'media'));

      await database.facesDao.replaceFacesForMedia('media', [
        face(id: 'first', mediaId: 'media'),
        face(id: 'second', mediaId: 'media'),
      ]);
      await database.facesDao.replaceFacesForMedia('media', [
        face(id: 'latest', mediaId: 'media'),
      ]);

      final stored = await database.facesDao.getFacesByMedia('media');
      expect(stored.map((item) => item.id), ['latest']);
    },
  );

  test(
    'media cleanup repairs representatives and prunes empty clusters',
    () async {
      await database.facesDao.insertFace(
        face(id: 'face-1', mediaId: 'media-1', clusterId: 'cluster'),
      );
      await database.facesDao.insertFace(
        face(id: 'face-2', mediaId: 'media-2', clusterId: 'cluster'),
      );
      await database.facesDao.insertCluster(
        FaceClustersCompanion.insert(
          id: 'cluster',
          representativeFaceId: const Value('face-1'),
          faceCount: const Value(2),
        ),
      );

      await database.facesDao.deleteFacesForMedia('media-1');

      final repaired = await database.facesDao.getClusterById('cluster');
      expect(repaired?.faceCount, 1);
      expect(repaired?.representativeFaceId, 'face-2');

      await database.facesDao.deleteFacesForMedia('media-2');
      expect(await database.facesDao.getClusterById('cluster'), null);
    },
  );

  test(
    'rejects a clustering result when its input snapshot became stale',
    () async {
      await database.facesDao.insertFace(face(id: 'old', mediaId: 'media'));
      final snapshot = await database.facesDao.captureClusteringSnapshot();

      // This models an unlink/new detection changing rows while the worker
      // isolate is clustering the old snapshot.
      await database.facesDao.deleteFacesForMedia('media');
      final committed = await database.facesDao
          .replaceClusterStateIfSnapshotCurrent(
            snapshot: snapshot,
            assignments: const {'old': 'stale-cluster'},
            centroids: {'stale-cluster': Uint8List(8)},
            counts: const {'stale-cluster': 1},
            representatives: const {'stale-cluster': 'old'},
          );

      expect(committed, isFalse);
      expect(await database.facesDao.getClusterById('stale-cluster'), isNull);
    },
  );
}
