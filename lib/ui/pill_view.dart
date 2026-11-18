import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/dictation.dart';
import 'i18n.dart';
import 'theme.dart';
import 'widgets.dart';

/// Compact always-on-top recording indicator shown while dictating into
/// another application (the window never takes focus in this mode).
class PillView extends StatelessWidget {
  const PillView({super.key});

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: dictation, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final s = dictation.state;
    final listening = s == DictationState.listening;
    final color = listening ? kListening : kProcessing;
    final live = dictation.liveText;
    // Show the newest words; the start of a long utterance scrolls away.
    final text = live.length > 64 ? '…${live.substring(live.length - 64)}' : live;
    return Scaffold(
      backgroundColor: const Color(0xFF16161E),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: listening
                ? const Icon(Icons.mic_rounded, color: Colors.white, size: 24)
                : const Padding(
                    padding: EdgeInsets.all(12),
                    child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                  ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text.isNotEmpty
                      ? text
                      : (listening ? t('正在聆听…', 'Listening…') : t('识别中…', 'Recognizing…')),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textDirection: TextDirection.ltr,
                  style: TextStyle(
                    color: text.isNotEmpty ? Colors.white : Colors.white70,
                    fontSize: 14,
                    height: 1.35,
                  ),
                ),
                if (listening) ...[
                  const SizedBox(height: 4),
                  const LevelBars(bars: 40, height: 14, color: kListening),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }
}
