import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';

class SelectionMenuIconWidget extends StatelessWidget {
  SelectionMenuIconWidget({
    super.key,
    this.name,
    this.icon,
    required this.isSelected,
    required this.style,
  }) {
    assert((name == null && icon != null) || ((name != null && icon == null)));
  }

  final String? name;
  final Widget? icon;
  final bool isSelected;
  final SelectionMenuStyle style;

  @override
  Widget build(BuildContext context) {
    if (icon != null) {
      return SizedBox(width: 18.0, height: 18.0, child: icon);
    } else if (name != null) {
      return EditorSvg(
        name: 'selection_menu/$name',
        width: 18.0,
        height: 18.0,
        color: isSelected
            ? style.selectionMenuItemSelectedIconColor
            : style.selectionMenuItemIconColor,
      );
    }
    throw UnimplementedError();
  }
}
