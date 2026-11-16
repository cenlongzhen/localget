import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:localsend_isolates/model/file_type.dart';

/// Broad file category used for icons, filters and sorting of the browser.
enum ShareFileKind {
  folder,
  image,
  audio,
  video,
  pdf,
  word,
  spreadsheet,
  presentation,
  text,
  ebook,
  document,
  archive,
  installer,
  other,
}

const _imageExtensions = {
  'jpg', 'jpeg', 'jpe', 'png', 'gif', 'bmp', 'webp', 'svg', 'heic', 'heif', 'avif', //
  'tif', 'tiff', 'ico', 'dng', 'cr2', 'cr3', 'nef', 'arw', 'raf', 'orf', 'rw2', 'psd', 'jxl',
};

const _audioExtensions = {
  'mp3', 'flac', 'wav', 'aac', 'ogg', 'oga', 'opus', 'm4a', 'wma', 'aiff', 'aif', //
  'alac', 'amr', 'mid', 'midi', 'ape', 'wv', 'dsf', 'dff', 'mka', 'ra',
};

const _videoExtensions = {
  'mp4', 'mkv', 'mov', 'avi', 'wmv', 'flv', 'webm', 'm4v', 'mpg', 'mpeg', //
  '3gp', '3g2', 'ts', 'm2ts', 'mts', 'ogv', 'rmvb', 'rm', 'vob', 'asf', 'divx',
};

const _wordExtensions = {'doc', 'docx', 'docm', 'dot', 'dotx', 'odt', 'rtf', 'pages', 'wpd'};
const _spreadsheetExtensions = {'xls', 'xlsx', 'xlsm', 'xlsb', 'ods', 'csv', 'tsv', 'numbers'};
const _presentationExtensions = {'ppt', 'pptx', 'pptm', 'odp', 'key'};
const _textExtensions = {'txt', 'md', 'markdown', 'log', 'ini', 'cfg', 'conf', 'yaml', 'yml', 'json', 'xml', 'toml', 'srt', 'vtt'};
const _ebookExtensions = {'epub', 'mobi', 'azw', 'azw3', 'fb2', 'djvu', 'cbz', 'cbr'};
const _documentExtensions = {'htm', 'html', 'mht', 'mhtml', 'tex', 'rst', 'odg'};

const _archiveExtensions = {
  'zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'tbz', 'tbz2', 'xz', 'txz', //
  'zst', 'zipx', 'iso', 'cab', 'lz', 'lzma', 'arj', 'z', 'tar.gz', 'tar.xz', 'tar.zst',
};

const _windowsInstallers = {'exe', 'msi', 'msix', 'msixbundle', 'appx', 'appxbundle'};
const _androidInstallers = {'apk', 'apks', 'aab', 'xapk', 'apkm'};
const _macosInstallers = {'dmg', 'pkg', 'mpkg'};
const _linuxInstallers = {'deb', 'rpm', 'appimage', 'flatpak', 'flatpakref', 'snap'};
const _iosInstallers = {'ipa'};

const _installerExtensions = {
  ..._windowsInstallers,
  ..._androidInstallers,
  ..._macosInstallers,
  ..._linuxInstallers,
  ..._iosInstallers,
};

/// Classifies a remote share entry by its name.
ShareFileKind shareFileKindOf({required String name, required bool isDir}) {
  if (isDir) return ShareFileKind.folder;
  final dot = name.lastIndexOf('.');
  if (dot == -1 || dot == name.length - 1) return ShareFileKind.other;
  final extension = name.substring(dot + 1).toLowerCase();
  if (_imageExtensions.contains(extension)) return ShareFileKind.image;
  if (_audioExtensions.contains(extension)) return ShareFileKind.audio;
  if (_videoExtensions.contains(extension)) return ShareFileKind.video;
  if (extension == 'pdf') return ShareFileKind.pdf;
  if (_wordExtensions.contains(extension)) return ShareFileKind.word;
  if (_spreadsheetExtensions.contains(extension)) return ShareFileKind.spreadsheet;
  if (_presentationExtensions.contains(extension)) return ShareFileKind.presentation;
  if (_textExtensions.contains(extension)) return ShareFileKind.text;
  if (_ebookExtensions.contains(extension)) return ShareFileKind.ebook;
  if (_documentExtensions.contains(extension)) return ShareFileKind.document;
  if (_archiveExtensions.contains(extension)) return ShareFileKind.archive;
  if (_installerExtensions.contains(extension)) return ShareFileKind.installer;
  return ShareFileKind.other;
}

