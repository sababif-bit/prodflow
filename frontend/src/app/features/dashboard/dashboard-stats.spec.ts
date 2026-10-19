import { Item, ProductionOrder, PurchaseRequest } from '../../shared/models/api.models';
import { computeDashboardStats } from './dashboard-stats';

const order = (
  id: number,
  status: ProductionOrder['status'],
  dueDate: string,
): ProductionOrder => ({
  id,
  orderNo: `FA-${String(id).padStart(5, '0')}`,
  productId: 1,
  productCode: 'MR-200',
  productName: 'Machine frame',
  quantity: 10,
  dueDate,
  status,
});
const request = (id: number, status: PurchaseRequest['status']): PurchaseRequest => ({
  id,
  itemId: 2,
  itemCode: 'SC-M8',
  itemName: 'Hex screw',
  unit: 'pcs',
  quantity: 15,
  status,
  orderNo: 'FA-00001',
  createdAt: '2026-10-19T10:00:00',
});
const item = (id: number, type: Item['type'], qtyOnHand: number): Item => ({
  id,
  code: `X-${id}`,
  name: `Item ${id}`,
  unit: 'pcs',
  type,
  qtyOnHand,
});

describe('computeDashboardStats (every number is a count or filter of API data)', () => {
  const orders = [
    order(1, 'DONE', '2026-10-30'),
    order(2, 'WAITING_MATERIAL', '2026-11-20'),
    order(3, 'WAITING_MATERIAL', '2026-11-02'),
    order(4, 'RELEASED', '2026-11-05'),
  ];
  const requests = [
    request(1, 'RECEIVED'),
    request(2, 'OPEN'),
    request(3, 'APPROVED'),
    request(4, 'OPEN'),
  ];
  const items = [
    item(1, 'PRODUCT', 0),
    item(2, 'MATERIAL', 0),
    item(3, 'MATERIAL', 12),
    item(4, 'MATERIAL', 0),
  ];
  const stats = computeDashboardStats(orders, requests, items);

  it('counts orders by status', () => {
    expect(stats.orders).toEqual({ total: 4, created: 0, waiting: 2, released: 1, done: 1 });
  });

  it('counts purchase requests by status', () => {
    expect(stats.purchase).toEqual({ total: 4, open: 2, approved: 1, received: 1 });
  });

  it('counts items by type', () => {
    expect(stats.inventory).toEqual({ items: 4, materials: 3, products: 1 });
  });

  it('lists only MATERIALS without stock as the shortage signal (a product with 0 stock is normal)', () => {
    expect(stats.materialsOutOfStock.map((i) => i.id)).toEqual([2, 4]);
  });

  it('lists waiting orders by earliest due date first', () => {
    expect(stats.waitingOrders.map((o) => o.orderNo)).toEqual(['FA-00003', 'FA-00002']);
    expect(stats.releasedOrders.map((o) => o.orderNo)).toEqual(['FA-00004']);
  });

  it('lists requests that still need an action (OPEN or APPROVED) in id order', () => {
    expect(stats.activeRequests.map((r) => r.id)).toEqual([2, 3, 4]);
  });

  it('is all zeros for an empty system (no invented numbers)', () => {
    const empty = computeDashboardStats([], [], []);
    expect(empty.orders.total + empty.purchase.total + empty.inventory.items).toBe(0);
    expect(empty.waitingOrders).toEqual([]);
  });
});
