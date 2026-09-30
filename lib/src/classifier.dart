import 'package:genkit/genkit.dart';
import 'package:meta/meta.dart';
import 'package:schemantic/schemantic.dart';
import 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

import 'errors.dart';
import 'serialization.dart';

/// The Genkit action type used to register TypeSafe classifiers.
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

/// A reusable Genkit action with fixed TypeSafe questions and typed answers.
///
/// Create instances through the plugin's `defineClassifier` method and retrieve
/// answers with `response.get(question)` using the original question object.
final class TypeSafeClassifier {
  @internal
  TypeSafeClassifier.internal({
    required String namespace,
    required this.name,
    required Map<String, Question<Answer>> questions,
    required TypeSafeClassifyFn classify,
    Map<String, Object?> typesafeMetadata = const {},
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
          ...typesafeMetadata,
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

  /// The local definition name, without the plugin namespace.
  final String name;

  /// The fully qualified Genkit action name.
  late final String actionName;

  /// The immutable mapping of wire names to typed question handles.
  final Map<String, Question<Answer>> questions;

  /// The classifier model override, or `null` to use the client default.
  final String? model;

  /// The request timeout override.
  final Duration? timeout;

  /// The request retry policy override.
  final RetryPolicy? retry;

  /// The immutable request-header overrides, if supplied.
  final Map<String, String>? headers;
  late final Action<Object?, _ClassifierActionResult, void, void> _action;

  @internal
  Action get action => _action;

  /// Classifies JSON-encodable state and returns typed TypeSafe answers.
  ///
  /// The request runs as a Genkit action and may expose [state] in traces.
  /// SDK failures are mapped to [GenkitException]. A supplied [cancel] token
  /// is checked before dispatch; it does not abort an in-flight SDK request.
  Future<SystemOneResponse> call(
    Object? state, {
    CancellationToken? cancel,
  }) async => (await _action(state, cancel: cancel)).response;
}
