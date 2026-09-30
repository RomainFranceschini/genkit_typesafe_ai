import 'package:genkit/plugin.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

import 'auto_mode.dart';
import 'classifier.dart';
import 'errors.dart';
import 'model_router.dart';

/// The default namespace for TypeSafe classifier actions and middleware.
const defaultTypeSafeNamespace = 'typesafe';

/// The callable factory for a TypeSafe plugin.
///
/// Define classifiers and middleware before registering the plugin with Genkit,
/// and call [TypeSafePlugin.close] when finished.
const typeSafeAI = TypeSafePluginHandle();

/// A callable factory for configuring a TypeSafe plugin.
final class TypeSafePluginHandle {
  /// Creates a reusable plugin factory.
  const TypeSafePluginHandle();

  /// Creates a plugin with lazily initialized TypeSafe client options.
  ///
  /// When [apiKey] is omitted, the SDK reads `TYPESAFE_API_KEY`. Browser use
  /// requires [dangerouslyAllowBrowser] and exposes the key to the client.
  /// The owner of an injected [httpClient] remains responsible for closing it.
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

/// A Genkit plugin providing TypeSafe classifier actions and middleware.
///
/// Definitions must be added before Genkit initializes or lists the plugin.
/// The TypeSafe client is created on first use, not during registration.
/// Call [close] when finished, separately from shutting down Genkit.
final class TypeSafePlugin extends GenkitPlugin {
  /// Creates a plugin with a distinct action and middleware namespace.
  ///
  /// The [name] must be nonblank and must not contain `/`. When [apiKey] is
  /// omitted, the SDK reads `TYPESAFE_API_KEY`. Client-wide options can be
  /// overridden by individual classifier or middleware definitions.
  /// An injected [httpClient] is not closed by this plugin.
  ///
  /// Browser use requires [dangerouslyAllowBrowser] and exposes credentials;
  /// prefer a server-side proxy for untrusted clients. The [clientFactory]
  /// parameter is a test seam, not an application configuration option.
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

  /// The explicit API key, or `null` to use the SDK's environment lookup.
  final String? apiKey;

  /// The API base URL override, or `null` to use the SDK default.
  final String? baseUrl;

  /// The default classifier model, or `null` to use the SDK default.
  final String? defaultModel;

  /// The logger override, or `null` to use the SDK default.
  final Logger? logger;

  /// The client-wide retry policy override.
  final RetryPolicy? retry;

  /// The client-wide request timeout override.
  final Duration? timeout;

  /// The immutable snapshot of client-wide request headers.
  final Map<String, String> defaultHeaders;

  /// The caller-owned HTTP client, or `null` for an SDK-owned client.
  final http.Client? httpClient;

  /// Whether client-side API key use is explicitly permitted in browsers.
  final bool dangerouslyAllowBrowser;

  /// The test-only factory used instead of creating an SDK client.
  @visibleForTesting
  final TypeSafeClient Function()? clientFactory;

  TypeSafeClient? _client;
  final _classifiers = <String, TypeSafeClassifier>{};
  final _modelRouters = <String, TypeSafeModelRouter>{};
  final _autoModes = <String, TypeSafeAutoMode>{};
  var _initialized = false;
  var _closed = false;

  /// Defines a named classifier with fixed questions and request options.
  ///
  /// Call the returned classifier with new state for each request and retrieve
  /// typed answers using the original question objects. The [name] must be
  /// unique, nonblank, and contain no `/`; [questions] must not be empty.
  /// Definitions cannot be added after plugin initialization or closure.
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

  /// Defines middleware that selects a registered Genkit model through TypeSafe.
  ///
  /// Pass the returned router to Genkit's `use` generation option. It classifies
  /// the latest user message once per generation run and retains the selected
  /// model and its reference configuration across tool-loop turns. Only one
  /// distinct TypeSafe router is permitted in a generation run.
  ///
  /// The [instructions], route criteria, and model configs must be
  /// JSON-encodable and are snapshotted at definition time. [routes] must be
  /// nonempty. [classifierModel] selects the TypeSafe classifier, not the
  /// downstream Genkit model. Classification errors fail the generation;
  /// low-confidence answers still select a route, without a fallback.
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

  /// Defines middleware that checks risk before each listed tool call.
  ///
  /// Pass the returned reference to Genkit's `use` generation option. [tools]
  /// are matched by their last path segment, as Genkit resolves tool requests.
  /// Unlisted tools and direct tool action invocations are not guarded.
  ///
  /// A risk probability below `0.5` permits execution; otherwise a refusal
  /// result replaces the call and the model can continue. Classification errors
  /// fail the generation without executing the tool. This is probabilistic
  /// filtering, not a security boundary or a human approval workflow.
  ///
  /// Tool arguments and up to 30 conversation messages are sent to TypeSafe
  /// and may appear in classifier traces. Only explicit user messages authorize
  /// execution under the default [instructions]. [classifierModel] selects the
  /// TypeSafe classifier model. Define this middleware before initialization.
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

    if (instructions.trim().isEmpty) {
      throw GenkitException(
        'Auto Mode "$name" requires nonblank instructions.',
        status: StatusCodes.INVALID_ARGUMENT,
      );
    }
    final guardedTools = List<String>.unmodifiable(normalizedTools);
    final normalizedCriteria =
        snapshotJson(criteria.toJson(), field: 'Auto Mode "$name" criteria')!
            as Map<String, dynamic>;
    final question = Noul(
      instructions: instructions,
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
        'tools': guardedTools,
      },
    );
    final autoMode = TypeSafeAutoMode.internal(
      name: '${this.name}/$name',
      localName: name,
      tools: guardedTools,
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

  /// Fetches available TypeSafe classifier models using the shared lazy client.
  ///
  /// SDK failures are mapped to [GenkitException] with the original error
  /// retained as the underlying exception. This does not register Genkit models.
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

  /// Closes the SDK client and prevents further definitions or requests.
  ///
  /// Repeated calls do nothing. An injected [httpClient] remains caller-owned;
  /// Genkit must be shut down separately.
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
