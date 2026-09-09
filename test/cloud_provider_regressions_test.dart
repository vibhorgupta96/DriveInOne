import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drive_in_one/core/errors/exceptions.dart';
import 'package:drive_in_one/data/datasources/cloud/dropbox_provider.dart';
import 'package:drive_in_one/data/datasources/cloud/google_drive_provider.dart';
import 'package:drive_in_one/data/datasources/cloud/onedrive_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';

void main() {
  group('cloud delta providers', () {
    test(
      'Google captures the cursor before listing and replays listing races',
      () async {
        final adapter = _ScriptedAdapter([
          (request) {
            expect(request.path, '/changes/startPageToken');
            return _json({'startPageToken': 'captured'});
          },
          (request) {
            expect(request.path, '/files');
            expect(request.queryParameters, isNot(contains('pageToken')));
            return _json({
              'files': [_googleFile('old')],
              'nextPageToken': 'second-list-page',
            });
          },
          (request) {
            expect(request.path, '/files');
            expect(request.queryParameters['pageToken'], 'second-list-page');
            return _json({
              'files': [_googleFile('changed')],
            });
          },
          (request) {
            expect(request.path, '/changes');
            expect(request.queryParameters['pageToken'], 'captured');
            return _json({
              'changes': [
                {'removed': true, 'fileId': 'old'},
                {'fileId': 'changed', 'file': _googleFile('changed')},
              ],
              'newStartPageToken': 'after-race',
            });
          },
        ]);
        final provider = GoogleDriveProvider(dio: _dio(adapter));
        _setValidToken(provider);

        final result = await provider.scanDelta(null);

        expect(result.isFullSnapshot, isTrue);
        expect(result.newSyncToken, 'after-race');
        expect(result.orderedEvents.map(_eventLabel), [
          'changed:old',
          'changed:changed',
          'deleted:old',
          'changed:changed',
        ]);
        expect(adapter.isEmpty, isTrue);
      },
    );

    test(
      'Google preserves delete then restore order across change pages',
      () async {
        final adapter = _ScriptedAdapter([
          (request) {
            expect(request.queryParameters['pageToken'], 'cursor');
            return _json({
              'changes': [
                {'removed': true, 'fileId': 'restored'},
              ],
              'nextPageToken': 'next',
            });
          },
          (request) {
            expect(request.queryParameters['pageToken'], 'next');
            return _json({
              'changes': [
                {'fileId': 'restored', 'file': _googleFile('restored')},
              ],
              'newStartPageToken': 'new-cursor',
            });
          },
        ]);
        final provider = GoogleDriveProvider(dio: _dio(adapter));
        _setValidToken(provider);

        final result = await provider.scanDelta('cursor');

        expect(result.orderedEvents.map(_eventLabel), [
          'deleted:restored',
          'changed:restored',
        ]);
        expect(result.isFullSnapshot, isFalse);
      },
    );

    test(
      'Google fails instead of returning the first partial change page',
      () async {
        final adapter = _ScriptedAdapter([
          (_) => _json({
            'changes': [
              {'fileId': 'first', 'file': _googleFile('first')},
            ],
            'nextPageToken': 'next',
          }),
          (request) => throw _dioError(request, 503, {
            'error': {'message': 'no'},
          }),
        ]);
        final provider = GoogleDriveProvider(dio: _dio(adapter));
        _setValidToken(provider);

        await expectLater(
          provider.scanDelta('cursor'),
          throwsA(isA<ApiException>()),
        );
        expect(adapter.requests, hasLength(2));
      },
    );

    test(
      'OneDrive 410 discards partial data and completes a root snapshot',
      () async {
        const staleCursor = 'https://graph.example/delta?cursor=stale';
        final adapter = _ScriptedAdapter([
          (request) {
            expect(request.path, staleCursor);
            return _json({
              'value': [_oneDriveFile('partial')],
              '@odata.nextLink': 'https://graph.example/delta?cursor=next',
            });
          },
          (request) => throw _dioError(request, 410, {'error': 'gone'}),
          (request) {
            expect(request.path, '/me/drive/root/delta');
            return _json({
              'value': [_oneDriveFile('complete')],
              '@odata.deltaLink': 'fresh-root-cursor',
            });
          },
        ]);
        final provider = OneDriveProvider(dio: _dio(adapter));
        _setValidToken(provider);

        final result = await provider.scanDelta(staleCursor);

        expect(result.isFullSnapshot, isTrue);
        expect(result.newSyncToken, 'fresh-root-cursor');
        expect(result.changedItems.single.remoteId, 'complete');
        expect(adapter.requests, hasLength(3));
      },
    );

    test('OneDrive fails instead of returning a partial later page', () async {
      final adapter = _ScriptedAdapter([
        (_) => _json({
          'value': [_oneDriveFile('first')],
          '@odata.nextLink': 'next',
        }),
        (request) => throw _dioError(request, 500, {'error': 'failed'}),
      ]);
      final provider = OneDriveProvider(dio: _dio(adapter));
      _setValidToken(provider);

      await expectLater(
        provider.scanDelta('stale'),
        throwsA(isA<ApiException>()),
      );
      expect(adapter.requests, hasLength(2));
    });

    test(
      'Dropbox restarts only a reset cursor as a complete root snapshot',
      () async {
        final adapter = _ScriptedAdapter([
          (request) => throw _dioError(request, 409, {
            'error_summary': 'reset/..',
            'error': {'.tag': 'reset'},
          }),
          (request) {
            expect(request.path, '/files/list_folder');
            return _json({
              'entries': [_dropboxFile('/complete.jpg')],
              'cursor': 'fresh-root-cursor',
              'has_more': false,
            });
          },
        ]);
        final provider = DropboxProvider(apiDio: _dio(adapter));
        _setValidToken(provider);

        final result = await provider.scanDelta('expired-cursor');

        expect(result.isFullSnapshot, isTrue);
        expect(result.changedItems.single.remoteId, '/complete.jpg');
        expect(adapter.requests, hasLength(2));
      },
    );

    test('Dropbox propagates a non-reset 409', () async {
      final adapter = _ScriptedAdapter([
        (request) => throw _dioError(request, 409, {
          'error_summary': 'path/not_found/..',
          'error': {'.tag': 'path'},
        }),
      ]);
      final provider = DropboxProvider(apiDio: _dio(adapter));
      _setValidToken(provider);

      await expectLater(
        provider.scanDelta('not-a-reset'),
        throwsA(
          isA<ApiException>().having(
            (error) => error.statusCode,
            'status',
            409,
          ),
        ),
      );
      expect(adapter.requests, hasLength(1));
    });

    test('Dropbox fails instead of returning a partial later page', () async {
      final adapter = _ScriptedAdapter([
        (_) => _json({
          'entries': [_dropboxFile('/first.jpg')],
          'cursor': 'next',
          'has_more': true,
        }),
        (request) =>
            throw _dioError(request, 500, {'error_summary': 'server_error/..'}),
      ]);
      final provider = DropboxProvider(apiDio: _dio(adapter));
      _setValidToken(provider);

      await expectLater(provider.scanDelta(null), throwsA(isA<ApiException>()));
      expect(adapter.requests, hasLength(2));
    });
  });

  group('Google account-scoped background authorization', () {
    late GoogleSignInPlatform originalPlatform;

    setUp(() {
      originalPlatform = GoogleSignInPlatform.instance;
    });

    tearDown(() {
      GoogleSignInPlatform.instance = originalPlatform;
      debugDefaultTargetPlatformOverride = null;
    });

    test(
      'Android requests each linked email without UI or singleton state',
      () async {
        final platform = _FakeGooglePlatform(
          tokensByEmail: {
            'one@example.com': 'one-token',
            'two@example.com': 'two-token',
          },
        );
        debugDefaultTargetPlatformOverride = TargetPlatform.android;

        final first = GoogleDriveProvider(
          accountId: 'google|one@example.com',
          signInPlatform: platform,
          initializer: () async {},
        );
        final second = GoogleDriveProvider(
          accountId: 'google|two@example.com',
          signInPlatform: platform,
          initializer: () async {},
        );
        _setExpiredToken(first);
        _setExpiredToken(second);

        await first.refreshTokenIfNeeded();
        await second.refreshTokenIfNeeded();

        expect(first.accessToken, 'one-token');
        expect(second.accessToken, 'two-token');
        expect(platform.requestedEmails, [
          'one@example.com',
          'two@example.com',
        ]);
        expect(
          platform.requests.every((request) => !request.promptIfUnauthorized),
          isTrue,
        );
        expect(
          platform.requests.every((request) => request.userId == null),
          isTrue,
        );
      },
    );

    test('Android reports a missing account grant without prompting', () async {
      final platform = _FakeGooglePlatform(tokensByEmail: const {});
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final provider = GoogleDriveProvider(
        accountId: 'google|missing@example.com',
        signInPlatform: platform,
        initializer: () async {},
      );
      _setExpiredToken(provider);

      await expectLater(
        provider.refreshTokenIfNeeded(),
        throwsA(
          isA<AuthException>().having(
            (error) => error.message,
            'message',
            contains('missing@example.com'),
          ),
        ),
      );
      expect(platform.requests.single.promptIfUnauthorized, isFalse);
    });

    test('iOS refuses a silent session for another linked account', () async {
      final platform = _FakeGooglePlatform(
        tokensByEmail: const {},
        restoredEmail: 'other@example.com',
      );
      GoogleSignInPlatform.instance = platform;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final provider = GoogleDriveProvider(
        accountId: 'google|expected@example.com',
        initializer: () async {},
      );
      _setExpiredToken(provider);

      await expectLater(
        provider.refreshTokenIfNeeded(),
        throwsA(
          isA<AuthException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('other@example.com'),
              contains('expected@example.com'),
            ),
          ),
        ),
      );
      expect(platform.requests, isEmpty);
    });
  });
}

