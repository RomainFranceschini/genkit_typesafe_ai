import 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

Map<String, Object?> serializeQuestions(
  Map<String, Question<Answer>> questions,
) => {for (final entry in questions.entries) entry.key: entry.value.toJson()};

Map<String, Object?> serializeSystemOneResponse(
  SystemOneResponse response,
  Map<String, Question<Answer>> questions,
) => {
  'model': response.model,
  'answers': {
    for (final entry in response.answers.entries)
      entry.key: _serializeAnswer(entry.value, questions[entry.key]),
  },
  'usage': {
    'inputTokens': response.usage.inputTokens,
    'outputTokens': response.usage.outputTokens,
  },
  'requestId': response.requestId,
};

Map<String, Object?> _serializeAnswer(
  Answer answer,
  Question<Answer>? question,
) {
  return switch (answer) {
    NoulAnswer(:final noul) => {'type': 'noul', 'noul': noul},
    ChoiceAnswer(:final choice, :final confidence, :final probabilities) => {
      'type': 'choice',
      'choice': _choiceLabel(question, choice),
      'confidence': confidence,
      'probabilities': {
        for (final entry in probabilities.entries)
          _choiceLabel(question, entry.key): entry.value,
      },
    },
    ScoreAnswer(
      :final score,
      :final confidence,
      :final legend,
      :final probabilities,
      :final scale,
    ) =>
      {
        'type': 'score',
        'score': score,
        'confidence': confidence,
        'legend': {
          for (var index = 0; index < scale.length; index++)
            '$index': legend[scale[index]],
        },
        'probabilities': {
          for (var index = 0; index < scale.length; index++)
            '$index': probabilities[scale[index]],
        },
        'scale': [for (var index = 0; index < scale.length; index++) index],
      },
  };
}

String _choiceLabel(Question<Answer>? question, Object label) {
  if (question is! Choice) {
    throw StateError('A ChoiceAnswer has no matching Choice question.');
  }
  return (question as dynamic).encodeLabel(label) as String;
}
