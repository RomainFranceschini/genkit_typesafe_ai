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

  test('public barrel registers a TypeSafe model router', () {
    final plugin = typeSafeAI(apiKey: 'test-key');
    final router = plugin.defineModelRouter(
      name: 'cost-router',
      instructions: 'Choose a route.',
      routes: {
        'fast': TypeSafeModelRoute(
          model: modelRef('fast-model'),
          criteria: 'Simple tasks.',
        ),
      },
    );
    final TypeSafeModelRouter typedRouter = router;
    final TypeSafeRouteDecision? decision = typedRouter.decisionFromContext(
      null,
    );

    expect(typedRouter.name, 'typesafe/cost-router');
    expect(decision, isNull);
    expect(plugin.middleware().single.name, typedRouter.name);
    plugin.close();
  });

  test('public barrel exports Auto Mode reference', () {
    final plugin = typeSafeAI(apiKey: 'test-key');
    final TypeSafeAutoMode guard = plugin.defineAutoMode(
      name: 'guard-writes',
      tools: ['delete'],
    );
    expect(guard.name, 'typesafe/guard-writes');
    expect(plugin.middleware().single.name, guard.name);
    plugin.close();
  });
}
