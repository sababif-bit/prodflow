import { HttpErrorResponse } from '@angular/common/http';
import { ApiError, describeError, toApiError } from './api-error';

const http = (status: number, body: unknown = null) =>
  new HttpErrorResponse({ status, error: body });

describe('toApiError', () => {
  it.each([
    [0, 'network'],
    [400, 'validation'],
    [401, 'unauthenticated'],
    [403, 'forbidden'],
    [404, 'notFound'],
    [409, 'conflict'],
    [500, 'server'],
    [503, 'server'],
    [418, 'unknown'],
  ])('HTTP %i becomes "%s"', (status, kind) => {
    expect(toApiError(http(status)).kind).toBe(kind);
  });

  it('reads the RFC 7807 detail and title of the backend (GlobalExceptionHandler)', () => {
    const error = toApiError(
      http(409, {
        title: 'Conflict',
        status: 409,
        detail: 'Only RELEASED orders can be completed (order is DONE)',
      }),
    );
    expect(error.status).toBe(409);
    expect(error.detail).toBe('Only RELEASED orders can be completed (order is DONE)');
    expect(error.title).toBe('Conflict');
  });

  it('copes with empty bodies (Spring Security answers 401/403 without a body)', () => {
    expect(toApiError(http(403, null)).detail).toBe('');
    expect(toApiError(http(401, '')).kind).toBe('unauthenticated');
  });

  it('keeps an ApiError unchanged and wraps anything else', () => {
    const original = new ApiError(409, 'conflict', 'x');
    expect(toApiError(original)).toBe(original);
    expect(toApiError(new Error('boom')).detail).toBe('boom');
    expect(toApiError('text').kind).toBe('unknown');
  });
});

describe('describeError (German user messages)', () => {
  it('403: tells the user their role may not do this', () => {
    expect(describeError(http(403))).toEqual({
      title: 'Keine Berechtigung',
      detail: 'Ihre Rolle darf diese Aktion nicht ausführen.',
    });
  });

  it('409: shows the precise reason from the server', () => {
    expect(describeError(http(409, { detail: 'Not enough SC-M8' }))).toEqual({
      title: 'Aktion nicht möglich',
      detail: 'Not enough SC-M8',
    });
  });

  it('400: shows the validation text', () => {
    expect(describeError(http(400, { detail: 'quantity: must be greater than 0' })).title).toBe(
      'Eingabe ungültig',
    );
  });

  it('network failure and server failure have their own wording', () => {
    expect(describeError(http(0)).title).toBe('Keine Verbindung');
    expect(describeError(http(500)).title).toBe('Serverfehler');
  });

  it('never leaks internals of an unknown error object into the title', () => {
    expect(describeError(new Error('NullPointerException at Foo.java:12')).title).toBe(
      'Unerwarteter Fehler',
    );
  });
});
