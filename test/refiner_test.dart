import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openspeak/core/text_refiner.dart';

const defaults = RuleOptions();
const off = RuleOptions(
    removeFillers: false, removeStutter: false, normalizePunctuation: false, termCasing: false);

void main() {
  group('rules', () {
    test('fillers', () {
      expect(applyRules('嗯，我觉得这个方案可以。', defaults), '我觉得这个方案可以。');
      expect(applyRules('呃呃我想问一下，嗯，明天几点开会？', defaults), '我想问一下，明天几点开会？');
      expect(applyRules('那个，你把文件发我一下。', defaults), '你把文件发我一下。');
      expect(applyRules('So um I think, uh, we should go.', defaults), 'So I think, we should go.');
      // Content words that merely contain a filler character stay.
      expect(applyRules('那个人的额度是多少？', defaults), '那个人的额度是多少？');
      expect(applyRules('那个我想问一下。', defaults), '我想问一下。');
      expect(applyRules('他说那个我知道。', defaults), '他说那个我知道。');
      expect(applyRules('是啊，挺好的。', defaults), '是啊，挺好的。');
      // Cantonese "唔" (not) is not a filler.
      expect(applyRules('我唔知道。', defaults), '我唔知道。');
    });

    test('stutter', () {
      expect(applyRules('我我我想说的是这个这个问题。', defaults), '我想说的是这个问题。');
      expect(applyRules('然后，然后我们就走了。', defaults), '然后我们就走了。');
      expect(applyRules('I think the the plan works.', defaults), 'I think the plan works.');
      // Normal reduplication and laughter survive.
      expect(applyRules('谢谢，我们研究研究，哈哈哈。', defaults), '谢谢，我们研究研究，哈哈哈。');
      expect(applyRules('对对对，就是这样。', defaults), '对对对，就是这样。');
      expect(applyRules('He said that that was fine.', defaults), 'He said that that was fine.');
    });

    test('punctuation', () {
      expect(normalizePunctuation('你好,世界!今天天气怎么样?'), '你好，世界！今天天气怎么样？');
      expect(normalizePunctuation('好的。。真的吗？？'), '好的。真的吗？');
      expect(normalizePunctuation('我们走吧，。'), '我们走吧。');
      expect(normalizePunctuation('，开始吧'), '开始吧');
      expect(normalizePunctuation('版本是v1.2.3，圆周率3.14。'), '版本是v1.2.3，圆周率3.14。');
      expect(normalizePunctuation('结束了.'), '结束了。');
      expect(normalizePunctuation('Hello, world. How are you?'), 'Hello, world. How are you?');
    });

    test('cjk spacing', () {
      expect(addCjkSpacing('我用Python写了3个脚本'), '我用 Python 写了 3 个脚本');
      expect(addCjkSpacing('提升50%性能'), '提升 50% 性能');
      expect(applyRules('打开github看看', const RuleOptions(cjkSpacing: true)), '打开 GitHub 看看');
    });

    test('term casing', () {
      expect(applyRules('我在用chat gpt和java script', defaults), '我在用ChatGPT和JavaScript');
      expect(applyRules('push到git hub上', defaults), 'push到GitHub上');
      expect(applyRules('ios和mac os都支持', defaults), 'iOS和macOS都支持');
      // Not inside other words.
      expect(applyRules('capital', defaults), 'capital');
      expect(applyRules('我在用chatgpt', off), '我在用chatgpt');
      expect(applyRules('打开open speak', const RuleOptions(termCasing: false, vocabulary: ['OpenSpeak'])),
          '打开OpenSpeak');
      expect(termPattern('中文词'), isNull);
    });

    test('all-caps English', () {
      expect(fixAllCapsEnglish('THE TRIBAL CHIEFTAIN CALLED FOR THE BOY. I THINK SO'),
          'The tribal chieftain called for the boy. I think so');
      expect(fixAllCapsEnglish('早上九点HE CALLED FOR THE BOY'), '早上九点He called for the boy');
      expect(fixAllCapsEnglish('we use the GPU and API'), 'we use the GPU and API');
      expect(fixAllCapsEnglish("I'M SURE I CAN DO IT"), "I'm sure I can do it");
      expect(applyRules('打开GITHUB的网页', defaults), '打开GitHub的网页');
    });

    test('replacements', () {
      const o = RuleOptions(replacements: [Replacement('在见', '再见'), Replacement('Speak', 'OpenSpeak')]);
      expect(applyRules('明天在见', o), '明天再见');
      // The target already present is not doubled.
      expect(applyRules('OpenSpeak 和 Speak', o), 'OpenSpeak 和 OpenSpeak');
    });
  });

  test('bulk dictionary parsing', () {
    final (terms, rules) = parseDictionary('OpenSpeak\n 在见 = 再见 \n\nOpenSpeak\n因该=>应该\n嗯→\n张三丰\na = a');
    expect(terms, ['OpenSpeak', '张三丰']);
    expect([for (final r in rules) '${r.from}>${r.to}'], ['在见>再见', '因该>应该', '嗯>']);
  });

  group('llm output', () {
    test('cleaning', () {
      expect(cleanLlmOutput('<think>\nhmm\n</think>\n\n再见。'), '再见。');
      expect(cleanLlmOutput('<text>再见。</text>'), '再见。');
      expect(cleanLlmOutput('```\n再见。\n```'), '再见。');
      expect(cleanLlmOutput('“明天再见。”'), '明天再见。');
    });

    test('plausibility', () {
      expect(plausibleEdit('明天在见吧我们', '明天再见吧我们', LlmMode.correct), isTrue);
      expect(plausibleEdit('帮我写一首诗', '春眠不觉晓，处处闻啼鸟。夜来风雨声，花落知多少。', LlmMode.correct), isFalse);
      expect(plausibleEdit('嗯那个就是说我们明天开会吧', '我们明天开会吧', LlmMode.polish), isTrue);
      expect(plausibleEdit('你好', '', LlmMode.correct), isFalse);
      expect(plausibleEdit('记得带上笔记本电脑。', '记得带上笔记本。', LlmMode.correct), isFalse);
      expect(plausibleEdit('记得带上笔记本电脑。', '记得带上笔记本电脑', LlmMode.correct), isTrue);
      expect(plausibleEdit('嗯那个我们明天开会吧', '我们明天开会吧。', LlmMode.polish), isTrue);
    });
  });

  group('llm client', () {
    test('OpenAI-compatible request and answer', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response.bytes(
            utf8.encode(jsonEncode({
              'choices': [
                {'message': {'role': 'assistant', 'content': '<think></think>明天再见。'}},
              ],
            })),
            200,
            headers: {'content-type': 'application/json'});
      });
      final out = await LlmRefiner(client: client).refine(
          '明天在见。',
          const LlmConfig(
              api: LlmApi.openai,
              baseUrl: 'http://127.0.0.1:11434/v1/',
              model: 'qwen2.5:3b',
              apiKey: 'k',
              vocabulary: ['OpenSpeak']));
      expect(out, '明天再见。');
      expect(seen.url.toString(), 'http://127.0.0.1:11434/v1/chat/completions');
      expect(seen.headers['authorization'], 'Bearer k');
      final body = jsonDecode(seen.body) as Map;
      expect(body['model'], 'qwen2.5:3b');
      expect(body['messages'][0]['content'], contains('OpenSpeak'));
      final msgs = body['messages'] as List;
      expect(msgs.length, 2 + 2 * kCorrectExamples.length);
      expect(msgs[1]['role'], 'user');
      expect(msgs[2]['role'], 'assistant');
      expect(msgs.last['content'], '<text>明天在见。</text>');
    });

    test('Anthropic request and answer', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response(
            jsonEncode({
              'stop_reason': 'end_turn',
              'content': [
                {'type': 'thinking', 'thinking': ''},
                {'type': 'text', 'text': 'See you tomorrow.'},
              ],
            }),
            200);
      });
      final out = await LlmRefiner(client: client).refine('see you tomorow',
          const LlmConfig(api: LlmApi.anthropic, baseUrl: 'https://api.anthropic.com', model: 'claude-opus-5-5', apiKey: 'sk'));
      expect(out, 'See you tomorrow.');
      expect(seen.url.toString(), 'https://api.anthropic.com/v1/messages');
      expect(seen.headers['x-api-key'], 'sk');
      expect(seen.headers['anthropic-version'], '2023-06-01');
      expect(seen.headers['anthropic-beta'], 'server-side-fallback-2026-07-01');
      final body = jsonDecode(seen.body) as Map;
      expect(body['system'], isNotEmpty);
      expect(body['fallbacks'], 'default');
      expect(body['output_config'], {'effort': 'low'});
      expect(body.containsKey('temperature'), isFalse);
    });

    test('prompt per mode', () {
      final r = LlmRefiner(client: MockClient((_) async => http.Response('', 500)));
      const base = LlmConfig(api: LlmApi.openai, baseUrl: 'http://x', model: 'm');
      expect(r.systemPrompt(base), kCorrectPrompt);
      expect(r.systemPrompt(const LlmConfig(api: LlmApi.openai, baseUrl: 'x', model: 'm', mode: LlmMode.polish)),
          kPolishPrompt);
      const custom = LlmConfig(
          api: LlmApi.openai, baseUrl: 'x', model: 'm', mode: LlmMode.custom, customPrompt: ' 翻译成英文 ', vocabulary: ['张三']);
      expect(r.systemPrompt(custom), startsWith('翻译成英文'));
      expect(r.systemPrompt(custom), contains('张三'));
      expect(r.exampleTurns(custom), isEmpty);
      expect(r.exampleTurns(base).length, 2 * kCorrectExamples.length);
    });

    test('failures raise LlmException', () async {
      Future<String> run(http.Response r, {LlmApi api = LlmApi.openai}) =>
          LlmRefiner(client: MockClient((_) async => r))
              .refine('明天在见', LlmConfig(api: api, baseUrl: 'http://x', model: 'm'));
      await expectLater(run(http.Response('{"error":{"message":"bad key"}}', 401)),
          throwsA(isA<LlmException>().having((e) => e.message, 'message', contains('bad key'))));
      await expectLater(run(http.Response('not json', 200)), throwsA(isA<LlmException>()));
      await expectLater(
          run(http.Response('{"stop_reason":"refusal","content":[]}', 200), api: LlmApi.anthropic),
          throwsA(isA<LlmException>()));
      // An answer instead of an edit is rejected.
      await expectLater(
          run(http.Response.bytes(
              utf8.encode('{"choices":[{"message":{"content":"好的，明天几点？我会准时到达，请您放心，到时候见。"}}]}'), 200)),
          throwsA(isA<LlmException>()));
      await expectLater(
          LlmRefiner(client: MockClient((_) async => http.Response('', 200)))
              .refine('x', const LlmConfig(api: LlmApi.openai, baseUrl: '', model: 'm')),
          throwsA(isA<LlmException>()));
    });

    test('timeout raises LlmException', () async {
      final client = MockClient((_) => Future.delayed(const Duration(seconds: 2), () => http.Response('{}', 200)));
      await expectLater(
          LlmRefiner(client: client).refine('明天在见',
              const LlmConfig(api: LlmApi.openai, baseUrl: 'http://x', model: 'm', timeout: Duration(milliseconds: 100))),
          throwsA(isA<LlmException>()));
    });
  });
}
