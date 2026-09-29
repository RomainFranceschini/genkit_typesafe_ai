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

## Model routing middleware

Define a named router from any registered Genkit model references, then pass the
router through `use`:

```dart
final typeSafe = typeSafeAI();
final router = typeSafe.defineModelRouter(
  name: 'cost-router',
  instructions: 'Choose the least costly capable model.',
  routes: {
    'fast': TypeSafeModelRoute(
      model: modelRef(
        'provider/fast',
        config: {'temperature': 0.1},
      ),
      criteria: 'Simple, well-scoped tasks.',
    ),
    'powerful': TypeSafeModelRoute(
      model: modelRef(
        'provider/powerful',
        config: {'temperature': 0.7},
      ),
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

The router classifies the latest user message once and keeps the selected model
and that model reference's config for every tool-loop turn. Low-confidence
answers still select their route; v1 does not apply a confidence threshold or
fallback. TypeSafe or routing failures produce Genkit failed responses and do
not call the original model or another fallback model.

The complete typed decision, including confidence and probabilities, is copied
into Genkit context for downstream middleware and tools. A tool can inspect it
without depending on the package's internal context key:

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

Router metadata and `TypeSafeRouteDecision.toJson()` include route and model
names, but never include model configs, credentials, or headers. Only one
distinct TypeSafe router may be used in a generation run; repeating the same
router reference is idempotent.

## Auto Mode tool-risk middleware

Choose the tools to guard when defining Auto Mode, then pass the named
middleware reference through `use`:

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

Only listed tools are checked; other tools run normally. A listed tool is matched
by its last path segment, the same way Genkit resolves tool requests, so
`delete`, `files/delete`, and any other `…/delete` request are all guarded by
either name. Before **each** guarded call, Auto Mode sends the proposed name,
arguments, available description, and up to 30 messages to TypeSafe: the most
recent ones, always including the first system message and the latest user
message. Only explicit user messages count as
authorization in its default risk instructions. A risk probability below `0.5`
allows the call. At or above `0.5`, it skips the tool and returns a tool result
explaining the refusal (with `typesafe.blocked` metadata), so the model can
continue. A TypeSafe failure fails the generation and does not execute the
guarded tool; Genkit reports tool-hook failures with an `INTERNAL` top-level
status and retains the mapped TypeSafe error as the underlying cause. Auto Mode
does not request human approval; use Genkit's `toolApproval` middleware for
interrupt-and-approve flows.

The classification input includes conversation contents and tool arguments:
they go to TypeSafe and can appear in Genkit classifier-action traces. Do not
include secrets in them unless that data transfer and trace visibility are
acceptable. Auto Mode guards tools in the Genkit generation loop, not direct
tool action invocations. It can be combined with the model router. Repeating an
Auto Mode reference evaluates a permitted call once per occurrence.

On Genkit 0.17, restarting a namespaced tool requires its **full registered
name** in both the saved tool-request message and the `interruptRestart` tool
request. A normal model call may store only its short wire name; callers must
normalize that saved history themselves before restarting. Auto Mode does not
rewrite it. Genkit 0.17 also drops tool-result metadata when rebuilding the
resumed conversation: the refusal text and call reference survive, but
`typesafe.blocked` does not. Inspect the classifier action trace for the
decision on restarted calls. Genkit may change this behavior in later versions.

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

This package does not provide a generative model, chat model, embeddings, or a
model-provider implementation. Model routing requires separately registered
Genkit models from the provider plugins selected by the application.
