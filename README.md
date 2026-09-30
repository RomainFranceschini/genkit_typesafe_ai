# Genkit TypeSafe AI

Typed classifiers, model routing, and tool-risk checks for Genkit Dart.

## Installation

```sh
dart pub add genkit genkit_typesafe_ai
export TYPESAFE_API_KEY="your-key"
```

Requires Dart `^3.13.3`. Alternatively, pass `apiKey` to `typeSafeAI()`.

## Classify

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

Define classifiers before creating `Genkit`. Retrieve answers with the original
question objects. TypeSafe SDK types are re-exported by this package.

### Mix question types

```dart
import 'package:genkit/genkit.dart' hide Score;
import 'package:genkit_typesafe_ai/genkit_typesafe_ai.dart';

final sentiment = Choice({'negative': 'Unhappy', 'positive': 'Happy'});
final needsFollowUp = Noul(instructions: 'Does this need a reply?');
final priority = Score.levels(['Low priority', 'High priority']);
final typeSafe = typeSafeAI();
final classifier = typeSafe.defineClassifier(
  name: 'ticket-analysis',
  questions: {
    'sentiment': sentiment,
    'needsFollowUp': needsFollowUp,
    'priority': priority,
  },
);
final response = await classifier('Happy with the fix, but please follow up.');
print(response.get(sentiment).choice);
print(response.get(needsFollowUp).noul);
print(response.get(priority).score);
```

Hide Genkit's `Score` when importing both packages.

## Route models

```dart
final typeSafe = typeSafeAI();
final router = typeSafe.defineModelRouter(
  name: 'cost-router',
  instructions: 'Choose the least costly capable model.',
  routes: {
    'fast': TypeSafeModelRoute(
      model: modelRef('provider/fast', config: {'temperature': 0.1}),
      criteria: 'Simple, well-scoped tasks.',
    ),
    'powerful': TypeSafeModelRoute(
      model: modelRef('provider/powerful', config: {'temperature': 0.7}),
      criteria: 'Complex tasks requiring deeper reasoning.',
    ),
  },
);
final ai = Genkit(plugins: [typeSafe, providerPlugin]);

final response = await ai.generate(
  prompt: 'Summarize this support request.',
  use: [router],
);
```

- Replace `providerPlugin` and model names with your registered provider models.
  This package does not supply generative models or embeddings.
- Routes the latest user message once; keeps the selected model and its config
  across tool-loop turns.
- Selects even low-confidence routes. No confidence threshold or fallback;
  routing failures return a failed generation without calling a model.
- One distinct router per generation. Repeating the same reference has no effect.

### Inspect the decision

```dart
final inspectRoute = ai.defineTool<Map<String, dynamic>, String>(
  name: 'inspectRoute',
  description: 'Reports the selected route.',
  fn: (input, args) async {
    final decision = router.decisionFromContext(args.context);
    return .response(decision?.route ?? 'no route');
  },
);
```

Downstream tools and middleware receive the typed decision in a copied context.
It includes the route, model, confidence, and probabilities. Router metadata and
`decision.toJson()` omit model configs, credentials, and headers.

## Guard tool calls with Auto Mode

```dart
final typeSafe = typeSafeAI();
final autoMode = typeSafe.defineAutoMode(
  name: 'guard-writes',
  tools: [deleteFile.name],
  criteria: const NoulCriteria(
    whenTrue: 'Deletes data or changes access without clear authorization.',
    whenFalse: 'Read-only, reversible, and explicitly authorized by the user.',
  ),
);
final ai = Genkit(plugins: [typeSafe, providerPlugin]);

final response = await ai.generate(
  prompt: 'Handle this request.',
  tools: [deleteFile, readFile],
  use: [autoMode],
);
```

Use your registered `deleteFile`, `readFile`, and provider plugin in this example.

| Risk probability | Result |
| --- | --- |
| Below `0.5` | Runs the tool. |
| `0.5` or higher | Skips it; returns a refusal with `typesafe.blocked` metadata. The model continues. |
| Classification fails | Fails the generation; does not run the guarded tool. |

- Checks **each** listed tool call; unlisted tools run normally.
- Matches the last name segment: `delete` and `files/delete` guard the same tool.
- Sends the proposed name, arguments, description, and up to 30 recent messages
  to TypeSafe, retaining the first system and latest user message.
- Default instructions accept authorization only from explicit user messages.
- Guards generation-loop calls, not direct tool invocations. Can combine with
  routing; repeated Auto Mode references recheck permitted calls.

**Safety:** Conversation contents and tool arguments go to TypeSafe and may appear
in Genkit traces. Avoid secrets. This probabilistic filter is not a security
boundary or human approval flow; use Genkit's `toolApproval` for approval.

### Genkit 0.17 notes

- Namespaced tool restarts require the **full registered name** in both saved
  tool-request history and `interruptRestart`. Normalize short names yourself;
  Auto Mode does not rewrite them.
- Resumed conversations retain refusal text and call references, but lose
  `typesafe.blocked` metadata. Check the classifier trace for restarted decisions.
- Tool-hook failures have top-level `INTERNAL` status; the mapped TypeSafe error
  remains in the underlying cause.

## Configure and discover models

```dart
final typeSafe = typeSafeAI(defaultModel: 'jev-latest');
final classifier = typeSafe.defineClassifier(
  name: 'priority',
  model: 'jev-latest',
  questions: {'urgent': Noul(instructions: 'Is this urgent?')},
);
final models = await typeSafe.listModels();
```

| Scope | Options |
| --- | --- |
| Plugin | `name`, `apiKey`, `baseUrl`, `defaultModel`, `logger`, `retry`, `timeout`, `defaultHeaders`, `httpClient`, `dangerouslyAllowBrowser` |
| Classifier | `model`, `timeout`, `retry`, `headers` |
| Router / Auto Mode | `classifierModel`, `timeout`, `retry`, `headers` |

`classifierModel` selects the TypeSafe model, not the downstream Genkit model.
`listModels()` discovers TypeSafe models; it does not register Genkit models.

## Handle errors and close clients

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

- Classifier and discovery failures throw `GenkitException`; inspect
  `underlyingException` for the original SDK error.
- Call `typeSafe.close()` and `await ai.shutdown()` when finished.
- The plugin closes its own HTTP client, not an injected `httpClient`.

## Browser use

```dart
final typeSafe = typeSafeAI(
  apiKey: 'client-visible-key',
  dangerouslyAllowBrowser: true,
);
```

**Exposes your API key to the client.** Avoid public or untrusted browser
deployments; prefer a server-side proxy.

## Run the examples

```sh
dart run example/genkit_typesafe_ai_example.dart
dart run example/model_router_example.dart
dart run example/auto_mode_example.dart
```

Requires `TYPESAFE_API_KEY`. Routing and Auto Mode use local demo generation
models, so no other provider key is needed. Auto Mode demonstrates a refused
deletion without touching real files.

## Development and release checks

```sh
dart pub get
dart format --output=none --set-exit-if-changed lib test example tool
dart analyze --fatal-infos
dart test --exclude-tags live
dart compile js tool/web_compile_check.dart -o "${TMPDIR:-/tmp}/genkit_typesafe_ai_web.js"
dart pub publish --dry-run
```

CI checks minimum and stable Dart. Run live tests separately:

```sh
dart test test/integration/live_test.dart
```

Live tests require `TYPESAFE_API_KEY` and may incur API charges. They cover
classification, routing, and allowed/blocked tools; rerun after SDK upgrades.

Preview pub.dev scoring:

```sh
dart pub global activate pana
dart pub global run pana .
```
