import 'dart:async';
import 'dart:io';

import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/receive_history_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/directories.dart';
import 'package:localsend_app/util/share_file_kind.dart';
import 'package:localsend_isolates/isolate.dart' show prepareFileSaveTarget;
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/share.dart';
import 'package:localsend_isolates/rust/api/cancel.dart';
import 'package:localsend_isolates/rust/api/http.dart' as rust_http;
import 'package:localsend_isolates/rust/api/model.dart' as rust_model;
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

final _logger = Logger('RemoteShare');

/// Whether this device may browse a remote peer's shares.
enum RemoteShareStatus {
  /// Not probed yet.
  unknown,

  /// The peer lists directories we may enter. An empty list is still
  /// accessible: the peer trusts this device but has not mounted anything.
  accessible,

  /// The peer answered 403: shares are active but this device is not trusted.
  notTrusted,

  /// The peer answered 404: the share feature is not available there.
  noShares,

  /// The peer could not be reached at all.
  unreachable,
}

/// One discovered peer plus what it exposes.
class RemoteDeviceShareInfo {
  final Device device;
  final RemoteShareStatus status;
  final List<ShareDirMeta> dirs;
  final String? probeError;

  const RemoteDeviceShareInfo({
    required this.device,
    required this.status,
    this.dirs = const [],
    this.probeError,
  });

  RemoteDeviceShareInfo copyWith({
    RemoteShareStatus? status,
    List<ShareDirMeta>? dirs,
    String? probeError,
  }) {
    return RemoteDeviceShareInfo(
      device: device,
      status: status ?? this.status,
      dirs: dirs ?? this.dirs,
      probeError: probeError ?? this.probeError,
    );
  }
}

/// One running download.
class ShareDownload {
  final String fingerprint;
  final String dirId;
  final String relPath;
  final String fileName;
  final int totalSize;
  final int received;

  /// Path or content URI the bytes are written to, known before the transfer
  /// starts so a cancellation can delete the partial file.
  final String? targetPath;

  /// Same as [targetPath] once the download finished; used to open the file.
  final String? savePath;
  final String? error;

  /// Set while the transfer is running so it can be cancelled.
  final RsCancellationToken? cancelToken;

  const ShareDownload({
    required this.fingerprint,
    required this.dirId,
    required this.relPath,
    required this.fileName,
    required this.totalSize,
    this.received = 0,
    this.targetPath,
    this.savePath,
    this.error,
    this.cancelToken,
  });

  String get key => '$fingerprint:$dirId:$relPath';

  bool get isFinished => error == null && savePath != null;

  bool get isRunning => cancelToken != null;

  double get progress {
    if (error != null) return 1;
    if (totalSize <= 0) return 0;
    return (received / totalSize).clamp(0.0, 1.0);
  }

  ShareDownload copyWith({
    int? received,
    String? targetPath,
    String? savePath,
    String? error,
    RsCancellationToken? cancelToken,
    bool clearCancelToken = false,
  }) {
    return ShareDownload(
      fingerprint: fingerprint,
      dirId: dirId,
      relPath: relPath,
      fileName: fileName,
      totalSize: totalSize,
      received: received ?? this.received,
      targetPath: targetPath ?? this.targetPath,
      savePath: savePath ?? this.savePath,
      error: error ?? this.error,
      cancelToken: clearCancelToken ? null : (cancelToken ?? this.cancelToken),
    );
  }
}

/// State of the "shared devices" tab: which peer is selected, what it
/// exposes, the directory currently open, and every running download.
class RemoteShareBrowseState {
  final Map<String, RemoteDeviceShareInfo> byFingerprint;

  /// Peer shown in the capsule selector. `null` means "first accessible one".
  final String? selectedFingerprint;

  final bool scanning;
  final String? currentDirId;
  final String? currentSubPath;
  final List<ShareListEntry> currentEntries;
  final String? nextCursor;
  final bool loadingEntries;
  final Map<String, ShareDownload> downloads;

  const RemoteShareBrowseState({
    this.byFingerprint = const {},
    this.selectedFingerprint,
    this.scanning = false,
    this.currentDirId,
    this.currentSubPath,
    this.currentEntries = const [],
    this.nextCursor,
    this.loadingEntries = false,
    this.downloads = const {},
  });

