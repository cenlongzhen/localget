import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/receive_history_page.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/remote_share_provider.dart';
import 'package:localsend_app/provider/network/share_thumbnail_provider.dart';
import 'package:localsend_app/util/device_type_ext.dart';
import 'package:localsend_app/util/native/media_thumbnail.dart';
import 'package:localsend_app/util/native/open_file.dart';
import 'package:localsend_app/util/share_file_kind.dart';
import 'package:localsend_app/widget/empty_state_view.dart';
import 'package:localsend_app/widget/list_tile/custom_list_tile.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';
import 'package:localsend_isolates/model/share.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// Fourth home tab: browse the directories other LocalSend devices share with
/// this one.
///
/// The capsule row on top switches between peers — a device may be trusted by
/// several of them, and every peer exposes its own directory list.
class SharedDevicesTab extends StatefulWidget {
  const SharedDevicesTab({super.key});

  @override
  State<SharedDevicesTab> createState() => _SharedDevicesTabState();
}

class _SharedDevicesTabState extends State<SharedDevicesTab> {
  Set<String>? _knownFingerprints;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(context.ref.notifier(remoteShareBrowseProvider).refresh());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.ref.watch(remoteShareBrowseProvider);
    final peers = state.browsableDevices;
    final selected = state.selectedDevice;

