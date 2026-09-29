import 'package:genkit/plugin.dart';
import 'package:genkit_typesafe_ai/src/classifier.dart';
import 'package:genkit_typesafe_ai/src/plugin.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

void main() {
  test('registers a named risk classifier and middleware without a client', () {
    var clientCreations = 0;
    final plugin = TypeSafePlugin(
      clientFactory: () {
        clientCreations++;
        throw StateError('client should be lazy');
      },
    );

    final guard = plugin.defineAutoMode(
      name: 'guard-writes',
      tools: ['delete'],
    );
    final action = plugin.resolve(
      typeSafeClassifierActionType,
      'guard-writes',
    )!;

    expect(guard.name, 'typesafe/guard-writes');
    expect(guard.localName, 'guard-writes');
    expect(guard.tools, ['delete']);
    expect(guard.config, isNull);
    expect(plugin.middleware().single.name, guard.name);
    expect(action.metadata['typesafe'], containsPair('kind', 'auto-mode'));
    expect(action.metadata['typesafe'], containsPair('tools', ['delete']));
    final metadata = action.metadata['typesafe'] as Map;
    final questions = metadata['questions'] as Map;
    final risk = questions['isRisky'] as Map;
    expect(risk['type'], 'noul');
    expect(risk['instructions'], contains('Only explicit user messages'));
    expect(clientCreations, 0);
    plugin.close();
  });

  test('snapshots tool names, criteria and headers', () {
    final tools = ['delete'];
    final outcome = <String, Object?>{'kind': 'destructive'};
    final headers = {'X-Policy': 'original'};
    final plugin = TypeSafePlugin();
    final guard = plugin.defineAutoMode(
      name: 'guard',
      tools: tools,
      criteria: NoulCriteria(whenTrue: outcome, whenFalse: 'safe'),
      headers: headers,
    );

    tools[0] = 'allow';
    outcome['kind'] = 'benign';
    headers['X-Policy'] = 'changed';

    expect(guard.tools, ['delete']);
    expect(guard.classifier.headers, {'X-Policy': 'original'});
    expect(guard.question.criteria!.whenTrue, {'kind': 'destructive'});
    expect(() => guard.tools.add('other'), throwsUnsupportedError);
    expect(
      () => (guard.question.criteria!.whenTrue as Map)['kind'] = 'tampered',
      throwsUnsupportedError,
    );
    plugin.close();
  });

  test('rejects invalid tool lists without partial registration', () async {
    for (final tools in <List<String>>[
      [],
      [''],
      ['  '],
      ['delete', 'delete'],
    ]) {
      final plugin = TypeSafePlugin();
      expect(
        () => plugin.defineAutoMode(name: 'guard', tools: tools),
        throwsA(
          isA<GenkitException>().having(
            (error) => error.status,
            'status',
            StatusCodes.INVALID_ARGUMENT,
          ),
        ),
      );
      expect(plugin.middleware(), isEmpty);
      expect(await plugin.list(), isEmpty);
      plugin.close();
    }
  });

  test('rejects blank instructions without partial registration', () async {
    for (final instructions in ['', '  ']) {
      final plugin = TypeSafePlugin();
      expect(
        () => plugin.defineAutoMode(
          name: 'guard',
          tools: ['delete'],
          instructions: instructions,
        ),
        throwsA(
          isA<GenkitException>().having(
            (error) => error.status,
            'status',
            StatusCodes.INVALID_ARGUMENT,
          ),
        ),
      );
      expect(plugin.middleware(), isEmpty);
      expect(await plugin.list(), isEmpty);
      plugin.close();
    }
  });

  test('rejects invalid names and non-JSON criteria', () async {
    for (final name in ['', '  ', 'bad/name']) {
      final plugin = TypeSafePlugin();
      expect(
        () => plugin.defineAutoMode(name: name, tools: ['delete']),
        throwsA(
          isA<GenkitException>().having(
            (error) => error.status,
            'status',
            StatusCodes.INVALID_ARGUMENT,
          ),
        ),
      );
      plugin.close();
    }

    final plugin = TypeSafePlugin();
    expect(
      () => plugin.defineAutoMode(
        name: 'guard',
        tools: ['delete'],
        criteria: NoulCriteria(whenTrue: Object()),
      ),
      throwsA(
        isA<GenkitException>().having(
          (error) => error.status,
          'status',
          StatusCodes.INVALID_ARGUMENT,
        ),
      ),
    );
    expect(plugin.middleware(), isEmpty);
    expect(await plugin.list(), isEmpty);
    plugin.close();
  });

  test('shares names with classifiers and routers', () {
    final plugin = TypeSafePlugin();
    plugin.defineAutoMode(name: 'guard', tools: ['delete']);
    expect(
      () => plugin.defineAutoMode(name: 'guard', tools: ['publish']),
      throwsA(
        isA<GenkitException>().having(
          (error) => error.status,
          'status',
          StatusCodes.ALREADY_EXISTS,
        ),
      ),
    );
    expect(
      () => plugin.defineClassifier(
        name: 'guard',
        questions: {'risk': Noul(instructions: 'Risky?')},
      ),
      throwsA(
        isA<GenkitException>().having(
          (error) => error.status,
          'status',
          StatusCodes.ALREADY_EXISTS,
        ),
      ),
    );
    plugin.close();
  });

  test('freezes definitions when middleware is listed', () {
    final plugin = TypeSafePlugin();
    plugin.defineAutoMode(name: 'guard', tools: ['delete']);
    plugin.middleware();
    expect(
      () => plugin.defineAutoMode(name: 'another', tools: ['publish']),
      throwsA(
        isA<GenkitException>().having(
          (error) => error.status,
          'status',
          StatusCodes.FAILED_PRECONDITION,
        ),
      ),
    );
    plugin.close();
  });
}
