import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;

/// Renderable states of [PermissionRequestFlow]. The granted outcome is a
/// terminal *event* (the caller navigates away), not a renderable state —
/// it lives on [PermissionRequestFlow.requestPermissions]'s return value,
/// not as an enum leaf.
enum PermissionFlowState {
  /// Pre-prompt rationale. Initial state, and where [tryAgain] returns to.
  rationale,

  /// The OS prompt is in flight — between the user's Continue tap and the
  /// platform reply.
  requesting,

  /// The most recent attempt was denied — either by the user, or by a
  /// platform-channel exception that the flow treats as a soft denial. The
  /// user can recover via [tryAgain] (→ [rationale]) or by leaving for the
  /// system settings app.
  denied,
}

/// State machine that drives [PermissionScreen]. Lifted out of the widget
/// so the transitions — and the platform-exception soft-denial rule — are
/// testable as plain Dart, without `tester.pumpWidget`.
///
/// **Transitions:**
/// - [PermissionFlowState.rationale] → [PermissionFlowState.requesting] on
///   [requestPermissions].
/// - [PermissionFlowState.requesting] → [PermissionFlowState.denied] when
///   the injected `request` callback resolves to `false` *or* throws.
/// - [PermissionFlowState.requesting] → (no state change, caller navigates
///   away) when `request` resolves to `true`. [requestPermissions] returns
///   `true` and the caller is expected to leave the screen.
/// - [PermissionFlowState.denied] → [PermissionFlowState.rationale] on
///   [tryAgain]. [tryAgain] is a no-op from any other state.
///
/// **Strict state machine.** [requestPermissions] is a no-op from any
/// state other than [PermissionFlowState.rationale] — that covers the
/// re-entrant double-tap (already in [PermissionFlowState.requesting])
/// and forces a [tryAgain] step between a denied attempt and the next
/// request rather than allowing a silent `denied → requesting` bypass.
///
/// **Errors:** a thrown exception from `request` (e.g. a
/// `MissingPluginException` from `permission_handler`) is swallowed and
/// treated as a denial. The user still lands on the denied screen with the
/// Open-Settings escape hatch rather than seeing an uncaught async error.
class PermissionRequestFlow {
  PermissionRequestFlow({required Future<bool> Function() request})
      : _request = request;

  final Future<bool> Function() _request;
  final ValueNotifier<PermissionFlowState> _state =
      ValueNotifier(PermissionFlowState.rationale);
  bool _disposed = false;

  /// The current state. Widgets can listen via [ValueListenableBuilder].
  ValueListenable<PermissionFlowState> get state => _state;

  /// Drive one OS-prompt round-trip. See class doc for transitions.
  /// Returns `true` iff the prompt was granted — caller is expected to
  /// navigate away; this flow does not transition out of `requesting` on
  /// success because the screen will be torn down. Returns `false` on
  /// denial, on platform exception, on a call from any state other than
  /// [PermissionFlowState.rationale] (re-entrant during `requesting`, or
  /// from `denied` without a [tryAgain] first), and on any resolution
  /// that lands after [dispose].
  Future<bool> requestPermissions() async {
    if (_disposed) return false;
    if (_state.value != PermissionFlowState.rationale) return false;
    _state.value = PermissionFlowState.requesting;

    bool granted;
    try {
      granted = await _request();
    } catch (_) {
      granted = false;
    }

    // The widget owning this flow may have been unmounted while the OS
    // prompt was up. Writing to a disposed ValueNotifier throws — short-
    // circuit instead.
    if (_disposed) return false;
    if (granted) return true;
    _state.value = PermissionFlowState.denied;
    return false;
  }

  /// Return from [PermissionFlowState.denied] to
  /// [PermissionFlowState.rationale]. No-op from any other state — in
  /// particular, this does NOT cancel an in-flight request.
  void tryAgain() {
    if (_disposed) return;
    if (_state.value != PermissionFlowState.denied) return;
    _state.value = PermissionFlowState.rationale;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _state.dispose();
  }
}
