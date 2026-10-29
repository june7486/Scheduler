import 'dart:js_interop';

@JS('addEventListener')
external void _addEventListener(String type, JSFunction listener);

/// Calls [onOnline] whenever the browser reports that connectivity returned.
void hookOnline(void Function() onOnline) {
  _addEventListener(
    'online',
    (() => onOnline()).toJS,
  );
}
