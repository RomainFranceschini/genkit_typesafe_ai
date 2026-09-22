import 'dart:convert';

import 'package:genkit/genkit.dart';
import 'package:genkit_typesafe_ai/src/plugin.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'support/fake_typesafe_client.dart';

void main() {
  test('refuses a guarded call at probability 0.5 and continues', () async {
    final scenario = await _runScenario(
      probabilities: [0.5],
      guarded: ['delete'],
      calls: [
        ToolRequest(ref: 'call-1', name: 'delete', input: {'path': 'report'}),
      ],
    );

    expect(scenario.response.finishReason, FinishReason.stop);
    expect(scenario.response.text, 'done');
    expect(scenario.executed, isEmpty);
    final denial = scenario.results.single;
    expect(denial.toolResponse.name, 'delete');
    expect(denial.toolResponse.ref, 'call-1');
    expect(denial.toolResponse.output, contains('was blocked'));
    expect(denial.metadata?['typesafe'], {
      'blocked': true,
      'riskProbability': 0.5,
    });
    expect(scenario.requests, hasLength(1));
    final state =
        (jsonDecode(scenario.requests.single.body) as Map)['state'] as Map;
    final messages = state['messages'] as List;
    expect(messages.first['role'], 'user');
    expect(state['tool_call'], {
      'id': 'call-1',
      'name': 'delete',
      'args': {'path': 'report'},
    });
    expect(state['tool_description'], 'Deletes a report.');
    expect(
      scenario.streamed.where((chunk) => chunk.role == Role.tool),
      hasLength(1),
    );
  });

  test('runs a guarded call below probability 0.5', () async {
    final scenario = await _runScenario(
      probabilities: [0.49],
      guarded: ['delete'],
      calls: [
        ToolRequest(ref: 'call-1', name: 'delete', input: {'path': 'report'}),
      ],
    );

    expect(scenario.response.finishReason, FinishReason.stop);
    expect(scenario.executed, ['delete']);
    expect(scenario.results.single.toolResponse.output, 'delete complete');
    expect(scenario.requests, hasLength(1));
  });

  test('does not classify unlisted tools', () async {
    final scenario = await _runScenario(
      probabilities: [],
      guarded: ['delete'],
      calls: [
        ToolRequest(ref: 'call-1', name: 'read', input: {'path': 'report'}),
      ],
    );

    expect(scenario.response.finishReason, FinishReason.stop);
    expect(scenario.executed, ['read']);
    expect(scenario.requests, isEmpty);
  });

  test('retains both results when the second tool is blocked', () async {
    final scenario = await _runScenario(
      probabilities: [0.8],
      guarded: ['delete'],
      calls: [
        ToolRequest(ref: 'read-1', name: 'read', input: {'path': 'report'}),
        ToolRequest(ref: 'delete-2', name: 'delete', input: {'path': 'report'}),
      ],
    );

    expect(scenario.executed, ['read']);
    expect(scenario.results.map((part) => part.toolResponse.ref), [
      'read-1',
      'delete-2',
    ]);
    expect(scenario.results.last.metadata?['typesafe']['blocked'], isTrue);
    expect(scenario.response.finishReason, FinishReason.stop);
  });
}

typedef _ScenarioResult = ({
  GenerateResponseHelper response,
  List<http.Request> requests,
  List<ToolResponsePart> results,
  List<String> executed,
  List<ModelResponseChunk> streamed,
});

Future<_ScenarioResult> _runScenario({
  required List<double> probabilities,
  required List<String> guarded,
  required List<ToolRequest> calls,
}) async {
  final requests = <http.Request>[];
  final client = MockClient((request) async {
    requests.add(request);
    return autoModeResponse(probabilities[requests.length - 1]);
  });
  final plugin = TypeSafePlugin(apiKey: 'test-key', httpClient: client);
  final autoMode = plugin.defineAutoMode(name: 'guard', tools: guarded);
  final ai = Genkit(plugins: [plugin], isDevEnv: false);
  final executed = <String>[];
  final streamed = <ModelResponseChunk>[];
  final tools = <Tool>[];
  for (final name in {'delete', 'read'}) {
    tools.add(
      ai.defineTool<Map<String, dynamic>, String>(
        name: name,
        description: name == 'delete' ? 'Deletes a report.' : 'Reads a report.',
        fn: (input, ctx) async {
          executed.add(name);
          return .response('$name complete');
        },
      ),
    );
  }
  var modelCalls = 0;
  var results = <ToolResponsePart>[];
  ai.defineModel(
    name: 'test-model',
    fn: (request, ctx) async {
      modelCalls++;
      if (modelCalls == 1) {
        return ModelResponse(
          finishReason: FinishReason.stop,
          message: Message(
            role: Role.model,
            content: [
              for (final call in calls) ToolRequestPart(toolRequest: call),
            ],
          ),
        );
      }
      results = request.messages.last.content
          .map((part) => part.toolResponsePart)
          .nonNulls
          .toList();
      return ModelResponse(
        finishReason: FinishReason.stop,
        message: Message(
          role: Role.model,
          content: [TextPart(text: 'done')],
        ),
      );
    },
  );
  try {
    final response = await ai.generate(
      prompt: 'Handle the report.',
      model: modelRef('test-model'),
      tools: tools,
      use: [autoMode],
      onChunk: (chunk) => streamed.add(chunk.rawChunk),
    );
    return (
      response: response,
      requests: requests,
      results: results,
      executed: executed,
      streamed: streamed,
    );
  } finally {
    plugin.close();
    await ai.shutdown();
  }
}
