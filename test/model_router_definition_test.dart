import 'package:genkit/plugin.dart';
import 'package:genkit_typesafe_ai/src/classifier.dart';
import 'package:genkit_typesafe_ai/src/model_router.dart';
import 'package:genkit_typesafe_ai/src/plugin.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

void main() {
  test('defines a named router, classifier action, and middleware offline', () {
    var clientsCreated = 0;
    final plugin = TypeSafePlugin(
      clientFactory: () {
        clientsCreated++;
        throw StateError('client must stay lazy');
      },
    );
    final router = plugin.defineModelRouter(
      name: 'cost-router',
      instructions: 'Choose the least costly capable model.',
      routes: {
        'fast': TypeSafeModelRoute(
          model: modelRef('fast-model', config: {'temperature': 0.1}),
          criteria: 'Simple tasks.',
        ),
        'powerful': TypeSafeModelRoute(
          model: modelRef('powerful-model', config: {'temperature': 0.7}),
          criteria: 'Complex tasks.',
        ),
      },
    );

    final definitions = plugin.middleware();
    final action = plugin.resolve(typeSafeClassifierActionType, 'cost-router')!;

    expect(router.name, 'typesafe/cost-router');
    expect(router.localName, 'cost-router');
    expect(router.config, isNull);
    expect(definitions.single.name, 'typesafe/cost-router');
    expect(action.metadata['typesafe'], {
      'kind': 'model-router',
      'router': 'typesafe/cost-router',
      'routes': {
        'fast': {'model': 'fast-model'},
        'powerful': {'model': 'powerful-model'},
      },
      'model': null,
      'questions': {
        'modelRoute': {
          'type': 'choice',
          'instructions': 'Choose the least costly capable model.',
          'criteria': {'fast': 'Simple tasks.', 'powerful': 'Complex tasks.'},
        },
      },
    });
    expect(clientsCreated, 0);
  });

  group('definition validation is transactional', () {
    for (final name in ['', '  ', 'bad/name']) {
      test('rejects router name ${name.isEmpty ? '<empty>' : name}', () async {
        final plugin = TypeSafePlugin();

        expect(
          () => plugin.defineModelRouter(
            name: name,
            instructions: 'Choose.',
            routes: _routes(),
          ),
          throwsA(_genkitStatus(StatusCodes.INVALID_ARGUMENT)),
        );

        expect(plugin.middleware(), isEmpty);
        expect(await plugin.init(), isEmpty);
      });
    }

    test('rejects an empty route map', () async {
      final plugin = TypeSafePlugin();

      expect(
        () => plugin.defineModelRouter(
          name: 'router',
          instructions: 'Choose.',
          routes: const {},
        ),
        throwsA(_genkitStatus(StatusCodes.INVALID_ARGUMENT)),
      );

      expect(plugin.middleware(), isEmpty);
      expect(await plugin.init(), isEmpty);
    });

    for (final label in ['', '  ']) {
      test(
        'rejects blank route label ${label.isEmpty ? '<empty>' : label}',
        () async {
          final plugin = TypeSafePlugin();

          expect(
            () => plugin.defineModelRouter(
              name: 'router',
              instructions: 'Choose.',
              routes: {
                label: TypeSafeModelRoute(
                  model: modelRef('fast-model'),
                  criteria: 'Simple.',
                ),
              },
            ),
            throwsA(_genkitStatus(StatusCodes.INVALID_ARGUMENT)),
          );

          expect(plugin.middleware(), isEmpty);
          expect(await plugin.init(), isEmpty);
        },
      );
    }

    for (final modelName in ['', '  ']) {
      test(
        'rejects blank model name ${modelName.isEmpty ? '<empty>' : modelName}',
        () async {
          final plugin = TypeSafePlugin();

          expect(
            () => plugin.defineModelRouter(
              name: 'router',
              instructions: 'Choose.',
              routes: {
                'fast': TypeSafeModelRoute(
                  model: modelRef(modelName),
                  criteria: 'Simple.',
                ),
              },
            ),
            throwsA(_genkitStatus(StatusCodes.INVALID_ARGUMENT)),
          );

          expect(plugin.middleware(), isEmpty);
          expect(await plugin.init(), isEmpty);
        },
      );
    }

    test('rejects model config that does not encode to an object', () async {
      final plugin = TypeSafePlugin();

      expect(
        () => plugin.defineModelRouter(
          name: 'router',
          instructions: 'Choose.',
          routes: {
            'fast': TypeSafeModelRoute(
              model: modelRef('fast-model', config: _ListJson()),
              criteria: 'Simple.',
            ),
          },
        ),
        throwsA(_genkitStatus(StatusCodes.INVALID_ARGUMENT)),
      );

      expect(plugin.middleware(), isEmpty);
      expect(await plugin.init(), isEmpty);
    });

    test('rejects non-JSON instructions before registration', () async {
      final plugin = TypeSafePlugin();

      expect(
        () => plugin.defineModelRouter(
          name: 'router',
          instructions: Object(),
          routes: _routes(),
        ),
        throwsA(_genkitStatus(StatusCodes.INVALID_ARGUMENT)),
      );

      expect(plugin.middleware(), isEmpty);
      expect(await plugin.init(), isEmpty);
    });

    test('rejects non-JSON route criteria before registration', () async {
      final plugin = TypeSafePlugin();

      expect(
        () => plugin.defineModelRouter(
          name: 'router',
          instructions: 'Choose.',
          routes: {
            'fast': TypeSafeModelRoute(
              model: modelRef('fast-model'),
              criteria: Object(),
            ),
          },
        ),
        throwsA(_genkitStatus(StatusCodes.INVALID_ARGUMENT)),
      );

      expect(plugin.middleware(), isEmpty);
      expect(await plugin.init(), isEmpty);
    });
  });

  group('classifier and router definitions share a namespace', () {
    test('classifier blocks a router with the same name', () {
      final plugin = TypeSafePlugin();
      plugin.defineClassifier(
        name: 'cost-router',
        questions: {'urgent': Noul(instructions: 'Urgent?')},
      );

      expect(
        () => plugin.defineModelRouter(
          name: 'cost-router',
          instructions: 'Choose.',
          routes: _routes(),
        ),
        throwsA(_genkitStatus(StatusCodes.ALREADY_EXISTS)),
      );
    });

    test('router blocks classifiers and routers with the same name', () {
      final plugin = TypeSafePlugin();
      plugin.defineModelRouter(
        name: 'cost-router',
        instructions: 'Choose.',
        routes: _routes(),
      );

      expect(
        () => plugin.defineClassifier(
          name: 'cost-router',
          questions: {'urgent': Noul(instructions: 'Urgent?')},
        ),
        throwsA(_genkitStatus(StatusCodes.ALREADY_EXISTS)),
      );
      expect(
        () => plugin.defineModelRouter(
          name: 'cost-router',
          instructions: 'Choose again.',
          routes: _routes(),
        ),
        throwsA(_genkitStatus(StatusCodes.ALREADY_EXISTS)),
      );
    });
  });

  group('definition freezing', () {
    for (final operation in <String, Future<void> Function(TypeSafePlugin)>{
      'middleware': (plugin) async {
        plugin.middleware();
      },
      'init': (plugin) async {
        await plugin.init();
      },
      'list': (plugin) async {
        await plugin.list();
      },
      'resolve': (plugin) async {
        plugin.resolve(typeSafeClassifierActionType, 'missing');
      },
    }.entries) {
      test(
        '${operation.key} prevents later classifier and router definitions',
        () async {
          final plugin = TypeSafePlugin();
          await operation.value(plugin);

          expect(
            () => plugin.defineClassifier(
              name: 'classifier',
              questions: {'urgent': Noul(instructions: 'Urgent?')},
            ),
            throwsA(_genkitStatus(StatusCodes.FAILED_PRECONDITION)),
          );
          expect(
            () => plugin.defineModelRouter(
              name: 'router',
              instructions: 'Choose.',
              routes: _routes(),
            ),
            throwsA(_genkitStatus(StatusCodes.FAILED_PRECONDITION)),
          );
        },
      );
    }
  });

  test('snapshots instructions, criteria, model config, and route maps', () {
    final instructions = <String, Object?>{'goal': 'cheap'};
    final criteria = <String, Object?>{
      'kinds': ['simple'],
    };
    final config = <String, Object?>{
      'temperature': 0.1,
      'nested': {'enabled': true},
    };
    final routes = <String, TypeSafeModelRoute>{
      'fast': TypeSafeModelRoute(
        model: modelRef('fast-model', config: config),
        criteria: criteria,
      ),
    };
    final plugin = TypeSafePlugin();
    final router = plugin.defineModelRouter(
      name: 'router',
      instructions: instructions,
      routes: routes,
    );

    instructions['goal'] = 'changed';
    (criteria['kinds'] as List<Object?>).add('changed');
    (config['nested'] as Map<String, Object?>)['enabled'] = false;
    routes.clear();

    expect(router.routes.keys, ['fast']);
    expect(router.routes['fast']!.criteria, {
      'kinds': ['simple'],
    });
    expect(router.resolvedRoutes['fast']!.config, {
      'temperature': 0.1,
      'nested': {'enabled': true},
    });
    expect(
      plugin
          .resolve(typeSafeClassifierActionType, 'router')!
          .metadata['typesafe'],
      containsPair('questions', {
        'modelRoute': {
          'type': 'choice',
          'instructions': {'goal': 'cheap'},
          'criteria': {
            'fast': {
              'kinds': ['simple'],
            },
          },
        },
      }),
    );
  });
}

Map<String, TypeSafeModelRoute> _routes() => {
  'fast': TypeSafeModelRoute(
    model: modelRef('fast-model'),
    criteria: 'Simple.',
  ),
};

Matcher _genkitStatus(StatusCodes status) =>
    isA<GenkitException>().having((error) => error.status, 'status', status);

final class _ListJson {
  List<Object?> toJson() => ['not', 'an', 'object'];
}
