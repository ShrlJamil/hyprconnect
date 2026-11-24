//! The update flow: an alert that offers the newer release,
//! downloads it with progress, and hands it to the system
//! installer. Reached automatically (at most once a day) and
//! manually from the About page.

import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../platform/native_bridge.dart';
import '../update/update_checker.dart';

/// A manual check that reports its outcome where it was started:
/// the update dialog when one is available, a snackbar otherwise.
Future<void> checkUpdatesManually(BuildContext context) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final current = await NativeBridge.appVersion();
  final latest = await UpdateChecker.fetchLatest();
  if (!context.mounted) return;
  if (latest == null || current == null) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.updateCheckFailed)));
    return;
  }
  if (compareVersions(latest.version, current) <= 0) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.updateUpToDate)));
    return;
  }
  await showUpdateDialog(context, latest);
}

Future<void> showUpdateDialog(BuildContext context, ReleaseInfo info) {
  return showDialog<void>(
    context: context,
    builder: (context) => UpdateDialog(info: info),
  );
}

class UpdateDialog extends StatefulWidget {
  final ReleaseInfo info;

  const UpdateDialog({super.key, required this.info});

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  double? _progress;
  File? _downloaded;
  bool _failed = false;
  bool _permissionHint = false;

  Future<void> _download() async {
    setState(() {
      _progress = 0;
      _failed = false;
    });
    try {
      final file = await UpdateChecker.downloadApk(
        widget.info,
        onProgress: (received, total) {
          if (mounted && total > 0) {
            setState(() => _progress = received / total);
          }
        },
      );
      if (mounted) {
        setState(() {
          _downloaded = file;
          _progress = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _progress = null;
        });
      }
    }
  }

  Future<void> _install() async {
    final file = _downloaded;
    if (file == null) return;
    if (!await NativeBridge.canInstallPackages()) {
      await NativeBridge.openInstallPermissionSettings();
      if (mounted) setState(() => _permissionHint = true);
      return;
    }
    await NativeBridge.installApk(file.path);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final downloading = _progress != null;
    return AlertDialog(
      title: Text(l10n.updateAvailableTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.versionLabel(widget.info.version)),
          const SizedBox(height: 12),
          if (downloading) ...[
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 8),
            Text(
              '${l10n.updateDownloading} '
              '${((_progress ?? 0) * 100).round()}%',
            ),
          ] else if (_downloaded != null) ...[
            Text(
              _permissionHint
                  ? l10n.updatePermissionHint
                  : l10n.updateReady,
            ),
          ] else if (_failed) ...[
            Text(l10n.updateFailed),
          ] else if (widget.info.notes.trim().isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: SingleChildScrollView(
                child: Text(widget.info.notes.trim()),
              ),
            ),
        ],
      ),
      actions: [
        if (!downloading)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.updateLater),
          ),
        if (_downloaded != null)
          FilledButton(
            onPressed: _install,
            child: Text(l10n.updateInstall),
          )
        else if (!downloading)
          FilledButton(
            onPressed: _download,
            child: Text(l10n.updateDownload),
          ),
      ],
    );
  }
}
