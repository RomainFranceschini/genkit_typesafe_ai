import 'package:genkit/genkit.dart' hide Score;
import 'package:genkit_typesafe_ai/genkit_typesafe_ai.dart';
import 'package:test/test.dart';

void main() {
  test('public barrel registers a typed classifier action', () async {
    final plugin = typeSafeAI(apiKey: 'test-key');
    final urgent = Noul(instructions: 'Is this urgent?');
    final department = Choice<String>({
      'billing': 'Payment and subscription issues',
      'technical': 'Product and integration issues',
    });
    final Score<int> score = Score.levels(['low priority', 'high priority']);
    plugin.defineClassifier(
      name: 'triage',
      questions: {'urgent': urgent, 'department': department, 'score': score},
    );
    final ai = Genkit(plugins: [plugin]);

    try {
      final actions = await ai.registry.listActions();

      expect(actions.any((action) => action.name == 'typesafe/triage'), isTrue);
    } finally {
      plugin.close();
      await ai.shutdown();
    }
  });
}
