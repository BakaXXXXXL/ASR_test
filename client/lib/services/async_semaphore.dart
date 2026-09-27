import 'dart:async';
import 'dart:collection';

/// 异步信号量，用于全局限制并发 HTTP 请求数，防止服务商 429 报错或网络资源耗尽。
class AsyncSemaphore {
  final int maxPermits;
  int _currentPermits;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  AsyncSemaphore(this.maxPermits)
      : assert(maxPermits > 0, 'maxPermits must be greater than 0'),
        _currentPermits = maxPermits;

  /// 当前可用许可证数
  int get availablePermits => _currentPermits;

  /// 当前排队等待者数量
  int get queueLength => _waiters.length;

  /// 获取一个许可证，无空闲时挂起等待
  Future<void> acquire() {
    if (_currentPermits > 0) {
      _currentPermits--;
      return Future.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  /// 释放一个许可证，唤醒等待队列中的下一个任务
  void release() {
    if (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      waiter.complete();
    } else {
      _currentPermits++;
    }
  }

  /// 受限执行一个异步操作，执行完毕后必定自动释放许可证
  Future<T> run<T>(Future<T> Function() action) async {
    await acquire();
    try {
      return await action();
    } finally {
      release();
    }
  }
}
