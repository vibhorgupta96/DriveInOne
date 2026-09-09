import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drive_in_one/data/datasources/local/account_operation_gate.dart';
import 'package:drive_in_one/data/datasources/local/thumbnail_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'parallel cache writes stay within the global disk entry bound',
    () async {
      final temp = await Directory.systemTemp.createTemp('bounded-cache-');
      addTearDown(() => temp.delete(recursive: true));
      final resolver = ThumbnailResolver(
        dio: Dio()..httpClientAdapter = _ByteAdapter(),
        cacheRoot: () async => temp,
      );

      await Future.wait([
        for (var i = 0; i < 240; i++)
          resolver.resolve(
            'https://example.test/bounded/$i',
            const {},
            cacheKey: 'google|bounded-${i % 3}@example.test|media-$i|revision',
          ),
      ]);

      final files = await temp
          .list(recursive: true)
          .where((entity) => entity is File)
          .toList();
      expect(files.length, lessThanOrEqualTo(200));
    },
  );

  test('account purge removes only its account-scoped previews', () async {
    final temp = await Directory.systemTemp.createTemp('purge-cache-');
    addTearDown(() => temp.delete(recursive: true));
    final resolver = ThumbnailResolver(
      dio: Dio()..httpClientAdapter = _ByteAdapter(),
      cacheRoot: () async => temp,
    );
    const firstAccount = 'google|purge-first@example.test';
    const first = '$firstAccount|media-one|revision';
    const second = 'google|purge-second@example.test|media-two|revision';

    await resolver.resolve(
      'https://example.test/one',
      const {},
      cacheKey: first,
    );
    await resolver.resolve(
      'https://example.test/two',
      const {},
      cacheKey: second,
    );
    await resolver.purgeAccount(firstAccount);

    expect(await resolver.readCached(first), isNull);
    expect(await resolver.readCached(second), isNotNull);
  });

  test('explicit account ids isolate an arbitrary shared cache key', () async {
    final temp = await Directory.systemTemp.createTemp('explicit-cache-');
    addTearDown(() => temp.delete(recursive: true));
    final resolver = ThumbnailResolver(
      dio: Dio()..httpClientAdapter = _ByteAdapter(),
      cacheRoot: () async => temp,
    );
    const firstAccount = 'google|explicit-first@example.test';
    const secondAccount = 'google|explicit-second@example.test';

    await resolver.resolve(
      'https://example.test/first',
      const {},
      cacheKey: 'shared-key',
      accountId: firstAccount,
    );
    await resolver.resolve(
      'https://example.test/second',
      const {},
      cacheKey: 'shared-key',
      accountId: secondAccount,
    );
    await resolver.purgeAccount(firstAccount);

    expect(
      await resolver.readCached('shared-key', accountId: firstAccount),
      isNull,
    );
    expect(
      await resolver.readCached('shared-key', accountId: secondAccount),
      isNotNull,
    );
  });

  test(
    'download completing after retirement cannot repopulate the cache',
    () async {
      final temp = await Directory.systemTemp.createTemp('retired-cache-');
      addTearDown(() => temp.delete(recursive: true));
      final adapter = _DeferredAdapter();
      final resolver = ThumbnailResolver(
        dio: Dio()..httpClientAdapter = adapter,
        cacheRoot: () async => temp,
      );
      const account = 'google|retired-cache@example.test';
      const key = '$account|media-three|revision';

      final pending = resolver.resolve(
        'https://example.test/three',
        const {},
        cacheKey: key,
        accountId: account,
      );
      await adapter.started.future;
      AccountOperationGate.retire(account);
      await resolver.purgeAccount(account);
      adapter.finish.complete();
      expect(await pending, isNull);
      expect(await resolver.readCached(key), isNull);
    },
  );
}

class _ByteAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromBytes(
    [1, 2, 3],
    HttpStatus.ok,
    headers: {
      Headers.contentTypeHeader: ['image/jpeg'],
    },
  );

  @override
  void close({bool force = false}) {}
}

class _DeferredAdapter extends _ByteAdapter {
  final started = Completer<void>();
  final finish = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    started.complete();
    await finish.future;
    return super.fetch(options, requestStream, cancelFuture);
  }
}
