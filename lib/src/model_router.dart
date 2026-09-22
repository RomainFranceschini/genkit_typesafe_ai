import 'dart:convert';

import 'package:genkit/plugin.dart';
import 'package:meta/meta.dart';
import 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

import 'classifier.dart';

const modelRouteQuestionName = 'modelRoute';
const _routeDecisionsContextKey = 'genkit_typesafe_ai/model-router-decisions';

final class TypeSafeModelRoute {
  const TypeSafeModelRoute({required this.model, required this.criteria});

  final ModelRef<dynamic> model;
  final Object? criteria;
}

final class TypeSafeRouteDecision {
  const TypeSafeRouteDecision({
    required this.routerName,
    required this.route,
    required this.modelName,
    required this.answer,
  });

  final String routerName;
  final String route;
  final String modelName;
  final ChoiceAnswer<String> answer;

  double get confidence => answer.confidence;
  Map<String, double> get probabilities => answer.probabilities;

  Map<String, Object?> toJson() => {
    'router': routerName,
    'route': route,
    'model': modelName,
    'confidence': confidence,
    'probabilities': probabilities,
  };
}

@immutable
final class ResolvedTypeSafeModelRoute {
  const ResolvedTypeSafeModelRoute({
    required this.definition,
    required this.modelName,
    required this.config,
  });

  final TypeSafeModelRoute definition;
  final String modelName;
  final Map<String, dynamic>? config;
}

@internal
Object? snapshotJson(Object? value, {required String field}) {
  try {
    return _freezeJson(jsonDecode(jsonEncode(value)));
  } on Object catch (error, stackTrace) {
    throw GenkitException(
      '$field must be JSON-encodable.',
      status: StatusCodes.INVALID_ARGUMENT,
      underlyingException: error,
      stackTrace: stackTrace,
    );
  }
}

@internal
Map<String, dynamic>? snapshotModelConfig(
  Object? value, {
  required String field,
}) {
  if (value == null) return null;
  final snapshot = snapshotJson(value, field: field);
  if (snapshot is! Map<String, dynamic>) {
    throw GenkitException(
      '$field must encode to a JSON object.',
      status: StatusCodes.INVALID_ARGUMENT,
    );
  }
  return snapshot;
}

Object? _freezeJson(Object? value) => switch (value) {
  Map<String, dynamic> map => Map<String, dynamic>.unmodifiable({
    for (final entry in map.entries) entry.key: _freezeJson(entry.value),
  }),
  List<dynamic> list => List<dynamic>.unmodifiable(list.map(_freezeJson)),
  _ => value,
};

final class TypeSafeModelRouter implements GenerateMiddlewareRef<Object?> {
  @internal
  TypeSafeModelRouter.internal({
    required this.localName,
    required this.name,
    required this.routes,
    required this.resolvedRoutes,
    required this.question,
    required this.classifier,
  });

  final String localName;

  @override
  final String name;

  @override
  Object? get config => null;

  final Map<String, TypeSafeModelRoute> routes;

  @internal
  final Map<String, ResolvedTypeSafeModelRoute> resolvedRoutes;

  @internal
  final Choice<String> question;

  @internal
  final TypeSafeClassifier classifier;

  TypeSafeRouteDecision? decisionFromContext(Map<String, dynamic>? context) {
    final decisions = context?[_routeDecisionsContextKey];
    if (decisions is! Map) return null;
    final decision = decisions[name];
    return decision is TypeSafeRouteDecision ? decision : null;
  }

  @internal
  GenerateMiddlewareDef<Object?> get middlewareDefinition =>
      defineMiddleware<Object?>(
        name: name,
        create: (config, context) => _TypeSafeModelRouterMiddleware(this),
      );
}

final class _TypeSafeModelRouterMiddleware extends GenerateMiddleware {
  _TypeSafeModelRouterMiddleware(this.router);

  final TypeSafeModelRouter router;

  @override
  Future<GenerateResponseHelper> generate(
    GenerateTurnState envelope,
    ActionFnArg<ModelResponseChunk, GenerateActionOptions, void> ctx,
    Future<GenerateResponseHelper> Function(
      GenerateTurnState envelope,
      ActionFnArg<ModelResponseChunk, GenerateActionOptions, void> ctx,
    )
    next,
  ) async {
    final latestUser = _latestUserMessage(envelope.request.messages);
    if (latestUser == null) {
      throw GenkitException(
        'TypeSafe model router "${router.localName}" requires a user message.',
        status: StatusCodes.INVALID_ARGUMENT,
      );
    }

    final response = await router.classifier(latestUser, cancel: ctx.cancel);
    final answer = response.get(router.question);
    final route = router.resolvedRoutes[answer.choice];
    if (route == null) {
      throw GenkitException(
        'TypeSafe model router "${router.localName}" selected an unknown route.',
        status: StatusCodes.INTERNAL,
      );
    }
    final decision = TypeSafeRouteDecision(
      routerName: router.name,
      route: answer.choice,
      modelName: route.modelName,
      answer: answer,
    );
    return next(
      _routeEnvelope(envelope, route),
      _withRouteDecision(ctx, router, decision),
    );
  }
}

Message? _latestUserMessage(List<Message> messages) {
  for (final message in messages.reversed) {
    if (message.role == Role.user) return message;
  }
  return null;
}

GenerateTurnState _routeEnvelope(
  GenerateTurnState envelope,
  ResolvedTypeSafeModelRoute route,
) => (
  request: GenerateActionOptions.fromJson({
    ...envelope.request.toJson(),
    'model': route.modelName,
    'config': route.config,
  }),
  currentTurn: envelope.currentTurn,
  messageIndex: envelope.messageIndex,
);

ActionFnArg<ModelResponseChunk, GenerateActionOptions, void> _withRouteDecision(
  ActionFnArg<ModelResponseChunk, GenerateActionOptions, void> context,
  TypeSafeModelRouter router,
  TypeSafeRouteDecision decision,
) {
  final copiedContext = <String, dynamic>{...?context.context};
  final existingDecisions = copiedContext[_routeDecisionsContextKey];
  final decisions = <String, dynamic>{
    if (existingDecisions is Map)
      for (final entry in existingDecisions.entries)
        if (entry.key is String) entry.key as String: entry.value,
    router.name: decision,
  };
  copiedContext[_routeDecisionsContextKey] = decisions;

  return (
    streamingRequested: context.streamingRequested,
    sendChunk: context.sendChunk,
    context: copiedContext,
    inputStream: context.inputStream,
    init: null,
    cancel: context.cancel,
  );
}
