import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../api/core.dart';
import '../api/model/events.dart';
import '../api/model/initial_snapshot.dart';
import '../api/model/model.dart';
import '../api/route/events.dart';
import '../api/route/messages.dart';
import 'database.dart';
import 'message_list.dart';

export 'package:drift/drift.dart' show Value;
export 'database.dart' show Account, AccountsCompanion;

/// Store for all the user's data.
///
/// From UI code, use [GlobalStoreWidget.of] to get hold of an appropriate
/// instance of this class.
///
/// This object carries data that is independent of the account, like some
/// settings. It also includes a small amount of data for each account: enough
/// to authenticate as the active account, if there is one.
///
/// For other data associated with a particular account, a [GlobalStore]
/// provides a [PerAccountStore] for each account, which can be reached with
/// [GlobalStore.perAccount] or [GlobalStore.perAccountSync].
///
/// See also:
///  * [LiveGlobalStore], the implementation of this class that
///    we use outside of tests.
abstract class GlobalStore extends ChangeNotifier {
  GlobalStore({required Map<int, Account> accounts})
      : _accounts = accounts;

  /// A cache of the [Accounts] table in the underlying data store.
  final Map<int, Account> _accounts;

  // TODO settings (those that are per-device rather than per-account)
  // TODO push token, and other data corresponding to GlobalSessionState

  final Map<int, PerAccountStore> _perAccountStores = {};
  final Map<int, Future<PerAccountStore>> _perAccountStoresLoading = {};

  /// The store's per-account data for the given account, if already loaded.
  ///
  /// When not null, this is the same [PerAccountStore] that would be returned
  /// by the asynchronous [perAccount].
  PerAccountStore? perAccountSync(int accountId) => _perAccountStores[accountId];

  /// The store's per-account data for the given account.
  ///
  /// If the data for this account is not already loaded, this will ensure a
  /// request is made to load it, and the returned future will complete when
  /// the data is ready.
  ///
  /// The [GlobalStore] will avoid making redundant requests for the same data,
  /// even if this method is called many times.  The futures returned from each
  /// call for the same account will all complete once the data is ready.
  ///
  /// Consider checking [perAccountSync] before calling this function, so that if
  /// the data is already available it can be used immediately (e.g., in the
  /// current frame.)
  ///
  /// See also:
  ///  * [PerAccountStoreWidget.of], for getting the relevant [PerAccountStore]
  ///    from UI code.
  Future<PerAccountStore> perAccount(int accountId) async {
    // First, see if we have the store already.
    PerAccountStore? store = _perAccountStores[accountId];
    if (store != null) {
      return store;
    }

    // Next, see if another call has already started loading one.
    Future<PerAccountStore>? future = _perAccountStoresLoading[accountId];
    if (future != null) {
      return future;
    }

    // It's up to us.  Start loading.
    final account = getAccount(accountId);
    assert(account != null, 'Account not found on global store');
    future = loadPerAccount(account!);
    _perAccountStoresLoading[accountId] = future;
    store = await future;
    _perAccountStores[accountId] = store;
    _perAccountStoresLoading.remove(accountId);
    return store;
  }

  /// Load per-account data for the given account, unconditionally.
  ///
  /// This method should be called only by the implementation of [perAccount].
  /// Other callers interested in per-account data should use [perAccount]
  /// and/or [perAccountSync].
  Future<PerAccountStore> loadPerAccount(Account account);

  // Just the Iterables, not the actual Map, to avoid clients mutating the map.
  // Mutations should go through the setters/mutators below.
  Iterable<Account> get accounts => _accounts.values;
  Iterable<int> get accountIds => _accounts.keys;
  Iterable<({ int accountId, Account account })> get accountEntries {
    return _accounts.entries.map((entry) {
      return (accountId: entry.key, account: entry.value);
    });
  }

  Account? getAccount(int id) => _accounts[id];

  /// Add an account to the store, returning its assigned account ID.
  Future<int> insertAccount(AccountsCompanion data) async {
    final account = await doInsertAccount(data);
    assert(!_accounts.containsKey(account.id));
    _accounts[account.id] = account;
    notifyListeners();
    return account.id;
  }

