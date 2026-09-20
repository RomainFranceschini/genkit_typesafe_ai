import 'dart:convert';

import 'package:genkit/genkit.dart';
import 'package:genkit_typesafe_ai/src/classifier.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

Future<SystemOneResponse> fakeResponse(
  Map<String, Question<Answer>> questions,
) async {
  final client = TypeSafeClient(
    apiKey: 'test-key',
    retry: RetryPolicy(maxRetries: 0),
    httpClient: MockClient(
      (request) async => http.Response(
        jsonEncode({
          'model': 'jev-latest',
          'answers': {
            for (final name in questions.keys)
              name: {'type': 'noul', 'noul': 0.8},
          },
          'usage': {'input_tokens': 12, 'output_tokens': 3},
        }),
        200,
        headers: {
          'content-type': 'application/json',
          'x-typesafe-request-id': 'req_123',
        },
      ),
    ),
  );
  final response = await client.systemOne(
    state: 'test state',
    questions: questions,
  );
  client.close();
  return response;
}

void main() {
  test(
    'fixes questions and options while accepting new state per call',
    () async {
      final urgent = Noul(instructions: 'Is this urgent?');
      final originalQuestions = <String, Question<Answer>>{'urgent': urgent};
      final originalHeaders = <String, String>{'x-tenant': 'alpha'};
      final calls = <Map<String, Object?>>[];
      final response = await fakeResponse({'urgent': urgent});
      final classifier = TypeSafeClassifier.internal(
        namespace: 'typesafe',
        name: 'triage',
        questions: originalQuestions,
        model: 'jev-2026-09-01',
        timeout: const Duration(seconds: 2),
        retry: RetryPolicy(maxRetries: 0),
        headers: originalHeaders,
        classify:
            ({
              required state,
              required questions,
              model,
              timeout,
              retry,
              headers,
            }) async {
              calls.add({
                'state': state,
                'questions': questions,
                'model': model,
                'timeout': timeout,
                'retry': retry,
                'headers': headers,
              });
              return response;
            },
      );

      originalQuestions.clear();
      originalHeaders['x-tenant'] = 'changed';
      final result = await classifier('new state');

      expect(result, same(response));
      expect(calls.single['state'], 'new state');
      expect((calls.single['questions'] as Map).keys, ['urgent']);
      expect(calls.single['model'], 'jev-2026-09-01');
      expect(calls.single['headers'], {'x-tenant': 'alpha'});
    },
  );

  test('exposes its name and action name', () async {
    final urgent = Noul(instructions: 'Is this urgent?');
    final classifier = TypeSafeClassifier.internal(
      namespace: 'typesafe',
      name: 'triage',
      questions: {'urgent': urgent},
      classify: ({
        required state,
        required questions,
        model,
        timeout,
        retry,
        headers,
      }) => fakeResponse(questions),
    );

    expect(classifier.name, 'triage');
    expect(classifier.actionName, 'typesafe/triage');
  });

  test('exposes a JSON-safe action with serialized metadata', () async {
    final urgent = Noul(instructions: 'Is this urgent?');
    final classifier = TypeSafeClassifier.internal(
      namespace: 'typesafe',
      name: 'triage',
      questions: {'urgent': urgent},
      model: 'jev-2026-09-01',
      classify: ({
        required state,
        required questions,
        model,
        timeout,
        retry,
        headers,
      }) => fakeResponse(questions),
    );
    final action = classifier.action;

    expect(action.actionType, typeSafeClassifierActionType);
    expect(action.metadata['typesafe'], {
      'model': 'jev-2026-09-01',
      'questions': {
        'urgent': {'type': 'noul', 'instructions': 'Is this urgent?'},
      },
    });
    expect(jsonEncode((await action.runRaw('state')).result), isA<String>());
  });

  test('does not call the callback when already cancelled', () async {
    final controller = CancellationController()..cancel();
    var calls = 0;
    final urgent = Noul(instructions: 'Is this urgent?');
    final classifier = TypeSafeClassifier.internal(
      namespace: 'typesafe',
      name: 'triage',
      questions: {'urgent': urgent},
      classify:
          ({
            required state,
            required questions,
            model,
            timeout,
            retry,
            headers,
          }) async {
            calls++;
            return fakeResponse(questions);
          },
    );

    await expectLater(
      classifier('state', cancel: controller.token),
      throwsA(isA<CancelledException>()),
    );
    expect(calls, 0);
  });

  test('maps authentication failures with the classifier name', () async {
    final urgent = Noul(instructions: 'Is this urgent?');
    final classifier = TypeSafeClassifier.internal(
      namespace: 'typesafe',
      name: 'triage',
      questions: {'urgent': urgent},
      classify:
          ({
            required state,
            required questions,
            model,
            timeout,
            retry,
            headers,
          }) async {
            throw AuthenticationError(statusCode: 401, body: null, headers: {});
          },
    );

    await expectLater(
      classifier('state'),
      throwsA(
        isA<GenkitException>()
            .having(
              (error) => error.status,
              'status',
              StatusCodes.UNAUTHENTICATED,
            )
            .having((error) => error.message, 'message', contains('triage')),
      ),
    );
  });

  test('preserves ambiguous question-handle response semantics', () async {
    final urgent = Noul(instructions: 'Is this urgent?');
    final questions = <String, Question<Answer>>{
      'urgent': urgent,
      'alsoUrgent': urgent,
    };
    final response = await fakeResponse(questions);
    final classifier = TypeSafeClassifier.internal(
      namespace: 'typesafe',
      name: 'triage',
      questions: questions,
      classify: ({
        required state,
        required questions,
        model,
        timeout,
        retry,
        headers,
      }) async => response,
    );

    final result = await classifier('state');

    expect(result, same(response));
    expect(() => result.get(urgent), throwsArgumentError);
  });
}
