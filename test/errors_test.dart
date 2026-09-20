import 'package:genkit/genkit.dart';
import 'package:genkit_typesafe_ai/src/errors.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_sdk/typesafe_ai_sdk.dart';

void main() {
  group('mapTypeSafeException', () {
    final cases = <(TypeSafeError, StatusCodes)>[
      (TypeSafeError('bad config'), StatusCodes.INVALID_ARGUMENT),
      (
        BadRequestError(statusCode: 400, body: null, headers: {}),
        StatusCodes.INVALID_ARGUMENT,
      ),
      (
        UnprocessableEntityError(statusCode: 422, body: null, headers: {}),
        StatusCodes.INVALID_ARGUMENT,
      ),
      (
        AuthenticationError(statusCode: 401, body: null, headers: {}),
        StatusCodes.UNAUTHENTICATED,
      ),
      (
        PermissionDeniedError(statusCode: 403, body: null, headers: {}),
        StatusCodes.PERMISSION_DENIED,
      ),
      (
        NotFoundError(statusCode: 404, body: null, headers: {}),
        StatusCodes.NOT_FOUND,
      ),
      (
        RateLimitError(statusCode: 429, body: null, headers: {}),
        StatusCodes.RESOURCE_EXHAUSTED,
      ),
      (
        ApiTimeoutError(const Duration(seconds: 2)),
        StatusCodes.DEADLINE_EXCEEDED,
      ),
      (ApiConnectionError(), StatusCodes.UNAVAILABLE),
      (ApiResponseValidationError('bad payload'), StatusCodes.INTERNAL),
      (
        InternalServerError(statusCode: 500, body: null, headers: {}),
        StatusCodes.INTERNAL,
      ),
    ];

    for (final (error, status) in cases) {
      test('${error.runtimeType} maps to ${status.name}', () {
        final stack = StackTrace.current;
        final mapped = mapTypeSafeException(
          error,
          stack,
          operation: 'Classifier "triage"',
        );

        expect(mapped.status, status);
        expect(mapped.underlyingException, same(error));
        expect(mapped.stackTrace, same(stack));
        expect(mapped.message, contains('Classifier "triage"'));
      });
    }

    test('includes an API request ID in the message', () {
      final mapped = mapTypeSafeException(
        ApiError(
          statusCode: 409,
          body: null,
          headers: {'x-typesafe-request-id': 'req_123'},
        ),
        StackTrace.current,
        operation: 'Classifier "triage"',
      );

      expect(mapped.message, contains('request ID: req_123'));
    });

    test('maps unknown errors to INTERNAL', () {
      final error = StateError('unexpected');
      final mapped = mapTypeSafeException(
        error,
        StackTrace.current,
        operation: 'Classifier "triage"',
      );

      expect(mapped.status, StatusCodes.INTERNAL);
      expect(mapped.underlyingException, same(error));
    });

    test('returns an existing GenkitException unchanged', () {
      final error = GenkitException(
        'already normalized',
        status: StatusCodes.UNAVAILABLE,
      );

      expect(
        mapTypeSafeException(
          error,
          StackTrace.current,
          operation: 'Classifier "triage"',
        ),
        same(error),
      );
    });

    test('does not expose authorization headers', () {
      final mapped = mapTypeSafeException(
        ApiError(
          statusCode: 500,
          body: null,
          headers: {'authorization': 'Bearer secret-token'},
        ),
        StackTrace.current,
        operation: 'Classifier "triage"',
      );

      expect(mapped.toString(), isNot(contains('secret-token')));
    });

    test('does not expose response-body or transport secrets', () {
      final mapped = mapTypeSafeException(
        ApiError(
          statusCode: 500,
          body: {'message': 'response-body-secret'},
          headers: {
            'authorization': 'Bearer authorization-secret',
            'cookie': 'session=cookie-secret',
            'x-upstream-debug': 'transport-secret',
          },
        ),
        StackTrace.current,
        operation: 'Classifier "triage"',
      );

      final rendered = '${mapped.message}\n${mapped.toString()}';
      expect(rendered, isNot(contains('response-body-secret')));
      expect(rendered, isNot(contains('authorization-secret')));
      expect(rendered, isNot(contains('cookie-secret')));
      expect(rendered, isNot(contains('transport-secret')));
    });
  });
}