Dio _dio(HttpClientAdapter adapter) => Dio()..httpClientAdapter = adapter;

void _setValidToken(dynamic provider) => provider.setTokens(
  accessToken: 'token',
  expiry: DateTime.now().add(const Duration(hours: 1)),
);

void _setExpiredToken(dynamic provider) => provider.setTokens(
  accessToken: 'expired',
  expiry: DateTime.now().subtract(const Duration(hours: 1)),
);

String _eventLabel(dynamic event) => event.deletedRemoteId != null
    ? 'deleted:${event.deletedRemoteId}'
    : 'changed:${event.changedItem.remoteId}';

Map<String, dynamic> _googleFile(String id) => {
  'id': id,
  'name': '$id.jpg',
  'mimeType': 'image/jpeg',
  'createdTime': '2026-01-01T00:00:00Z',
  'modifiedTime': '2026-01-01T00:00:00Z',
  'size': '5',
};

Map<String, dynamic> _oneDriveFile(String id) => {
  'id': id,
  'name': '$id.jpg',
  'createdDateTime': '2026-01-01T00:00:00Z',
  'file': {
    'mimeType': 'image/jpeg',
    'hashes': {'quickXorHash': '$id-hash'},
  },
};

Map<String, dynamic> _dropboxFile(String path) => {
  '.tag': 'file',
  'path_lower': path,
  'name': path.substring(1),
  'client_modified': '2026-01-01T00:00:00Z',
  'size': 5,
  'rev': 'revision-$path',
};

