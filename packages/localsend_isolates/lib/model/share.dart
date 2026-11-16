import 'package:flutter/foundation.dart' show immutable;

import 'package:localsend_isolates/model/device.dart' show DeviceType;

/// Local model mirroring `share::ShareKind` in `packages/core/src/share/mod.rs`.
///
/// - [ShareKind.longTerm]   → persisted via `settings.share.directories`, lives
///   across server restarts until the user explicitly removes it.
/// - [ShareKind.sessionOnly] → held **in memory only**; dropped automatically
///   when the HTTP server is stopped.
enum ShareKind { longTerm, sessionOnly }

/// A single directory the local user has published for trusted peers.
///
/// Field layout intentionally mirrors the Rust counterpart so the future
/// FRB-generated model can align without a data-loss pass.
@immutable
class SharedDirectory {
  final String id;
  final String name;
  final String root;
  final ShareKind kind;
  final bool readOnly;
  final bool enabled;
  final DateTime addedAt;

  const SharedDirectory({
    required this.id,
    required this.name,
    required this.root,
    required this.kind,
    required this.readOnly,
    required this.enabled,
    required this.addedAt,
  });

  bool get isTemporary => kind == ShareKind.sessionOnly;

  SharedDirectory copyWith({
    String? name,
    String? root,
    ShareKind? kind,
    bool? readOnly,
    bool? enabled,
    DateTime? addedAt,
  }) {
    return SharedDirectory(
      id: id,
      name: name ?? this.name,
      root: root ?? this.root,
      kind: kind ?? this.kind,
      readOnly: readOnly ?? this.readOnly,
      enabled: enabled ?? this.enabled,
      addedAt: addedAt ?? this.addedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SharedDirectory &&
          other.id == id &&
          other.name == name &&
          other.root == root &&
          other.kind == kind &&
          other.readOnly == readOnly &&
          other.enabled == enabled &&
          other.addedAt == addedAt;

  @override
  int get hashCode =>
      Object.hash(id, name, root, kind, readOnly, enabled, addedAt);
}

/// A peer granted browse/download access to every *enabled* directory.
///
/// `fingerprint` is a 64-char uppercase hex string — the SHA-256 of the peer's
/// mTLS client certificate DER, matching the value produced by
/// `RequestClientInfo::cert_fingerprint` on the Rust side.
@immutable
class TrustedDevice {
  final String fingerprint;
  final String alias;
  final DateTime addedAt;
  final DateTime? lastSeenAt;

  /// Device kind captured when trust was granted, so the row keeps its
  /// phone/computer icon while the peer is offline.
  final DeviceType deviceType;

  const TrustedDevice({
    required this.fingerprint,
    required this.alias,
    required this.addedAt,
    this.lastSeenAt,
    this.deviceType = DeviceType.desktop,
  });

  /// Coarse human-readable form: `ABCDEF12 3456789A`.
  String get shortFingerprint {
    if (fingerprint.length != 64) return fingerprint;
    return '${fingerprint.substring(0, 8)} ${fingerprint.substring(56)}';
  }

  TrustedDevice copyWith({DateTime? lastSeenAt, DeviceType? deviceType}) {
    return TrustedDevice(
      fingerprint: fingerprint,
      alias: alias,
      addedAt: addedAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      deviceType: deviceType ?? this.deviceType,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrustedDevice &&
          other.fingerprint == fingerprint &&
          other.alias == alias &&
          other.addedAt == addedAt &&
          other.lastSeenAt == lastSeenAt &&
          other.deviceType == deviceType;

  @override
  int get hashCode =>
      Object.hash(fingerprint, alias, addedAt, lastSeenAt, deviceType);
}

/// A single row returned by `GET /api/localsend/v2/share/list`.
@immutable
class ShareListEntry {
  final String name;
  final bool isDir;
  final int size;
  /// Unix seconds; `0` when the sender's filesystem does not report one.
  final int mtimeUnix;
  /// POSIX-style relative path from the shared directory root — feed back
  /// verbatim into `share/download?path=…&dir=…`.
  final String relPath;

  const ShareListEntry({
    required this.name,
    required this.isDir,
    required this.size,
    required this.mtimeUnix,
    required this.relPath,
  });
}

/// Top-level metadata visible via `GET /api/localsend/v2/share/dirs`.
@immutable
class ShareDirMeta {
  final String id;
  final String name;
  final bool readOnly;

  const ShareDirMeta({
    required this.id,
    required this.name,
    required this.readOnly,
  });
}

/// Aggregate view handed between the app UI, isolate and Rust registry.
///
/// The app-side provider owns the editable copy; every mutation is mirrored
/// into the running server's registry through the isolate layer.
@immutable
class ShareSnapshot {
  final List<SharedDirectory> directories;
  final List<TrustedDevice> trustedDevices;

  const ShareSnapshot({
    this.directories = const [],
    this.trustedDevices = const [],
  });

  ShareSnapshot copyWith({
    List<SharedDirectory>? directories,
    List<TrustedDevice>? trustedDevices,
  }) {
    return ShareSnapshot(
      directories: directories ?? this.directories,
      trustedDevices: trustedDevices ?? this.trustedDevices,
    );
  }
}
