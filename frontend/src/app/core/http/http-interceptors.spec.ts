import { HttpClient, provideHttpClient, withInterceptors } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { firstValueFrom } from 'rxjs';
import { vi } from 'vitest';
import { AuthService } from '../auth/auth.service';
import { ApiError } from './api-error';
import {
  authInterceptor,
  errorInterceptor,
  isApiUrl,
  resetReLoginGuard,
} from './http-interceptors';

describe('HTTP interceptors', () => {
  let http: HttpClient;
  let backend: HttpTestingController;
  const auth = { getToken: vi.fn(), login: vi.fn() };

  beforeEach(() => {
    resetReLoginGuard();
    auth.getToken.mockReset().mockResolvedValue('the-token');
    auth.login.mockReset().mockResolvedValue(undefined);
    TestBed.configureTestingModule({
      providers: [
        { provide: AuthService, useValue: auth },
        provideHttpClient(withInterceptors([authInterceptor, errorInterceptor])),
        provideHttpClientTesting(),
      ],
    });
    http = TestBed.inject(HttpClient);
    backend = TestBed.inject(HttpTestingController);
  });

  afterEach(() => backend.verify());

  it('recognizes only relative /api URLs as the application API', () => {
    expect(isApiUrl('/api/items')).toBe(true);
    expect(isApiUrl('/api')).toBe(true);
    expect(isApiUrl('/version')).toBe(false);
    expect(isApiUrl('/apis/items')).toBe(false);
    expect(isApiUrl('https://evil.example/api/items')).toBe(false);
    expect(isApiUrl('//evil.example/api/items')).toBe(false);
  });

  it('adds the bearer token to API calls', async () => {
    const result = firstValueFrom(http.get('/api/items'));
    const request = await vi.waitFor(() => backend.expectOne('/api/items'));
    expect(request.request.headers.get('Authorization')).toBe('Bearer the-token');
    request.flush([]);
    await result;
  });

  it('never sends the token to another origin or to public endpoints', async () => {
    const other = firstValueFrom(http.get('https://other.example/api/items'));
    const otherRequest = await vi.waitFor(() =>
      backend.expectOne('https://other.example/api/items'),
    );
    expect(otherRequest.request.headers.has('Authorization')).toBe(false);
    otherRequest.flush([]);
    await other;

    const version = firstValueFrom(http.get('/version'));
    const versionRequest = backend.expectOne('/version');
    expect(versionRequest.request.headers.has('Authorization')).toBe(false);
    versionRequest.flush({ revision: 'abc1234' });
    await version;
    expect(auth.getToken).not.toHaveBeenCalled();
  });

  it('sends the call without a header when no token is available (a redirect to the login is under way)', async () => {
    auth.getToken.mockResolvedValue(undefined);
    const result = firstValueFrom(http.get('/api/items'));
    const request = await vi.waitFor(() => backend.expectOne('/api/items'));
    expect(request.request.headers.has('Authorization')).toBe(false);
    request.flush([]);
    await result;
  });

  it('turns a 403 into an ApiError "forbidden" and does NOT start a login', async () => {
    const result = firstValueFrom(http.post('/api/purchase-requests/1/approve', {}));
    const request = await vi.waitFor(() => backend.expectOne('/api/purchase-requests/1/approve'));
    request.flush('', { status: 403, statusText: 'Forbidden' });
    const error = await result.catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ApiError);
    expect((error as ApiError).kind).toBe('forbidden');
    expect(auth.login).not.toHaveBeenCalled();
  });

  it('starts the login exactly once when the API rejects the token (401), however many calls fail', async () => {
    const first = firstValueFrom(http.get('/api/items'));
    const second = firstValueFrom(http.get('/api/production-orders'));
    const r1 = await vi.waitFor(() => backend.expectOne('/api/items'));
    const r2 = await vi.waitFor(() => backend.expectOne('/api/production-orders'));
    r1.flush('', { status: 401, statusText: 'Unauthorized' });
    r2.flush('', { status: 401, statusText: 'Unauthorized' });
    const e1 = await first.catch((e: unknown) => e);
    await second.catch(() => undefined);
    expect((e1 as ApiError).kind).toBe('unauthenticated');
    expect(auth.login).toHaveBeenCalledTimes(1);
  });

  it('a 401 from a non-API URL does not trigger a login', async () => {
    const result = firstValueFrom(http.get('/version'));
    backend.expectOne('/version').flush('', { status: 401, statusText: 'Unauthorized' });
    await result.catch(() => undefined);
    expect(auth.login).not.toHaveBeenCalled();
  });

  it('carries the RFC 7807 detail of a 409 to the caller', async () => {
    const result = firstValueFrom(http.post('/api/production-orders/1/complete', {}));
    const request = await vi.waitFor(() => backend.expectOne('/api/production-orders/1/complete'));
    request.flush(
      {
        title: 'Conflict',
        status: 409,
        detail: 'Only RELEASED orders can be completed (order is DONE)',
      },
      { status: 409, statusText: 'Conflict' },
    );
    const error = (await result.catch((e: unknown) => e)) as ApiError;
    expect(error.kind).toBe('conflict');
    expect(error.detail).toBe('Only RELEASED orders can be completed (order is DONE)');
  });
});
