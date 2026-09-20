import 'package:genkit/genkit.dart';
import 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

GenkitException mapTypeSafeException(
  Object error,
  StackTrace stackTrace, {
  required String operation,
}) {
  if (error is GenkitException) return error;

  final status = switch (error) {
    ApiTimeoutError() => StatusCodes.DEADLINE_EXCEEDED,
    AuthenticationError() => StatusCodes.UNAUTHENTICATED,
    PermissionDeniedError() => StatusCodes.PERMISSION_DENIED,
    NotFoundError() => StatusCodes.NOT_FOUND,
    RateLimitError() => StatusCodes.RESOURCE_EXHAUSTED,
    BadRequestError() ||
    UnprocessableEntityError() => StatusCodes.INVALID_ARGUMENT,
    ApiResponseValidationError() ||
    InternalServerError() => StatusCodes.INTERNAL,
    ApiConnectionError() => StatusCodes.UNAVAILABLE,
    ApiError(:final statusCode) => StatusCodes.fromHttpStatus(statusCode),
    TypeSafeError() => StatusCodes.INVALID_ARGUMENT,
    _ => StatusCodes.INTERNAL,
  };
  final requestId = error is ApiError ? error.requestId : null;
  final suffix = requestId == null ? '' : ' (request ID: $requestId)';

  return _TypeSafeGenkitException(
    '$operation failed$suffix',
    status: status == StatusCodes.UNKNOWN ? StatusCodes.INTERNAL : status,
    underlyingException: error,
    stackTrace: stackTrace,
  );
}

class _TypeSafeGenkitException extends GenkitException {
  _TypeSafeGenkitException(
    super.message, {
    required super.status,
    required super.underlyingException,
    required super.stackTrace,
  });

  @override
  String toString() =>
      'GenkitException: $message (Status: ${status.name}, Code: ${status.value})';
}
