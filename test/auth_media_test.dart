import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:drive_in_one/core/constants/provider_constants.dart';
import 'package:drive_in_one/core/enums/provider_type.dart';
import 'package:drive_in_one/data/datasources/cloud/cloud_provider.dart';
import 'package:drive_in_one/data/datasources/cloud/dropbox_provider.dart';
import 'package:drive_in_one/data/datasources/cloud/onedrive_provider.dart';
import 'package:drive_in_one/data/datasources/local/thumbnail_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('account-scoped token state', () {
    test(
      'restoring null optional values clears the previous account state',
      () {
        final provider = _TokenProvider();
        provider.setTokens(
          accessToken: 'first-access',
          refreshToken: 'first-refresh',
          expiry: DateTime.utc(2030),
        );

        provider.setTokens(accessToken: 'second-access');

        expect(provider.accessToken, 'second-access');
        expect(provider.refreshToken, isNull);
        expect(provider.tokenExpiry, isNull);
      },
    );
  });

  group('OAuth configuration', () {
    test('reports the missing dart-define by name', () {
      expect(
        () => ProviderConstants.requireConfigured('', 'DROPBOX_APP_KEY'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('--dart-define=DROPBOX_APP_KEY=<value>'),
          ),
        ),
      );
    });

    test('accepts a configured identifier', () {
      expect(
        ProviderConstants.requireConfigured('configured-id', 'CLIENT_ID'),
        'configured-id',
      );
    });
  });

  test('OneDrive replays an opaque delta link byte-for-byte', () {
    const deltaLink =
        'https://graph.microsoft.com/v1.0/me/drive/root/delta?token=a%2Bb%2Fc%3D';
    expect(OneDriveProvider.initialDeltaRequestUrl(deltaLink), deltaLink);
    expect(
      OneDriveProvider.initialDeltaRequestUrl(null),
      '/me/drive/root/delta',
    );
  });

  test('Dropbox deletion paths have an unambiguous reversible key', () {
    const path = '/camera uploads/été & family.jpg';
    final key = DropboxProvider.deletionKeyForPath(path);

    expect(key, startsWith(DropboxProvider.deletionPathKeyPrefix));
    expect(DropboxProvider.pathFromDeletionKey(key), path);
    expect(DropboxProvider.pathFromDeletionKey('id:abc'), isNull);
  });

  test('ThumbnailResolver uses the stable disk cache key', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'driveinone-thumbnail-test-',
    );
    addTearDown(() => tempDirectory.delete(recursive: true));

    final adapter = _CountingAdapter([1, 2, 3, 4]);
    final dio = Dio()..httpClientAdapter = adapter;
    final resolver = ThumbnailResolver(
      dio: dio,
      cacheRoot: () async => tempDirectory,
    );

    final first = await resolver.resolve(
      'https://example.test/thumbnail',
      const {},
      cacheKey: 'account|stable-media-id|content-hash',
    );
    final second = await resolver.resolve(
      'https://different.example.test/ignored-after-cache-hit',
      const {},
      cacheKey: 'account|stable-media-id|content-hash',
    );

    expect(first, Uint8List.fromList([1, 2, 3, 4]));
    expect(second, first);
    expect(adapter.requestCount, 1);
  });
}

class _TokenProvider extends CloudProvider {
  @override
  String get providerId => 'test';

  @override
  ProviderType get providerType => ProviderType.google;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CountingAdapter implements HttpClientAdapter {
  final List<int> bytes;
  int requestCount = 0;

  _CountingAdapter(this.bytes);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    return ResponseBody.fromBytes(
      bytes,
      HttpStatus.ok,
      headers: {
        Headers.contentTypeHeader: ['image/jpeg'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
