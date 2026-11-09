import 'package:flutter/material.dart';

import '../services/push_progress.dart';
import '../services/saf_workspace.dart';

/// Live push status.
///
/// A push of a real project takes minutes. Without this the app looked frozen,
/// which is indistinguishable from a crash, so the user force-closed it and
/// retried — which is exactly how a half-finished upload looked "stuck".
class PushProgressPanel extends StatelessWidget {
  const PushProgressPanel({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PushProgress>(
      valueListenable: PushProgressReporter.current,
      builder: (context, progress, _) {
        if (progress.phase == PushPhase.idle) {
          return const SizedBox.shrink();
        }

        final running = progress.isRunning;
        final color = _colorFor(progress.phase);

        return Container(
          margin: EdgeInsets.fromLTRB(12, compact ? 6 : 8, 12, 4),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: const Color(0xFF0F1729),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.45)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (running)
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        valueColor: AlwaysStoppedAnimation<Color>(color),
                      ),
                    )
                  else
                    Icon(_iconFor(progress.phase), size: 14, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      progress.label,
                      style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (progress.total > 0)
                    Text(
                      '${progress.done}/${progress.total}',
                      style: const TextStyle(
                        color: Color(0xFF94A3B8),
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  if (running) ...[
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: () {
                        PushProgressReporter.requestCancel();
                        _cancelNative();
                      },
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          'STOP',
                          style: TextStyle(
                            color: Color(0xFFF87171),
                            fontSize: 10.5,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  // Null value = indeterminate sweep, used while the total is
                  // not yet known (scan, commit) so the bar never sits at 0%.
                  value: progress.fraction,
                  minHeight: 4,
                  backgroundColor: const Color(0xFF1E293B),
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
              if (progress.message.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  progress.message,
                  style: const TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 11,
                    height: 1.3,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  void _cancelNative() {
    // Fire and forget: also stops a native SAF walk/hash loop.
    SafWorkspace.cancel();
  }

  Color _colorFor(PushPhase phase) => switch (phase) {
        PushPhase.done => const Color(0xFF34D399),
        PushPhase.failed => const Color(0xFFF87171),
        PushPhase.cancelled => const Color(0xFFFBBF24),
        PushPhase.committing => const Color(0xFFA78BFA),
        _ => const Color(0xFF38BDF8),
      };

  IconData _iconFor(PushPhase phase) => switch (phase) {
        PushPhase.done => Icons.check_circle_rounded,
        PushPhase.failed => Icons.error_rounded,
        PushPhase.cancelled => Icons.block_rounded,
        _ => Icons.sync_rounded,
      };
}
