import 'dart:async';

/// Cooperative priority at operation boundaries; never interrupts an active PTP transaction.
class PriorityWorkQueue {
  static final Object _priorityKey = Object();
  static int get currentPriority => Zone.current[_priorityKey] as int? ?? 0;
  static T background<T>(T Function() action) =>
      runZoned(action, zoneValues: {_priorityKey: 1});
  final List<({int priority, Future<void> Function() run})> _pending = [];
  bool _running = false;

  Future<T> run<T>(Future<T> Function() action) {
    final result = Completer<T>();
    final bound = Zone.current.bindCallback(action);
    _pending.add((
      priority: currentPriority,
      run: () async {
        try {
          result.complete(await bound());
        } catch (error, stack) {
          result.completeError(error, stack);
        }
      }
    ));
    _drain();
    return result.future;
  }

  void _drain() {
    if (_running || _pending.isEmpty) return;
    var index = 0;
    for (var i = 1; i < _pending.length; i++) {
      if (_pending[i].priority < _pending[index].priority) index = i;
    }
    _running = true;
    final next = _pending.removeAt(index);
    unawaited(next.run().whenComplete(() {
      _running = false;
      _drain();
    }));
  }
}