/// Platform of an installer file, or `null` for anything else.
TargetPlatform? installerPlatformOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot == -1) return null;
  final extension = name.substring(dot + 1).toLowerCase();
  if (_androidInstallers.contains(extension)) return TargetPlatform.android;
  if (_windowsInstallers.contains(extension)) return TargetPlatform.windows;
  if (_macosInstallers.contains(extension)) return TargetPlatform.macOS;
  if (_linuxInstallers.contains(extension)) return TargetPlatform.linux;
  if (_iosInstallers.contains(extension)) return TargetPlatform.iOS;
  return null;
}

extension ShareFileKindExt on ShareFileKind {
  bool get isDocument =>
      this == ShareFileKind.pdf ||
      this == ShareFileKind.word ||
      this == ShareFileKind.spreadsheet ||
      this == ShareFileKind.presentation ||
      this == ShareFileKind.text ||
      this == ShareFileKind.ebook ||
      this == ShareFileKind.document;

  IconData icon({TargetPlatform? installerPlatform}) {
    return switch (this) {
      ShareFileKind.folder => Icons.folder_outlined,
      ShareFileKind.image => Icons.image_outlined,
      ShareFileKind.audio => Icons.audiotrack,
      ShareFileKind.video => Icons.movie_outlined,
      ShareFileKind.pdf => Icons.picture_as_pdf_outlined,
      ShareFileKind.word => Icons.description_outlined,
      ShareFileKind.spreadsheet => Icons.table_chart_outlined,
      ShareFileKind.presentation => Icons.slideshow_outlined,
      ShareFileKind.text => Icons.subject,
      ShareFileKind.ebook => Icons.menu_book_outlined,
      ShareFileKind.document => Icons.article_outlined,
      ShareFileKind.archive => Icons.folder_zip_outlined,
      ShareFileKind.installer => switch (installerPlatform) {
        TargetPlatform.android => Icons.android,
        TargetPlatform.iOS => Icons.phone_iphone,
        TargetPlatform.macOS => Icons.laptop_mac,
        TargetPlatform.linux => Icons.laptop_chromebook,
        TargetPlatform.windows => Icons.desktop_windows_outlined,
        _ => Icons.install_desktop_outlined,
      },
      ShareFileKind.other => Icons.insert_drive_file_outlined,
    };
  }

  /// Coarse protocol type used by the receive history.
  FileType get fileType {
    return switch (this) {
      ShareFileKind.image => FileType.image,
      ShareFileKind.video => FileType.video,
      ShareFileKind.pdf => FileType.pdf,
      ShareFileKind.word ||
      ShareFileKind.spreadsheet ||
      ShareFileKind.presentation ||
      ShareFileKind.text ||
      ShareFileKind.ebook ||
      ShareFileKind.document => FileType.text,
      ShareFileKind.installer => FileType.apk,
      _ => FileType.other,
    };
  }

  /// Rank used by "sort by type": installers group by platform with the
  /// current platform first.
  int typeRank(String name) {
    if (this == ShareFileKind.installer) {
      final platform = installerPlatformOf(name);
      if (platform == defaultTargetPlatform) return -1;
      return platform?.index ?? 999;
    }
    return index;
  }
}

/// Filters offered by the browser toolbar.
enum ShareFileFilter {
  none,
  images,
  audio,
  videos,
  documents,
  installers,
  archives;

  bool matches(ShareFileKind kind) {
    return switch (this) {
      ShareFileFilter.none => true,
      ShareFileFilter.images => kind == ShareFileKind.image,
      ShareFileFilter.audio => kind == ShareFileKind.audio,
      ShareFileFilter.videos => kind == ShareFileKind.video,
      ShareFileFilter.documents => kind.isDocument,
      ShareFileFilter.installers => kind == ShareFileKind.installer,
      ShareFileFilter.archives => kind == ShareFileKind.archive,
    };
  }
}

/// Sort orders offered by the browser toolbar.
enum ShareSortOrder {
  name,
  type,
  sizeAsc,
  sizeDesc,
  newest,
  oldest,
}
