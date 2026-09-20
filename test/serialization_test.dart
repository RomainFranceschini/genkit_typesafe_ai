import 'dart:convert';

import 'package:genkit_typesafe_ai/src/serialization.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

enum Department { billing, technical }

enum Urgency { low, high }

void main() {
  test('serializes questions and answers using wire labels', () async {
    final department = Choice({
      Department.billing: 'Payment issue',
      Department.technical: 'Product issue',
    });
    final urgent = Noul(instructions: 'Is this urgent?');
    final urgency = Score.ofEnum({
      Urgency.low: 'Can wait',
      Urgency.high: 'Needs attention now',
    });
    final questions = <String, Question<Answer>>{
      'department': department,
      'urgent': urgent,
      'urgency': urgency,
    };
    final client = TypeSafeClient(
      apiKey: 'test-key',
      retry: RetryPolicy(maxRetries: 0),
      httpClient: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'model': 'jev-latest',
            'answers': {
              'department': {
                'type': 'choice',
                'choice': 'billing',
                'confidence': 0.9,
                'probabilities': {'billing': 0.9, 'technical': 0.1},
              },
              'urgent': {'type': 'noul', 'noul': 0.8},
              'urgency': {
                'type': 'score',
                'score': 0.75,
                'confidence': 0.7,
                'legend': {'0': 'Can wait', '1': 'Needs attention now'},
                'probabilities': {'0': 0.25, '1': 0.75},
              },
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
      state: 'Please fix this now',
      questions: questions,
    );

    expect(serializeQuestions(questions), {
      'department': {
        'type': 'choice',
        'instructions': null,
        'criteria': {'billing': 'Payment issue', 'technical': 'Product issue'},
      },
      'urgent': {'type': 'noul', 'instructions': 'Is this urgent?'},
      'urgency': {
        'type': 'score',
        'instructions': null,
        'criteria': ['Can wait', 'Needs attention now'],
      },
    });
    expect(serializeSystemOneResponse(response, questions), {
      'model': 'jev-latest',
      'answers': {
        'department': {
          'type': 'choice',
          'choice': 'billing',
          'confidence': 0.9,
          'probabilities': {'billing': 0.9, 'technical': 0.1},
        },
        'urgent': {'type': 'noul', 'noul': 0.8},
        'urgency': {
          'type': 'score',
          'score': 0.75,
          'confidence': 0.7,
          'legend': {'0': 'Can wait', '1': 'Needs attention now'},
          'probabilities': {'0': 0.25, '1': 0.75},
          'scale': [0, 1],
        },
      },
      'usage': {'inputTokens': 12, 'outputTokens': 3},
      'requestId': 'req_123',
    });
    client.close();
  });

  test('serializes missing usage counts and request ID as null', () async {
    final urgent = Noul(instructions: 'Is this urgent?');
    final questions = <String, Question<Answer>>{'urgent': urgent};
    final client = TypeSafeClient(
      apiKey: 'test-key',
      retry: RetryPolicy(maxRetries: 0),
      httpClient: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'model': 'jev-latest',
            'answers': {
              'urgent': {'type': 'noul', 'noul': 0.8},
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    final response = await client.systemOne(
      state: 'Please fix this now',
      questions: questions,
    );
    final serialized = serializeSystemOneResponse(response, questions);

    expect(serialized['usage'], {'inputTokens': null, 'outputTokens': null});
    expect(serialized['requestId'], isNull);
    expect(jsonEncode(serialized), isA<String>());
    client.close();
  });
}
