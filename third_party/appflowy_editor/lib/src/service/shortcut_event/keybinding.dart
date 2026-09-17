import 'dart:convert';

import 'package:appflowy_editor/src/service/shortcut_event/key_mapping.dart';
import 'package:flutter/services.dart';

extension KeybindingsExtension on List<Keybinding> {
  bool containsKeyEvent(KeyEvent keyEvent) {
    for (final keybinding in this) {
      // 用可空的 [Keybinding.keyCodeOrNull]：键名不在映射表里时跳过该条，
      // 而不是让 `keyCode` 的 `!` 在按键消息处理器里抛异常
      // （抛了会打断整个键盘分发，见 sinan 的 vendored 补丁说明）。
      if (keybinding.isMetaPressed == HardwareKeyboard.instance.isMetaPressed &&
          keybinding.isControlPressed ==
              HardwareKeyboard.instance.isControlPressed &&
          keybinding.isAltPressed == HardwareKeyboard.instance.isAltPressed &&
          keybinding.isShiftPressed ==
              HardwareKeyboard.instance.isShiftPressed &&
          keybinding.keyCodeOrNull == keyEvent.logicalKey.keyId) {
        return true;
      }
    }
    return false;
  }
}

class Keybinding {
  Keybinding({
    required this.isAltPressed,
    required this.isControlPressed,
    required this.isMetaPressed,
    required this.isShiftPressed,
    required this.keyLabel,
  });

  factory Keybinding.parse(String command) {
    command = command.toLowerCase().trim();

    var isAltPressed = false;
    var isControlPressed = false;
    var isMetaPressed = false;
    var isShiftPressed = false;

    var matchedModifier = false;

    do {
      matchedModifier = false;
      if (RegExp(r'^alt(\+|\-)').hasMatch(command)) {
        isAltPressed = true;
        command = command.substring(4); // 4 = 'alt '.length
        matchedModifier = true;
      }
      if (RegExp(r'^ctrl(\+|\-)').hasMatch(command)) {
        isControlPressed = true;
        command = command.substring(5); // 5 = 'ctrl '.length
        matchedModifier = true;
      }
      if (RegExp(r'^shift(\+|\-)').hasMatch(command)) {
        isShiftPressed = true;
        command = command.substring(6); // 6 = 'shift '.length
        matchedModifier = true;
      }
      if (RegExp(r'^meta(\+|\-)').hasMatch(command)) {
        isMetaPressed = true;
        command = command.substring(5); // 5 = 'meta '.length
        matchedModifier = true;
      }
      if (RegExp(r'^cmd(\+|\-)').hasMatch(command) ||
          RegExp(r'^win(\+|\-)').hasMatch(command)) {
        isMetaPressed = true;
        command = command.substring(4); // 4 = 'win '.length
        matchedModifier = true;
      }
    } while (matchedModifier);

    return Keybinding(
      isAltPressed: isAltPressed,
      isControlPressed: isControlPressed,
      isMetaPressed: isMetaPressed,
      isShiftPressed: isShiftPressed,
      keyLabel: command,
    );
  }

  final bool isAltPressed;
  final bool isControlPressed;
  final bool isMetaPressed;
  final bool isShiftPressed;
  final String keyLabel;

  int get keyCode => keyToCodeMapping[keyLabel.toLowerCase()]!;

  /// 可空版 [keyCode]：键名不在 [keyToCodeMapping] 里时返回 `null`（官方原版
  /// 直接 `!` 抛异常）。sinan 补丁——按键匹配走这个 getter，键名写错的
  /// keybinding 会被静默跳过，而不是在键盘消息处理器里炸掉整个分发链。
  int? get keyCodeOrNull => keyToCodeMapping[keyLabel.toLowerCase()];

  Keybinding copyWith({
    bool? isAltPressed,
    bool? isControlPressed,
    bool? isMetaPressed,
    bool? isShiftPressed,
    String? keyLabel,
  }) {
    return Keybinding(
      isAltPressed: isAltPressed ?? this.isAltPressed,
      isControlPressed: isControlPressed ?? this.isControlPressed,
      isMetaPressed: isMetaPressed ?? this.isMetaPressed,
      isShiftPressed: isShiftPressed ?? this.isShiftPressed,
      keyLabel: keyLabel ?? this.keyLabel,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'isAltPressed': isAltPressed,
      'isControlPressed': isControlPressed,
      'isMetaPressed': isMetaPressed,
      'isShiftPressed': isShiftPressed,
      'keyLabel': keyLabel,
    };
  }

  factory Keybinding.fromMap(Map<String, dynamic> map) {
    return Keybinding(
      isAltPressed: map['isAltPressed'] ?? false,
      isControlPressed: map['isControlPressed'] ?? false,
      isMetaPressed: map['isMetaPressed'] ?? false,
      isShiftPressed: map['isShiftPressed'] ?? false,
      keyLabel: map['keyLabel'] ?? '',
    );
  }

  String toJson() => json.encode(toMap());

  factory Keybinding.fromJson(String source) =>
      Keybinding.fromMap(json.decode(source));

  @override
  String toString() {
    return 'Keybinding(isAltPressed: $isAltPressed, isControlPressed: $isControlPressed, isMetaPressed: $isMetaPressed, isShiftPressed: $isShiftPressed, keyLabel: $keyLabel)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is Keybinding &&
        other.isAltPressed == isAltPressed &&
        other.isControlPressed == isControlPressed &&
        other.isMetaPressed == isMetaPressed &&
        other.isShiftPressed == isShiftPressed &&
        other.keyCodeOrNull == keyCodeOrNull;
  }

  @override
  int get hashCode {
    return isAltPressed.hashCode ^
        isControlPressed.hashCode ^
        isMetaPressed.hashCode ^
        isShiftPressed.hashCode ^
        (keyCodeOrNull ?? 0);
  }
}
