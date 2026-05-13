import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, LengthLimitingTextInputFormatter;

/// Cap on user-typed display names. Long enough to fit "Right-front
/// upper rack #2" or similar; short enough that a paste of an
/// entire essay can't bloat the prefs blob or push the card into a
/// layout the ellipsis can't recover. Enforced both as a TextField
/// `maxLength` (UI counter visible to the user) and via the
/// `LengthLimitingTextInputFormatter` (rejects programmatic pastes
/// past the cap).
const int kRenameMaxLength = 32;

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
  //
  // The selection covers the whole pre-populated string so a user who
  // taps the existing name and just starts typing replaces it in one
  // keystroke — matches the rename UX on macOS Finder, iOS Files, etc.
  late final TextEditingController _controller =
      TextEditingController.fromValue(
    TextEditingValue(
      text: widget.initialName,
      selection: TextSelection(
        baseOffset: 0,
        extentOffset: widget.initialName.length,
      ),
    ),
  );

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
        // autofocus brings up the soft keyboard immediately on tap-to-
        // rename, matching the expected affordance. Safe to re-enable
        // now that the controller lives on the State (vs the earlier
        // `showDialog` + `finally controller.dispose()` shape that
        // tripped widget-test focus-traversal panics).
        autofocus: true,
        maxLength: kRenameMaxLength,
        textInputAction: TextInputAction.done,
        // Reject newline characters at the input layer so a paste of
        // a multi-line string can't sneak past the dialog and render
        // a multi-line name on a single-line card row.
        inputFormatters: [
          FilteringTextInputFormatter.deny(RegExp(r'[\r\n]')),
          LengthLimitingTextInputFormatter(kRenameMaxLength),
        ],
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
