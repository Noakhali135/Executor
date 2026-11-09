import 'dart:async';

import 'package:flutter/foundation.dart';

/// Stage of a push, in the order it happens.
enum PushPhase {
  idle,
  checking,
  scanning,
  hashing,
  uploading,
  committing,
  done,
  failed,
  cancelled,
}

/// A snapshot of what a push is doing right now.
@immutable
class PushProgress {
  final PushPhase phase;

  /// Work completed within [phase] (files hashed, files uploaded, ...).
  final int done;

  /// Total work for [phase]. 0 means "unknown / indeterminate".
  final int total;

  /// Human readable summary, shown under the bar.
  final String message;

  const PushProgress({
    required this.phase,
    this.done = 0,
    this.total = 0,
    this.message = '',
  });

  const PushProgress.idle()
      : phase = PushPhase.idle,
        done = 0,
        total = 0,
        message = '';

  bool get isRunning => switch (phase) {
        PushPhase.idle ||
        PushPhase.done ||
        PushPhase.failed ||
        PushPhase.cancelled =>
          false,
        _ => true,
      };

  /// 0..1, or null when the phase has no measurable total.
  double? get fraction {
    if (total <= 0) return null;
    final value = done / total;
    // clamp() is declared to return num, so convert explicitly.
    return value < 0 ? 0.0 : (value > 1 ? 1.0 : value);
  }

  String get label => switch (phase) {
        PushPhase.idle => 'Idle',
        PushPhase.checking => 'Checking repository access',
        PushPhase.scanning => 'Scanning workspace',
        PushPhase.hashing => 'Comparing files',
        PushPhase.uploading => 'Uploading files',
        PushPhase.committing => 'Creating commit',
        PushPhase.done => 'Push complete',
        PushPhase.failed => 'Push failed',
        PushPhase.cancelled => 'Push cancelled',
      };
}

/// Global push progress, so the Runner keeps showing status after the sync
/// dialog is dismissed.
///
/// A push must never look frozen: a large project takes minutes, and without a
/// heartbeat the app was indistinguishable from a crash.
class PushProgressReporter {
  PushProgressReporter._();

  static final ValueNotifier<PushProgress> current =
      ValueNotifier<PushProgress>(const PushProgress.idle());

  static bool _cancelRequested = false;

  /// True once the user asked to stop. Long operations poll this.
  static bool get cancelRequested => _cancelRequested;

  static void begin([String message = '']) {
    _cancelRequested = false;
    current.value = PushProgress(
      phase: PushPhase.checking,
      message: message,
    );
  }

  static void report(
    PushPhase phase, {
    int done = 0,
    int total = 0,
    String message = '',
  }) {
    current.value = PushProgress(
      phase: phase,
      done: done,
      total: total,
      message: message,
    );
  }

  static void finish(PushPhase phase, String message) {
    current.value = PushProgress(phase: phase, message: message);
  }

  static void reset() {
    _cancelRequested = false;
    current.value = const PushProgress.idle();
  }

  static void requestCancel() {
    _cancelRequested = true;
    final snapshot = current.value;
    if (snapshot.isRunning) {
      current.value = PushProgress(
        phase: snapshot.phase,
        done: snapshot.done,
        total: snapshot.total,
        message: 'Cancelling... waiting for in-flight files to finish.',
      );
    }
  }
}

/// Thrown internally when the user cancels; caught before any commit is made.
class PushCancelled implements Exception {
  const PushCancelled();
  @override
  String toString() => 'Push cancelled before any commit was created.';
}

/// Caps how much upload work may be in flight at once.
///
/// Callers reserve the *encoded* cost of a file (raw bytes x ~3 for the base64
/// string and JSON body). Without a cap, "workers x file size" is what gets a
/// phone process killed; with it, peak memory is a fixed budget regardless of
/// how many files are queued or how large they are.
class ByteBudget {
  ByteBudget(this.capacity);

  final int capacity;
  int _used = 0;
  final List<Completer<void>> _waiters = [];

  /// Bytes still available without waiting.
  int get available => capacity - _used;

  Future<void> reserve(int bytes) async {
    if (capacity <= 0) return;
    // A single file bigger than the whole budget gets an exclusive slot.
    final need = bytes > capacity ? capacity : bytes;
    while (_used + need > capacity) {
      final completer = Completer<void>();
      _waiters.add(completer);
      await completer.future;
    }
    _used += need;
  }

  void release(int bytes) {
    if (capacity <= 0) return;
    final need = bytes > capacity ? capacity : bytes;
    _used -= need;
    if (_used < 0) _used = 0;
    if (_waiters.isEmpty) return;
    // Wake everyone; each re-checks the condition in the loop above.
    final waiting = List<Completer<void>>.from(_waiters);
    _waiters.clear();
    for (final completer in waiting) {
      if (!completer.isCompleted) completer.complete();
    }
  }
}
