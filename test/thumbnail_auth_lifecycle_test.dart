import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drive_in_one/data/datasources/local/account_operation_gate.dart';
import 'package:drive_in_one/data/datasources/local/thumbnail_resolver.dart';
import 'package:drive_in_one/domain/repositories/auth_repository.dart';
import 'package:drive_in_one/presentation/providers/auth_providers.dart';
import 'package:drive_in_one/presentation/widgets/common/authenticated_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final target in [
    'https://lh3.googleusercontent.com/private=s220',
    'https://googleusercontent.com.attacker.test/private=s220',
    'http://lh3.googleusercontent.com/private=s220',
  ]) {
    test(
      'Google credentials are scoped to trusted thumbnail hosts: $target',
      () async {
        final adapter = _RedirectMetadata(target);
        final resolver = ThumbnailResolver(
          dio: Dio()..httpClientAdapter = adapter,
        );
        await resolver.resolve('gdrive://thumb/file-id', const {
          'Authorization': 'Bearer fixture-secret',
        });
        final downloads = adapter.requests
            .where((request) => request.uri.host != 'www.googleapis.com')
            .toList();
        final trusted = target.startsWith('https://lh3.googleusercontent.com/');
        expect(downloads, hasLength(1));
        expect(downloads.single.headers.containsKey('Authorization'), trusted);
      },
    );
  }

  testWidgets('retired widget work stops after awaiting credentials', (
    tester,
  ) async {
    late Directory temp;
    final oldPaths = PathProviderPlatform.instance;
    const account = 'google|retired-widget@example.test';
    const key = '$account|media|revision';
    final auth = _DeferredAuth();

    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('thumbnail-auth-');
      PathProviderPlatform.instance = _TestPaths(temp.path);
    });

    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [authRepositoryProvider.overrideWithValue(auth)],
          child: const MaterialApp(
            home: Scaffold(
              body: AuthenticatedImage(
                accountId: account,
                imageUrl: 'https://example.test/image',
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
      await auth.requested.future;
      AccountOperationGate.retire(account);
      auth.complete.complete(const {'Authorization': 'Bearer retired'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(Image), findsNothing);
      expect(
        await tester.runAsync(
          () => ThumbnailResolver(cacheRoot: () async => temp).readCached(key),
        ),
        isNull,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      PathProviderPlatform.instance = oldPaths;
      await tester.runAsync(() => temp.delete(recursive: true));
    }
  });
}

class _RedirectMetadata implements HttpClientAdapter {
  _RedirectMetadata(this.target);
  final String target;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.uri.host == 'www.googleapis.com') {
      return ResponseBody.fromString(
        jsonEncode({'thumbnailLink': target}),
        HttpStatus.ok,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    return ResponseBody.fromBytes(
      [1, 2, 3],
      HttpStatus.ok,
      headers: {
        Headers.contentTypeHeader: ['image/jpeg'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _DeferredAuth implements AuthRepository {
  final requested = Completer<void>();
  final complete = Completer<Map<String, String>>();

  @override
  Future<Map<String, String>> getAuthHeaders(String accountId) {
    requested.complete();
    return complete.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getTemporaryPath() async => path;
}
