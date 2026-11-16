import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Opens a file picker to select a directory.
/// Returns null if the user cancels the selection.
Future<String?> pickDirectoryPath() async {
  if (defaultTargetPlatform == TargetPlatform.android &&
      (RefenaScope.defaultRef.read(deviceRawInfoProvider).androidSdkInt ?? 0) >= android_channel.contentUriMinSdk) {
    return await android_channel.pickDirectoryPathAndroid();
  }

  if (checkPlatform([TargetPlatform.android, TargetPlatform.iOS])) {
    /// We need to use the file_picker package because file_selector does not expose the raw path.
    /// We need the raw path to properly manipulate the path to save new files, or
    /// to list files recursively.
    /// Also, on iOS, file_selector does not work with directories.
    return await FilePicker.getDirectoryPath();
  } else {
    return await file_selector.getDirectoryPath();
  }
}

/// Thrown when the user did not grant the storage access a share needs.
class ShareDirectoryAccessDenied implements Exception {
  const ShareDirectoryAccessDenied();
}

/// Picks a directory for the shared-directory feature.
///
/// The server reads shares through absolute filesystem paths, so on Android the
/// result is a path rather than a SAF content URI — which requires the
/// all-files access grant. Returns null when the user cancels the picker.
Future<String?> pickShareDirectoryPath() async {
  if (defaultTargetPlatform != TargetPlatform.android) {
    return await pickDirectoryPath();
  }

  if (!await android_channel.hasAllFilesAccessAndroid()) {
    await android_channel.requestAllFilesAccessAndroid();
    // The grant is given on a system screen, so its result only arrives once
    // this app is in the foreground again.
    await _waitForForeground();
    if (!await android_channel.hasAllFilesAccessAndroid()) {
      throw const ShareDirectoryAccessDenied();
    }
  }

  return await android_channel.pickShareDirectoryPathAndroid();
}

/// Completes on the next `resumed` lifecycle event, or after a timeout when the
/// app never leaves the foreground (e.g. the grant screen failed to open).
Future<void> _waitForForeground() async {
  final completer = Completer<void>();
  late final AppLifecycleListener listener;
  listener = AppLifecycleListener(
    onResume: () {
      if (!completer.isCompleted) completer.complete();
    },
  );
  // A pending dialog or a screen that closes instantly would otherwise hang
  // until the timeout.
  final timeout = Timer(const Duration(seconds: 60), () {
    if (!completer.isCompleted) completer.complete();
  });
  await completer.future;
  timeout.cancel();
  listener.dispose();
}
