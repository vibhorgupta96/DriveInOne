import 'dart:io';
import 'dart:typed_data';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../../core/constants/app_constants.dart';
import 'tables/accounts_table.dart';
import 'tables/media_items_table.dart';
import 'tables/faces_table.dart';
import 'tables/face_clusters_table.dart';
import 'daos/accounts_dao.dart';
import 'daos/media_items_dao.dart';
import 'daos/faces_dao.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [Accounts, MediaItems, Faces, FaceClusters],
  daos: [AccountsDao, MediaItemsDao, FacesDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();
        },
        onUpgrade: (Migrator m, int from, int to) async {
          // Future migrations
        },
      );

  /// Removes an account and every locally derived record in one transaction.
  ///
  /// Face clusters shared with other accounts are retained and have their
  /// aggregate fields recomputed. Clusters with no remaining faces are pruned.
  Future<void> deleteAccountData(String accountId) {
    return transaction(() async {
      final affectedClusterRows = await customSelect(
        'SELECT DISTINCT f.cluster_id '
        'FROM faces AS f '
        'INNER JOIN media_items AS m ON m.id = f.media_item_id '
        'WHERE m.account_id = ? AND f.cluster_id IS NOT NULL',
        variables: [Variable<String>(accountId)],
        readsFrom: {faces, mediaItems},
      ).get();
      final affectedClusterIds = affectedClusterRows
          .map((row) => row.read<String>('cluster_id'))
          .toList();

      await customUpdate(
        'DELETE FROM faces WHERE media_item_id IN '
        '(SELECT id FROM media_items WHERE account_id = ?)',
        variables: [Variable<String>(accountId)],
        updates: {faces},
      );
      await (delete(mediaItems)
            ..where((media) => media.accountId.equals(accountId)))
          .go();

      for (final clusterId in affectedClusterIds) {
        final remainingFaces = await (select(faces)
              ..where((face) => face.clusterId.equals(clusterId))
              ..orderBy([(face) => OrderingTerm.asc(face.detectedAt)]))
            .get();
        if (remainingFaces.isEmpty) {
          await (delete(faceClusters)
                ..where((cluster) => cluster.id.equals(clusterId)))
              .go();
          continue;
        }

        final cluster = await (select(faceClusters)
              ..where((candidate) => candidate.id.equals(clusterId)))
            .getSingleOrNull();
        if (cluster == null) continue;

        final remainingIds = remainingFaces.map((face) => face.id).toSet();
        final representativeId =
            remainingIds.contains(cluster.representativeFaceId)
                ? cluster.representativeFaceId
                : remainingFaces.first.id;
        await (update(faceClusters)
              ..where((candidate) => candidate.id.equals(clusterId)))
            .write(
          FaceClustersCompanion(
            representativeFaceId: Value(representativeId),
            centroidEmbedding: Value(_averageEmbedding(remainingFaces)),
            faceCount: Value(remainingFaces.length),
          ),
        );
      }

      await (delete(accounts)..where((account) => account.id.equals(accountId)))
          .go();
    });
  }

  Uint8List _averageEmbedding(List<Face> clusterFaces) {
    final byteLength = clusterFaces.first.embedding.length;
    final valueCount = byteLength ~/ Float32List.bytesPerElement;
    final sums = Float64List(valueCount);

    for (final face in clusterFaces) {
      if (face.embedding.length != byteLength) {
        throw StateError('Inconsistent face embedding sizes in a cluster');
      }
      final bytes = ByteData.sublistView(face.embedding);
      for (var index = 0; index < valueCount; index++) {
        sums[index] += bytes.getFloat32(
          index * Float32List.bytesPerElement,
          Endian.host,
        );
      }
    }

    final centroid = Uint8List(byteLength);
    final centroidBytes = ByteData.sublistView(centroid);
    for (var index = 0; index < valueCount; index++) {
      centroidBytes.setFloat32(
        index * Float32List.bytesPerElement,
        sums[index] / clusterFaces.length,
        Endian.host,
      );
    }
    return centroid;
  }
}

Future<AppDatabase> constructDb() async {
  final dbFolder = await getApplicationDocumentsDirectory();
  final file = File(p.join(dbFolder.path, AppConstants.dbName));
  return AppDatabase(NativeDatabase.createInBackground(file));
}
