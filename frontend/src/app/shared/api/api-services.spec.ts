import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { ItemsApi, OrdersApi, PurchaseRequestsApi, VersionApi } from './api-services';

/**
 * Contract test: the frontend calls exactly the endpoints the Spring Boot controllers expose
 * (ItemController, BomController, ProductionOrderController, PurchaseRequestController, VersionController).
 */
describe('API services', () => {
  let backend: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [provideHttpClient(), provideHttpClientTesting()],
    });
    backend = TestBed.inject(HttpTestingController);
  });

  afterEach(() => backend.verify());

  function expectCall(method: string, url: string, body?: unknown): void {
    const request = backend.expectOne(url);
    expect(request.request.method).toBe(method);
    if (body !== undefined) {
      expect(request.request.body).toEqual(body);
    }
    request.flush(null);
  }

  it('items: list, get and the single-level BOM', () => {
    const api = TestBed.inject(ItemsApi);
    api.list().subscribe();
    expectCall('GET', '/api/items');
    api.get(7).subscribe();
    expectCall('GET', '/api/items/7');
    api.bom(7).subscribe();
    expectCall('GET', '/api/items/7/bom');
  });

  it('orders: list, get, create (with the request body), check-material and complete', () => {
    const api = TestBed.inject(OrdersApi);
    api.list().subscribe();
    expectCall('GET', '/api/production-orders');
    api.get(3).subscribe();
    expectCall('GET', '/api/production-orders/3');
    api.create({ productId: 1, quantity: 10, dueDate: '2026-11-02' }).subscribe();
    expectCall('POST', '/api/production-orders', {
      productId: 1,
      quantity: 10,
      dueDate: '2026-11-02',
    });
    api.checkMaterial(3).subscribe();
    expectCall('POST', '/api/production-orders/3/check-material');
    api.complete(3).subscribe();
    expectCall('POST', '/api/production-orders/3/complete');
  });

  it('purchase requests: list, approve and receive', () => {
    const api = TestBed.inject(PurchaseRequestsApi);
    api.list().subscribe();
    expectCall('GET', '/api/purchase-requests');
    api.approve(5).subscribe();
    expectCall('POST', '/api/purchase-requests/5/approve');
    api.receive(5).subscribe();
    expectCall('POST', '/api/purchase-requests/5/receive');
  });

  it('version: the public endpoint outside /api', () => {
    TestBed.inject(VersionApi).get().subscribe();
    expectCall('GET', '/version');
  });
});
