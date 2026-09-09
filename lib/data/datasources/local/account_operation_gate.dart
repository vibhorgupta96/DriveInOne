import 'dart:async';

/// Process-local account generation guard.
///
/// A sync deliberately does network I/O outside a database transaction.  An
/// unlink may therefore finish while that I/O is pending.  Capturing a
/// generation at the beginning and retiring it before deleting local data
/// prevents the late sync response from repopulating an unlinked catalogue.
class AccountOperationGate {
  AccountOperationGate._();

  static final Map<String, int> _generations = <String, int>{};
  static final Map<String, Future<void>> _tails = <String, Future<void>>{};

  static int beginSync(String accountId) => _generations[accountId] ??= 0;

  static int generationFor(String accountId) => _generations[accountId] ??= 0;

  static bool isCurrent(String accountId, int generation) =>
      (_generations[accountId] ?? 0) == generation;

  static void retire(String accountId) {
    _generations[accountId] = (_generations[accountId] ?? 0) + 1;
  }

  /// Serializes local account mutations. Network work deliberately remains
  /// outside this gate; a stale operation is rejected only when it tries to
  /// commit state. Unlink retires first and drains the current commit before
  /// deleting rows/tokens, so a late commit cannot follow the purge.
  static Future<T?> runIfCurrent<T>(
    String accountId,
    int generation,
    Future<T> Function() action,
  ) {
    final previous = _tails[accountId] ?? Future<void>.value();
    final completer = Completer<void>();
    _tails[accountId] = completer.future;
    return previous.then((_) async {
      try {
        if (!isCurrent(accountId, generation)) return null;
        return await action();
      } finally {
        completer.complete();
        if (identical(_tails[accountId], completer.future)) {
          _tails.remove(accountId);
        }
      }
    });
  }

  static Future<void> retireAndDrain(String accountId) async {
    retire(accountId);
    await (_tails[accountId] ?? Future<void>.value());
  }

  static Future<T> retireAndRunExclusive<T>(
    String accountId,
    Future<T> Function() action,
  ) {
    retire(accountId);
    final previous = _tails[accountId] ?? Future<void>.value();
    final completer = Completer<void>();
    _tails[accountId] = completer.future;
    return previous.then((_) async {
      try {
        return await action();
      } finally {
        completer.complete();
        if (identical(_tails[accountId], completer.future)) {
          _tails.remove(accountId);
        }
      }
    });
  }
}
