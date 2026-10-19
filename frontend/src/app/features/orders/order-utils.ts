import { OrderStatus } from '../../shared/models/api.models';

/** yyyy-MM-dd from a LOCAL date (toISOString would shift the day around midnight in other time zones). */
export function toIsoDate(date: Date): string {
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${date.getFullYear()}-${month}-${day}`;
}

export function addDays(date: Date, days: number): Date {
  const result = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  result.setDate(result.getDate() + days);
  return result;
}

export function startOfToday(now: Date = new Date()): Date {
  return new Date(now.getFullYear(), now.getMonth(), now.getDate());
}

/** An order is overdue when its due date has passed and it is not finished. */
export function isOverdue(dueDate: string, status: OrderStatus, now: Date = new Date()): boolean {
  return status !== 'DONE' && dueDate < toIsoDate(now);
}

/** Orders that can still be material-checked (the backend only accepts these). */
export function canCheckMaterial(status: OrderStatus): boolean {
  return status === 'CREATED' || status === 'WAITING_MATERIAL';
}

export function canComplete(status: OrderStatus): boolean {
  return status === 'RELEASED';
}
