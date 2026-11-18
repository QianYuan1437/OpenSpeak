import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak/core/asr_engine.dart';
import 'package:openspeak/core/mic_profiles.dart';
import 'package:openspeak/core/text_output.dart';

void main() {
  test('traditional to simplified', () {
    expect(traditionalToSimplified('開放時間：早上9點至下午5點。'), '开放时间：早上9点至下午5点。');
    // Japanese stays untouched.
    expect(traditionalToSimplified('會議は時間です'), '會議は時間です');
  });

  test('post-process', () {
    expect(postProcess(' WITH  FIFTY. ', stripTrailingPeriod: true), 'WITH FIFTY');
    expect(postProcess('你好。', stripTrailingPeriod: false), '你好。');
  });

  test('join segments', () {
    expect(joinSegments(['你好。', '世界']), '你好。世界');
    expect(joinSegments(['hello', 'world']), 'hello world');
    expect(joinSegments(['', 'a', '  ']), 'a');
  });

  test('mic brands', () {
    expect(detectMicBrand('DJI Mic Mini RX')?.name, 'DJI Mic');
    expect(detectMicBrand('Wireless Microphone RX')?.name, 'DJI Mic');
    expect(detectMicBrand('麦克风 (GODOX MoveLink)')?.name, 'Godox');
    expect(detectMicBrand('Insta360 Mic Air')?.name, 'Insta360 Mic');
    expect(detectMicBrand('麦克风阵列 (Realtek(R) Audio)'), isNull);
    expect(micPreference('Monitor of Built-in Audio'), -1);
  });
}