  RemoteShareBrowseState copyWith({
    Map<String, RemoteDeviceShareInfo>? byFingerprint,
    String? selectedFingerprint,
    bool? scanning,
    String? currentDirId,
    String? currentSubPath,
    List<ShareListEntry>? currentEntries,
    String? nextCursor,
    bool clearNextCursor = false,
    bool? loadingEntries,
    Map<String, ShareDownload>? downloads,
  }) {
    return RemoteShareBrowseState(
      byFingerprint: byFingerprint ?? this.byFingerprint,
      selectedFingerprint: selectedFingerprint ?? this.selectedFingerprint,
      scanning: scanning ?? this.scanning,
      currentDirId: currentDirId ?? this.currentDirId,
      currentSubPath: currentSubPath ?? this.currentSubPath,
      currentEntries: currentEntries ?? this.currentEntries,
      nextCursor: clearNextCursor ? null : (nextCursor ?? this.nextCursor),
      loadingEntries: loadingEntries ?? this.loadingEntries,
      downloads: downloads ?? this.downloads,
    );
  }

  /// Peers this device may browse. A trusted peer that has mounted nothing
  /// yet stays visible, so the user can tell "trusted but empty" apart from
  /// "not there".
  List<RemoteDeviceShareInfo> get browsableDevices {
    final list = byFingerprint.values.where((e) => e.status == RemoteShareStatus.accessible).toList();
    list.sort((a, b) => a.device.alias.toLowerCase().compareTo(b.device.alias.toLowerCase()));
    return list;
  }

  RemoteDeviceShareInfo? get selectedDevice {
    final list = browsableDevices;
    if (list.isEmpty) return null;
    final selected = selectedFingerprint;
    if (selected != null) {
      for (final info in list) {
        if (info.device.fingerprint == selected) return info;
      }
    }
    return list.first;
  }

  /// Downloads belonging to the currently selected peer.
  List<ShareDownload> get downloadsOfSelected {
    final fp = selectedDevice?.device.fingerprint;
    if (fp == null) return const [];
    return downloads.values.where((d) => d.fingerprint == fp).toList();
  }
}

/// Drives the "shared devices" tab: probes peers for `share/dirs`, lists
/// directories, and downloads files with inline progress.
class RemoteShareBrowseNotifier extends Notifier<RemoteShareBrowseState> {
  static const _listLimit = 1000;

  bool _refreshQueued = false;

  @override
  RemoteShareBrowseState init() => const RemoteShareBrowseState();

  /// Probes every discovered peer for its shared directories.
  ///
  /// A probe started while another one runs is queued instead of dropped, so
  /// peers discovered mid-scan still get their turn.
  Future<void> refresh() async {
    if (state.scanning) {
      _refreshQueued = true;
      return;
    }
    state = state.copyWith(scanning: true);

    final devices = ref.read(nearbyDevicesProvider).allDevices.values.where((d) => d.ip != null).toList();
    final results = await Future.wait(devices.map(_probe));
    final next = <String, RemoteDeviceShareInfo>{
      for (final info in results) info.device.fingerprint: info,
    };

    var selected = state.selectedFingerprint;
    final browsable = next.values.where((e) => e.status == RemoteShareStatus.accessible).toList();
    if (selected == null || !browsable.any((e) => e.device.fingerprint == selected)) {
      selected = browsable.isEmpty
          ? null
          : (browsable..sort((a, b) => a.device.alias.toLowerCase().compareTo(b.device.alias.toLowerCase()))).first.device.fingerprint;
    }

    // A probe refresh must not close a directory the user is browsing, so the
    // listing fields carry over — but the selection may legitimately become
    // empty, which `copyWith` cannot express.
    state = RemoteShareBrowseState(
      byFingerprint: next,
      selectedFingerprint: selected,
      currentDirId: state.currentDirId,
      currentSubPath: state.currentSubPath,
      currentEntries: state.currentEntries,
      nextCursor: state.nextCursor,
      downloads: state.downloads,
    );

    if (_refreshQueued) {
      _refreshQueued = false;
      await refresh();
    }
  }

  Future<RemoteDeviceShareInfo> _probe(Device device) async {
    try {
      final dirs = await _client(device).shareDirs(
        protocol: _protocolOf(device),
        ip: device.ip!,
        port: device.port,
      );
      return RemoteDeviceShareInfo(
        device: device,
        status: RemoteShareStatus.accessible,
        dirs: dirs.map(_toDirMeta).toList(),
      );
    } on rust_http.RsHttpClientError_StatusCode catch (e) {
      return RemoteDeviceShareInfo(
        device: device,
        status: switch (e.status) {
          403 => RemoteShareStatus.notTrusted,
          404 => RemoteShareStatus.noShares,
          _ => RemoteShareStatus.unreachable,
        },
        probeError: e.message,
      );
    } catch (e) {
      return RemoteDeviceShareInfo(
        device: device,
        status: RemoteShareStatus.unreachable,
        probeError: e.toString(),
      );
    }
  }

