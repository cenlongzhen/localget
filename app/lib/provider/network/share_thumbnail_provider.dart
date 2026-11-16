import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/util/native/directories.dart';
import 'package:localsend_app/util/native/media_thumbnail.dart';
import 'package:localsend_app/util/share_file_kind.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/share.dart';
import 'package:localsend_isolates/rust/api/cancel.dart';
import 'package:localsend_isolates/rust/api/http.dart' as rust_http;
import 'package:localsend_isolates/rust/api/model.dart' as rust_model;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('ShareThumbnail');

/// Images above this size are shown with their type icon instead.
const _maxImageBytes = 40 * 1024 * 1024;

/// Audio and video above this size are shown with their type icon instead.
const _maxMediaBytes = 120 * 1024 * 1024;

/// A preview for one remote entry: an image file on disk, or decoded bytes.
class ShareThumbnail {
  final String? filePath;
  final Uint8List? bytes;

  const ShareThumbnail.file(this.filePath) : bytes = null;

  const ShareThumbnail.bytes(this.bytes) : filePath = null;
}

class ShareThumbnailState {
  final Map<String, ShareThumbnail?> byKey;
  final Set<String> pending;

  const ShareThumbnailState({this.byKey = const {}, this.pending = const {}});
}

/// Fetches and caches previews for the files of a remote share.
///
/// A preview needs the bytes, so an image is downloaded once into the cache
/// directory, while an audio or video file is downloaded, inspected for its
/// poster image and deleted again. Files that are too large keep their icon.
class ShareThumbnailNotifier extends Notifier<ShareThumbnailState> {
  @override
  ShareThumbnailState init() => const ShareThumbnailState();

  /// Starts loading the preview of [entry] if it is not known yet.
  Future<void> request(Device device, String dirId, ShareListEntry entry) async {
    final kind = shareFileKindOf(name: entry.name, isDir: entry.isDir);
    if (kind != ShareFileKind.image && kind != ShareFileKind.audio && kind != ShareFileKind.video) return;

    final key = shareThumbnailKey(fingerprint: device.fingerprint, dirId: dirId, entry: entry);
    if (state.byKey.containsKey(key) || state.pending.contains(key)) return;
    if (entry.size > (kind == ShareFileKind.image ? _maxImageBytes : _maxMediaBytes)) {
      state = ShareThumbnailState(byKey: {...state.byKey, key: null}, pending: state.pending);
      return;
    }

    state = ShareThumbnailState(byKey: state.byKey, pending: {...state.pending, key});
    ShareThumbnail? thumbnail;
    try {
      final cacheDirectory = await getCacheDirectory();
      final extension = p.extension(entry.name).replaceFirst('.', '');
      final path = p.join(cacheDirectory, 'share_thumbs', '${sha1.convert(key.codeUnits).toString()}${extension.isEmpty ? '' : '.$extension'}');
      await Directory(p.dirname(path)).create(recursive: true);

      final events = _client(device).shareDownload(
        protocol: device.https ? rust_model.ProtocolType.https : rust_model.ProtocolType.http,
        ip: device.ip!,
        port: device.port,
        dir: dirId,
        path: entry.relPath,
        totalSize: BigInt.from(entry.size),
        targetPath: path,
        cancelToken: createCancellationToken(),
      );
      var failed = false;
      await for (final event in events) {
        if (event is rust_http.RsShareDownloadEvent_Failed) {
          failed = true;
        }
      }
      if (failed) throw 'download failed';

      if (kind == ShareFileKind.image) {
        thumbnail = ShareThumbnail.file(path);
      } else {
        thumbnail = ShareThumbnail.bytes(await extractMediaThumbnail(path, isVideo: kind == ShareFileKind.video));
        try {
          await File(path).delete();
        } catch (_) {}
      }
    } catch (e) {
      _logger.warning('Could not build a preview for ${entry.relPath}', e);
      thumbnail = null;
    }

    state = ShareThumbnailState(
      byKey: {...state.byKey, key: thumbnail},
      pending: {...state.pending}..remove(key),
    );
  }

  rust_http.RsHttpClient _client(Device device) => ref.read(httpProvider).pinnedTo(device.fingerprint);
}

final shareThumbnailProvider = NotifierProvider<ShareThumbnailNotifier, ShareThumbnailState>((ref) => ShareThumbnailNotifier());
