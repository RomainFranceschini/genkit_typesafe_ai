import 'package:genkit/plugin.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

import 'auto_mode.dart';
import 'classifier.dart';
import 'errors.dart';
import 'model_router.dart';

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
  final _modelRouters = <String, TypeSafeModelRouter>{};
  final _autoModes = <String, TypeSafeAutoMode>{};
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
    _ensureDefinitionsOpen();
    _validateDefinitionName(name);
    if (questions.isEmpty) {
      throw GenkitException(
        'Classifier "$name" requires at least one question.',
        status: StatusCodes.INVALID_ARGUMENT,
      );
    }
    _ensureNameAvailable(name);
    final classifier = _buildClassifier(
      name: name,
      questions: questions,
      model: model,
      timeout: timeout,
      retry: retry,
      headers: headers,
    );
    _classifiers[name] = classifier;
    return classifier;
  }

  TypeSafeModelRouter defineModelRouter({
    required String name,
    required Object instructions,
    required Map<String, TypeSafeModelRoute> routes,
    String? classifierModel,
    Duration? timeout,
    RetryPolicy? retry,
    Map<String, String>? headers,
  }) {
    _ensureDefinitionsOpen();
    _validateDefinitionName(name);
    _ensureNameAvailable(name);
    if (routes.isEmpty) {
      throw GenkitException(
        'Model router "$name" requires at least one route.',
        status: StatusCodes.INVALID_ARGUMENT,
      );
    }

    final normalizedInstructions = snapshotJson(
      instructions,
      field: 'Model router "$name" instructions',
    );
    if (normalizedInstructions == null) {
      throw GenkitException(
        'Model router "$name" instructions must not encode to null.',
        status: StatusCodes.INVALID_ARGUMENT,
      );
    }

    final normalizedDefinitions = <String, TypeSafeModelRoute>{};
    final resolved = <String, ResolvedTypeSafeModelRoute>{};
    for (final entry in routes.entries) {
      final label = entry.key;
      final route = entry.value;
      if (label.trim().isEmpty) {
        throw GenkitException(
          'Model router "$name" route labels must not be blank.',
          status: StatusCodes.INVALID_ARGUMENT,
        );
      }
      final modelName = route.model.name;
      if (modelName.trim().isEmpty) {
        throw GenkitException(
          'Model router "$name" route "$label" requires a model name.',
          status: StatusCodes.INVALID_ARGUMENT,
        );
      }
      final criteria = snapshotJson(
        route.criteria,
        field: 'Model router "$name" route "$label" criteria',
      );
      final config = snapshotModelConfig(
        route.model.config,
        field: 'Model router "$name" route "$label" model config',
      );
      final definition = TypeSafeModelRoute(
        model: modelRef<dynamic>(modelName, config: config),
        criteria: criteria,
      );
      normalizedDefinitions[label] = definition;
      resolved[label] = ResolvedTypeSafeModelRoute(
        definition: definition,
        modelName: modelName,
        config: config,
      );
    }

    final question = Choice<String>({
      for (final entry in normalizedDefinitions.entries)
        entry.key: entry.value.criteria,
    }, instructions: normalizedInstructions);
    final classifier = _buildClassifier(
      name: name,
      questions: {modelRouteQuestionName: question},
      model: classifierModel,
      timeout: timeout,
      retry: retry,
      headers: headers,
      typesafeMetadata: {
        'kind': 'model-router',
        'router': '${this.name}/$name',
        'routes': {
          for (final entry in resolved.entries)
            entry.key: {'model': entry.value.modelName},
        },
      },
    );
    final router = TypeSafeModelRouter.internal(
      localName: name,
      name: '${this.name}/$name',
      routes: Map.unmodifiable(normalizedDefinitions),
      resolvedRoutes: Map.unmodifiable(resolved),
      question: question,
      classifier: classifier,
    );

    _classifiers[name] = classifier;
    _modelRouters[name] = router;
    return router;
  }

  TypeSafeAutoMode defineAutoMode({
    required String name,
    required List<String> tools,
    String instructions = defaultAutoModeInstructions,
    NoulCriteria criteria = defaultAutoModeCriteria,
    String? classifierModel,
    Duration? timeout,
    RetryPolicy? retry,
    Map<String, String>? headers,
  }) {
    _ensureDefinitionsOpen();
    _validateDefinitionName(name);
    _ensureNameAvailable(name);
    if (tools.isEmpty) {
      throw GenkitException(
        'Auto Mode "$name" requires at least one tool.',
        status: StatusCodes.INVALID_ARGUMENT,
      );
    }
    final normalizedTools = <String>[];
    for (final tool in tools) {
      final normalized = tool.trim();
      if (normalized.isEmpty || normalizedTools.contains(normalized)) {
        throw GenkitException(
          'Auto Mode "$name" requires distinct, nonblank tool names.',
          status: StatusCodes.INVALID_ARGUMENT,
        );
      }
      normalizedTools.add(normalized);
    }

    final normalizedInstructions = snapshotJson(
      instructions,
      field: 'Auto Mode "$name" instructions',
    ) as String;
    final normalizedCriteria =
        snapshotJson(criteria.toJson(), field: 'Auto Mode "$name" criteria')!
            as Map<String, dynamic>;
    final question = Noul(
      instructions: normalizedInstructions,
      criteria: NoulCriteria(
        whenTrue: normalizedCriteria['true'],
        whenFalse: normalizedCriteria['false'],
      ),
    );
    final classifier = _buildClassifier(
      name: name,
      questions: {autoModeQuestionName: question},
      model: classifierModel,
      timeout: timeout,
      retry: retry,
      headers: headers,
      typesafeMetadata: {
        'kind': 'auto-mode',
        'middleware': '${this.name}/$name',
        'tools': List<String>.unmodifiable(normalizedTools),
      },
    );
    final autoMode = TypeSafeAutoMode.internal(
      name: '${this.name}/$name',
      localName: name,
      tools: normalizedTools,
      question: question,
      classifier: classifier,
    );
    _classifiers[name] = classifier;
    _autoModes[name] = autoMode;
    return autoMode;
  }

  TypeSafeClassifier _buildClassifier({
    required String name,
    required Map<String, Question<Answer>> questions,
    String? model,
    Duration? timeout,
    RetryPolicy? retry,
    Map<String, String>? headers,
    Map<String, Object?> typesafeMetadata = const {},
  }) => TypeSafeClassifier.internal(
    namespace: this.name,
    name: name,
    questions: questions,
    model: model,
    timeout: timeout,
    retry: retry,
    headers: headers,
    typesafeMetadata: typesafeMetadata,
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

  @override
  List<GenerateMiddlewareDef> middleware() {
    _freezeDefinitions();
    return [
      for (final router in _modelRouters.values) router.middlewareDefinition,
      for (final autoMode in _autoModes.values) autoMode.middlewareDefinition,
    ];
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

  void _ensureDefinitionsOpen() {
    _ensureOpen();
    if (_initialized) {
      throw GenkitException(
        'TypeSafe definitions must be added before plugin initialization.',
        status: StatusCodes.FAILED_PRECONDITION,
      );
    }
  }

  void _validateDefinitionName(String name) {
    if (name.trim().isEmpty || name.contains('/')) {
      throw GenkitException(
        'Definition name must be non-empty and must not contain "/".',
        status: StatusCodes.INVALID_ARGUMENT,
      );
    }
  }

  void _ensureNameAvailable(String name) {
    if (_classifiers.containsKey(name) || _modelRouters.containsKey(name)) {
      throw GenkitException(
        'TypeSafe definition "$name" is already defined.',
        status: StatusCodes.ALREADY_EXISTS,
      );
    }
  }

  void _freezeDefinitions() {
    _ensureOpen();
    _initialized = true;
  }
}
