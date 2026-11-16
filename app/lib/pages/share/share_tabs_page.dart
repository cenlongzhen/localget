import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/share/add_directory_sheet.dart';
import 'package:localsend_app/pages/share/directories_tab.dart';
import 'package:localsend_app/pages/share/trusted_devices_tab.dart';
import 'package:localsend_app/pages/tabs/shared_devices_tab.dart';

/// Share page: browsing what nearby peers offer, this device's shared
/// directories, and the trusted-device allowlist.
///
/// Only the "My shares" tab needs a create action; trust is granted with the
/// switch on each row of the device list.
class ShareTabsPage extends StatefulWidget {
  const ShareTabsPage({super.key});

  @override
  State<ShareTabsPage> createState() => _ShareTabsPageState();
}

class _ShareTabsPageState extends State<ShareTabsPage> with SingleTickerProviderStateMixin {
  late final TabController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TabController(length: 3, vsync: this)..addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (!_controller.indexIsChanging) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onTabChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TabBar(
              controller: _controller,
              tabs: [
                Tab(text: t.shareTab.browse),
                Tab(text: t.shareTab.local),
                Tab(text: t.shareTab.trustedDevices),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _controller,
                children: const [
                  SharedDevicesTab(),
                  DirectoriesTab(),
                  TrustedDevicesTab(),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: _controller.index == 1
          ? FloatingActionButton.extended(
              onPressed: () async => showAddDirectorySheet(context),
              icon: const Icon(Icons.add),
              label: Text(t.shareTab.add),
            )
          : null,
    );
  }
}
