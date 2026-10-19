import { Injector, runInInjectionContext } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { Subject } from 'rxjs';
import { ApiError } from '../../core/http/api-error';
import { createLoadable } from './loadable';

describe('createLoadable', () => {
  const inContext = <T>(fn: () => T): T => runInInjectionContext(TestBed.inject(Injector), fn);

  it('starts loading, then holds the value', () => {
    const source = new Subject<string>();
    const loadable = inContext(() => createLoadable(() => source));
    expect(loadable.loading()).toBe(true);
    expect(loadable.value()).toBeUndefined();
    source.next('daten');
    expect(loadable.loading()).toBe(false);
    expect(loadable.value()).toBe('daten');
    expect(loadable.error()).toBeUndefined();
  });

  it('turns a failure into an ApiError and stops loading', () => {
    const source = new Subject<string>();
    const loadable = inContext(() => createLoadable(() => source));
    source.error(new ApiError(500, 'server', 'x'));
    expect(loadable.loading()).toBe(false);
    expect(loadable.error()?.kind).toBe('server');
  });

  it('reload() loads again and clears a previous error', () => {
    let calls = 0;
    const sources = [new Subject<number>(), new Subject<number>()];
    const loadable = inContext(() => createLoadable(() => sources[calls++]));
    sources[0].error(new ApiError(0, 'network', ''));
    expect(loadable.error()?.kind).toBe('network');
    loadable.reload();
    expect(loadable.loading()).toBe(true);
    expect(loadable.error()).toBeUndefined();
    sources[1].next(42);
    expect(loadable.value()).toBe(42);
  });

  it('keeps the previous value visible while reloading (no flicker)', () => {
    const first = new Subject<string>();
    const second = new Subject<string>();
    let n = 0;
    const loadable = inContext(() => createLoadable(() => (n++ === 0 ? first : second)));
    first.next('alt');
    loadable.reload();
    expect(loadable.loading()).toBe(true);
    expect(loadable.value()).toBe('alt');
  });
});
