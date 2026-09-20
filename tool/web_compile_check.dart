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
  Genkit(plugins: [plugin]);
  plugin.close();
}