  /// Switches the peer shown in the selector and drops whatever directory was
  /// open on the previous one.
  void selectDevice(String fingerprint) {
    if (state.selectedFingerprint == fingerprint) return;
    state = RemoteShareBrowseState(
      byFingerprint: state.byFingerprint,
      selectedFingerprint: fingerprint,
      scanning: state.scanning,
      downloads: state.downloads,
    );
  }

  /// Lists `dir` at [subPath] (`''` for the root).
  Future<void> openDirectory(ShareDirMeta dir, {String subPath = ''}) async {
    final info = state.selectedDevice;
    if (info == null) return;

    state = state.copyWith(
      currentDirId: dir.id,
      currentSubPath: subPath,
      loadingEntries: true,
      currentEntries: const [],
      clearNextCursor: true,
    );

    try {
      final page = await _client(info.device).shareList(
        protocol: _protocolOf(info.device),
        ip: info.device.ip!,
        port: info.device.port,
        dir: dir.id,
        sub: subPath,
        cursor: null,
        limit: _listLimit,
      );
      state = state.copyWith(
        loadingEntries: false,
        currentEntries: page.entries.map(_toEntry).toList(),
        currentSubPath: page.subPath,
        nextCursor: page.nextCursor,
        clearNextCursor: page.nextCursor == null,
      );
    } on rust_http.RsHttpClientError catch (e) {
      state = state.copyWith(loadingEntries: false, currentEntries: const []);
      throw _ShareBrowseException(t.homeTab.listFailed(error: _describe(e)));
    }
  }

  /// Appends the next page of the directory currently open.
  Future<void> loadMore() async {
    final info = state.selectedDevice;
    final dirId = state.currentDirId;
    final cursor = state.nextCursor;
    if (info == null || dirId == null || cursor == null || state.loadingEntries) return;

    state = state.copyWith(loadingEntries: true);
    try {
      final page = await _client(info.device).shareList(
        protocol: _protocolOf(info.device),
        ip: info.device.ip!,
        port: info.device.port,
        dir: dirId,
        sub: state.currentSubPath ?? '',
        cursor: cursor,
        limit: _listLimit,
      );
      state = state.copyWith(
        loadingEntries: false,
        currentEntries: [...state.currentEntries, ...page.entries.map(_toEntry)],
        nextCursor: page.nextCursor,
        clearNextCursor: page.nextCursor == null,
      );
    } on rust_http.RsHttpClientError catch (e) {
      state = state.copyWith(loadingEntries: false);
      throw _ShareBrowseException(t.homeTab.listFailed(error: _describe(e)));
    }
  }

  /// Steps back to the parent of the open directory; `false` at the root.
  Future<bool> goUp(ShareDirMeta dir) async {
    final sub = state.currentSubPath ?? '';
    if (sub.isEmpty) return false;
    final parts = sub.split('/')..removeLast();
    await openDirectory(dir, subPath: parts.join('/'));
    return true;
  }

  /// Downloads one file into the configured destination directory.
  Future<void> download(ShareDirMeta dir, ShareListEntry entry) async {
    final info = state.selectedDevice;
    if (info == null) return;

    final token = createCancellationToken();
    final download = ShareDownload(
      fingerprint: info.device.fingerprint,
      dirId: dir.id,
      relPath: entry.relPath,
      fileName: entry.name,
      totalSize: entry.size,
      cancelToken: token,
    );
    // A failed entry may be started again; only a running one is left alone.
    if (state.downloads[download.key]?.isRunning ?? false) return;
    state = state.copyWith(downloads: {...state.downloads, download.key: download});

    try {
      final settings = ref.read(settingsProvider);
      final destination = settings.destination ?? await getDefaultDestinationDirectory();
      final cacheDirectory = await getCacheDirectory();
      final target = await prepareFileSaveTarget(
        destinationDirectory: destination,
        cacheDirectory: cacheDirectory,
        fileName: entry.name,
        saveToGallery: false,
        createdDirectories: {},
      );
      _updateDownload(download.key, (d) => d.copyWith(targetPath: target.displayPath));

      final events = _client(info.device).shareDownload(
        protocol: _protocolOf(info.device),
        ip: info.device.ip!,
        port: info.device.port,
        dir: dir.id,
        path: entry.relPath,
        totalSize: BigInt.from(entry.size),
        targetPath: target.path,
        targetFileDescriptor: target.fileDescriptor,
        cancelToken: token,
      );

      await for (final event in events) {
        switch (event) {
          case rust_http.RsShareDownloadEvent_Progress():
            _updateDownload(download.key, (d) => d.copyWith(received: event.received.toInt()));
          case rust_http.RsShareDownloadEvent_Finished():
            _updateDownload(download.key, (d) => d.copyWith(received: d.totalSize, savePath: target.displayPath, clearCancelToken: true));
            _addToHistory(entry, target.displayPath, info.device.alias);
          case rust_http.RsShareDownloadEvent_Failed():
            // A cancelled download has already been removed from the state.
            unawaited(_failDownload(download.key, _describe(event.error)));
        }
      }
    } catch (e) {
      unawaited(_failDownload(download.key, e.toString()));
    }
  }

