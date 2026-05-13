import 'package:flutter/material.dart';

/// Pop-up used by both [DumbbellCard] and [FailedDeviceCard] when the
/// user taps the device-name region.
///
/// Returns the user's input on OK (possibly empty — the caller treats
/// an empty / whitespace-only string as "clear the custom name and
/// fall back to the advertised name"); returns `null` if the user
/// cancelled. The string is returned *unmodified* — trimming and
/// emptiness handling live in [SelectionModel.rename] so the
/// normalization rule is in one place.
Future<String?> showRenameDeviceDialog(
  BuildContext context, {
  required String initialName,
}) {
  return showDialog<String?>(
    context: context,
    builder: (ctx) => _RenameDialog(initialName: initialName),
  );
}

class _RenameDialog extends StatefulWidget {
  final String initialName;

  const _RenameDialog({required this.initialName});

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  // A StatefulWidget owns the controller across the dialog's lifetime
  // so its dispose is deterministically scheduled by the framework
  // (rather than a `finally`-block race against the dialog route
  // tearing down). The earlier `showDialog` + `finally controller.dispose()`
  // shape caused widget-test focus-traversal panics on dialog pop —
  // moving ownership here is the canonical fix.
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialName);

  void _commit() => Navigator.of(context).pop(_controller.text);
  void _cancel() => Navigator.of(context).pop(null);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename dumbbell'),
      content: TextField(
        controller: _controller,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: 'Display name',
          hintText: 'e.g. Left, Right',
        ),
        onSubmitted: (_) => _commit(),
      ),
      actions: [
        TextButton(onPressed: _cancel, child: const Text('Cancel')),
        FilledButton(onPressed: _commit, child: const Text('OK')),
      ],
    );
  }
}
