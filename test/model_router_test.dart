import 'dart:convert';

import 'package:genkit/genkit.dart';
import 'package:genkit/plugin.dart' as genkit_plugin;
import 'package:genkit_typesafe_ai/src/model_router.dart';
import 'package:genkit_typesafe_ai/src/plugin.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

import 'support/fake_typesafe_client.dart';

void main() {
  test('routes latest user state and replaces model plus config', () async {
    final typeSafeRequests = <http.Request>[];
    final client = MockClient((request) async {
      typeSafeRequests.add(request);
      return modelRouteResponse(
        'fast',
        probabilities: {'fast': 0.8, 'powerful': 0.2},
      );
    });
    final plugin = TypeSafePlugin(apiKey: 'test-key', httpClient: client);
    final callerContext = <String, dynamic>{
      'genkit_typesafe_ai/model-router-decisions': 'caller-owned',
    };
    final router = plugin.defineModelRouter(
      name: 'cost-router',
      instructions: 'Choose a route.',
      routes: {
        'fast': TypeSafeModelRoute(
          model: modelRef('fast-model', config: {'temperature': 0.1}),
          criteria: {'kind': 'simple'},
        ),
        'powerful': TypeSafeModelRoute(
          model: modelRef('powerful-model', config: {'temperature': 0.9}),
          criteria: {'kind': 'complex'},
        ),
      },
    );
    final ai = Genkit(plugins: [plugin], isDevEnv: false);
    Map<String, dynamic>? modelContext;
    Map<String, dynamic>? modelConfig;
    ai.defineModel(
      name: 'fast-model',
      fn: (request, ctx) async {
        modelContext = ctx.context;
        modelConfig = request.config;
        return ModelResponse(
          finishReason: FinishReason.stop,
          message: Message(
            role: Role.model,
            content: [TextPart(text: 'fast')],
          ),
        );
      },
    );
    ai.defineModel(
      name: 'powerful-model',
      fn: (request, ctx) => throw StateError('wrong model'),
    );
    final messages = [
      Message(
        role: Role.user,
        content: [TextPart(text: 'earlier')],
      ),
      Message(
        role: Role.model,
        content: [TextPart(text: 'reply')],
      ),
      Message(
        role: Role.user,
        content: [
          TextPart(text: 'latest'),
          DataPart(data: {'priority': 2}),
        ],
      ),
    ];

    try {
      final response = await ai.generate(
        messages: messages,
        model: modelRef('powerful-model', config: {'wrong': true}),
        context: callerContext,
        use: [router],
      );

      expect(response.text, 'fast');
      expect(modelConfig, {'temperature': 0.1});
      final decision = router.decisionFromContext(modelContext);
      expect(decision?.route, 'fast');
      expect(decision?.modelName, 'fast-model');
      expect(decision?.probabilities, {'fast': 0.8, 'powerful': 0.2});
      expect(decision?.toJson(), {
        'router': 'typesafe/cost-router',
        'route': 'fast',
        'model': 'fast-model',
        'confidence': 0.9,
        'probabilities': {'fast': 0.8, 'powerful': 0.2},
      });
      expect(
        callerContext['genkit_typesafe_ai/model-router-decisions'],
        'caller-owned',
      );
      final body = jsonDecode(typeSafeRequests.single.body) as Map;
      expect(body['state'], messages.last.toJson());
    } finally {
      plugin.close();
      await ai.shutdown();
    }
  });

  test('routes the selected model even at low confidence', () async {
    final plugin = TypeSafePlugin(
      apiKey: 'test-key',
      httpClient: MockClient(
        (request) async => modelRouteResponse('fast', confidence: 0.01),
      ),
    );
    final router = plugin.defineModelRouter(
      name: 'cost-router',
      instructions: 'Choose.',
      routes: {
        'fast': TypeSafeModelRoute(
          model: modelRef('fast-model'),
          criteria: 'Simple.',
        ),
      },
    );
    final ai = Genkit(plugins: [plugin], isDevEnv: false);
    ai.defineModel(
      name: 'fast-model',
      fn: (request, ctx) async => _textResponse('fast'),
    );

    try {
      final response = await ai.generate(prompt: 'simple', use: [router]);

      expect(response.text, 'fast');
    } finally {
      plugin.close();
      await ai.shutdown();
    }
  });

  test(
    'fails when there is no user message before any external work',
    () async {
      var typeSafeRequestCount = 0;
      var generativeModelCallCount = 0;
      final plugin = TypeSafePlugin(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          typeSafeRequestCount++;
          return modelRouteResponse('fast');
        }),
      );
      final router = plugin.defineModelRouter(
        name: 'cost-router',
        instructions: 'Choose.',
        routes: {
          'fast': TypeSafeModelRoute(
            model: modelRef('fast-model'),
            criteria: 'Simple.',
          ),
        },
      );
      final ai = Genkit(plugins: [plugin], isDevEnv: false);
      ai.defineModel(
        name: 'fast-model',
        fn: (request, ctx) async {
          generativeModelCallCount++;
          return _textResponse('fast');
        },
      );

      try {
        final response = await ai.generate(
          messages: [
            Message(
              role: Role.system,
              content: [TextPart(text: 'system only')],
            ),
          ],
          model: modelRef('fast-model'),
          use: [router],
        );

        expect(response.finishReason, FinishReason.failed);
        expect(response.error?.status, StatusCodes.INVALID_ARGUMENT.name);
        expect(typeSafeRequestCount, 0);
        expect(generativeModelCallCount, 0);
      } finally {
        plugin.close();
        await ai.shutdown();
      }
    },
  );

  test('returns authentication failures without calling a model', () async {
    var generativeModelCallCount = 0;
    final plugin = TypeSafePlugin(
      apiKey: 'test-key',
      retry: RetryPolicy(maxRetries: 0),
      httpClient: MockClient((request) async => http.Response('', 401)),
    );
    final router = plugin.defineModelRouter(
      name: 'cost-router',
      instructions: 'Choose.',
      routes: {
        'fast': TypeSafeModelRoute(
          model: modelRef('fast-model'),
          criteria: 'Simple.',
        ),
      },
    );
    final ai = Genkit(plugins: [plugin], isDevEnv: false);
    ai.defineModel(
      name: 'fast-model',
      fn: (request, ctx) async {
        generativeModelCallCount++;
        return _textResponse('fast');
      },
    );

    try {
      final response = await ai.generate(prompt: 'simple', use: [router]);

      expect(response.finishReason, FinishReason.failed);
      expect(response.error?.status, StatusCodes.UNAUTHENTICATED.name);
      expect(response.cause, isA<GenkitException>());
      expect(generativeModelCallCount, 0);
    } finally {
      plugin.close();
      await ai.shutdown();
    }
  });

  test('fails an unknown selected route without calling a model', () async {
    var generativeModelCallCount = 0;
    final plugin = TypeSafePlugin(
      apiKey: 'test-key',
      httpClient: MockClient((request) async => modelRouteResponse('unknown')),
    );
    final router = plugin.defineModelRouter(
      name: 'cost-router',
      instructions: 'Choose.',
      routes: {
        'fast': TypeSafeModelRoute(
          model: modelRef('fast-model'),
          criteria: 'Simple.',
        ),
      },
    );
    final ai = Genkit(plugins: [plugin], isDevEnv: false);
    ai.defineModel(
      name: 'fast-model',
      fn: (request, ctx) async {
        generativeModelCallCount++;
        return _textResponse('fast');
      },
    );

    try {
      final response = await ai.generate(prompt: 'simple', use: [router]);

      expect(response.finishReason, FinishReason.failed);
      expect(response.error?.status, StatusCodes.INTERNAL.name);
      expect(generativeModelCallCount, 0);
    } finally {
      plugin.close();
      await ai.shutdown();
    }
  });

  test(
    'uses the native not-found response for an unregistered selected model',
    () async {
      final plugin = TypeSafePlugin(
        apiKey: 'test-key',
        httpClient: MockClient((request) async => modelRouteResponse('fast')),
      );
      final router = plugin.defineModelRouter(
        name: 'cost-router',
        instructions: 'Choose.',
        routes: {
          'fast': TypeSafeModelRoute(
            model: modelRef('missing-model'),
            criteria: 'Simple.',
          ),
        },
      );
      final ai = Genkit(plugins: [plugin], isDevEnv: false);

      try {
        final response = await ai.generate(prompt: 'simple', use: [router]);

        expect(response.finishReason, FinishReason.failed);
        expect(response.error?.status, StatusCodes.NOT_FOUND.name);
      } finally {
        plugin.close();
        await ai.shutdown();
      }
    },
  );

  test('honors cancellation before TypeSafe or model work', () async {
    var typeSafeRequestCount = 0;
    var generativeModelCallCount = 0;
    final controller = CancellationController()..cancel();
    final plugin = TypeSafePlugin(
      apiKey: 'test-key',
      httpClient: MockClient((request) async {
        typeSafeRequestCount++;
        return modelRouteResponse('fast');
      }),
    );
    final router = plugin.defineModelRouter(
      name: 'cost-router',
      instructions: 'Choose.',
      routes: {
        'fast': TypeSafeModelRoute(
          model: modelRef('fast-model'),
          criteria: 'Simple.',
        ),
      },
    );
    final ai = Genkit(plugins: [plugin], isDevEnv: false);
    ai.defineModel(
      name: 'fast-model',
      fn: (request, ctx) async {
        generativeModelCallCount++;
        return _textResponse('fast');
      },
    );

    try {
      final response = await ai.generate(
        prompt: 'simple',
        use: [router],
        cancel: controller.token,
      );

      expect(response.finishReason, FinishReason.aborted);
      expect(typeSafeRequestCount, 0);
      expect(generativeModelCallCount, 0);
    } finally {
      plugin.close();
      await ai.shutdown();
    }
  });

  test('classifies once across tool-loop turns', () async {
    var typeSafeCalls = 0;
    var modelCalls = 0;
    TypeSafeRouteDecision? toolDecision;
    final plugin = TypeSafePlugin(
      apiKey: 'test-key',
      httpClient: MockClient((request) async {
        typeSafeCalls++;
        return modelRouteResponse('fast');
      }),
    );
    final router = plugin.defineModelRouter(
      name: 'cost-router',
      instructions: 'Choose.',
      routes: {
        'fast': TypeSafeModelRoute(
          model: modelRef('fast-model'),
          criteria: 'Simple.',
        ),
      },
    );
    final ai = Genkit(plugins: [plugin], isDevEnv: false);
    final echoTool = ai.defineTool<Map<String, dynamic>, String>(
      name: 'echo',
      description: 'Echo input.',
      fn: (input, args) async {
        toolDecision = router.decisionFromContext(args.context);
        return ToolResult.response(input['value'] as String);
      },
    );
    ai.defineModel(
      name: 'fast-model',
      fn: (request, ctx) async {
        modelCalls++;
        if (modelCalls == 1) {
          return ModelResponse(
            finishReason: FinishReason.stop,
            message: Message(
              role: Role.model,
              content: [
                ToolRequestPart(
                  toolRequest: ToolRequest(
                    ref: 'call-1',
                    name: 'echo',
                    input: {'value': 'ok'},
                  ),
                ),
              ],
            ),
          );
        }
        return _textResponse('done');
      },
    );

    try {
      final response = await ai.generate(
        prompt: 'run the tool',
        model: modelRef('original-model'),
        tools: [echoTool],
        use: [router],
      );

      expect(response.text, 'done');
      expect(typeSafeCalls, 1);
      expect(modelCalls, 2);
      expect(toolDecision?.route, 'fast');
    } finally {
      plugin.close();
      await ai.shutdown();
    }
  });

  test('repeating the same router reference is idempotent', () async {
    var typeSafeCalls = 0;
    var modelCalls = 0;
    final plugin = TypeSafePlugin(
      apiKey: 'test-key',
      httpClient: MockClient((request) async {
        typeSafeCalls++;
        return modelRouteResponse('fast');
      }),
    );
    final router = plugin.defineModelRouter(
      name: 'cost-router',
      instructions: 'Choose.',
      routes: {
        'fast': TypeSafeModelRoute(
          model: modelRef('fast-model'),
          criteria: 'Simple.',
        ),
      },
    );
    final ai = Genkit(plugins: [plugin], isDevEnv: false);
    ai.defineModel(
      name: 'fast-model',
      fn: (request, ctx) async {
        modelCalls++;
        return _textResponse('fast');
      },
    );

    try {
      final response = await ai.generate(
        prompt: 'simple',
        use: [router, router],
      );

      expect(response.finishReason, FinishReason.stop);
      expect(typeSafeCalls, 1);
      expect(modelCalls, 1);
    } finally {
      plugin.close();
      await ai.shutdown();
    }
  });

  test(
    'rejects distinct routers before the second classification or model',
    () async {
      var typeSafeCalls = 0;
      var modelCalls = 0;
      final plugin = TypeSafePlugin(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          typeSafeCalls++;
          return modelRouteResponse('fast');
        }),
      );
      final firstRouter = plugin.defineModelRouter(
        name: 'first-router',
        instructions: 'Choose.',
        routes: {
          'fast': TypeSafeModelRoute(
            model: modelRef('fast-model'),
            criteria: 'Simple.',
          ),
        },
      );
      final secondRouter = plugin.defineModelRouter(
        name: 'second-router',
        instructions: 'Choose.',
        routes: {
          'fast': TypeSafeModelRoute(
            model: modelRef('fast-model'),
            criteria: 'Simple.',
          ),
        },
      );
      final ai = Genkit(plugins: [plugin], isDevEnv: false);
      ai.defineModel(
        name: 'fast-model',
        fn: (request, ctx) async {
          modelCalls++;
          return _textResponse('fast');
        },
      );

      try {
        final response = await ai.generate(
          prompt: 'simple',
          use: [firstRouter, secondRouter],
        );

        expect(response.finishReason, FinishReason.failed);
        expect(response.error?.status, StatusCodes.FAILED_PRECONDITION.name);
        expect(typeSafeCalls, 1);
        expect(modelCalls, 0);
      } finally {
        plugin.close();
        await ai.shutdown();
      }
    },
  );

  test('isolates route decisions across concurrent generation runs', () async {
    var typeSafeCalls = 0;
    var fastModelCalls = 0;
    var powerfulModelCalls = 0;
    final modelDecisions = <String, TypeSafeRouteDecision?>{};
    final plugin = TypeSafePlugin(
      apiKey: 'test-key',
      httpClient: MockClient((request) async {
        typeSafeCalls++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final state = body['state'] as Map<String, dynamic>;
        final content = state['content'] as List<dynamic>;
        final text = (content.first as Map<String, dynamic>)['text'] as String;
        final route = text.contains('powerful') ? 'powerful' : 'fast';
        await Future<void>.delayed(
          route == 'fast'
              ? const Duration(milliseconds: 20)
              : const Duration(milliseconds: 5),
        );
        return modelRouteResponse(route);
      }),
    );
    final router = plugin.defineModelRouter(
      name: 'cost-router',
      instructions: 'Choose.',
      routes: {
        'fast': TypeSafeModelRoute(
          model: modelRef('fast-model'),
          criteria: 'Simple.',
        ),
        'powerful': TypeSafeModelRoute(
          model: modelRef('powerful-model'),
          criteria: 'Complex.',
        ),
      },
    );
    final ai = Genkit(plugins: [plugin], isDevEnv: false);
    ai.defineModel(
      name: 'fast-model',
      fn: (request, ctx) async {
        fastModelCalls++;
        modelDecisions['fast'] = router.decisionFromContext(ctx.context);
        return _textResponse('fast');
      },
    );
    ai.defineModel(
      name: 'powerful-model',
      fn: (request, ctx) async {
        powerfulModelCalls++;
        modelDecisions['powerful'] = router.decisionFromContext(ctx.context);
        return _textResponse('powerful');
      },
    );

    try {
      final responses = await Future.wait([
        ai.generate(prompt: 'choose fast', use: [router]),
        ai.generate(prompt: 'choose powerful', use: [router]),
      ]);

      expect(responses.map((response) => response.text), ['fast', 'powerful']);
      expect(typeSafeCalls, 2);
      expect(fastModelCalls, 1);
      expect(powerfulModelCalls, 1);
      expect(modelDecisions['fast']?.route, 'fast');
      expect(modelDecisions['powerful']?.route, 'powerful');
    } finally {
      plugin.close();
      await ai.shutdown();
    }
  });

  test('preserves generation options and turn state while routing', () async {
    final plugin = TypeSafePlugin(
      apiKey: 'test-key',
      httpClient: MockClient((request) async => modelRouteResponse('fast')),
    );
    final router = plugin.defineModelRouter(
      name: 'cost-router',
      instructions: 'Choose.',
      routes: {
        'fast': TypeSafeModelRoute(
          model: modelRef('fast-model', config: {'temperature': 0.1}),
          criteria: 'Simple.',
        ),
      },
    );
    genkit_plugin.GenerateTurnState? captured;
    Map<String, dynamic>? injectedJson;
    final middlewarePlugin = _TestMiddlewarePlugin([
      genkit_plugin.defineMiddleware<Object?>(
        name: 'test/inject-options',
        create: (config, context) => _CallbackMiddleware((envelope, ctx, next) {
          injectedJson = {
            ...envelope.request.toJson(),
            'model': 'original-model',
            'docs': [
              {
                'content': [
                  {'text': 'document'},
                ],
              },
            ],
            'tools': <String>[],
            'resources': ['resource://one'],
            'toolChoice': 'none',
            'config': {'wrong': true},
            'output': {'format': 'text'},
            'resume': {
              'metadata': {'cursor': 'one'},
            },
            'returnToolRequests': true,
            'maxTurns': 7,
            'stepName': 'routing-step',
            'use': [
              {
                'name': 'preserved/middleware',
                'config': {'flag': true},
              },
            ],
          };
          return next((
            request: GenerateActionOptions.fromJson(injectedJson!),
            currentTurn: 3,
            messageIndex: 4,
          ), ctx);
        }),
      ),
      genkit_plugin.defineMiddleware<Object?>(
        name: 'test/capture-options',
        create: (config, context) =>
            _CallbackMiddleware((envelope, ctx, next) async {
              captured = envelope;
              return GenerateResponseHelper(_textResponse('captured'));
            }),
      ),
    ]);
    final ai = Genkit(plugins: [plugin, middlewarePlugin], isDevEnv: false);

    try {
      final response = await ai.generate(
        prompt: 'simple',
        use: [
          middlewareRef(name: 'test/inject-options'),
          router,
          middlewareRef(name: 'test/capture-options'),
        ],
      );

      expect(response.text, 'captured');
      expect(captured?.currentTurn, 3);
      expect(captured?.messageIndex, 4);
      expect(captured?.request.toJson(), {
        ...injectedJson!,
        'model': 'fast-model',
        'config': {'temperature': 0.1},
      });
    } finally {
      plugin.close();
      await ai.shutdown();
    }
  });

  test('forwards streaming chunks from the selected model', () async {
    final plugin = TypeSafePlugin(
      apiKey: 'test-key',
      httpClient: MockClient((request) async => modelRouteResponse('fast')),
    );
    final router = plugin.defineModelRouter(
      name: 'cost-router',
      instructions: 'Choose.',
      routes: {
        'fast': TypeSafeModelRoute(
          model: modelRef('fast-model'),
          criteria: 'Simple.',
        ),
      },
    );
    final ai = Genkit(plugins: [plugin], isDevEnv: false);
    ai.defineModel(
      name: 'fast-model',
      fn: (request, ctx) async {
        ctx.sendChunk(
          ModelResponseChunk(
            role: Role.model,
            content: [TextPart(text: 'chunk')],
          ),
        );
        return _textResponse('done');
      },
    );
    final chunks = <String>[];

    try {
      final response = await ai.generate(
        prompt: 'simple',
        use: [router],
        onChunk: (chunk) => chunks.add(chunk.text),
      );

      expect(response.text, 'done');
      expect(chunks, ['chunk']);
    } finally {
      plugin.close();
      await ai.shutdown();
    }
  });

  test(
    'uses route criteria and config snapshots after source mutation',
    () async {
      final typeSafeRequests = <http.Request>[];
      final criteria = <String, Object?>{
        'kinds': ['simple'],
      };
      final config = <String, Object?>{
        'temperature': 0.1,
        'nested': {'enabled': true},
      };
      final plugin = TypeSafePlugin(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          typeSafeRequests.add(request);
          return modelRouteResponse('fast');
        }),
      );
      final router = plugin.defineModelRouter(
        name: 'cost-router',
        instructions: 'Choose.',
        routes: {
          'fast': TypeSafeModelRoute(
            model: modelRef('fast-model', config: config),
            criteria: criteria,
          ),
        },
      );
      (criteria['kinds'] as List<Object?>).add('changed');
      (config['nested'] as Map<String, Object?>)['enabled'] = false;
      Map<String, dynamic>? receivedConfig;
      final ai = Genkit(plugins: [plugin], isDevEnv: false);
      ai.defineModel(
        name: 'fast-model',
        fn: (request, ctx) async {
          receivedConfig = request.config;
          return _textResponse('fast');
        },
      );

      try {
        await ai.generate(prompt: 'simple', use: [router]);

        final body = jsonDecode(typeSafeRequests.single.body) as Map;
        expect(body['questions'], {
          'modelRoute': {
            'type': 'choice',
            'instructions': 'Choose.',
            'criteria': {
              'fast': {
                'kinds': ['simple'],
              },
            },
          },
        });
        expect(receivedConfig, {
          'temperature': 0.1,
          'nested': {'enabled': true},
        });
      } finally {
        plugin.close();
        await ai.shutdown();
      }
    },
  );
}

