import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drive_in_one/data/datasources/local/thumbnail_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'forwards Google bearer token only to trusted HTTPS thumbnail hosts',
    () async {
      for (final target in [
        'https://lh3.googleusercontent.com/image=s220',
        'https://googleusercontent.com.attacker.test/image=s220',
        'http://lh3.googleusercontent.com/image=s220',
      ]) {
        final adapter = _Adapter(target);
        final resolver = ThumbnailResolver(
          dio: Dio()..httpClientAdapter = adapter,
        );
        await resolver.resolve('gdrive://thumb/file', const {
          'Authorization': 'Bearer token',
        });
        final download = adapter.requests.last;
        final trusted = target.startsWith('https://lh3.googleusercontent.com/');
        expect(download.headers.containsKey('Authorization'), trusted);
      }
    },
  );

  test(
    'content revision separates cache entries and unlink purge clears account',
    () async {
      final root = await Directory.systemTemp.createTemp('thumbnail-cache-');
      addTearDown(() => root.delete(recursive: true));
      final adapter = _Adapter('https://example.test/image');
      final resolver = ThumbnailResolver(
        dio: Dio()..httpClientAdapter = adapter,
        cacheRoot: () async => root,
      );
      const first = 'google|a@example.test|media|revision-a';
      const second = 'google|a@example.test|media|revision-b';
      await resolver.resolve(
        'https://example.test/image',
        const {},
        cacheKey: first,
      );
      await resolver.resolve(
        'https://example.test/image',
        const {},
        cacheKey: second,
      );
      expect(adapter.requests.length, 2);
      expect(await resolver.readCached(first), isNotNull);
      await resolver.purgeAccount('google|a@example.test');
      expect(await resolver.readCached(first), isNull);
      expect(await resolver.readCached(second), isNull);
    },
  );
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.target);
  final String target;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    if (options.uri.host == 'www.googleapis.com') {
      return ResponseBody.fromString(
        jsonEncode({'thumbnailLink': target}),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    return ResponseBody.fromBytes(
      [requests.length],
      200,
      headers: {
        Headers.contentTypeHeader: ['image/jpeg'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
