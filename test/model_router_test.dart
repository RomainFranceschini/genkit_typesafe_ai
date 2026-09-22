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
}

ModelResponse _textResponse(String text) => ModelResponse(
  finishReason: FinishReason.stop,
  message: Message(
    role: Role.model,
    content: [TextPart(text: text)],
  ),
);