  /// Add an account to the underlying data store.
  Future<Account> doInsertAccount(AccountsCompanion data);

  // More mutators as needed:
  // Future<void> updateAccount...
}

/// Store for the user's data for a given Zulip account.
///
/// This should always have a consistent snapshot of the state on the server,
/// as provided by the Zulip event system.
///
/// An instance directly of this class will not attempt to poll an event queue
/// to keep the data up to date.  For that behavior, see the subclass
/// [LivePerAccountStore].
class PerAccountStore extends ChangeNotifier {
  /// Create a per-account data store that does not automatically stay up to date.
  ///
  /// For a [PerAccountStore] that polls an event queue to keep itself up to
  /// date, use [LivePerAccountStore.fromInitialSnapshot].
  PerAccountStore.fromInitialSnapshot({
    required this.account,
    required this.connection,
    required InitialSnapshot initialSnapshot,
  })  : zulipVersion = initialSnapshot.zulipVersion,
        subscriptions = Map.fromEntries(initialSnapshot.subscriptions.map(
                (subscription) => MapEntry(subscription.streamId, subscription))),
        maxFileUploadSizeMib = initialSnapshot.maxFileUploadSizeMib;

  final Account account;
  final ApiConnection connection;

  final String zulipVersion;
  final Map<int, Subscription> subscriptions;
  final int maxFileUploadSizeMib; // No event for this.

  // TODO lots more data.  When adding, be sure to update handleEvent too.

  final Set<MessageListView> _messageListViews = {};

  void registerMessageList(MessageListView view) {
    final added = _messageListViews.add(view);
    assert(added);
  }

  void unregisterMessageList(MessageListView view) {
    final removed = _messageListViews.remove(view);
    assert(removed);
  }

  /// Called when the app is reassembled during debugging, e.g. for hot reload.
  ///
  /// This will redo from scratch any computations we can, such as parsing
  /// message contents.  It won't repeat network requests.
  void reassemble() {
    for (final view in _messageListViews) {
      view.reassemble();
    }
  }

  void handleEvent(Event event) {
    if (event is HeartbeatEvent) {
      debugPrint("server event: heartbeat");
    } else if (event is AlertWordsEvent) {
      debugPrint("server event: alert_words");
      // We don't yet store this data, so there's nothing to update.
    } else if (event is MessageEvent) {
      debugPrint("server event: message ${jsonEncode(event.message.toJson())}");
      for (final view in _messageListViews) {
        view.maybeAddMessage(event.message);
      }
    } else if (event is UnexpectedEvent) {
      debugPrint("server event: ${jsonEncode(event.toJson())}"); // TODO log better
    } else {
      // TODO(dart-3): Use a sealed class / pattern-matching to exclude this.
      throw Exception("Event object of impossible type: ${event.toString()}");
    }
  }

  Future<void> sendStreamMessage({required String topic, required String content}) {
    // TODO implement outbox; see design at
    //   https://chat.zulip.org/#narrow/stream/243-mobile-team/topic/.23M3881.20Sending.20outbox.20messages.20is.20fraught.20with.20issues/near/1405739
    return sendMessage(connection, topic: topic, content: content);
  }
}

/// A [GlobalStore] that uses a live server and live, persistent local database.
///
/// The underlying data store is an [AppDatabase] corresponding to a SQLite
/// database file in the app's persistent storage on the device.
///
/// The per-account stores will be instances of [LivePerAccountStore],
/// with data loaded through [LiveApiConnection].
class LiveGlobalStore extends GlobalStore {
  LiveGlobalStore._({
    required AppDatabase db,
    required super.accounts,
  }) : _db = db;

  // We keep the API simple and synchronous for the bulk of the app's code
  // by doing this loading up front before constructing a [GlobalStore].
  static Future<GlobalStore> load() async {
    final db = AppDatabase(NativeDatabase.createInBackground(await _dbFile()));
    final accounts = await db.select(db.accounts).get();
    return LiveGlobalStore._(
      db: db,
      accounts: Map.fromEntries(accounts.map((a) => MapEntry(a.id, a))),
    );
  }

