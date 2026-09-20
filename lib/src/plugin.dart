import 'package:genkit/genkit.dart';
// ignore: implementation_imports
import 'package:genkit/src/core/plugin.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

import 'classifier.dart';
import 'errors.dart';

const defaultTypeSafeNamespace = 'typesafe';
const typeSafeAI = TypeSafePluginHandle();

final class TypeSafePluginHandle {
  const TypeSafePluginHandle();

  TypeSafePlugin call({
    String name = defaultTypeSafeNamespace,
    String? apiKey,
    String? baseUrl,
    String? defaultModel,
    Logger? logger,
    RetryPolicy? retry,
    Duration? timeout,
    Map<String, String>? defaultHeaders,
    http.Client? httpClient,
    bool dangerouslyAllowBrowser = false,
  }) => TypeSafePlugin(
    name: name,
    apiKey: apiKey,
    baseUrl: baseUrl,
    defaultModel: defaultModel,
    logger: logger,
    retry: retry,
    timeout: timeout,
    defaultHeaders: defaultHeaders,
    httpClient: httpClient,
    dangerouslyAllowBrowser: dangerouslyAllowBrowser,
  );
}

final class TypeSafePlugin extends GenkitPlugin {
  factory TypeSafePlugin({
    String name = defaultTypeSafeNamespace,
    String? apiKey,
    String? baseUrl,
    String? defaultModel,
    Logger? logger,
    RetryPolicy? retry,
    Duration? timeout,
    Map<String, String>? defaultHeaders,
    http.Client? httpClient,
    bool dangerouslyAllowBrowser = false,
    @visibleForTesting TypeSafeClient Function()? clientFactory,
  }) {
    if (name.trim().isEmpty || name.contains('/')) {
      throw GenkitException(
        'Plugin name must be non-empty and must not contain "/".',
        status: StatusCodes.INVALID_ARGUMENT,
      );
    }
    return TypeSafePlugin._(
      name: name,
      apiKey: apiKey,
      baseUrl: baseUrl,
      defaultModel: defaultModel,
      logger: logger,
      retry: retry,
      timeout: timeout,
      defaultHeaders: defaultHeaders,
      httpClient: httpClient,
      dangerouslyAllowBrowser: dangerouslyAllowBrowser,
      clientFactory: clientFactory,
    );
  }

  TypeSafePlugin._({
    required this.name,
    required this.apiKey,
    required this.baseUrl,
    required this.defaultModel,
    required this.logger,
    required this.retry,
    required this.timeout,
    Map<String, String>? defaultHeaders,
    required this.httpClient,
    required this.dangerouslyAllowBrowser,
    required this.clientFactory,
  }) : defaultHeaders = Map.unmodifiable(defaultHeaders ?? const {});

  @override
  final String name;
  final String? apiKey;
  final String? baseUrl;
  final String? defaultModel;
  final Logger? logger;
  final RetryPolicy? retry;
  final Duration? timeout;
  final Map<String, String> defaultHeaders;
  final http.Client? httpClient;
  final bool dangerouslyAllowBrowser;

  @visibleForTesting
  final TypeSafeClient Function()? clientFactory;

  TypeSafeClient? _client;
  final _classifiers = <String, TypeSafeClassifier>{};
  var _initialized = false;
  var _closed = false;

  TypeSafeClassifier defineClassifier({
    required String name,
    required Map<String, Question<Answer>> questions,
    String? model,
    Duration? timeout,
    RetryPolicy? retry,
    Map<String, String>? headers,
  }) {
    _ensureOpen();
    if (_initialized) {
      throw GenkitException(
        'TypeSafe classifiers must be defined before plugin initialization.',
        status: StatusCodes.FAILED_PRECONDITION,
      );
    }
    if (name.trim().isEmpty || name.contains('/')) {
      throw GenkitException(
        'Classifier name must be non-empty and must not contain "/".',
        status: StatusCodes.INVALID_ARGUMENT,
      );
    }
    if (questions.isEmpty) {
      throw GenkitException(
        'Classifier "$name" requires at least one question.',
        status: StatusCodes.INVALID_ARGUMENT,
      );
    }
    if (_classifiers.containsKey(name)) {
      throw GenkitException(
        'Classifier "$name" is already defined.',
        status: StatusCodes.ALREADY_EXISTS,
      );
    }
    return _classifiers[name] = TypeSafeClassifier.internal(
      namespace: this.name,
      name: name,
      questions: questions,
      model: model,
      timeout: timeout,
      retry: retry,
      headers: headers,
      classify:
          ({
            required state,
            required questions,
            model,
            timeout,
            retry,
            headers,
          }) => _getClient().systemOne(
            state: state,
            questions: questions,
            model: model,
            timeout: timeout,
            retry: retry,
            headers: headers,
          ),
    );
  }

  Future<List<ModelCard>> listModels() async {
    _ensureOpen();
    try {
      return await _getClient().models.list();
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        mapTypeSafeException(
          error,
          stackTrace,
          operation: 'TypeSafe model discovery',
        ),
        stackTrace,
      );
    }
  }

  @override
  Future<List<Action>> init() async {
    _freezeDefinitions();
    return [for (final classifier in _classifiers.values) classifier.action];
  }

  @override
  Future<List<ActionMetadata>> list() async {
    _freezeDefinitions();
    return [for (final classifier in _classifiers.values) classifier.action];
  }

  @override
  Action? resolve(ActionType actionType, String name) {
    _freezeDefinitions();
    if (actionType != typeSafeClassifierActionType) return null;
    return _classifiers[name]?.action;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _client?.close();
  }

  TypeSafeClient _getClient() {
    _ensureOpen();
    return _client ??=
        clientFactory?.call() ??
        TypeSafeClient(
          apiKey: apiKey,
          baseUrl: baseUrl,
          defaultModel: defaultModel,
          logger: logger,
          retry: retry,
          timeout: timeout,
          defaultHeaders: defaultHeaders,
          httpClient: httpClient,
          dangerouslyAllowBrowser: dangerouslyAllowBrowser,
        );
  }

  void _ensureOpen() {
    if (_closed) {
      throw GenkitException(
        'TypeSafe plugin "$name" is closed.',
        status: StatusCodes.FAILED_PRECONDITION,
      );
    }
  }

  void _freezeDefinitions() {
    _ensureOpen();
    _initialized = true;
  }
}
