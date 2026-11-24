//! Devices added by IP: the stored list of addresses the app
//! announces itself to directly, for desktops that discovery
//! broadcasts cannot reach (another subnet, a router that eats
//! broadcasts). Tapping a row announces again right away; a
//! desktop that hears it connects back, and then appears under
//! Pair new device like any discovered one. Mirrors the stock
//! KDE Connect page of the same name.

import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'app_state.dart';

class ManualDevicesPage extends StatelessWidget {
  final AppState appState;

  const ManualDevicesPage({super.key, required this.appState});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.addDeviceByIp)),
      body: AnimatedBuilder(
        animation: Listenable.merge([appState, appState.prefs]),
        builder: (context, _) {
          final l = context.l10n;
          final addresses = appState.prefs.manualAddresses;
          return ListView(
            children: [
              if (addresses.isEmpty)
                ListTile(
                  title: Text(l.noManualDevices),
                  subtitle: Text(l.noManualDevicesBody),
                ),
              for (final address in addresses)
                ListTile(
                  title: Text(address),
                  subtitle: Text(l.manualDeviceTapHint),
                  onTap: () {
                    appState.probeManualAddress(address);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l.manualDeviceProbing(address))),
                    );
                  },
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: l.delete,
                    onPressed: () => appState.removeManualAddress(address),
                  ),
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addAddress(context),
        tooltip: context.l10n.add,
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _addAddress(BuildContext context) async {
    final l = context.l10n;
    final controller = TextEditingController();
    final address = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.addDeviceByIp),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: l.ipAddress,
            hintText: l.ipAddressHint,
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text(l.add),
          ),
        ],
      ),
    );
    if (address == null || !context.mounted) return;
    final trimmed = address.trim();
    if (InternetAddress.tryParse(trimmed) == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.invalidIp)));
      return;
    }
    await appState.addManualAddress(trimmed);
  }
}
