import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/provider/share/share_provider.dart';
import 'package:localsend_app/util/device_type_ext.dart';
import 'package:localsend_app/widget/device_bage.dart';
import 'package:localsend_app/widget/empty_state_view.dart';
import 'package:localsend_app/widget/list_tile/custom_list_tile.dart';
import 'package:localsend_app/widget/scan_button.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/share.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Which rows the trust list shows.
enum _TrustFilter { all, trusted, untrusted }

/// Trusted-device allowlist rendered inside the "Trusted devices" tab.
///
/// Rows look like the nearby-device entries of the send page, with the trust
/// toggle in place of the details button: nearby devices that are not trusted
/// yet show up too, so granting access does not need a separate dialog.
class TrustedDevicesTab extends StatefulWidget {
  const TrustedDevicesTab({super.key});

  @override
  State<TrustedDevicesTab> createState() => _TrustedDevicesTabState();
}

class _TrustedDevicesTabState extends State<TrustedDevicesTab> {
  _TrustFilter _filter = _TrustFilter.all;

  @override
  Widget build(BuildContext context) {
    final trusted = context.ref.watch(shareProvider).trustedDevices;
    final trustedFingerprints = {for (final t in trusted) t.fingerprint.toUpperCase()};
    final localFingerprint = context.ref.read(securityProvider).certificateHash.toUpperCase();
    final nearby = context.ref.watch(nearbyDevicesProvider).allDevices.values.where((d) => d.fingerprint.toUpperCase() != localFingerprint).toList();

    final rows = <_TrustRow>[
      for (final device in nearby)
        _TrustRow(
          fingerprint: device.fingerprint.toUpperCase(),
          alias: device.alias,
          device: device,
          trusted: trustedFingerprints.contains(device.fingerprint.toUpperCase()),
          lastSeenAt: _lastSeenOf(trusted, device.fingerprint),
          rememberedType: _typeOf(trusted, device.fingerprint),
        ),
      for (final device in trusted)
        if (!nearby.any((d) => d.fingerprint.toUpperCase() == device.fingerprint.toUpperCase()))
          _TrustRow(
            fingerprint: device.fingerprint.toUpperCase(),
            alias: device.alias,
            device: null,
            trusted: true,
            lastSeenAt: device.lastSeenAt,
            rememberedType: device.deviceType,
          ),
    ]..sort((a, b) => a.alias.toLowerCase().compareTo(b.alias.toLowerCase()));

    final visible = switch (_filter) {
      _TrustFilter.all => rows,
      _TrustFilter.trusted => rows.where((r) => r.trusted).toList(),
      _TrustFilter.untrusted => rows.where((r) => !r.trusted).toList(),
    };

    final localIps = context.ref.watch(localIpProvider).localIps;

    return Column(
      children: [
        SizedBox(
          height: 60,
          child: Row(
            children: [
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(15, 12, 15, 4),
                  children: [
                    _FilterChip(
                      label: t.shareTab.trustAll,
                      selected: _filter == _TrustFilter.all,
                      onTap: () => setState(() => _filter = _TrustFilter.all),
                    ),
                    const SizedBox(width: 8),
                    _FilterChip(
                      label: t.shareTab.trustTrusted,
                      selected: _filter == _TrustFilter.trusted,
                      onTap: () => setState(() => _filter = _TrustFilter.trusted),
                    ),
                    const SizedBox(width: 8),
                    _FilterChip(
                      label: t.shareTab.trustUntrusted,
                      selected: _filter == _TrustFilter.untrusted,
                      onTap: () => setState(() => _filter = _TrustFilter.untrusted),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 7),
                child: ScanButton(ips: localIps),
              ),
            ],
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? EmptyStateView(
                  icon: _filter == _TrustFilter.untrusted ? Icons.devices_other_outlined : Icons.verified_user_outlined,
                  message: _filter == _TrustFilter.untrusted ? t.shareTab.noNearbyDevices : t.shareTab.emptyTrustedDevices,
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(15, 4, 15, 30),
                  itemCount: visible.length,
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _TrustRowTile(
                      row: visible[index],
                      onChanged: (value) {
                        final notifier = context.ref.notifier(shareProvider);
                        final row = visible[index];
                        if (value) {
                          notifier.trustDevice(fingerprint: row.fingerprint, alias: row.alias, deviceType: row.iconType);
                        } else {
                          notifier.revokeDevice(row.fingerprint);
                        }
                      },
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  static DateTime? _lastSeenOf(List<TrustedDevice> trusted, String fingerprint) {
    final key = fingerprint.toUpperCase();
    for (final device in trusted) {
      if (device.fingerprint == key) return device.lastSeenAt;
    }
    return null;
  }

  static DeviceType _typeOf(List<TrustedDevice> trusted, String fingerprint) {
    final key = fingerprint.toUpperCase();
    for (final device in trusted) {
      if (device.fingerprint == key) return device.deviceType;
    }
    return DeviceType.desktop;
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ChoiceChip(
      selected: selected,
      showCheckmark: false,
      label: Text(label),
      labelStyle: TextStyle(
        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
        color: selected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
      ),
      selectedColor: colorScheme.primary,
      onSelected: (_) => onTap(),
    );
  }
}

/// One row of the trust list: a nearby device, a remembered one, or both.
class _TrustRow {
  final String fingerprint;
  final String alias;

  /// The live discovery entry; null for a remembered device that is offline.
  final Device? device;
  final bool trusted;
  final DateTime? lastSeenAt;

  /// Device kind stored with the trust record, used while the peer is offline.
  final DeviceType rememberedType;

  const _TrustRow({
    required this.fingerprint,
    required this.alias,
    required this.device,
    required this.trusted,
    required this.lastSeenAt,
    required this.rememberedType,
  });

  DeviceType get iconType => device?.deviceType ?? rememberedType;
}

class _TrustRowTile extends StatelessWidget {
  final _TrustRow row;
  final ValueChanged<bool> onChanged;

  const _TrustRowTile({required this.row, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final badgeColor = Color.lerp(Theme.of(context).colorScheme.secondaryContainer, Colors.white, 0.3)!;
    final device = row.device;
    final lastSeen = row.lastSeenAt == null ? t.shareTab.neverSeen : _relativeDelta(row.lastSeenAt!);
    return CustomListTile(
      icon: Icon(row.iconType.icon, size: 46),
      title: Text(row.alias, style: const TextStyle(fontSize: 20)),
      subTitle: Wrap(
        runSpacing: 10,
        spacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (device != null)
            DeviceBadge(
              backgroundColor: badgeColor,
              foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
              label: device.ip != null ? 'HTTP' : 'WebRTC',
            ),
          if (device?.deviceModel != null)
            DeviceBadge(
              backgroundColor: badgeColor,
              foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
              label: device!.deviceModel!,
            ),
          Text(lastSeen, style: const TextStyle(color: Colors.grey)),
        ],
      ),
      trailing: Switch(
        value: row.trusted,
        onChanged: onChanged,
      ),
    );
  }

  static String _relativeDelta(DateTime lastSeen) {
    final diff = DateTime.now().difference(lastSeen);
    if (diff.inSeconds < 60) return t.shareTab.seenJustNow;
    if (diff.inMinutes < 60) return t.shareTab.seenMinutesAgo(count: diff.inMinutes);
    if (diff.inHours < 24) return t.shareTab.seenHoursAgo(count: diff.inHours);
    if (diff.inDays < 30) return t.shareTab.seenDaysAgo(count: diff.inDays);
    return t.shareTab.seenMonthsAgo(count: diff.inDays ~/ 30);
  }
}
