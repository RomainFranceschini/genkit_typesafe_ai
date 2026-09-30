import 'package:genkit/genkit.dart';
import 'package:genkit_typesafe_ai/genkit_typesafe_ai.dart';

// Requires TYPESAFE_API_KEY. TypeSafe is real; the generation models are local
// demonstrations so no second provider account or key is needed.
Future<void> main() async {
  final typeSafe = typeSafeAI();
  final router = typeSafe.defineModelRouter(
    name: 'demo-router',
    instructions: 'Choose the model whose criteria best match the request.',
    routes: {
      'fast': TypeSafeModelRoute(
        model: modelRef('demo/fast'),
        criteria: 'Simple, well-scoped requests that prioritize speed.',
      ),
      'powerful': TypeSafeModelRoute(
        model: modelRef('demo/powerful'),
        criteria: 'Complex requests requiring deeper reasoning.',
      ),
    },
  );
  final ai = Genkit(plugins: [typeSafe], isDevEnv: false);
  for (final name in ['demo/fast', 'demo/powerful']) {
    ai.defineModel(
      name: name,
      fn: (request, context) async {
        final decision = router.decisionFromContext(context.context);
        print('Route: ${decision?.route}; confidence: ${decision?.confidence}');
        return ModelResponse(
          finishReason: FinishReason.stop,
          message: Message(
            role: Role.model,
            content: [TextPart(text: 'Local demo response from $name.')],
          ),
        );
      },
    );
  }
  try {
    final response = await ai.generate(
      prompt: 'Say hello. This is a simple request; prioritize speed.',
      use: [router],
    );
    if (response.finishReason == FinishReason.failed) {
      throw StateError('Routing failed: ${response.error}');
    }
    print(response.text);
  } finally {
    typeSafe.close();
    await ai.shutdown();
  }
}
