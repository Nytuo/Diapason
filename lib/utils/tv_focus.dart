import 'package:diapason/services/tvos/appletv_audio_channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A [FocusNode] for text fields that lets the Siri Remote's D-pad move
/// focus to the next/previous field with Up/Down (and Left/Right at the
/// start/end of the text) instead of getting stuck moving the text cursor.
///
/// EditableText unconditionally consumes arrow keys for cursor movement, so
/// on tvOS - where remote swipes arrive as the same arrow-key events used
/// for D-pad focus traversal - a focused text field otherwise has no way to
/// hand focus back to the rest of the screen. On every other platform this
/// returns a plain [FocusNode], since consuming arrow keys for the cursor is
/// the correct desktop/mobile behavior.
///
/// Pass [controller] so Left/Right only escape the field at the start/end of
/// the text; without it, Left/Right are left alone (only Up/Down redirect).
FocusNode tvNavFocusNode({TextEditingController? controller}) {
  if (!AppleTvAudioChannel.isSupported) return FocusNode();
  return FocusNode(
    onKeyEvent: (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      final TraversalDirection? direction;
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowUp:
          direction = TraversalDirection.up;
        case LogicalKeyboardKey.arrowDown:
          direction = TraversalDirection.down;
        case LogicalKeyboardKey.arrowLeft:
          final atStart = controller != null && controller.selection.start == 0 && controller.selection.end == 0;
          if (!atStart) return KeyEventResult.ignored;
          direction = TraversalDirection.left;
        case LogicalKeyboardKey.arrowRight:
          final atEnd =
              controller != null &&
              controller.selection.start == controller.text.length &&
              controller.selection.end == controller.text.length;
          if (!atEnd) return KeyEventResult.ignored;
          direction = TraversalDirection.right;
        default:
          return KeyEventResult.ignored;
      }
      return node.focusInDirection(direction) ? KeyEventResult.handled : KeyEventResult.ignored;
    },
  );
}

KeyEventResult tvTextFieldKeyHandler(FocusNode node, KeyEvent event) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
  final focused = FocusManager.instance.primaryFocus;
  final editable = focused?.context?.findAncestorStateOfType<EditableTextState>();
  if (focused == null || editable == null) return KeyEventResult.ignored;
  final value = editable.textEditingValue;
  final collapsed = value.selection.isCollapsed;

  switch (event.logicalKey) {
    case LogicalKeyboardKey.arrowUp:
      if (!focused.focusInDirection(TraversalDirection.up)) focused.previousFocus();
      return KeyEventResult.handled;
    case LogicalKeyboardKey.arrowDown:
      if (!focused.focusInDirection(TraversalDirection.down)) focused.nextFocus();
      return KeyEventResult.handled;
    case LogicalKeyboardKey.arrowLeft:
      if (!collapsed || value.selection.baseOffset > 0) return KeyEventResult.ignored;
      return focused.focusInDirection(TraversalDirection.left) ? KeyEventResult.handled : KeyEventResult.ignored;
    case LogicalKeyboardKey.arrowRight:
      if (!collapsed || value.selection.baseOffset < value.text.length) return KeyEventResult.ignored;
      return focused.focusInDirection(TraversalDirection.right) ? KeyEventResult.handled : KeyEventResult.ignored;
    default:
      return KeyEventResult.ignored;
  }
}