ResponseBody _json(Map<String, dynamic> body) => ResponseBody.fromString(
  jsonEncode(body),
  200,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

DioException _dioError(RequestOptions request, int status, dynamic body) =>
    DioException.badResponse(
      requestOptions: request,
      response: Response<dynamic>(
        requestOptions: request,
        statusCode: status,
        data: body,
      ),
      statusCode: status,
    );

typedef _ResponseHandler = FutureOr<ResponseBody> Function(RequestOptions);

class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(List<_ResponseHandler> handlers)
    : _handlers = List<_ResponseHandler>.from(handlers);

  final List<_ResponseHandler> _handlers;
  final List<RequestOptions> requests = [];

  bool get isEmpty => _handlers.isEmpty;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (_handlers.isEmpty) {
      throw StateError('Unexpected request: ${options.method} ${options.path}');
    }
    return _handlers.removeAt(0)(options);
  }

  @override
  void close({bool force = false}) {}
}

class _FakeGooglePlatform extends GoogleSignInPlatform {
  _FakeGooglePlatform({required this.tokensByEmail, this.restoredEmail});

  final Map<String, String> tokensByEmail;
  final String? restoredEmail;
  final List<AuthorizationRequestDetails> requests = [];

  List<String?> get requestedEmails =>
      requests.map((request) => request.email).toList();

  @override
  Future<void> init(InitParameters params) async {}

  @override
  Future<AuthenticationResults?>? attemptLightweightAuthentication(
    AttemptLightweightAuthenticationParameters params,
  ) async {
    final email = restoredEmail;
    if (email == null) return null;
    return AuthenticationResults(
      user: GoogleSignInUserData(email: email, id: 'id-$email'),
      authenticationTokens: const AuthenticationTokenData(idToken: null),
    );
  }

  @override
  bool supportsAuthenticate() => true;

  @override
  Future<AuthenticationResults> authenticate(AuthenticateParameters params) {
    throw UnimplementedError();
  }

  @override
  bool authorizationRequiresUserInteraction() => true;

  @override
  Future<ClientAuthorizationTokenData?> clientAuthorizationTokensForScopes(
    ClientAuthorizationTokensForScopesParameters params,
  ) async {
    requests.add(params.request);
    final token = tokensByEmail[params.request.email];
    return token == null
        ? null
        : ClientAuthorizationTokenData(accessToken: token);
  }

  @override
  Future<ServerAuthorizationTokenData?> serverAuthorizationTokensForScopes(
    ServerAuthorizationTokensForScopesParameters params,
  ) async => null;

  @override
  Future<void> signOut(SignOutParams params) async {}

  @override
  Future<void> disconnect(DisconnectParams params) async {}
}
