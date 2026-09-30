import 'package:genkit/genkit.dart';
import 'package:genkit_typesafe_ai/genkit_typesafe_ai.dart';

void main() {
  final plugin = typeSafeAI(
    apiKey: 'compile-only',
    dangerouslyAllowBrowser: true,
  );
  plugin.defineClassifier(
    name: 'web-check',
    questions: {'safe': Noul(instructions: 'Is this safe?')},
  );
  plugin.defineModelRouter(
    name: 'web-router',
    instructions: 'Choose a route.',
    routes: {
      'fast': TypeSafeModelRoute(
        model: modelRef('provider/fast'),
        criteria: 'Simple browser-safe task.',
      ),
    },
  );
  plugin.defineAutoMode(name: 'web-guard', tools: ['deleteDemoReport']);
  Genkit(plugins: [plugin]);
  plugin.close();
}