  /// Marks a download as failed and removes whatever it wrote so far.
  Future<void> _failDownload(String key, String error) async {
    final current = state.downloads[key];
    if (current == null) return;
    _updateDownload(key, (d) => d.copyWith(error: error, clearCancelToken: true));
    await _deletePartialFile(current.targetPath);
  }

  /// Cancels a running download and deletes the partially written file.
  Future<void> cancelDownload(String key) async {
    final download = state.downloads[key];
    if (download == null || !download.isRunning) return;

    download.cancelToken?.cancel();
    state = state.copyWith(downloads: {...state.downloads}..remove(key));
    await _deletePartialFile(download.targetPath);
  }

  Future<void> _deletePartialFile(String? target) async {
    if (target == null) return;
    try {
      if (target.startsWith('content://')) {
        await android_channel.deleteContentUriAndroid(uri: target);
      } else {
        final file = File(target);
        if (await file.exists()) await file.delete();
      }
    } catch (e) {
      _logger.warning('Could not delete the partial download $target', e);
    }
  }

  /// Drops the downloads of one directory that already ended, so a later visit
  /// shows the download icon again; a transfer still in flight keeps running.
  void clearFinishedDownloads(String dirId) {
    final remaining = {
      for (final entry in state.downloads.entries)
        if (entry.value.dirId != dirId || entry.value.isRunning) entry.key: entry.value,
    };
    if (remaining.length == state.downloads.length) return;
    state = state.copyWith(downloads: remaining);
  }

  void _addToHistory(ShareListEntry entry, String path, String peerAlias) {
    final kind = shareFileKindOf(name: entry.name, isDir: false);
    unawaited(
      ref
          .redux(receiveHistoryProvider)
          .dispatchAsync(
            AddHistoryEntryAction(
              entryId: const Uuid().v4(),
              fileName: entry.name,
              fileType: kind.fileType,
              path: path,
              savedToGallery: false,
              isMessage: false,
              fileSize: entry.size,
              senderAlias: peerAlias,
              timestamp: DateTime.now().toUtc(),
            ),
          ),
    );
  }

  void _updateDownload(String key, ShareDownload Function(ShareDownload) update) {
    final current = state.downloads[key];
    if (current == null) return;
    state = state.copyWith(downloads: {...state.downloads, key: update(current)});
  }

  rust_http.RsHttpClient _client(Device device) => ref.read(httpProvider).pinnedTo(device.fingerprint);

  rust_model.ProtocolType _protocolOf(Device device) => device.https ? rust_model.ProtocolType.https : rust_model.ProtocolType.http;

  static ShareDirMeta _toDirMeta(rust_http.RsShareDir dir) => ShareDirMeta(id: dir.id, name: dir.name, readOnly: dir.readOnly);

  static ShareListEntry _toEntry(rust_http.RsShareEntry entry) => ShareListEntry(
    name: entry.name,
    isDir: entry.isDir,
    size: entry.size.toInt(),
    mtimeUnix: entry.mtime,
    relPath: entry.relPath,
  );

  static String _describe(rust_http.RsHttpClientError error) {
    return switch (error) {
      rust_http.RsHttpClientError_StatusCode() => 'HTTP ${error.status}${error.message == null ? '' : '：${error.message}'}',
      rust_http.RsHttpClientError_Reqwest() => error.field0,
      rust_http.RsHttpClientError_Json() => 'JSON',
      rust_http.RsHttpClientError_Io() => error.field0,
      rust_http.RsHttpClientError_Other() => error.field0,
    };
  }
}

class _ShareBrowseException implements Exception {
  final String message;

  _ShareBrowseException(this.message);

  @override
  String toString() => message;
}

final remoteShareBrowseProvider = NotifierProvider<RemoteShareBrowseNotifier, RemoteShareBrowseState>(
  (ref) => RemoteShareBrowseNotifier(),
);
