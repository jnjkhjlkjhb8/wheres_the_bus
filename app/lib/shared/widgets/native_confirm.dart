import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('me.rabbitsayhello.wheresthebus/native_dialog');

/// Asks the user to confirm a destructive action; true only on an explicit
/// confirm.
///
/// iOS presents the system alert (UIAlertController) rather than a drawn
/// one, so the destructive styling, blur and dismissal match the platform.
/// Other platforms get the Material dialog.
Future<bool> confirmDestructive(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  required String cancelLabel,
}) async {
  final confirmed = defaultTargetPlatform == TargetPlatform.iOS
      ? await _channel.invokeMethod<bool>('confirm', {
          'title': title,
          'message': message,
          'confirmLabel': confirmLabel,
          'cancelLabel': cancelLabel,
          'dark': Theme.of(context).brightness == Brightness.dark,
        })
      : await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(cancelLabel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(confirmLabel),
              ),
            ],
          ),
        );
  return confirmed ?? false;
}
