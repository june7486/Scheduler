import 'dart:js_interop';
import 'dart:js_interop_unsafe';

@JS('EventSource')
extension type _EventSource._(JSObject _) implements JSObject {
  external factory _EventSource(String url);
  external void close();
  external set onopen(JSFunction f);
  external set onmessage(JSFunction f);
  external set onerror(JSFunction f);
  external int get readyState;
}

class EventSourceHandle {
  EventSourceHandle._(this._es);
  final _EventSource _es;
  void close() {
    try {
      _es.close();
    } catch (_) {}
  }

  bool get isOpen => _es.readyState == 1;
}

/// Opens a browser EventSource. The browser reconnects on its own; we only
/// surface open/message/error so the caller can react.
EventSourceHandle openEventSource(
  String url, {
  required void Function() onOpen,
  required void Function(String data) onMessage,
  required void Function() onError,
}) {
  final es = _EventSource(url);
  es.onopen = (() => onOpen()).toJS;
  es.onmessage = ((JSAny event) {
    try {
      final data = (event as JSObject)['data'];
      if (data != null) onMessage((data as JSString).toDart);
    } catch (_) {}
  }).toJS;
  es.onerror = (() => onError()).toJS;
  return EventSourceHandle._(es);
}