    // Discovery usually finishes after this tab is built, so re-probe whenever
    // the set of visible peers changes.
    final fingerprints = context.ref.watch(nearbyDevicesProvider.select((state) => state.allDevices.keys.toSet()));
    if (_knownFingerprints != null && !setEquals(_knownFingerprints, fingerprints)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(context.ref.notifier(remoteShareBrowseProvider).refresh());
        }
      });
    }
    _knownFingerprints = fingerprints;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: ResponsiveListView.defaultMaxWidth),
        child: Column(
          children: [
            if (peers.isNotEmpty)
              _PeerSelector(
                peers: peers,
                selectedFingerprint: selected?.device.fingerprint,
                onSelected: (fp) => context.ref.notifier(remoteShareBrowseProvider).selectDevice(fp),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => context.ref.notifier(remoteShareBrowseProvider).refresh(),
                child: _body(state, peers, selected),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(RemoteShareBrowseState state, List<RemoteDeviceShareInfo> peers, RemoteDeviceShareInfo? selected) {
    if (state.scanning && peers.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (peers.isEmpty) {
      return _EmptyState(byFingerprint: state.byFingerprint);
    }
    final dirs = selected?.dirs ?? const <ShareDirMeta>[];
    if (dirs.isEmpty) {
      return EmptyStateView(
        icon: Icons.folder_off_outlined,
        message: t.homeTab.noDirectories,
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(15, 4, 15, 30),
      itemCount: dirs.length,
      itemBuilder: (context, index) {
        final dir = dirs[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: CustomListTile(
            icon: const Icon(Icons.folder_outlined, size: 46),
            title: Text(dir.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subTitle: Text(
              dir.readOnly ? t.homeTab.readOnly : t.homeTab.readWrite,
              style: const TextStyle(color: Colors.grey),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(() => RemoteShareDirectoryPage(dir: dir)),
          ),
        );
      },
    );
  }
}

/// Capsule-style segmented control listing every browsable peer.
class _PeerSelector extends StatelessWidget {
  final List<RemoteDeviceShareInfo> peers;
  final String? selectedFingerprint;
  final ValueChanged<String> onSelected;

  const _PeerSelector({
    required this.peers,
    required this.selectedFingerprint,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(15, 16, 15, 8),
        itemCount: peers.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final peer = peers[index];
          final selected = peer.device.fingerprint == selectedFingerprint;
          return ChoiceChip(
            selected: selected,
            showCheckmark: false,
            avatar: Icon(
              peer.device.deviceType.icon,
              size: 18,
              color: selected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
            ),
            label: Text(peer.device.alias),
            labelStyle: TextStyle(
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              color: selected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
            ),
            selectedColor: colorScheme.primary,
            onSelected: (_) => onSelected(peer.device.fingerprint),
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final Map<String, RemoteDeviceShareInfo> byFingerprint;

  const _EmptyState({required this.byFingerprint});

  @override
  Widget build(BuildContext context) {
    final notTrusted = byFingerprint.values.where((e) => e.status == RemoteShareStatus.notTrusted).length;
    final hint = notTrusted > 0 ? '${t.homeTab.notTrusted(count: notTrusted)}\n${t.homeTab.notTrustedHint}' : t.homeTab.empty;
    return EmptyStateView(
      icon: Icons.folder_shared_outlined,
      message: hint,
    );
  }
}

/// Files inside one shared directory of the selected peer.
class RemoteShareDirectoryPage extends StatefulWidget {
  final ShareDirMeta dir;

  const RemoteShareDirectoryPage({super.key, required this.dir});

  @override
  State<RemoteShareDirectoryPage> createState() => _RemoteShareDirectoryPageState();
}

class _RemoteShareDirectoryPageState extends State<RemoteShareDirectoryPage> {
  bool _grid = false;
  ShareSortOrder _sort = ShareSortOrder.name;
  ShareFileFilter _filter = ShareFileFilter.none;
  RemoteShareBrowseNotifier? _browse;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_browse != null) return;
    _browse = context.ref.notifier(remoteShareBrowseProvider);
    // The "already downloaded" mark belongs to one visit only, so a transfer
    // that finished in the background does not resurface on the next visit.
    _browse?.clearFinishedDownloads(widget.dir.id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_open(''));
    });
  }

  @override
  void dispose() {
    _browse?.clearFinishedDownloads(widget.dir.id);
    super.dispose();
  }

  Future<void> _open(String subPath) async {
    try {
      await context.ref.notifier(remoteShareBrowseProvider).openDirectory(widget.dir, subPath: subPath);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _loadMore() async {
    try {
      await context.ref.notifier(remoteShareBrowseProvider).loadMore();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _goUp() async {
    try {
      await context.ref.notifier(remoteShareBrowseProvider).goUp(widget.dir);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  void _openHistory() {
    unawaited(context.push(() => const ReceiveHistoryPage()));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.ref.watch(remoteShareBrowseProvider);
    final subPath = state.currentSubPath ?? '';
    final parts = subPath.isEmpty ? const <String>[] : subPath.split('/');
    final entries = _visibleEntries(state.currentEntries);
    final fingerprint = state.selectedDevice?.device.fingerprint ?? '';
    final dirId = state.currentDirId ?? widget.dir.id;

    return PopScope(
      // Back inside a sub-directory steps one level up instead of leaving.
      canPop: parts.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_goUp());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.dir.name),
          actions: [
            IconButton(
              tooltip: t.homeTab.history,
              icon: const Icon(Icons.history),
              onPressed: _openHistory,
            ),
            IconButton(
              tooltip: _grid ? t.homeTab.viewList : t.homeTab.viewGrid,
              icon: Icon(_grid ? Icons.view_list_outlined : Icons.grid_view_outlined),
              onPressed: () => setState(() => _grid = !_grid),
            ),
            _SortFilterButton(
              sort: _sort,
              filter: _filter,
              onSortChanged: (sort) => setState(() => _sort = sort),
              onFilterChanged: (filter) => setState(() => _filter = filter),
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(42),
            child: Column(
              children: [
                const Divider(height: 1),
                _Breadcrumb(
                  rootName: widget.dir.name,
                  parts: parts,
                  onTapDepth: (depth) => unawaited(_open(parts.take(depth).join('/'))),
                ),
                const Divider(height: 1),
              ],
            ),
          ),
        ),
        body: state.loadingEntries
            ? const Center(child: CircularProgressIndicator())
            : entries.isEmpty
            ? Center(child: Text(state.currentEntries.isEmpty ? t.homeTab.emptyDirectory : t.homeTab.filteredEmpty))
            : _grid
            ? _EntryGrid(
                entries: entries,
                downloads: state.downloads,
                fingerprint: fingerprint,
                dirId: dirId,
                onOpenDir: (entry) => unawaited(_open(entry.relPath)),
                onDownload: (entry) => context.ref.notifier(remoteShareBrowseProvider).download(widget.dir, entry),
                onCancel: (key) => context.ref.notifier(remoteShareBrowseProvider).cancelDownload(key),
                hasMore: state.nextCursor != null,
                onLoadMore: _loadMore,
              )
            : _EntryList(
                entries: entries,
                downloads: state.downloads,
                fingerprint: fingerprint,
                dirId: dirId,
                onOpenDir: (entry) => unawaited(_open(entry.relPath)),
                onDownload: (entry) => context.ref.notifier(remoteShareBrowseProvider).download(widget.dir, entry),
                onCancel: (key) => context.ref.notifier(remoteShareBrowseProvider).cancelDownload(key),
                hasMore: state.nextCursor != null,
                onLoadMore: _loadMore,
              ),
      ),
    );
  }

  /// Applies the toolbar filter and sort order to the entries loaded so far.
  List<ShareListEntry> _visibleEntries(List<ShareListEntry> entries) {
    final visible = <ShareListEntry>[];
    for (final entry in entries) {
      if (entry.isDir) {
        // Directories stay reachable regardless of the file filter.
        visible.add(entry);
        continue;
      }
      if (_filter.matches(shareFileKindOf(name: entry.name, isDir: false))) {
        visible.add(entry);
      }
    }

    int byName(ShareListEntry a, ShareListEntry b) => a.name.toLowerCase().compareTo(b.name.toLowerCase());
    int byType(ShareListEntry a, ShareListEntry b) =>
        shareFileKindOf(name: a.name, isDir: a.isDir).typeRank(a.name).compareTo(shareFileKindOf(name: b.name, isDir: b.isDir).typeRank(b.name));

    // Installers are always grouped by platform, current platform first.
    final groupByType = _sort == ShareSortOrder.type || _filter == ShareFileFilter.installers;

    visible.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      if (groupByType) {
        final typeResult = byType(a, b);
        if (typeResult != 0) return typeResult;
      }
      final result = switch (_sort) {
        ShareSortOrder.name => byName(a, b),
        ShareSortOrder.type => 0,
        ShareSortOrder.sizeAsc => a.size.compareTo(b.size),
        ShareSortOrder.sizeDesc => b.size.compareTo(a.size),
        ShareSortOrder.newest => b.mtimeUnix.compareTo(a.mtimeUnix),
        ShareSortOrder.oldest => a.mtimeUnix.compareTo(b.mtimeUnix),
      };
      return result != 0 ? result : byName(a, b);
    });
    return visible;
  }
}

class _SortFilterButton extends StatelessWidget {
  final ShareSortOrder sort;
  final ShareFileFilter filter;
  final ValueChanged<ShareSortOrder> onSortChanged;
  final ValueChanged<ShareFileFilter> onFilterChanged;

  const _SortFilterButton({
    required this.sort,
    required this.filter,
    required this.onSortChanged,
    required this.onFilterChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return PopupMenuButton<Object>(
      tooltip: t.homeTab.sortBy,
      icon: Icon(
        filter == ShareFileFilter.none ? Icons.sort : Icons.filter_list,
        color: filter == ShareFileFilter.none ? null : colorScheme.primary,
      ),
      onSelected: (value) {
        if (value is ShareSortOrder) onSortChanged(value);
        if (value is ShareFileFilter) onFilterChanged(value);
      },
      itemBuilder: (context) => [
        for (final order in ShareSortOrder.values)
          CheckedPopupMenuItem<Object>(
            value: order,
            checked: order == sort,
            child: Text(switch (order) {
              ShareSortOrder.name => t.homeTab.sortName,
              ShareSortOrder.type => t.homeTab.sortType,
              ShareSortOrder.sizeAsc => t.homeTab.sortSizeAsc,
              ShareSortOrder.sizeDesc => t.homeTab.sortSizeDesc,
              ShareSortOrder.newest => t.homeTab.sortNewest,
              ShareSortOrder.oldest => t.homeTab.sortOldest,
            }),
          ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem<Object>(
          value: ShareFileFilter.none,
          checked: filter == ShareFileFilter.none,
          child: Text(t.general.files),
        ),
        for (final value in ShareFileFilter.values.where((e) => e != ShareFileFilter.none))
          CheckedPopupMenuItem<Object>(
            value: value,
            checked: value == filter,
            child: Text(switch (value) {
              ShareFileFilter.images => t.homeTab.filterImages,
              ShareFileFilter.audio => t.homeTab.filterAudio,
              ShareFileFilter.videos => t.homeTab.filterVideos,
              ShareFileFilter.documents => t.homeTab.filterDocuments,
              ShareFileFilter.installers => t.homeTab.filterInstallers,
              ShareFileFilter.archives => t.homeTab.filterArchives,
              ShareFileFilter.none => t.general.files,
            }),
          ),
      ],
    );
  }
}

/// Clickable path trail: the directory root followed by every level entered.
class _Breadcrumb extends StatelessWidget {
  final String rootName;
  final List<String> parts;
  final ValueChanged<int> onTapDepth;

  const _Breadcrumb({
    required this.rootName,
    required this.parts,
    required this.onTapDepth,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall;
    return SizedBox(
      height: 40,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var depth = 0; depth <= parts.length; depth++) ...[
              if (depth > 0) Icon(Icons.chevron_right, size: 16, color: colorScheme.onSurfaceVariant),
              InkWell(
                onTap: depth == parts.length ? null : () => onTapDepth(depth),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                  child: Text(
                    depth == 0 ? rootName : parts[depth - 1],
                    style: depth == parts.length
                        ? style?.copyWith(color: colorScheme.onSurface, fontWeight: FontWeight.w600)
                        : style?.copyWith(color: colorScheme.primary),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _downloadKey(String fingerprint, String dirId, ShareListEntry entry) => '$fingerprint:$dirId:${entry.relPath}';

class _EntryList extends StatelessWidget {
  final List<ShareListEntry> entries;
  final Map<String, ShareDownload> downloads;
  final String fingerprint;
  final String dirId;
  final ValueChanged<ShareListEntry> onOpenDir;
  final ValueChanged<ShareListEntry> onDownload;
  final ValueChanged<String> onCancel;
  final bool hasMore;
  final Future<void> Function() onLoadMore;

  const _EntryList({
    required this.entries,
    required this.downloads,
    required this.fingerprint,
    required this.dirId,
    required this.onOpenDir,
    required this.onDownload,
    required this.onCancel,
    required this.hasMore,
    required this.onLoadMore,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: entries.length + (hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= entries.length) {
          return _LoadMoreButton(onPressed: onLoadMore);
        }
        final entry = entries[index];
        return _EntryRow(
          entry: entry,
          download: downloads[_downloadKey(fingerprint, dirId, entry)],
          onOpenDir: () => onOpenDir(entry),
          onDownload: () => onDownload(entry),
          onCancel: onCancel,
        );
      },
    );
  }
}

class _EntryGrid extends StatelessWidget {
  final List<ShareListEntry> entries;
  final Map<String, ShareDownload> downloads;
  final String fingerprint;
  final String dirId;
  final ValueChanged<ShareListEntry> onOpenDir;
  final ValueChanged<ShareListEntry> onDownload;
  final ValueChanged<String> onCancel;
  final bool hasMore;
  final Future<void> Function() onLoadMore;

  const _EntryGrid({
    required this.entries,
    required this.downloads,
    required this.fingerprint,
    required this.dirId,
    required this.onOpenDir,
    required this.onDownload,
    required this.onCancel,
    required this.hasMore,
    required this.onLoadMore,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        mainAxisExtent: 168,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: entries.length + (hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= entries.length) {
          return Center(
            child: TextButton(onPressed: onLoadMore, child: Text(t.homeTab.loadMore)),
          );
        }
        final entry = entries[index];
        return _GridCell(
          entry: entry,
          download: downloads[_downloadKey(fingerprint, dirId, entry)],
          fingerprint: fingerprint,
          dirId: dirId,
          onOpenDir: () => onOpenDir(entry),
          onDownload: () => onDownload(entry),
          onCancel: onCancel,
        );
      },
    );
  }
}

class _LoadMoreButton extends StatelessWidget {
  final Future<void> Function() onPressed;

  const _LoadMoreButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: TextButton(
          onPressed: onPressed,
          child: Text(t.homeTab.loadMore),
        ),
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  final ShareListEntry entry;
  final ShareDownload? download;
  final VoidCallback onOpenDir;
  final VoidCallback onDownload;
  final ValueChanged<String> onCancel;

  const _EntryRow({
    required this.entry,
    required this.download,
    required this.onOpenDir,
    required this.onDownload,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final kind = shareFileKindOf(name: entry.name, isDir: entry.isDir);

    return ListTile(
      leading: Icon(kind.icon(installerPlatform: installerPlatformOf(entry.name))),
      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: _subtitle(context, download, entry),
      trailing: _trailing(context),
      onTap: entry.isDir
          ? onOpenDir
          : download?.isFinished == true
          ? () => _openDownloaded(context, download!)
          : null,
    );
  }

  Widget? _trailing(BuildContext context) {
    final download = this.download;
    if (download == null || download.error != null) {
      return IconButton(
        tooltip: t.homeTab.download,
        icon: const Icon(Icons.download),
        onPressed: onDownload,
      );
    }
    if (download.isFinished) {
      return IconButton(
        tooltip: t.general.open,
        icon: const Icon(Icons.open_in_new),
        onPressed: () => _openDownloaded(context, download),
      );
    }
    return IconButton(
      tooltip: t.homeTab.cancelDownload,
      icon: const Icon(Icons.close),
      onPressed: () => onCancel(download.key),
    );
  }
}

class _GridCell extends StatelessWidget {
  final ShareListEntry entry;
  final ShareDownload? download;
  final String fingerprint;
  final String dirId;
  final VoidCallback onOpenDir;
  final VoidCallback onDownload;
  final ValueChanged<String> onCancel;

  const _GridCell({
    required this.entry,
    required this.download,
    required this.fingerprint,
    required this.dirId,
    required this.onOpenDir,
    required this.onDownload,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final kind = shareFileKindOf(name: entry.name, isDir: entry.isDir);
    final colorScheme = Theme.of(context).colorScheme;
    final download = this.download;

    final Widget overlay;
    if (download == null || download.error != null) {
      overlay = const SizedBox.shrink();
    } else if (download.isFinished) {
      overlay = _Badge(icon: Icons.open_in_new, color: colorScheme.primary, onTap: () => _openDownloaded(context, download));
    } else {
      overlay = _Badge(icon: Icons.close, color: colorScheme.error, onTap: () => onCancel(download.key));
    }

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: entry.isDir
          ? onOpenDir
          : download?.isFinished == true
          ? () => _openDownloaded(context, download!)
          : download == null || download.error != null
          ? onDownload
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _Preview(entry: entry, kind: kind, fingerprint: fingerprint, dirId: dirId),
                ),
                if (download != null && !download.isFinished)
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: LinearProgressIndicator(value: download.progress),
                  ),
                Positioned(top: 4, right: 4, child: overlay),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(entry.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _Badge({required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 16, color: Theme.of(context).colorScheme.onPrimary),
        ),
      ),
    );
  }
}

/// Grid preview: image thumbnail, video poster, audio album art, else an icon.
class _Preview extends StatefulWidget {
  final ShareListEntry entry;
  final ShareFileKind kind;
  final String fingerprint;
  final String dirId;

  const _Preview({required this.entry, required this.kind, required this.fingerprint, required this.dirId});

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  bool _requested = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _requestThumbnail();
    });
  }

  @override
  void didUpdateWidget(_Preview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.relPath != widget.entry.relPath) {
      _requested = false;
      _requestThumbnail();
    }
  }

  void _requestThumbnail() {
    if (_requested) return;
    _requested = true;
    final info = context.ref.read(remoteShareBrowseProvider).selectedDevice;
    if (info == null) return;
    unawaited(context.ref.notifier(shareThumbnailProvider).request(info.device, widget.dirId, widget.entry));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.ref.watch(shareThumbnailProvider);
    final key = shareThumbnailKey(fingerprint: widget.fingerprint, dirId: widget.dirId, entry: widget.entry);
    final thumbnail = state.byKey[key];
    final colorScheme = Theme.of(context).colorScheme;

    if (thumbnail != null) {
      if (thumbnail.filePath != null) {
        return Image.file(File(thumbnail.filePath!), fit: BoxFit.cover, cacheWidth: 320);
      }
      if (thumbnail.bytes != null) {
        return Image.memory(thumbnail.bytes!, fit: BoxFit.cover, cacheWidth: 320);
      }
    }

    return ColoredBox(
      color: colorScheme.secondaryContainer,
      child: Center(
        child: state.pending.contains(key)
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(
                widget.kind.icon(installerPlatform: installerPlatformOf(widget.entry.name)),
                size: 40,
                color: colorScheme.onSecondaryContainer,
              ),
      ),
    );
  }
}

Widget _subtitle(BuildContext context, ShareDownload? download, ShareListEntry entry) {
  if (download == null) return Text(_readable(entry.size));
  if (download.error != null) {
    return Text(
      t.homeTab.downloadFailed(error: download.error!),
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    );
  }
  if (download.isFinished) return Text(t.homeTab.downloaded);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(t.homeTab.downloading(progress: (download.progress * 100).floor())),
      const SizedBox(height: 4),
      LinearProgressIndicator(value: download.progress),
    ],
  );
}

Future<void> _openDownloaded(BuildContext context, ShareDownload download) async {
  final path = download.savePath;
  if (path == null) return;
  await openFile(context, shareFileKindOf(name: download.fileName, isDir: false).fileType, path);
}

String _readable(int size) {
  const unit = ['B', 'KB', 'MB', 'GB', 'TB'];
  var s = size.toDouble();
  var i = 0;
  while (s >= 1024 && i < unit.length - 1) {
    s /= 1024;
    i++;
  }
  return '${s.toStringAsFixed(i == 0 ? 0 : 1)} ${unit[i]}';
}
