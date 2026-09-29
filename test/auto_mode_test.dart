import 'dart:convert';

import 'package:genkit/genkit.dart';
import 'package:genkit_typesafe_ai/src/model_router.dart';
import 'package:genkit_typesafe_ai/src/plugin.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

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

  test('fails closed when TypeSafe rejects authentication', () async {
    final scenario = await _runScenario(
      probabilities: [],
      guarded: ['delete'],
      calls: [ToolRequest(ref: 'call-1', name: 'delete', input: {})],
      answer: (_) => http.Response('', 401),
      retry: RetryPolicy(maxRetries: 0),
    );

    expect(scenario.response.finishReason, FinishReason.failed);
    expect(scenario.response.error?.status, StatusCodes.INTERNAL.name);
    final cause = scenario.response.cause as GenkitException;
    expect(
      cause.underlyingException,
      isA<GenkitException>().having(
        (error) => error.status,
        'status',
        StatusCodes.UNAUTHENTICATED,
      ),
    );
    expect(scenario.executed, isEmpty);
  });

  for (final score in [-0.1, 1.1]) {
    test('fails closed for out-of-range probability $score', () async {
      final scenario = await _runScenario(
        probabilities: [score],
        guarded: ['delete'],
        calls: [ToolRequest(ref: 'call-1', name: 'delete', input: {})],
      );

      expect(scenario.response.finishReason, FinishReason.failed);
      expect(scenario.executed, isEmpty);
    });
  }

  test('fails closed for a missing probability', () async {
    final scenario = await _runScenario(
      probabilities: [],
      guarded: ['delete'],
      calls: [ToolRequest(ref: 'call-1', name: 'delete', input: {})],
      answer: (_) => systemOneResponse(
        answers: {
          'isRisky': {'type': 'noul'},
        },
      ),
    );

    expect(scenario.response.finishReason, FinishReason.failed);
    expect(scenario.executed, isEmpty);
  });

  for (final token in ['NaN', 'Infinity']) {
    test('fails closed for malformed JSON probability $token', () async {
      final scenario = await _runScenario(
        probabilities: [],
        guarded: ['delete'],
        calls: [ToolRequest(ref: 'call-1', name: 'delete', input: {})],
        answer: (_) => http.Response(
          '{"model":"jev-latest","answers":{"isRisky":{"type":"noul","noul":$token}},"usage":{"input_tokens":4,"output_tokens":1}}',
          200,
          headers: {'content-type': 'application/json'},
        ),
      );

      expect(scenario.response.finishReason, FinishReason.failed);
      expect(scenario.executed, isEmpty);
    });
  }

  test('aborts before classification when cancelled during the turn', () async {
    final controller = CancellationController();
    final scenario = await _runScenario(
      probabilities: [],
      guarded: ['delete'],
      calls: [ToolRequest(ref: 'call-1', name: 'delete', input: {})],
      cancel: controller.token,
      onFirstModelCall: controller.cancel,
    );

    expect(scenario.response.finishReason, FinishReason.aborted);
    expect(scenario.requests, isEmpty);
    expect(scenario.executed, isEmpty);
  });

  for (final (:description, :guarded, :toolNames, :called) in [
    (
      description: 'a prefixed alias of a guarded tool',
      guarded: ['delete'],
      toolNames: ['delete', 'read'],
      called: 'x/delete',
    ),
    (
      description: 'a prefixed alias of a guarded namespaced tool',
      guarded: ['files/delete'],
      toolNames: ['files/delete'],
      called: 'x/delete',
    ),
    (
      description: 'a short-name guard called by the full name',
      guarded: ['delete'],
      toolNames: ['files/delete'],
      called: 'files/delete',
    ),
  ]) {
    test('guards $description', () async {
      final scenario = await _runScenario(
        probabilities: [0.8],
        guarded: guarded,
        toolNames: toolNames,
        calls: [ToolRequest(ref: 'call-1', name: called, input: {})],
      );

      expect(scenario.requests, hasLength(1));
      expect(scenario.executed, isEmpty);
      expect(scenario.response.finishReason, FinishReason.stop);
    });
  }

  test('guards a full-name restart with a short-name guard', () async {
    final requests = <http.Request>[];
    final plugin = TypeSafePlugin(
      apiKey: 'test-key',
      httpClient: MockClient((request) async {
        requests.add(request);
        return autoModeResponse(0.8);
      }),
    );
    final guard = plugin.defineAutoMode(name: 'guard', tools: ['delete']);
    final ai = Genkit(plugins: [plugin], isDevEnv: false);
    var executions = 0;
    final tool = ai.defineTool<Map<String, dynamic>, String>(
      name: 'files/delete',
      description: 'Deletes the report.',
      fn: (input, ctx) async {
        executions++;
        return .response('deleted');
      },
    );
    ai.defineModel(
      name: 'test-model',
      fn: (request, ctx) async => ModelResponse(
        finishReason: FinishReason.stop,
        message: Message(
          role: Role.model,
          content: [TextPart(text: 'done')],
        ),
      ),
    );
    final call = ToolRequestPart(
      toolRequest: ToolRequest(
        ref: 'call-1',
        name: 'files/delete',
        input: {'path': 'report'},
      ),
    );

    try {
      final response = await ai.generate(
        messages: [
          Message(
            role: Role.user,
            content: [TextPart(text: 'Handle report')],
          ),
          Message(role: Role.model, content: [call]),
        ],
        model: modelRef('test-model'),
        tools: [tool],
        interruptRestart: [call],
        use: [guard],
      );
      expect(response.finishReason, FinishReason.stop);
      expect(requests, hasLength(1));
      expect(executions, 0);
    } finally {
      plugin.close();
      await ai.shutdown();
    }
  });

  test('sends resumed tool responses to TypeSafe', () async {
    final requests = <http.Request>[];
    final plugin = TypeSafePlugin(
      apiKey: 'test-key',
      httpClient: MockClient((request) async {
        requests.add(request);
        return autoModeResponse(0.8);
      }),
    );
    final guard = plugin.defineAutoMode(name: 'guard', tools: ['delete']);
    final ai = Genkit(plugins: [plugin], isDevEnv: false);
    final delete = ai.defineTool<Map<String, dynamic>, String>(
      name: 'delete',
      description: 'Deletes the report.',
      fn: (input, ctx) async => .response('deleted'),
    );
    final confirm = ai.defineTool<Map<String, dynamic>, String>(
      name: 'confirm',
      description: 'Asks the user for confirmation.',
      fn: (input, ctx) async => .response('unused'),
    );
    var modelCalls = 0;
    ai.defineModel(
      name: 'test-model',
      fn: (request, ctx) async {
        modelCalls++;
        return ModelResponse(
          finishReason: FinishReason.stop,
          message: Message(
            role: Role.model,
            content: modelCalls == 1
                ? [
                    ToolRequestPart(
                      toolRequest: ToolRequest(
                        ref: 'delete-1',
                        name: 'delete',
                        input: <String, dynamic>{},
                      ),
                    ),
                  ]
                : [TextPart(text: 'done')],
          ),
        );
      },
    );
    final ask = ToolRequestPart(
      toolRequest: ToolRequest(
        ref: 'ask-1',
        name: 'confirm',
        input: <String, dynamic>{},
      ),
    );

    try {
      final response = await ai.generate(
        messages: [
          Message(
            role: Role.user,
            content: [TextPart(text: 'Delete the report once I confirm.')],
          ),
          Message(role: Role.model, content: [ask]),
        ],
        model: modelRef('test-model'),
        tools: [delete, confirm],
        interruptRespond: [InterruptResponse(ask, 'yes, delete it')],
        use: [guard],
      );
      expect(response.finishReason, FinishReason.stop);
      final state = (jsonDecode(requests.single.body) as Map)['state'] as Map;
      final messages = state['messages'] as List;
      expect(messages.map((message) => message['role']), [
        'user',
        'model',
        'tool',
        'model',
      ]);
      expect(messages[2].toString(), contains('yes, delete it'));
    } finally {
      plugin.close();
      await ai.shutdown();
    }
  });

  test('guards a namespaced tool called by its short wire name', () async {
    final scenario = await _runScenario(
      probabilities: [0.7],
      guarded: ['files/delete'],
      toolNames: ['files/delete'],
      calls: [ToolRequest(ref: 'call-1', name: 'delete', input: {})],
    );

    expect(scenario.requests, hasLength(1));
    expect(scenario.executed, isEmpty);
    expect(scenario.results.single.toolResponse.name, 'delete');
    expect(scenario.response.finishReason, FinishReason.stop);
  });

  test('conservatively checks a tool sharing a guarded short name', () async {
    final scenario = await _runScenario(
      probabilities: [0.8],
      guarded: ['files/delete'],
      toolNames: ['other/delete'],
      calls: [ToolRequest(ref: 'call-1', name: 'delete', input: {})],
    );

    expect(scenario.requests, hasLength(1));
    expect(scenario.executed, isEmpty);
  });

  test(
    'guards restarted namespaced tools by full name without a model hook',
    () async {
      final requests = <http.Request>[];
      final plugin = TypeSafePlugin(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          requests.add(request);
          return autoModeResponse(0.8);
        }),
      );
      final guard = plugin.defineAutoMode(
        name: 'guard',
        tools: ['files/delete'],
      );
      final ai = Genkit(plugins: [plugin], isDevEnv: false);
      var executions = 0;
      var modelCalls = 0;
      ToolResponsePart? resumedToolResponse;
      final tool = ai.defineTool<Map<String, dynamic>, String>(
        name: 'files/delete',
        description: 'Deletes the report.',
        fn: (input, ctx) async {
          executions++;
          return .response('deleted');
        },
      );
      ai.defineModel(
        name: 'test-model',
        fn: (request, ctx) async {
          modelCalls++;
          resumedToolResponse =
              request.messages.last.content.single.toolResponsePart;
          return ModelResponse(
            finishReason: FinishReason.stop,
            message: Message(
              role: Role.model,
              content: [TextPart(text: 'done')],
            ),
          );
        },
      );
      final history = [
        Message(
          role: Role.user,
          content: [TextPart(text: 'Handle report')],
        ),
        Message(
          role: Role.model,
          content: [
            ToolRequestPart(
              toolRequest: ToolRequest(
                ref: 'call-1',
                name: 'files/delete',
                input: {'path': 'report'},
              ),
            ),
          ],
        ),
      ];

      try {
        final response = await ai.generate(
          messages: history,
          model: modelRef('test-model'),
          tools: [tool],
          interruptRestart: [
            ToolRequestPart(
              toolRequest: ToolRequest(
                ref: 'call-1',
                name: 'files/delete',
                input: {'path': 'report'},
              ),
            ),
          ],
          use: [guard],
        );
        expect(
          response.finishReason,
          FinishReason.stop,
          reason: 'error=${response.error} cause=${response.cause}',
        );
        expect(modelCalls, 1);
        expect(executions, 0);
        expect(requests, hasLength(1));
        expect(resumedToolResponse?.toolResponse.ref, 'call-1');
        expect(
          resumedToolResponse?.toolResponse.output,
          contains('was blocked'),
        );
        // Genkit 0.17 reconstructs restarted tool results without metadata.
        expect(resumedToolResponse?.metadata, isNull);
        final state = (jsonDecode(requests.single.body) as Map)['state'] as Map;
        expect(state['tool_description'], 'Deletes the report.');
        expect((state['messages'] as List).first['role'], 'user');

        final shortHistory = [
          history.first,
          Message(
            role: Role.model,
            content: [
              ToolRequestPart(
                toolRequest: ToolRequest(
                  ref: 'call-1',
                  name: 'delete',
                  input: {'path': 'report'},
                ),
              ),
            ],
          ),
        ];
        final mismatchedHistory = await ai.generate(
          messages: shortHistory,
          model: modelRef('test-model'),
          tools: [tool],
          interruptRestart: [
            ToolRequestPart(
              toolRequest: ToolRequest(
                ref: 'call-1',
                name: 'files/delete',
                input: {'path': 'report'},
              ),
            ),
          ],
          use: [guard],
        );
        expect(mismatchedHistory.finishReason, FinishReason.failed);
        expect(
          mismatchedHistory.error?.status,
          StatusCodes.INVALID_ARGUMENT.name,
        );
        expect(executions, 0);

        requests.clear();
        final shortRestart = await ai.generate(
          messages: history,
          model: modelRef('test-model'),
          tools: [tool],
          interruptRestart: [
            ToolRequestPart(
              toolRequest: ToolRequest(
                ref: 'call-1',
                name: 'delete',
                input: {'path': 'report'},
              ),
            ),
          ],
          use: [guard],
        );
        expect(shortRestart.finishReason, FinishReason.failed);
        expect(shortRestart.error?.status, StatusCodes.NOT_FOUND.name);
        expect(requests, isEmpty);
        expect(executions, 0);
      } finally {
        plugin.close();
        await ai.shutdown();
      }
    },
  );

  test('repeating a guard evaluates a permitted call twice', () async {
    var classifications = 0;
    final plugin = TypeSafePlugin(
      apiKey: 'test-key',
      httpClient: MockClient((request) async {
        classifications++;
        return autoModeResponse(0.1);
      }),
    );
    final guard = plugin.defineAutoMode(name: 'guard', tools: ['delete']);
    final ai = Genkit(plugins: [plugin], isDevEnv: false);
    var executions = 0;
    final tool = ai.defineTool<Map<String, dynamic>, String>(
      name: 'delete',
      description: 'Deletes report.',
      fn: (input, ctx) async {
        executions++;
        return .response('deleted');
      },
    );
    var modelCalls = 0;
    ai.defineModel(
      name: 'model',
      fn: (request, ctx) async {
        modelCalls++;
        return ModelResponse(
          finishReason: FinishReason.stop,
          message: Message(
            role: Role.model,
            content: modelCalls == 1
                ? [
                    ToolRequestPart(
                      toolRequest: ToolRequest(
                        name: 'delete',
                        input: <String, dynamic>{},
                      ),
                    ),
                  ]
                : [TextPart(text: 'done')],
          ),
        );
      },
    );
    try {
      final response = await ai.generate(
        prompt: 'Delete report',
        model: modelRef('model'),
        tools: [tool],
        use: [guard, guard],
      );
      expect(
        response.finishReason,
        FinishReason.stop,
        reason: 'error=${response.error} cause=${response.cause}',
      );
      expect(classifications, 2);
      expect(executions, 1);
    } finally {
      plugin.close();
      await ai.shutdown();
    }
  });

  test('runs Auto Mode with the model router', () async {
    final requests = <http.Request>[];
    final plugin = TypeSafePlugin(
      apiKey: 'test-key',
      httpClient: MockClient((request) async {
        requests.add(request);
        final questions = (jsonDecode(request.body) as Map)['questions'] as Map;
        return questions.containsKey('modelRoute')
            ? modelRouteResponse('fast')
            : autoModeResponse(0.8);
      }),
    );
    final router = plugin.defineModelRouter(
      name: 'router',
      instructions: 'Route.',
      routes: {
        'fast': TypeSafeModelRoute(model: modelRef('fast'), criteria: 'Fast.'),
      },
    );
    final guard = plugin.defineAutoMode(name: 'guard', tools: ['delete']);
    final ai = Genkit(plugins: [plugin], isDevEnv: false);
    var executions = 0;
    final tool = ai.defineTool<Map<String, dynamic>, String>(
      name: 'delete',
      description: 'Deletes report.',
      fn: (input, ctx) async {
        executions++;
        return .response('deleted');
      },
    );
    var modelCalls = 0;
    ai.defineModel(
      name: 'fast',
      fn: (request, ctx) async {
        modelCalls++;
        return ModelResponse(
          finishReason: FinishReason.stop,
          message: Message(
            role: Role.model,
            content: modelCalls == 1
                ? [
                    ToolRequestPart(
                      toolRequest: ToolRequest(
                        name: 'delete',
                        input: <String, dynamic>{},
                      ),
                    ),
                  ]
                : [TextPart(text: 'done')],
          ),
        );
      },
    );
    try {
      final response = await ai.generate(
        prompt: 'Delete report',
        tools: [tool],
        use: [router, guard],
      );
      expect(response.finishReason, FinishReason.stop);
      expect(executions, 0);
      expect(requests, hasLength(2));
    } finally {
      plugin.close();
      await ai.shutdown();
    }
  });

  test(
    'isolates simultaneous generations using one guard definition',
    () async {
      final prompts = <String>[];
      final plugin = TypeSafePlugin(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          final state = (jsonDecode(request.body) as Map)['state'] as Map;
          prompts.add(
            ((state['messages'] as List).first['content'] as List).first['text']
                as String,
          );
          return autoModeResponse(0.1);
        }),
      );
      final guard = plugin.defineAutoMode(name: 'guard', tools: ['audit']);
      final ai = Genkit(plugins: [plugin], isDevEnv: false);
      final tool = ai.defineTool<Map<String, dynamic>, String>(
        name: 'audit',
        description: 'Audits a request.',
        fn: (input, ctx) async => .response('audited'),
      );
      ai.defineModel(
        name: 'model',
        fn: (request, ctx) async {
          final isFirstTurn = request.messages.last.role == Role.user;
          return ModelResponse(
            finishReason: FinishReason.stop,
            message: Message(
              role: Role.model,
              content: isFirstTurn
                  ? [
                      ToolRequestPart(
                        toolRequest: ToolRequest(
                          name: 'audit',
                          input: <String, dynamic>{},
                        ),
                      ),
                    ]
                  : [TextPart(text: 'done')],
            ),
          );
        },
      );
      try {
        final responses = await Future.wait([
          ai.generate(
            prompt: 'first request',
            model: modelRef('model'),
            tools: [tool],
            use: [guard],
          ),
          ai.generate(
            prompt: 'second request',
            model: modelRef('model'),
            tools: [tool],
            use: [guard],
          ),
        ]);
        expect(
          responses.map((response) => response.finishReason),
          everyElement(FinishReason.stop),
        );
        expect(prompts, unorderedEquals(['first request', 'second request']));
      } finally {
        plugin.close();
        await ai.shutdown();
      }
    },
  );

  test('does not inherit parent history in a nested generation', () async {
    final states = <Map>[];
    final plugin = TypeSafePlugin(
      apiKey: 'test-key',
      httpClient: MockClient((request) async {
        states.add((jsonDecode(request.body) as Map)['state'] as Map);
        return autoModeResponse(0.1);
      }),
    );
    final guard = plugin.defineAutoMode(
      name: 'guard',
      tools: ['delete', 'audit'],
    );
    final ai = Genkit(plugins: [plugin], isDevEnv: false);
    final audit = ai.defineTool<Map<String, dynamic>, String>(
      name: 'audit',
      description: 'Audits a request.',
      fn: (input, ctx) async => .response('audited'),
    );
    late final Tool delete;
    delete = ai.defineTool<Map<String, dynamic>, String>(
      name: 'delete',
      description: 'Deletes a report.',
      fn: (input, ctx) async {
        final nested = await ai.generate(
          prompt: 'inner request',
          model: modelRef('model'),
          tools: [audit],
          use: [guard],
        );
        expect(nested.finishReason, FinishReason.stop);
        return .response('outer completed');
      },
    );
    ai.defineModel(
      name: 'model',
      fn: (request, ctx) async {
        final isFirstTurn = request.messages.last.role == Role.user;
        final prompt = request.messages.first.text;
        return ModelResponse(
          finishReason: FinishReason.stop,
          message: Message(
            role: Role.model,
            content: isFirstTurn
                ? [
                    ToolRequestPart(
                      toolRequest: ToolRequest(
                        name: prompt.contains('inner') ? 'audit' : 'delete',
                        input: <String, dynamic>{},
                      ),
                    ),
                  ]
                : [TextPart(text: 'done')],
          ),
        );
      },
    );
    try {
      final response = await ai.generate(
        prompt: 'outer request',
        model: modelRef('model'),
        tools: [delete],
        use: [guard],
      );
      expect(response.finishReason, FinishReason.stop);
      expect(states, hasLength(2));
      final firstMessages = states[0]['messages'] as List;
      final secondMessages = states[1]['messages'] as List;
      expect(firstMessages.first.toString(), contains('outer request'));
      expect(secondMessages.first.toString(), contains('inner request'));
      expect(secondMessages.toString(), isNot(contains('outer request')));
    } finally {
      plugin.close();
      await ai.shutdown();
    }
  });

  test('sends only the 30 most recent messages to TypeSafe', () async {
    final requests = <http.Request>[];
    final plugin = TypeSafePlugin(
      apiKey: 'test-key',
      httpClient: MockClient((request) async {
        requests.add(request);
        return autoModeResponse(0.8);
      }),
    );
    final guard = plugin.defineAutoMode(name: 'guard', tools: ['delete']);
    final ai = Genkit(plugins: [plugin], isDevEnv: false);
    final tool = ai.defineTool<Map<String, dynamic>, String>(
      name: 'delete',
      description: 'Deletes a report.',
      fn: (input, ctx) async => .response('deleted'),
    );
    ai.defineModel(
      name: 'model',
      fn: (request, ctx) async {
        return ModelResponse(
          finishReason: FinishReason.stop,
          message: Message(
            role: Role.model,
            content: request.messages.last.role == Role.tool
                ? [TextPart(text: 'done')]
                : [
                    ToolRequestPart(
                      toolRequest: ToolRequest(
                        name: 'delete',
                        input: <String, dynamic>{},
                      ),
                    ),
                  ],
          ),
        );
      },
    );
    try {
      final response = await ai.generate(
        messages: [
          for (var i = 1; i <= 31; i++)
            Message(
              role: Role.user,
              content: [TextPart(text: 'message $i')],
            ),
        ],
        model: modelRef('model'),
        tools: [tool],
        use: [guard],
      );
      expect(response.finishReason, FinishReason.stop);
      final state = (jsonDecode(requests.single.body) as Map)['state'] as Map;
      final messages = state['messages'] as List;
      expect(messages, hasLength(30));
      expect(messages.first.toString(), contains('message 3'));
      expect(messages.last['role'], 'model');
    } finally {
      plugin.close();
      await ai.shutdown();
    }
  });

  test(
    'keeps the system prompt and latest user message when truncating',
    () async {
      final requests = <http.Request>[];
      final plugin = TypeSafePlugin(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          requests.add(request);
          return autoModeResponse(0.8);
        }),
      );
      final guard = plugin.defineAutoMode(name: 'guard', tools: ['delete']);
      final ai = Genkit(plugins: [plugin], isDevEnv: false);
      final tool = ai.defineTool<Map<String, dynamic>, String>(
        name: 'delete',
        description: 'Deletes a report.',
        fn: (input, ctx) async => .response('deleted'),
      );
      ai.defineModel(
        name: 'model',
        fn: (request, ctx) async {
          return ModelResponse(
            finishReason: FinishReason.stop,
            message: Message(
              role: Role.model,
              content: request.messages.last.role == Role.tool
                  ? [TextPart(text: 'done')]
                  : [
                      ToolRequestPart(
                        toolRequest: ToolRequest(
                          name: 'delete',
                          input: <String, dynamic>{},
                        ),
                      ),
                    ],
            ),
          );
        },
      );
      try {
        final response = await ai.generate(
          messages: [
            Message(
              role: Role.system,
              content: [TextPart(text: 'system policy')],
            ),
            Message(
              role: Role.user,
              content: [TextPart(text: 'user instruction')],
            ),
            for (var i = 1; i <= 40; i++)
              Message(
                role: Role.model,
                content: [TextPart(text: 'progress $i')],
              ),
          ],
          model: modelRef('model'),
          tools: [tool],
          use: [guard],
        );
        expect(response.finishReason, FinishReason.stop);
        final state = (jsonDecode(requests.single.body) as Map)['state'] as Map;
        final messages = state['messages'] as List;
        expect(messages, hasLength(30));
        expect(messages[0]['role'], 'system');
        expect(messages[0].toString(), contains('system policy'));
        expect(messages[1]['role'], 'user');
        expect(messages[1].toString(), contains('user instruction'));
        expect(messages[2].toString(), contains('progress 14'));
        expect(messages.last['role'], 'model');
      } finally {
        plugin.close();
        await ai.shutdown();
      }
    },
  );
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
  List<String> toolNames = const ['delete', 'read'],
  http.Response Function(int call)? answer,
  RetryPolicy? retry,
  CancellationToken? cancel,
  void Function()? onFirstModelCall,
}) async {
  final requests = <http.Request>[];
  final client = MockClient((request) async {
    requests.add(request);
    return answer?.call(requests.length) ??
        autoModeResponse(probabilities[requests.length - 1]);
  });
  final plugin = TypeSafePlugin(
    apiKey: 'test-key',
    httpClient: client,
    retry: retry,
  );
  final autoMode = plugin.defineAutoMode(name: 'guard', tools: guarded);
  final ai = Genkit(plugins: [plugin], isDevEnv: false);
  final executed = <String>[];
  final streamed = <ModelResponseChunk>[];
  final tools = <Tool>[];
  for (final name in toolNames) {
    tools.add(
      ai.defineTool<Map<String, dynamic>, String>(
        name: name,
        description: name.endsWith('delete')
            ? 'Deletes a report.'
            : 'Reads a report.',
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
        onFirstModelCall?.call();
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
      cancel: cancel,
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
