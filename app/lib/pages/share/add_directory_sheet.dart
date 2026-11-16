import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/share/share_provider.dart';
import 'package:localsend_app/util/native/pick_directory_path.dart';
import 'package:localsend_isolates/model/share.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Modal used from [ShareTabsPage] "Directories" tab to configure a new
/// shared directory, or an existing one when [initial] is given.
Future<void> showAddDirectorySheet(BuildContext context, {SharedDirectory? initial}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _AddDirectorySheet(initial: initial),
  );
}

class _AddDirectorySheet extends StatefulWidget {
  final SharedDirectory? initial;

  const _AddDirectorySheet({this.initial});

  @override
  State<_AddDirectorySheet> createState() => _AddDirectorySheetState();
}

class _AddDirectorySheetState extends State<_AddDirectorySheet> {
  final _nameCtrl = TextEditingController();
  final _rootCtrl = TextEditingController();
  bool _readOnly = true;
  ShareKind _kind = ShareKind.longTerm;

  bool get _isEdit => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      _nameCtrl.text = initial.name;
      _rootCtrl.text = initial.root;
      _readOnly = initial.readOnly;
      _kind = initial.kind;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _rootCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid = _nameCtrl.text.trim().isNotEmpty && _rootCtrl.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _isEdit ? t.shareTab.editDirectory : t.shareTab.addDirectory,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(
            t.shareTab.addDirectoryHint,
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nameCtrl,
            decoration: InputDecoration(
              labelText: t.shareTab.directoryName,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _rootCtrl,
            decoration: InputDecoration(
              labelText: t.shareTab.directoryRoot,
              helperText: t.shareTab.directoryRootHint,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                String? picked;
                try {
                  picked = await pickShareDirectoryPath();
                } on ShareDirectoryAccessDenied {
                  messenger.showSnackBar(SnackBar(content: Text(t.shareTab.allFilesAccessRequired)));
                  return;
                }
                if (picked == null || picked.isEmpty) return;
                final path = picked;
                if (!mounted) return;
                setState(() {
                  _rootCtrl.text = path;
                  if (_nameCtrl.text.trim().isEmpty) {
                    final tail = path.replaceAll(RegExp(r'[\\/]+$'), '');
                    final slash = tail.lastIndexOf(RegExp(r'[\\/]'));
                    _nameCtrl.text = slash == -1 ? tail : tail.substring(slash + 1);
                  }
                });
              },
              icon: const Icon(Icons.folder_open),
              label: Text(t.shareTab.pickDirectory),
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t.shareTab.readOnly),
            subtitle: Text(t.shareTab.readOnlyHint),
            value: _readOnly,
            onChanged: (v) => setState(() => _readOnly = v),
          ),
          const SizedBox(height: 8),
          SegmentedButton<ShareKind>(
            segments: [
              ButtonSegment(value: ShareKind.longTerm, label: Text(t.shareTab.longTerm)),
              ButtonSegment(value: ShareKind.sessionOnly, label: Text(t.shareTab.sessionOnly)),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(t.general.cancel),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: valid
                      ? () {
                          final notifier = context.ref.notifier(shareProvider);
                          final initial = widget.initial;
                          if (initial == null) {
                            notifier.addDirectory(
                              name: _nameCtrl.text.trim(),
                              root: _rootCtrl.text.trim(),
                              kind: _kind,
                              readOnly: _readOnly,
                            );
                          } else {
                            notifier.updateDirectory(
                              initial.id,
                              name: _nameCtrl.text.trim(),
                              root: _rootCtrl.text.trim(),
                              kind: _kind,
                              readOnly: _readOnly,
                            );
                          }
                          Navigator.of(context).pop();
                        }
                      : null,
                  child: Text(_isEdit ? t.general.save : t.general.add),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
