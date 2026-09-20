# Genkit TypeSafe AI

Typed TypeSafe AI classifier actions and model discovery for Genkit Dart. This
package is a Genkit plugin, not a Genkit Model provider.

## Installation

```sh
dart pub add genkit genkit_typesafe_ai
```

The TypeSafe SDK resolves `TYPESAFE_API_KEY` from the environment. You can also
pass `apiKey` directly when constructing the plugin.

## Typed classifier quickstart

```dart
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
```

The package exports TypeSafe SDK question and answer types. A classifier may mix
`Choice`, `Noul`, and `Score` questions in one request:

```dart
import 'package:genkit/genkit.dart' hide Score;
import 'package:genkit_typesafe_ai/genkit_typesafe_ai.dart';

final sentiment = Choice({'negative': 'Unhappy', 'positive': 'Happy'});
final needsFollowUp = Noul(instructions: 'Does this need a reply?');
final priority = Score.levels(['Low priority', 'High priority']);
final classifier = typeSafe.defineClassifier(
  name: 'ticket-analysis',
  questions: {
    'sentiment': sentiment,
    'needsFollowUp': needsFollowUp,
    'priority': priority,
  },
);
```

Retrieve each typed answer with `response.get(question)`, such as
`response.get(sentiment).choice`, `response.get(needsFollowUp).noul`, or
`response.get(priority).score`.

## Plugin options and models

`typeSafeAI` accepts `apiKey`, `baseUrl`, `defaultModel`, `logger`, `retry`,
`timeout`, `defaultHeaders`, and an optional `httpClient`. The SDK also honors
`TYPESAFE_API_KEY` when no key is passed. Set a fixed plugin model with
`defaultModel`, or override the request for a classifier with its `model`,
`timeout`, `retry`, and `headers` options:

```dart
final typeSafe = typeSafeAI(defaultModel: 'jev-latest');
final classifier = typeSafe.defineClassifier(
  name: 'priority',
  model: 'jev-latest',
  questions: {'urgent': Noul(instructions: 'Is this urgent?')},
);
```

Discover available models explicitly with:

```dart
final models = await typeSafe.listModels();
```

## Errors and lifecycle

Classifier and model-discovery failures are surfaced as `GenkitException`.
Inspect `underlyingException` to handle a TypeSafe SDK `TypeSafeError` or
`ApiError` when needed:

```dart
try {
  await classifier('Classify this ticket.');
} on GenkitException catch (error) {
  final underlying = error.underlyingException;
  if (underlying is TypeSafeError || underlying is ApiError) {
    print(underlying);
  }
}
```

Call `typeSafe.close()` when finished. The plugin closes clients it creates but
does not close an injected `httpClient`; its owner remains responsible for that
client. Also shut down the `Genkit` instance with `await ai.shutdown()`.

## Browser use

Browser use requires `dangerouslyAllowBrowser: true`. This explicitly permits a
client-side API key and is unsafe for public or untrusted browser deployments;
use a server-side proxy instead whenever possible.

## Limitations

This subproject supports TypeSafe classifier actions and model discovery only.
It does not provide `ai.generate`, chat, streaming, tools, embeddings, or
middleware.
