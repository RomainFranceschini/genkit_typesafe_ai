import 'package:genkit/genkit.dart';
import 'package:meta/meta.dart';
import 'package:schemantic/schemantic.dart';
import 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

import 'errors.dart';
import 'serialization.dart';

const typeSafeClassifierActionType = ActionType('typesafe-classifier');

typedef TypeSafeClassifyFn = Future<SystemOneResponse> Function({
  required Object? state,
  required Map<String, Question<Answer>> questions,
  String? model,
  Duration? timeout,
  RetryPolicy? retry,
  Map<String, String>? headers,
});

final _stateSchema = SchemanticType.from<Object?>(
  jsonSchema: const {},
  parse: (json) => json,
);

final class _ClassifierActionResult {
  const _ClassifierActionResult(this.response, this.json);

  final SystemOneResponse response;
  final Map<String, Object?> json;

  Map<String, Object?> toJson() => json;
}

final _resultSchema = SchemanticType.from<_ClassifierActionResult>(
  jsonSchema: const {
    'type': 'object',
    'properties': {
      'model': {'type': 'string'},
      'answers': {'type': 'object'},
      'usage': {'type': 'object'},
      'requestId': {
        'type': ['string', 'null'],
      },
    },
    'required': ['model', 'answers', 'usage', 'requestId'],
  },
  parse: (json) =>
      throw UnsupportedError('Classifier results are output-only.'),
  serialize: (result) => result.toJson(),
);

final class TypeSafeClassifier {
  @internal
  TypeSafeClassifier.internal({
    required String namespace,
    required this.name,
    required Map<String, Question<Answer>> questions,
    required TypeSafeClassifyFn classify,
    this.model,
    this.timeout,
    this.retry,
    Map<String, String>? headers,
  }) : questions = Map.unmodifiable(questions),
       headers = headers == null ? null : Map.unmodifiable(headers) {
    actionName = '$namespace/$name';
    _action = Action(
      name: actionName,
      actionType: typeSafeClassifierActionType,
      inputSchema: _stateSchema,
      outputSchema: _resultSchema,
      metadata: {
        'typesafe': {
          'model': model,
          'questions': serializeQuestions(this.questions),
        },
      },
      fn: (state, context) async {
        context.cancel?.throwIfCancelled();
        try {
          final response = await classify(
            state: state,
            questions: this.questions,
            model: model,
            timeout: timeout,
            retry: retry,
            headers: this.headers,
          );
          return _ClassifierActionResult(
            response,
            serializeSystemOneResponse(response, this.questions),
          );
        } on CancelledException {
          rethrow;
        } catch (error, stackTrace) {
          Error.throwWithStackTrace(
            mapTypeSafeException(
              error,
              stackTrace,
              operation: 'TypeSafe classifier "$name"',
            ),
            stackTrace,
          );
        }
      },
    );
  }

  final String name;
  late final String actionName;
  final Map<String, Question<Answer>> questions;
  final String? model;
  final Duration? timeout;
  final RetryPolicy? retry;
  final Map<String, String>? headers;
  late final Action<Object?, _ClassifierActionResult, void, void> _action;

  @internal
  Action get action => _action;

  Future<SystemOneResponse> call(
    Object? state, {
    CancellationToken? cancel,
  }) async => (await _action(state, cancel: cancel)).response;
}
