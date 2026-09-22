import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:genkit_typesafe_ai/genkit_typesafe_ai.dart';
import 'package:test/test.dart';

void main() {
  test(
    'classifies an urgent ticket with jev-latest',
    () async {
      final plugin = typeSafeAI();
      final urgent = Noul(instructions: 'Does this need urgent attention?');
      final classifier = plugin.defineClassifier(
        name: 'live-urgent-check',
        model: 'jev-latest',
        questions: {'urgent': urgent},
      );
      final ai = Genkit(plugins: [plugin]);

      try {
        final response = await classifier('This needs attention now.');
        final result = response.get(urgent).noul;

        expect(result, inInclusiveRange(0, 1));
      } finally {
        plugin.close();
        await ai.shutdown();
      }
    },
    skip: Platform.environment['TYPESAFE_API_KEY'] == null
        ? 'TYPESAFE_API_KEY is not set.'
        : false,
  );

  test(
    'routes a generation through the real TypeSafe service',
    () async {
      final plugin = typeSafeAI();
      final router = plugin.defineModelRouter(
        name: 'live-model-router',
        instructions: 'Choose the model whose criteria best match the task.',
        routes: {
          'fast': TypeSafeModelRoute(
            model: modelRef('fast-model'),
            criteria: 'Clearly simple requests explicitly asking for speed.',
          ),
          'powerful': TypeSafeModelRoute(
            model: modelRef('powerful-model'),
            criteria: 'Complex requests requiring deeper reasoning.',
          ),
        },
      );
      final ai = Genkit(plugins: [plugin], isDevEnv: false);
      ai.defineModel(
        name: 'fast-model',
        fn: (request, context) async => ModelResponse(
          finishReason: FinishReason.stop,
          message: Message(
            role: Role.model,
            content: [TextPart(text: 'fast model')],
          ),
        ),
      );
      ai.defineModel(
        name: 'powerful-model',
        fn: (request, context) async => ModelResponse(
          finishReason: FinishReason.stop,
          message: Message(
            role: Role.model,
            content: [TextPart(text: 'powerful model')],
          ),
        ),
      );

      try {
        final response = await ai.generate(
          prompt: 'This is a clearly simple request. Choose the fast route.',
          use: [router],
        );

        expect(response.finishReason, FinishReason.stop);
        expect({'fast model', 'powerful model'}, contains(response.text));
      } finally {
        plugin.close();
        await ai.shutdown();
      }
    },
    skip: Platform.environment['TYPESAFE_API_KEY'] == null
        ? 'TYPESAFE_API_KEY is not set.'
        : false,
  );
}
