import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:genkit/genkit.dart';
import 'package:genkit_typesafe_ai/src/classifier.dart';
import 'package:genkit_typesafe_ai/src/plugin.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

import 'support/fake_typesafe_client.dart';

void main() {
  group('plugin validation', () {
    test('handle creates the default named plugin', () {
      final plugin = typeSafeAI(apiKey: 'test-key');

      expect(plugin, isA<TypeSafePlugin>());
      expect(plugin.name, defaultTypeSafeNamespace);
    });

    test('rejects invalid plugin names', () {
      for (final name in ['', '  ', 'bad/name']) {
        expect(
          () => TypeSafePlugin(name: name),
          throwsA(
            isA<GenkitException>().having(
              (error) => error.status,
              'status',
              StatusCodes.INVALID_ARGUMENT,
            ),
          ),
        );
      }
    });

    test('validates an invalid name before copying configuration', () {
      expect(
        () => TypeSafePlugin(
          name: 'bad/name',
          defaultHeaders: _ThrowingHeaders(),
        ),
        throwsA(
          isA<GenkitException>().having(
            (error) => error.status,
            'status',
            StatusCodes.INVALID_ARGUMENT,
          ),
        ),
      );
    });

    test('rejects invalid classifier names and questions', () {
      final plugin = TypeSafePlugin();
      for (final name in ['', '  ', 'bad/name']) {
        expect(
          () => plugin.defineClassifier(name: name, questions: _questions),
          throwsA(isA<GenkitException>()),
        );
      }
      expect(
        () => plugin.defineClassifier(name: 'triage', questions: {}),
        throwsA(
          isA<GenkitException>().having(
            (error) => error.status,
            'status',
            StatusCodes.INVALID_ARGUMENT,
          ),
        ),
      );
    });

    test('rejects duplicate classifier names', () {
      final plugin = TypeSafePlugin();
      plugin.defineClassifier(name: 'triage', questions: _questions);

      expect(
        () => plugin.defineClassifier(name: 'triage', questions: _questions),
        throwsA(
          isA<GenkitException>().having(
            (error) => error.status,
            'status',
            StatusCodes.ALREADY_EXISTS,
          ),
        ),
      );
    });
  });

  group('offline registration', () {
    test('init, list, and resolve avoid creating a client', () async {
      var created = 0;
      final plugin = TypeSafePlugin(
        clientFactory: () {
          created++;
          return TypeSafeClient(apiKey: 'test-key');
        },
      );
      plugin.defineClassifier(name: 'triage', questions: _questions);

      final actions = await plugin.init();
      final metadata = await plugin.list();
      final resolved = plugin.resolve(typeSafeClassifierActionType, 'triage');

      expect(actions.single.name, 'typesafe/triage');
      expect(metadata.single.name, 'typesafe/triage');
      expect(resolved, isNotNull);
      expect(created, 0);
    });
  });

  group('resolve', () {
    test('returns matching classifiers only', () {
      final plugin = TypeSafePlugin();
      final classifier = plugin.defineClassifier(
        name: 'triage',
        questions: _questions,
      );

      expect(
        plugin.resolve(typeSafeClassifierActionType, 'triage'),
        same(classifier.action),
      );
      expect(plugin.resolve(const ActionType('other'), 'triage'), isNull);
      expect(plugin.resolve(typeSafeClassifierActionType, 'other'), isNull);
    });
  });

  group('freeze definitions', () {
    for (final operation in <String, Future<void> Function(TypeSafePlugin)>{
      'init': (plugin) => plugin.init(),
      'list': (plugin) => plugin.list(),
      'resolve': (plugin) async {
        plugin.resolve(typeSafeClassifierActionType, 'triage');
      },
    }.entries) {
      test('${operation.key} prevents later definitions', () async {
        final plugin = TypeSafePlugin();
        plugin.defineClassifier(name: 'triage', questions: _questions);

        await operation.value(plugin);

        expect(
          () => plugin.defineClassifier(name: 'later', questions: _questions),
          throwsA(
            isA<GenkitException>().having(
              (error) => error.status,
              'status',
              StatusCodes.FAILED_PRECONDITION,
            ),
          ),
        );
      });
    }
  });

  group('requests and snapshots', () {
    test(
      'forwards classification options and preserves definition snapshots',
      () async {
        final requests = <http.Request>[];
        final sourceQuestions = <String, Question<Answer>>{
          'urgent': Noul(instructions: 'Is this urgent?'),
        };
        final sourceHeaders = <String, String>{'x-tenant': 'alpha'};
        final plugin = TypeSafePlugin(
          apiKey: 'test-key',
          defaultModel: 'plugin-default',
          httpClient: MockClient((request) async {
            requests.add(request);
            return systemOneResponse();
          }),
        );
        final classifier = plugin.defineClassifier(
          name: 'triage',
          questions: sourceQuestions,
          model: 'jev-2026-09-01',
          timeout: const Duration(seconds: 1),
          retry: RetryPolicy(maxRetries: 0),
          headers: sourceHeaders,
        );
        sourceQuestions.clear();
        sourceHeaders['x-tenant'] = 'changed';

        final response = await classifier({'ticket': 'charged twice'});

        final request = requests.single;
        expect(request.url.path, '/v1/systemone');
        expect(jsonDecode(request.body), {
          'state': {'ticket': 'charged twice'},
          'questions': {
            'urgent': {'type': 'noul', 'instructions': 'Is this urgent?'},
          },
          'model': 'jev-2026-09-01',
        });
        expect(request.headers['x-tenant'], 'alpha');
        expect(
          response.get(classifier.questions['urgent']!),
          isA<NoulAnswer>().having((answer) => answer.noul, 'noul', 0.8),
        );
        expect(classifier.action.metadata['typesafe'], {
          'model': 'jev-2026-09-01',
          'questions': {
            'urgent': {'type': 'noul', 'instructions': 'Is this urgent?'},
          },
        });
      },
    );

    test('creates one client for simultaneous first classifications', () async {
      var created = 0;
      final plugin = TypeSafePlugin(
        clientFactory: () {
          created++;
          return TypeSafeClient(
            apiKey: 'test-key',
            httpClient: MockClient((request) async => systemOneResponse()),
          );
        },
      );
      final classifier = plugin.defineClassifier(
        name: 'triage',
        questions: _questions,
      );

      await Future.wait([classifier('first'), classifier('second')]);

      expect(created, 1);
    });

    test('forwards each supported state unchanged or through toJson', () async {
      final states = <Object?>[
        'help',
        {'ticket': 'charged twice'},
        ['help'],
        null,
        const TicketState('help'),
      ];
      final received = <Object?>[];
      final plugin = TypeSafePlugin(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          received.add((jsonDecode(request.body) as Map)['state']);
          return systemOneResponse();
        }),
      );
      final classifier = plugin.defineClassifier(
        name: 'triage',
        questions: _questions,
      );

      for (final state in states) {
        await classifier(state);
      }

      expect(received, [
        'help',
        {'ticket': 'charged twice'},
        ['help'],
        null,
        {'message': 'help'},
      ]);
    });

    test(
      'uses the plugin default model unless a classifier overrides it',
      () async {
        final models = <String>[];
        final plugin = TypeSafePlugin(
          apiKey: 'test-key',
          defaultModel: 'plugin-default',
          httpClient: MockClient((request) async {
            models.add((jsonDecode(request.body) as Map)['model'] as String);
            return systemOneResponse();
          }),
        );
        final defaultClassifier = plugin.defineClassifier(
          name: 'default',
          questions: _questions,
        );
        final overridingClassifier = plugin.defineClassifier(
          name: 'override',
          questions: _questions,
          model: 'classifier-model',
        );

        await defaultClassifier('state');
        await overridingClassifier('state');

        expect(models, ['plugin-default', 'classifier-model']);
      },
    );

    test('forwards timeout and retry overrides', () async {
      var timeoutRequests = 0;
      final timeoutPlugin = TypeSafePlugin(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          timeoutRequests++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return systemOneResponse();
        }),
      );
      final timeoutClassifier = timeoutPlugin.defineClassifier(
        name: 'timeout',
        questions: _questions,
        timeout: const Duration(milliseconds: 1),
      );

      await expectLater(
        timeoutClassifier('state'),
        throwsA(isA<GenkitException>()),
      );
      expect(timeoutRequests, greaterThanOrEqualTo(1));

      var retryRequests = 0;
      final retryPlugin = TypeSafePlugin(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          retryRequests++;
          return http.Response('failure', 500);
        }),
      );
      final retryClassifier = retryPlugin.defineClassifier(
        name: 'retry',
        questions: _questions,
        retry: RetryPolicy(maxRetries: 0),
      );

      await expectLater(
        retryClassifier('state'),
        throwsA(isA<GenkitException>()),
      );
      expect(retryRequests, 1);
    });
  });

  group('raw reflection and ambiguity', () {
    test('returns the raw serialized action result', () async {
      final plugin = _pluginWithResponse(systemOneResponse());
      plugin.defineClassifier(name: 'triage', questions: _questions);

      final action = plugin.resolve(typeSafeClassifierActionType, 'triage')!;
      final raw = await action.runRaw({'ticket': 'charged twice'});
      final encoded =
          jsonDecode(jsonEncode(raw.result)) as Map<String, dynamic>;

      expect(encoded['model'], 'jev-latest');
      expect(encoded['answers']['urgent']['noul'], 0.8);
    });

    test('preserves ambiguous question handles', () async {
      final question = Noul(instructions: 'Is this urgent?');
      final plugin = _pluginWithResponse(
        systemOneResponse(
          answers: {
            'first': {'type': 'noul', 'noul': 0.8},
            'second': {'type': 'noul', 'noul': 0.2},
          },
        ),
      );
      final classifier = plugin.defineClassifier(
        name: 'triage',
        questions: {'first': question, 'second': question},
      );

      final response = await classifier('state');

      expect(() => response.get(question), throwsArgumentError);
    });
  });

  group('model discovery and closure', () {
    test(
      'discovers models and shares the lazy client with classification',
      () async {
        var created = 0;
        final paths = <String>[];
        final plugin = TypeSafePlugin(
          clientFactory: () {
            created++;
            return TypeSafeClient(
              apiKey: 'test-key',
              httpClient: MockClient((request) async {
                paths.add(request.url.path);
                return request.url.path == '/v1/models'
                    ? modelsResponse()
                    : systemOneResponse();
              }),
            );
          },
        );
        final classifier = plugin.defineClassifier(
          name: 'triage',
          questions: _questions,
        );

        await classifier('state');
        final models = await plugin.listModels();

        expect(models.single.name, 'jev-latest');
        expect(paths, ['/v1/systemone', '/v1/models']);
        expect(created, 1);
      },
    );

    test('maps discovery authentication errors', () async {
      final plugin = TypeSafePlugin(
        apiKey: 'test-key',
        retry: RetryPolicy(maxRetries: 0),
        httpClient: MockClient((request) async => http.Response('', 401)),
      );

      await expectLater(
        plugin.listModels(),
        throwsA(
          isA<GenkitException>()
              .having(
                (error) => error.status,
                'status',
                StatusCodes.UNAUTHENTICATED,
              )
              .having(
                (error) => error.underlyingException,
                'underlying exception',
                isA<AuthenticationError>(),
              ),
        ),
      );
    });

    test('close blocks future work without creating a client', () async {
      var created = 0;
      var requests = 0;
      final plugin = TypeSafePlugin(
        clientFactory: () {
          created++;
          return TypeSafeClient(
            apiKey: 'test-key',
            httpClient: MockClient((request) async {
              requests++;
              return systemOneResponse();
            }),
          );
        },
      );
      final classifier = plugin.defineClassifier(
        name: 'triage',
        questions: _questions,
      );
      plugin.close();
      plugin.close();

      await expectLater(classifier('state'), throwsA(isA<GenkitException>()));
      await expectLater(plugin.listModels(), throwsA(isA<GenkitException>()));
      expect(created, 0);
      expect(requests, 0);
    });

    test(
      'does not close injected clients and snapshots default headers',
      () async {
        final client = _TrackingClient(systemOneResponse());
        final headers = <String, String>{'x-tenant': 'alpha'};
        final plugin = TypeSafePlugin(
          apiKey: 'test-key',
          defaultHeaders: headers,
          httpClient: client,
        );
        headers['x-tenant'] = 'changed';
        final classifier = plugin.defineClassifier(
          name: 'triage',
          questions: _questions,
        );

        await classifier('state');
        plugin.close();

        expect(client.requests.single.headers['x-tenant'], 'alpha');
        expect(client.closeCalled, isFalse);
      },
    );
  });
}

final _questions = <String, Question<Answer>>{
  'urgent': Noul(instructions: 'Is this urgent?'),
};

TypeSafePlugin _pluginWithResponse(http.Response response) => TypeSafePlugin(
  apiKey: 'test-key',
  httpClient: MockClient((request) async => response),
);

final class TicketState {
  const TicketState(this.message);

  final String message;

  Map<String, Object?> toJson() => {'message': message};
}

final class _TrackingClient extends http.BaseClient {
  _TrackingClient(this.response);

  final http.Response response;
  final requests = <http.BaseRequest>[];
  var closeCalled = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }

  @override
  void close() {
    closeCalled = true;
    super.close();
  }
}

final class _ThrowingHeaders extends MapBase<String, String> {
  @override
  String? operator [](Object? key) => throw StateError('Headers copied.');

  @override
  void operator []=(String key, String value) => throw UnimplementedError();

  @override
  void clear() => throw UnimplementedError();

  @override
  Iterable<String> get keys => throw StateError('Headers copied.');

  @override
  String? remove(Object? key) => throw UnimplementedError();
}