  /// The file path to use for the app database.
  static Future<File> _dbFile() async {
    // What directory should we use?
    //   path_provider's getApplicationSupportDirectory:
    //     on Android, -> Flutter's PathUtils.getFilesDir -> https://developer.android.com/reference/android/content/Context#getFilesDir()
    //       -> empirically /data/data/com.zulip.flutter/files/
    //     on iOS, -> "Library/Application Support" via https://developer.apple.com/documentation/foundation/nssearchpathdirectory/nsapplicationsupportdirectory
    //     on Linux, -> "${XDG_DATA_HOME:-~/.local/share}/com.zulip.flutter/"
    //     All seem reasonable.
    //   path_provider's getApplicationDocumentsDirectory:
    //     on Android, -> Flutter's PathUtils.getDataDirectory -> https://developer.android.com/reference/android/content/Context#getDir(java.lang.String,%20int)
    //       with https://developer.android.com/reference/android/content/Context#MODE_PRIVATE
    //     on iOS, "Document directory" via https://developer.apple.com/documentation/foundation/nssearchpathdirectory/nsdocumentdirectory
    //     on Linux, -> `xdg-user-dir DOCUMENTS` -> e.g. ~/Documents
    //     That Linux answer is definitely not a fit.  Harder to tell about the rest.
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'zulip.db'));
  }

  final AppDatabase _db;

  @override
  Future<PerAccountStore> loadPerAccount(Account account) {
    return LivePerAccountStore.load(account);
  }

  @override
  Future<Account> doInsertAccount(AccountsCompanion data) async {
    final accountId = await _db.createAccount(data); // TODO(log): db errors
    // We can *basically* predict what the Account will contain
    // based on the AccountsCompanion and the account ID.  But
    // if we did that and then there was some subtle case where we
    // didn't match the database's behavior, that'd be a nasty bug.
    // This isn't a hot path, so just make the extra query.
    return await (_db.select(_db.accounts) // TODO perhaps put this logic in AppDatabase
      ..where((a) => a.id.equals(accountId))
    ).getSingle();
  }
}

/// A [PerAccountStore] which polls an event queue to stay up to date.
class LivePerAccountStore extends PerAccountStore {
  LivePerAccountStore.fromInitialSnapshot({
    required super.account,
    required super.connection,
    required super.initialSnapshot,
  })  : queueId = initialSnapshot.queueId ?? (() {
            // The queueId is optional in the type, but should only be missing in the
            // case of unauthenticated access to a web-public realm.  We authenticated.
            throw Exception("bad initial snapshot: missing queueId");
          })(),
        lastEventId = initialSnapshot.lastEventId,
        super.fromInitialSnapshot();

  /// Load the user's data from the server, and start an event queue going.
  ///
  /// In the future this might load an old snapshot from local storage first.
  static Future<PerAccountStore> load(Account account) async {
    final connection = LiveApiConnection(
      auth: Auth(realmUrl: account.realmUrl, email: account.email, apiKey: account.apiKey));

    final stopwatch = Stopwatch()..start();
    final initialSnapshot = await registerQueue(connection); // TODO retry
    final t = (stopwatch..stop()).elapsed;
    // TODO log the time better
    if (kDebugMode) print("initial fetch time: ${t.inMilliseconds}ms");

    final store = LivePerAccountStore.fromInitialSnapshot(
      account: account,
      connection: connection,
      initialSnapshot: initialSnapshot,
    );
    store.poll();
    return store;
  }

  final String queueId;
  int lastEventId;

  void poll() async {
    while (true) {
      final result = await getEvents(connection,
          queueId: queueId, lastEventId: lastEventId);
      // TODO handle errors on get-events; retry with backoff
      // TODO abort long-poll and close LiveApiConnection on [dispose]
      final events = result.events;
      for (final event in events) {
        handleEvent(event);
      }
      if (events.isNotEmpty) {
        lastEventId = events.last.id;
      }
    }
  }
}