typedef _GenerateCallback = Future<GenerateResponseHelper> Function(
  genkit_plugin.GenerateTurnState envelope,
  ActionFnArg<ModelResponseChunk, GenerateActionOptions, void> context,
  Future<GenerateResponseHelper> Function(
    genkit_plugin.GenerateTurnState envelope,
    ActionFnArg<ModelResponseChunk, GenerateActionOptions, void> context,
  )
  next,
);

final class _CallbackMiddleware extends GenerateMiddleware {
  _CallbackMiddleware(this.callback);

  final _GenerateCallback callback;

  @override
  Future<GenerateResponseHelper> generate(
    genkit_plugin.GenerateTurnState envelope,
    ActionFnArg<ModelResponseChunk, GenerateActionOptions, void> ctx,
    Future<GenerateResponseHelper> Function(
      genkit_plugin.GenerateTurnState envelope,
      ActionFnArg<ModelResponseChunk, GenerateActionOptions, void> ctx,
    )
    next,
  ) => callback(envelope, ctx, next);
}

final class _TestMiddlewarePlugin extends genkit_plugin.GenkitPlugin {
  _TestMiddlewarePlugin(this.definitions);

  final List<genkit_plugin.GenerateMiddlewareDef> definitions;

  @override
  String get name => 'test-middleware';

  @override
  List<genkit_plugin.GenerateMiddlewareDef> middleware() => definitions;
}

ModelResponse _textResponse(String text) => ModelResponse(
  finishReason: FinishReason.stop,
  message: Message(
    role: Role.model,
    content: [TextPart(text: text)],
  ),
);
