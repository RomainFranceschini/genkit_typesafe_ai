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
}
