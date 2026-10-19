import { HttpErrorResponse } from '@angular/common/http';
import { ProblemDetail } from '../../shared/models/api.models';

export type ApiErrorKind =
  | 'unauthenticated'
  | 'forbidden'
  | 'notFound'
  | 'validation'
  | 'conflict'
  | 'network'
  | 'server'
  | 'unknown';

/** Every failed backend call reaches the application as an ApiError (see error.interceptor.ts). */
export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly kind: ApiErrorKind,
    readonly detail: string,
    readonly title?: string,
  ) {
    super(detail || title || `HTTP ${status}`);
    this.name = 'ApiError';
  }
}

function kindOf(status: number): ApiErrorKind {
  switch (status) {
    case 0:
      return 'network';
    case 400:
      return 'validation';
    case 401:
      return 'unauthenticated';
    case 403:
      return 'forbidden';
    case 404:
      return 'notFound';
    case 409:
      return 'conflict';
    default:
      return status >= 500 ? 'server' : 'unknown';
  }
}

/** Turns anything thrown by HttpClient (RFC 7807 bodies from GlobalExceptionHandler, empty 401/403 bodies, network failures) into an ApiError. */
export function toApiError(error: unknown): ApiError {
  if (error instanceof ApiError) {
    return error;
  }
  if (error instanceof HttpErrorResponse) {
    const body = (
      typeof error.error === 'object' && error.error !== null ? error.error : {}
    ) as ProblemDetail;
    return new ApiError(error.status, kindOf(error.status), body.detail ?? '', body.title);
  }
  return new ApiError(-1, 'unknown', error instanceof Error ? error.message : String(error));
}

export interface ErrorMessage {
  title: string;
  detail: string;
}

/**
 * German user-facing wording. The backend's own detail text (English business-rule messages) is shown as the reason,
 * because it is the precise, trustworthy explanation (e.g. "Only RELEASED orders can be completed").
 */
export function describeError(error: unknown): ErrorMessage {
  const e = toApiError(error);
  switch (e.kind) {
    case 'forbidden':
      return {
        title: 'Keine Berechtigung',
        detail: 'Ihre Rolle darf diese Aktion nicht ausführen.',
      };
    case 'unauthenticated':
      return { title: 'Sitzung abgelaufen', detail: 'Bitte melden Sie sich erneut an.' };
    case 'notFound':
      return { title: 'Nicht gefunden', detail: e.detail || 'Der Eintrag existiert nicht (mehr).' };
    case 'validation':
      return { title: 'Eingabe ungültig', detail: e.detail || 'Bitte prüfen Sie Ihre Eingaben.' };
    case 'conflict':
      return {
        title: 'Aktion nicht möglich',
        detail: e.detail || 'Der Zustand erlaubt diese Aktion nicht.',
      };
    case 'network':
      return {
        title: 'Keine Verbindung',
        detail: 'Der Server ist nicht erreichbar. Bitte Verbindung prüfen und erneut versuchen.',
      };
    case 'server':
      return {
        title: 'Serverfehler',
        detail: 'Es ist ein Fehler aufgetreten. Bitte später erneut versuchen.',
      };
    default:
      return {
        title: 'Unerwarteter Fehler',
        detail: e.detail || 'Die Aktion konnte nicht ausgeführt werden.',
      };
  }
}
