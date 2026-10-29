/// Non-web fallback: no EventSource available, so no live stream.
/// The periodic reconciliation timer still keeps things in sync.
class EventSourceHandle {
  void close() {}
  bool get isOpen => false;
}

EventSourceHandle openEventSource(
  String url, {
  required void Function() onOpen,
  required void Function(String data) onMessage,
  required void Function() onError,
}) {
  onError();
  return EventSourceHandle();
}
