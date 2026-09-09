import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drive_in_one/data/datasources/local/thumbnail_resolver.dart';
import 'package:drive_in_one/domain/repositories/auth_repository.dart';
import 'package:drive_in_one/presentation/providers/auth_providers.dart';
import 'package:drive_in_one/presentation/widgets/common/authenticated_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('cached preview renders without requesting expired credentials', (
    tester,
  ) async {
    late Directory temp;
    final oldPaths = PathProviderPlatform.instance;
    const account = 'google|offline@example.test';
    const key = '$account|media-id|revision-a';
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('offline-cache-');
      PathProviderPlatform.instance = _TestPaths(temp.path);
      await ThumbnailResolver(
        dio: Dio()..httpClientAdapter = _ImageAdapter(),
        cacheRoot: () async => temp,
      ).resolve(
        'https://example.test/photo',
        const {},
        cacheKey: key,
        accountId: account,
      );
    });
    final auth = _OfflineAuth();

    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [authRepositoryProvider.overrideWithValue(auth)],
          child: const MaterialApp(
            home: Scaffold(
              body: AuthenticatedImage(
                accountId: account,
                imageUrl: 'https://example.test/photo',
                cacheKey: key,
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();

      expect(auth.requests, 0);
      expect(find.byType(Image), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      PathProviderPlatform.instance = oldPaths;
      await tester.runAsync(() => temp.delete(recursive: true));
    }
  });
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getTemporaryPath() async => path;
}

class _OfflineAuth implements AuthRepository {
  int requests = 0;

  @override
  Future<Map<String, String>> getAuthHeaders(String accountId) async {
    requests++;
    throw StateError('offline');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromBytes(
    image.encodePng(image.Image(width: 10, height: 10)),
    HttpStatus.ok,
    headers: {
      Headers.contentTypeHeader: ['image/png'],
    },
  );

  @override
  void close({bool force = false}) {}
}
