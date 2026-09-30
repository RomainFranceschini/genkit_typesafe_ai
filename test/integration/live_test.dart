@Tags(['live'])
library;

import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:genkit_typesafe_ai/genkit_typesafe_ai.dart';
import 'package:test/test.dart';

void main() {
  test(
    'classifies an urgent ticket with default model',
    () async {
      final plugin = typeSafeAI();
      final urgent = Noul(instructions: 'Does this need urgent attention?');
      final classifier = plugin.defineClassifier(
        name: 'live-urgent-check',
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

  for (final (label, prompt, toolName, description, blocked) in [
    (
      'refuses unauthorized deletion',
      'Do not delete the demo report. I only want to read it.',
      'deleteDemoReport',
      'Deletes a disposable in-memory demo report; '
          'no real data, files, or external systems are affected.',
      true,
    ),
    (
      'allows explicitly authorized read-only access',
      'Please read the disposable demo report. This is an in-memory demo '
          'with no secrets or external side effects, and I authorize reading it.',
      'readDemoReport',
      'Reads a public in-memory demo report without changing it; '
          'no files, secrets, or external systems are accessed.',
      false,
    ),
  ]) {
    test(
      'Auto Mode $label through the real TypeSafe service',
      () async {
        final plugin = typeSafeAI();
        final guard = plugin.defineAutoMode(
          name: 'live-tool-guard',
          tools: [toolName],
        );
        final ai = Genkit(plugins: [plugin], isDevEnv: false);
        var executions = 0;
        final tool = ai.defineTool<Map<String, dynamic>, String>(
          name: toolName,
          description: description,
          fn: (input, context) async {
            executions++;
            return .response('public demo report');
          },
        );
        ToolResponsePart? result;
        ai.defineModel(
          name: 'live-tool-proposer',
          fn: (request, context) async {
            final isToolResult = request.messages.last.role == Role.tool;
            if (isToolResult) {
              result = request.messages.last.content
                  .map((part) => part.toolResponsePart)
                  .nonNulls
                  .single;
            }
            return ModelResponse(
              finishReason: FinishReason.stop,
              message: Message(
                role: Role.model,
                content: isToolResult
                    ? [TextPart(text: 'done')]
                    : [
                        ToolRequestPart(
                          toolRequest: ToolRequest(
                            ref: 'demo-call-1',
                            name: tool.name,
                            input: <String, dynamic>{},
                          ),
                        ),
                      ],
              ),
            );
          },
        );

        try {
          final response = await ai.generate(
            prompt: prompt,
            model: modelRef('live-tool-proposer'),
            tools: [tool],
            use: [guard],
          );

          expect(response.finishReason, FinishReason.stop);
          expect(response.text, 'done');
          expect(executions, blocked ? 0 : 1);
          expect(result, isNotNull);
          expect(result!.toolResponse.ref, 'demo-call-1');
          if (blocked) {
            expect(result!.toolResponse.output, contains('was blocked'));
            expect(result!.metadata?['typesafe']['blocked'], isTrue);
            expect(
              result!.metadata?['typesafe']['riskProbability'],
              inInclusiveRange(0.5, 1),
            );
          } else {
            expect(result!.toolResponse.output, 'public demo report');
          }
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
}
