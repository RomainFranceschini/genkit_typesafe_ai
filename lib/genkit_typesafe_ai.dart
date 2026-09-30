/// Typed TypeSafe AI classifiers, model routing, and tool-risk guards for Genkit.
///
/// Defines reusable classifier actions and generation middleware, not a
/// generative model provider. The TypeSafe SDK's question, answer, and error
/// types are re-exported for use with these actions.
library;

export 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

export 'src/auto_mode.dart' show TypeSafeAutoMode;
export 'src/classifier.dart'
    show TypeSafeClassifier, typeSafeClassifierActionType;
export 'src/model_router.dart'
    show TypeSafeModelRoute, TypeSafeModelRouter, TypeSafeRouteDecision;
export 'src/plugin.dart'
    show
        TypeSafePlugin,
        TypeSafePluginHandle,
        defaultTypeSafeNamespace,
        typeSafeAI;
