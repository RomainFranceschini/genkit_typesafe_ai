/// TypeSafe AI classifier actions and model discovery for Genkit Dart.
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
