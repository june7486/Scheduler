import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Web implementation: opens the browser's file chooser and returns the text
/// contents of the chosen `.json` file (or null if the user cancels).
Future<String?> pickTextFile() {
  final completer = Completer<String?>();
  try {
    final input = web.document.createElement('input') as web.HTMLInputElement;
    input.type = 'file';
    input.accept = '.json,application/json,text/plain';
    input.style.display = 'none';
    web.document.body?.append(input);

    input.onchange = ((web.Event _) {
      final files = input.files;
      if (files == null || files.length == 0) {
        if (!completer.isCompleted) completer.complete(null);
        input.remove();
        return;
      }
      final file = files.item(0)!;
      final reader = web.FileReader();
      reader.onload = ((web.Event _) {
        final result = reader.result;
        if (!completer.isCompleted) {
          completer.complete(result == null ? null : (result as JSString).toDart);
        }
        input.remove();
      }).toJS;
      reader.onerror = ((web.Event _) {
        if (!completer.isCompleted) completer.complete(null);
        input.remove();
      }).toJS;
      reader.readAsText(file);
    }).toJS;

    input.click();
  } catch (_) {
    if (!completer.isCompleted) completer.complete(null);
  }
  return completer.future;
}
