//! Run commands (kdeconnect.runcommand / kdeconnect.runcommand.request
//! / kdeconnect.runcommand.output). Wire rules read from the daemon
//! (src/main.rs: send_command_list, run_remote_command,
//! stop_remote_commands):
//!
//! - Ask for the list: kdeconnect.runcommand.request with
//!   {"requestCommandList": true}. The daemon answers with
//!   kdeconnect.runcommand {"commandList": "<JSON string>",
//!   "canAddCommand": true}, where the string is an object of
//!   key -> {"name": ..., "command": ...}. (The list is a string
//!   inside the packet, exactly like upstream.)
//! - Run one: kdeconnect.runcommand.request {"key": "<key>"}.
//! - The daemon streams back kdeconnect.runcommand.output packets:
//!   {"commandStarted": true, "id": N, "command": "..."} first,
//!   then {"commandOutput": true, "stdout": [lines], "stderr":
//!   [lines], "id": N} in batches (every 5 lines or 100 ms), then
//!   {"commandFinished": true, "success": bool, "exitCode": N,
//!   "id": N}. The id is the daemon's per-run counter.
//! - Stop everything running: kdeconnect.runcommand.request
//!   {"stop": true} (the daemon kills every pid it started for us).
//! - {"setup": true} asks the desktop to open its command editor
//!   (the daemon launches hyprconnect-app); the list is re-sent when
//!   it changes.

import 'dart:convert';

import 'packet.dart';

/// One predefined command the desktop offers.
class RunCommand {
  final String key;
  final String name;
  final String command;

  const RunCommand({
    required this.key,
    required this.name,
    required this.command,
  });
}

/// Parse a kdeconnect.runcommand commandList packet. Returns an empty
/// list when the packet carries no list (a malformed list string is
/// also treated as empty, like the daemon treats a bad commands.json).
List<RunCommand> parseCommandList(Packet packet) {
  final raw = packet.body['commandList'];
  if (raw is! String) return [];
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return [];
  }
  if (decoded is! Map<String, dynamic>) return [];
  final commands = <RunCommand>[];
  for (final entry in decoded.entries) {
    final value = entry.value;
    if (value is! Map<String, dynamic>) continue;
    commands.add(
      RunCommand(
        key: entry.key,
        name: value['name'] as String? ?? entry.key,
        command: value['command'] as String? ?? '',
      ),
    );
  }
  commands.sort((a, b) => a.name.compareTo(b.name));
  return commands;
}

/// Whether the desktop lets this phone add commands
/// (kdeconnect.runcommand "canAddCommand").
bool canAddCommandOf(Packet packet) {
  return packet.body['canAddCommand'] as bool? ?? false;
}

/// One streamed event of a running command, parsed from a
/// kdeconnect.runcommand.output packet. Null when the packet is not
/// an output event at all.
class RunCommandOutput {
  final int id;
  final String kind;
  final String? command;
  final List<String> stdoutLines;
  final List<String> stderrLines;
  final bool? success;
  final int? exitCode;

  const RunCommandOutput({
    required this.id,
    required this.kind,
    this.command,
    this.stdoutLines = const [],
    this.stderrLines = const [],
    this.success,
    this.exitCode,
  });

  static const String started = 'started';
  static const String output = 'output';
  static const String finished = 'finished';

  static RunCommandOutput? fromPacket(Packet packet) {
    final body = packet.body;
    final id = (body['id'] as num?)?.toInt();
    if (id == null) return null;
    if (body['commandStarted'] == true) {
      return RunCommandOutput(
        id: id,
        kind: started,
        command: body['command'] as String?,
      );
    }
    if (body['commandOutput'] == true) {
      return RunCommandOutput(
        id: id,
        kind: output,
        stdoutLines: _lines(body['stdout']),
        stderrLines: _lines(body['stderr']),
      );
    }
    if (body['commandFinished'] == true) {
      return RunCommandOutput(
        id: id,
        kind: finished,
        success: body['success'] as bool?,
        exitCode: (body['exitCode'] as num?)?.toInt(),
      );
    }
    return null;
  }

  static List<String> _lines(Object? value) {
    if (value is! List) return [];
    return value.map((line) => line.toString()).toList();
  }
}

/// kdeconnect.runcommand.request asking for the command list.
Packet runCommandRequestList() {
  return Packet.now('kdeconnect.runcommand.request', {
    'requestCommandList': true,
  });
}

/// kdeconnect.runcommand.request running one predefined command.
Packet runCommandRun(String key) {
  return Packet.now('kdeconnect.runcommand.request', {'key': key});
}

/// kdeconnect.runcommand.request stopping every running command.
Packet runCommandStop() {
  return Packet.now('kdeconnect.runcommand.request', {'stop': true});
}

/// kdeconnect.runcommand.request asking the desktop to open its
/// command editor.
Packet runCommandSetup() {
  return Packet.now('kdeconnect.runcommand.request', {'setup': true});
}
