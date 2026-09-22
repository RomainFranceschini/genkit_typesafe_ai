import 'package:genkit/genkit.dart';
import 'package:genkit_typesafe_ai/genkit_typesafe_ai.dart';

Future<void> main() async {
  final typeSafe = typeSafeAI();
  final department = Choice({
    'billing': 'Payment and subscription issues',
    'technical': 'Product and integration issues',
  });
  final urgent = Noul(instructions: 'Does this require an urgent response?');
  final triage = typeSafe.defineClassifier(
    name: 'support-triage',
    questions: {'department': department, 'urgent': urgent},
  );
  typeSafe.defineModelRouter(
    name: 'cost-router',
    instructions: 'Choose the least costly capable model.',
    routes: {
      'fast': TypeSafeModelRoute(
        model: modelRef('provider/fast'),
        criteria: 'Simple, well-scoped requests.',
      ),
      'powerful': TypeSafeModelRoute(
        model: modelRef('provider/powerful'),
        criteria: 'Complex requests requiring deeper reasoning.',
      ),
    },
  );
  typeSafe.defineAutoMode(
    name: 'guard-writes',
    tools: ['provider/delete-file'],
  );
  final ai = Genkit(plugins: [typeSafe]);
  try {
    final response = await triage('I was charged twice. Please fix this now.');
    print(response.get(department).choice);
    print(response.get(urgent).noul);
  } finally {
    typeSafe.close();
    await ai.shutdown();
  }
}
