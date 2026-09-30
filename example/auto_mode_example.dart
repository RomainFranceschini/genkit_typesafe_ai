import 'package:genkit/genkit.dart';
import 'package:genkit_typesafe_ai/genkit_typesafe_ai.dart';

// Requires TYPESAFE_API_KEY. A local demo model intentionally requests a
// forbidden deletion so Auto Mode can refuse it. No real files are touched.
Future<void> main() async {
  final typeSafe = typeSafeAI();
  final guard = typeSafe.defineAutoMode(
    name: 'demo-guard',
    tools: ['deleteDemoReport'],
  );
  final ai = Genkit(plugins: [typeSafe], isDevEnv: false);
  var executions = 0;
  final tool = ai.defineTool<Map<String, dynamic>, String>(
    name: 'deleteDemoReport',
    description:
        'Deletes a disposable in-memory demo report; '
        'no real files or external systems are affected.',
    fn: (input, context) async {
      executions++;
      return .response('demo report deleted');
    },
  );
  ai.defineModel(
    name: 'demo/tool-proposer',
    fn: (request, context) async {
      if (request.messages.last.role == Role.tool) {
        final result = request.messages.last.content
            .map((part) => part.toolResponsePart)
            .nonNulls
            .single;
        print('Blocked: ${result.metadata?['typesafe']['blocked'] == true}');
        return ModelResponse(
          finishReason: FinishReason.stop,
          message: Message(
            role: Role.model,
            content: [TextPart(text: '${result.toolResponse.output}')],
          ),
        );
      }
      return ModelResponse(
        finishReason: FinishReason.stop,
        message: Message(
          role: Role.model,
          content: [
            ToolRequestPart(
              toolRequest: ToolRequest(
                ref: 'demo-delete-1',
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
      prompt: 'Do not delete the demo report. I only want to read it.',
      model: modelRef('demo/tool-proposer'),
      tools: [tool],
      use: [guard],
    );
    if (response.finishReason == FinishReason.failed) {
      throw StateError('Risk classification failed: ${response.error}');
    }
    print(response.text);
    print('Tool executions: $executions');
  } finally {
    typeSafe.close();
    await ai.shutdown();
  }
}
