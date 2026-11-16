import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/share/add_directory_sheet.dart';
import 'package:localsend_app/provider/share/share_provider.dart';
import 'package:localsend_app/widget/empty_state_view.dart';
import 'package:localsend_isolates/model/share.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Directory list rendered inside the "Directories" tab of [ShareTabsPage].
class DirectoriesTab extends StatelessWidget {
  const DirectoriesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final dirs = context.ref.watch(shareProvider).directories;
    if (dirs.isEmpty) {
      return EmptyStateView(
        icon: Icons.folder_off_outlined,
        message: t.shareTab.emptyDirectories,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: dirs.length,
      separatorBuilder: (_, _) => const Divider(
        height: 1,
        indent: 12,
        endIndent: 12,
      ),
      itemBuilder: (context, index) => _DirectoryRow(dir: dirs[index]),
    );
  }
}

class _DirectoryRow extends StatelessWidget {
  final SharedDirectory dir;

  const _DirectoryRow({required this.dir});

  @override
  Widget build(BuildContext context) {
    final notifier = context.ref.notifier(shareProvider);
    return ListTile(
      leading: Icon(
        dir.isTemporary ? Icons.timer_outlined : Icons.folder_outlined,
      ),
      title: Text(
        dir.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        dir.root,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Chip(
            label: Text(dir.isTemporary ? t.shareTab.kindSession : t.shareTab.kindLongTerm),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: t.general.delete,
            icon: const Icon(Icons.delete_outline),
            onPressed: () => notifier.removeDirectory(dir.id),
          ),
        ],
      ),
      onTap: () => showAddDirectorySheet(context, initial: dir),
    );
  }
}
