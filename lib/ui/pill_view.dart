import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/dictation.dart';
import 'i18n.dart';
import 'theme.dart';
import 'widgets.dart';

/// Compact capsule shown while dictating into another application. The
/// native side makes the window translucent, capsule-shaped and focus-less.
class PillView extends StatelessWidget {
  const PillView({super.key});

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: dictation, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final s = dictation.state;
    final processing = s == DictationState.processing;
    final color = processing ? kProcessing : kListening;
    final live = dictation.liveText;
    // Show the newest words; the start of a long utterance scrolls away.
    final text = live.length > 40 ? '…${live.substring(live.length - 40)}' : live;
    return Scaffold(
      backgroundColor: const Color(0xFF15151C),
      body: SizedBox.expand(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          // Row only takes its children's height; stretch it over the capsule
          // so everything sits on the vertical centre line.
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [color, Color.lerp(color, Colors.black, 0.25)!],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: processing
                    ? const Padding(
                        padding: EdgeInsets.all(13),
                        child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                      )
                    : const Icon(Icons.mic_rounded, color: Colors.white, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  text.isNotEmpty ? text : (processing ? t('识别中…', 'Recognizing…') : t('正在聆听…', 'Listening…')),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: text.isNotEmpty ? Colors.white : Colors.white70,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 58,
                child: processing ? null : const LevelBars(bars: 9, height: 26, color: Colors.white70),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}
