import 'dart:convert';

import 'package:genkit_typesafe_ai/src/model_router.dart';
import 'package:http/http.dart' as http;

http.Response systemOneResponse({
  String model = 'jev-latest',
  Map<String, Object?> answers = const {
    'urgent': {'type': 'noul', 'noul': 0.8},
  },
}) => http.Response(
  jsonEncode({
    'model': model,
    'answers': answers,
    'usage': {'input_tokens': 4, 'output_tokens': 1},
  }),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response modelRouteResponse(
  String route, {
  double confidence = 0.9,
  Map<String, double>? probabilities,
}) => systemOneResponse(
  answers: {
    modelRouteQuestionName: {
      'type': 'choice',
      'choice': route,
      'confidence': confidence,
      'probabilities': probabilities ?? {route: 1.0},
    },
  },
);

http.Response autoModeResponse(double probability) => systemOneResponse(
  answers: {
    'isRisky': {'type': 'noul', 'noul': probability},
  },
);

http.Response modelsResponse() => http.Response(
  jsonEncode({
    'models': [
      {
        'name': 'jev-latest',
        'description': 'Latest compatible Jev model',
        'release_date': '2026-09-01',
      },
    ],
  }),
  200,
  headers: {'content-type': 'application/json'},
);
