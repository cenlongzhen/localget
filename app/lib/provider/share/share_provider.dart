import 'dart:async';

import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart' show DeviceType;
import 'package:localsend_isolates/model/share.dart';
import 'package:localsend_isolates/rust/api/server.dart' show RsShareSnapshot, RsSharedDirectory, RsTrustedDevice;
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

/// Local view of this device's shared-directory configuration.
///
/// Long-term directories and the trusted-device allowlist are persisted;
/// session-only directories live in memory and disappear on restart. Every
/// mutation is also pushed into the running server's `ShareRegistry`, so
/// mounting a directory takes effect without a restart.
///
/// See `docs/share-directory.md` §5 + §6.
class ShareNotifier extends Notifier<ShareSnapshot> {
  static const _uuid = Uuid();

  @override
  ShareSnapshot init() {
    final persistence = ref.read(persistenceProvider);
    return ShareSnapshot(
      directories: persistence.getShareDirectories(),
      trustedDevices: persistence.getShareTrustedDevices(),
    );
  }

  SharedDirectory addDirectory({
    required String name,
    required String root,
    required ShareKind kind,
    bool readOnly = true,
  }) {
    final dir = SharedDirectory(
      id: _uuid.v4(),
      name: name,
      root: root,
      kind: kind,
      readOnly: readOnly,
      enabled: true,
      addedAt: DateTime.now(),
    );
    state = state.copyWith(directories: [...state.directories, dir]);
    _persistAndPush();
    return dir;
  }

  void updateDirectory(
    String id, {
    String? name,
    String? root,
    ShareKind? kind,
    bool? readOnly,
    bool? enabled,
  }) {
    state = state.copyWith(
      directories: [
        for (final d in state.directories)
          if (d.id == id)
            d.copyWith(
              name: name,
              root: root,
              kind: kind,
              readOnly: readOnly,
              enabled: enabled,
            )
          else
            d,
      ],
    );
    _persistAndPush();
  }

  void removeDirectory(String id) {
    state = state.copyWith(
      directories: state.directories.where((d) => d.id != id).toList(growable: false),
    );
    _persistAndPush();
  }

  void setDirectoryEnabled(String id, bool enabled) {
    updateDirectory(id, enabled: enabled);
  }

  void trustDevice({required String fingerprint, required String alias, DeviceType deviceType = DeviceType.desktop}) {
    final next = TrustedDevice(
      fingerprint: fingerprint.toUpperCase(),
      alias: alias,
      addedAt: DateTime.now(),
      deviceType: deviceType,
    );
    state = state.copyWith(
      trustedDevices: [
        for (final t in state.trustedDevices)
          if (t.fingerprint != next.fingerprint) t,
        next,
      ],
    );
    _persistAndPush();
  }

  void revokeDevice(String fingerprint) {
    final key = fingerprint.toUpperCase();
    state = state.copyWith(
      trustedDevices: state.trustedDevices.where((t) => t.fingerprint != key).toList(growable: false),
    );
    _persistAndPush();
  }

  /// Refresh `lastSeenAt` at most once per 15 s (mirrors
  /// `LAST_SEEN_COALESCE` in the Rust registry). Does not push: the
  /// server-side `touch_seen` bookkeeping is authoritative.
  void touchSeen(String fingerprint, {DateTime? now}) {
    final key = fingerprint.toUpperCase();
    final stamp = now ?? DateTime.now();
    var changed = false;
    final next = <TrustedDevice>[];
    for (final t in state.trustedDevices) {
      if (t.fingerprint != key) {
        next.add(t);
        continue;
      }
      final prev = t.lastSeenAt;
      if (prev != null && stamp.difference(prev) < const Duration(seconds: 15)) {
        next.add(t);
      } else {
        changed = true;
        next.add(t.copyWith(lastSeenAt: stamp));
      }
    }
    if (changed) {
      state = state.copyWith(trustedDevices: next);
    }
  }

  /// Writes the long-term part to disk, then hands the full snapshot to the
  /// running server's registry.
  void _persistAndPush() {
    final persistence = ref.read(persistenceProvider);
    unawaited(persistence.setShareDirectories(state.directories.where((d) => d.kind == ShareKind.longTerm).toList(growable: false)));
    unawaited(persistence.setShareTrustedDevices(state.trustedDevices));
    _pushToIsolate();
  }

  /// Push the current [ShareSnapshot] into the Rust `ShareRegistry`.
  ///
  /// The update travels through the isolate controller so the running server
  /// swaps its contents in place — **no restart**. When the isolate has not
  /// been initialized (unit tests, first boot before preInit finished), the
  /// action returns silently. Once the server later starts, the initial
  /// snapshot comes along via `ServerService._currentShareSnapshot`.
  void _pushToIsolate() {
    final connection = ref.read(parentIsolateProvider);
    if (connection.httpServer == null) {
      return;
    }
    ref.redux(parentIsolateProvider).dispatch(IsolateHttpServerUpdateShareAction(snapshot: _snapshot()));
  }

  RsShareSnapshot _snapshot() {
    return RsShareSnapshot(
      directories: [
        for (final d in state.directories)
          RsSharedDirectory(
            id: d.id,
            name: d.name,
            root: d.root,
            kind: d.kind == ShareKind.sessionOnly ? 'sessionOnly' : 'longTerm',
            readOnly: d.readOnly,
            enabled: d.enabled,
            addedAtUnixSecs: BigInt.from(d.addedAt.millisecondsSinceEpoch ~/ 1000),
          ),
      ],
      trustedDevices: [
        for (final t in state.trustedDevices)
          RsTrustedDevice(
            fingerprint: t.fingerprint,
            alias: t.alias,
            addedAtUnixSecs: BigInt.from(t.addedAt.millisecondsSinceEpoch ~/ 1000),
            lastSeenAtUnixSecs: t.lastSeenAt == null ? null : BigInt.from(t.lastSeenAt!.millisecondsSinceEpoch ~/ 1000),
          ),
      ],
    );
  }
}

/// Local-view provider for the shared-directory feature.
final shareProvider = NotifierProvider<ShareNotifier, ShareSnapshot>(
  (ref) => ShareNotifier(),
);
