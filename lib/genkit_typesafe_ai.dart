/// TypeSafe AI classifier actions and model discovery for Genkit Dart.
library;

export 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

export 'src/classifier.dart'
    show TypeSafeClassifier, typeSafeClassifierActionType;
export 'src/plugin.dart'
    show
        TypeSafePlugin,
        TypeSafePluginHandle,
        defaultTypeSafeNamespace,
        typeSafeAI;
