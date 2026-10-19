import {
  addDays,
  canCheckMaterial,
  canComplete,
  isOverdue,
  startOfToday,
  toIsoDate,
} from './order-utils';
import { orderSteps } from './order-progress';

describe('order utilities', () => {
  it('toIsoDate uses the LOCAL calendar day (no UTC shift near midnight)', () => {
    expect(toIsoDate(new Date(2026, 9, 19, 23, 59))).toBe('2026-10-19');
    expect(toIsoDate(new Date(2026, 0, 1, 0, 1))).toBe('2026-01-01');
  });

  it('addDays crosses month and year boundaries and ignores the time of day', () => {
    expect(toIsoDate(addDays(new Date(2026, 9, 25, 22, 0), 14))).toBe('2026-11-08');
    expect(toIsoDate(addDays(new Date(2026, 11, 30), 3))).toBe('2027-01-02');
  });

  it('startOfToday drops the time', () => {
    const start = startOfToday(new Date(2026, 9, 19, 15, 45, 12));
    expect([start.getHours(), start.getMinutes(), start.getSeconds()]).toEqual([0, 0, 0]);
  });

  it('an order is overdue after its due date unless it is DONE', () => {
    const now = new Date(2026, 9, 19, 12);
    expect(isOverdue('2026-10-18', 'WAITING_MATERIAL', now)).toBe(true);
    expect(isOverdue('2026-10-18', 'RELEASED', now)).toBe(true);
    expect(isOverdue('2026-10-18', 'DONE', now)).toBe(false);
    expect(isOverdue('2026-10-19', 'WAITING_MATERIAL', now)).toBe(false); // due today is not overdue
    expect(isOverdue('2026-10-20', 'CREATED', now)).toBe(false);
  });

  it('only open orders can be material-checked; only RELEASED orders can be completed (backend rules)', () => {
    expect(canCheckMaterial('CREATED')).toBe(true);
    expect(canCheckMaterial('WAITING_MATERIAL')).toBe(true);
    expect(canCheckMaterial('RELEASED')).toBe(false);
    expect(canCheckMaterial('DONE')).toBe(false);
    expect(canComplete('RELEASED')).toBe(true);
    expect(canComplete('WAITING_MATERIAL')).toBe(false);
    expect(canComplete('DONE')).toBe(false);
  });
});

describe('orderSteps', () => {
  const states = (status: Parameters<typeof orderSteps>[0]) =>
    orderSteps(status).map((step) => step.state);

  it('waiting for material: the first step is current and says so', () => {
    expect(states('WAITING_MATERIAL')).toEqual(['current', 'todo', 'todo']);
    expect(orderSteps('WAITING_MATERIAL')[0].label).toBe('Wartet auf Material');
  });

  it('released: material is done, release is current', () => {
    expect(states('RELEASED')).toEqual(['done', 'current', 'todo']);
  });

  it('done: everything is done', () => {
    expect(states('DONE')).toEqual(['done', 'done', 'done']);
  });
});
