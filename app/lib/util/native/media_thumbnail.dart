import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_isolates/model/share.dart';
import 'package:logging/logging.dart';
import 'package:win32/win32.dart';

final _logger = Logger('MediaThumbnail');

const _thumbnailSize = 192;

/// Extracts a poster image for a local media file: the first video frame or
/// the embedded album art of an audio file. Returns null when the platform
/// cannot produce one.
Future<Uint8List?> extractMediaThumbnail(String path, {required bool isVideo}) async {
  try {
    if (Platform.isWindows) {
      return _windowsShellThumbnail(path);
    }
    if (Platform.isAndroid) {
      return await android_channel.extractMediaThumbnailAndroid(path: path, isVideo: isVideo);
    }
  } catch (e, st) {
    _logger.warning('Could not extract a thumbnail for $path', e, st);
  }
  return null;
}

/// Asks the Windows shell for the file's thumbnail. It covers video posters and
/// the album art of audio files, and falls back to the file type icon.
Uint8List? _windowsShellThumbnail(String path) {
  final coInit = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
  final shouldUninitialize = coInit == S_OK || coInit == S_FALSE;
  final pathPtr = path.toNativeUtf16();
  final iid = Guid.parse('{BCC18B79-BA16-442F-80C4-8A59C30C463B}').toNativeGUID();
  final itemOut = calloc<Pointer>();
  final bitmapOut = calloc<IntPtr>();
  Pointer<BITMAPINFO>? bmi;
  Pointer<Uint8>? pixels;
  var dc = 0;
  var bitmap = 0;
  try {
    final hr = SHCreateItemFromParsingName(pathPtr, nullptr, iid, itemOut);
    if (hr != S_OK) return null;

    final factory = IShellItemImageFactory(Pointer<COMObject>.fromAddress(itemOut.value.address));
    try {
      final size = calloc<SIZE>();
      size.ref.cx = _thumbnailSize;
      size.ref.cy = _thumbnailSize;
      // Bigger sizes are accepted so small files are not upscaled by the shell;
      // thumbnail-only keeps the result to real content instead of an icon.
      var got = factory.getImage(size.ref, SIIGBF_THUMBNAILONLY | SIIGBF_BIGGERSIZEOK, bitmapOut);
      if (got != S_OK) {
        got = factory.getImage(size.ref, SIIGBF_BIGGERSIZEOK, bitmapOut);
      }
      calloc.free(size);
      if (got != S_OK || bitmapOut.value == 0) return null;
      bitmap = bitmapOut.value;

      final info = calloc<BITMAP>();
      try {
        if (GetObject(bitmap, sizeOf<BITMAP>(), info) == 0) return null;
        final width = info.ref.bmWidth;
        final height = info.ref.bmHeight;
        if (width <= 0 || height <= 0) return null;

        dc = CreateCompatibleDC(0);
        if (dc == 0) return null;

        bmi = calloc<BITMAPINFO>();
        bmi.ref.bmiHeader
          ..biSize = sizeOf<BITMAPINFOHEADER>()
          ..biWidth = width
          // Negative height asks for a top-down DIB, which keeps the rows in
          // image order and avoids flipping the buffer afterwards.
          ..biHeight = -height
          ..biPlanes = 1
          ..biBitCount = 32
          ..biCompression = BI_RGB;
        pixels = calloc<Uint8>(width * height * 4);
        final lines = GetDIBits(dc, bitmap, 0, height, pixels, bmi, DIB_RGB_COLORS);
        if (lines == 0) return null;

        final image = img.Image.fromBytes(
          width: width,
          height: height,
          bytes: pixels.asTypedList(width * height * 4).buffer,
          order: img.ChannelOrder.bgra,
        );
        return Uint8List.fromList(img.encodePng(image, level: 3));
      } finally {
        calloc.free(info);
      }
    } finally {
      factory.release();
    }
  } finally {
    if (dc != 0) DeleteDC(dc);
    if (bitmap != 0) DeleteObject(bitmap);
    if (pixels != null) calloc.free(pixels);
    if (bmi != null) calloc.free(bmi);
    calloc.free(itemOut);
    calloc.free(bitmapOut);
    calloc.free(pathPtr);
    calloc.free(iid);
    if (shouldUninitialize) CoUninitialize();
  }
}

/// Cache key for a remote entry; the modified time invalidates it when the
/// peer replaces the file.
String shareThumbnailKey({required String fingerprint, required String dirId, required ShareListEntry entry}) =>
    '$fingerprint:$dirId:${entry.relPath}|${entry.mtimeUnix}|${entry.size}';
