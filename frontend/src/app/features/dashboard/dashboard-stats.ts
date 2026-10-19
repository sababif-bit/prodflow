import { Item, ProductionOrder, PurchaseRequest } from '../../shared/models/api.models';

export interface DashboardStats {
  orders: { total: number; created: number; waiting: number; released: number; done: number };
  purchase: { total: number; open: number; approved: number; received: number };
  inventory: { items: number; materials: number; products: number };
  /** Materials with zero stock: the real shortage signal (no invented KPI). */
  materialsOutOfStock: Item[];
  /** Orders that wait for material, most urgent (earliest due date) first. */
  waitingOrders: ProductionOrder[];
  /** Released orders: material is complete, the planner can finish them. */
  releasedOrders: ProductionOrder[];
  /** Requests that still need an action by purchasing: OPEN (approve) and APPROVED (book goods receipt). */
  activeRequests: PurchaseRequest[];
}

function byDueDate(a: ProductionOrder, b: ProductionOrder): number {
  return a.dueDate.localeCompare(b.dueDate) || a.id - b.id;
}

/** Everything on the overview is a direct count or filter of data returned by the API. */
export function computeDashboardStats(
  orders: readonly ProductionOrder[],
  requests: readonly PurchaseRequest[],
  items: readonly Item[],
): DashboardStats {
  const countOrders = (status: ProductionOrder['status']): number =>
    orders.filter((o) => o.status === status).length;
  const countRequests = (status: PurchaseRequest['status']): number =>
    requests.filter((r) => r.status === status).length;

  return {
    orders: {
      total: orders.length,
      created: countOrders('CREATED'),
      waiting: countOrders('WAITING_MATERIAL'),
      released: countOrders('RELEASED'),
      done: countOrders('DONE'),
    },
    purchase: {
      total: requests.length,
      open: countRequests('OPEN'),
      approved: countRequests('APPROVED'),
      received: countRequests('RECEIVED'),
    },
    inventory: {
      items: items.length,
      materials: items.filter((i) => i.type === 'MATERIAL').length,
      products: items.filter((i) => i.type === 'PRODUCT').length,
    },
    materialsOutOfStock: items.filter((i) => i.type === 'MATERIAL' && i.qtyOnHand <= 0),
    waitingOrders: orders.filter((o) => o.status === 'WAITING_MATERIAL').sort(byDueDate),
    releasedOrders: orders.filter((o) => o.status === 'RELEASED').sort(byDueDate),
    activeRequests: requests
      .filter((r) => r.status === 'OPEN' || r.status === 'APPROVED')
      .sort((a, b) => a.id - b.id),
  };
}
