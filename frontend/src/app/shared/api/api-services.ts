import { HttpClient } from '@angular/common/http';
import { inject, Injectable } from '@angular/core';
import { Observable } from 'rxjs';
import {
  BomLine,
  CreateOrderRequest,
  Item,
  MaterialCheckResult,
  ProductionOrder,
  PurchaseRequest,
  VersionInfo,
} from '../models/api.models';

/**
 * One typed service per backend resource. All URLs are relative (/api/...): in development the dev proxy forwards them,
 * in production the backend (or reverse proxy) serves the application from the same origin, so no CORS is involved.
 * Endpoints are exactly those of ItemController, BomController, ProductionOrderController and PurchaseRequestController.
 */
@Injectable({ providedIn: 'root' })
export class ItemsApi {
  private readonly http = inject(HttpClient);

  list(): Observable<Item[]> {
    return this.http.get<Item[]>('/api/items');
  }

  get(id: number): Observable<Item> {
    return this.http.get<Item>(`/api/items/${id}`);
  }

  /** Single-level BOM: only the direct components of the item. (Multi-level explosion does not exist in the backend yet.) */
  bom(id: number): Observable<BomLine[]> {
    return this.http.get<BomLine[]>(`/api/items/${id}/bom`);
  }
}

@Injectable({ providedIn: 'root' })
export class OrdersApi {
  private readonly http = inject(HttpClient);

  list(): Observable<ProductionOrder[]> {
    return this.http.get<ProductionOrder[]>('/api/production-orders');
  }

  get(id: number): Observable<ProductionOrder> {
    return this.http.get<ProductionOrder>(`/api/production-orders/${id}`);
  }

  /** Creates the order AND runs the material check (may create purchase requests). */
  create(request: CreateOrderRequest): Observable<MaterialCheckResult> {
    return this.http.post<MaterialCheckResult>('/api/production-orders', request);
  }

  checkMaterial(id: number): Observable<MaterialCheckResult> {
    return this.http.post<MaterialCheckResult>(`/api/production-orders/${id}/check-material`, {});
  }

  complete(id: number): Observable<ProductionOrder> {
    return this.http.post<ProductionOrder>(`/api/production-orders/${id}/complete`, {});
  }
}

@Injectable({ providedIn: 'root' })
export class PurchaseRequestsApi {
  private readonly http = inject(HttpClient);

  list(): Observable<PurchaseRequest[]> {
    return this.http.get<PurchaseRequest[]>('/api/purchase-requests');
  }

  approve(id: number): Observable<PurchaseRequest> {
    return this.http.post<PurchaseRequest>(`/api/purchase-requests/${id}/approve`, {});
  }

  /** Books the goods receipt: stock increases and waiting orders are re-checked by the backend. */
  receive(id: number): Observable<PurchaseRequest> {
    return this.http.post<PurchaseRequest>(`/api/purchase-requests/${id}/receive`, {});
  }
}

@Injectable({ providedIn: 'root' })
export class VersionApi {
  private readonly http = inject(HttpClient);

  /** Public endpoint (no token): the commit the running backend was built from. */
  get(): Observable<VersionInfo> {
    return this.http.get<VersionInfo>('/version');
  }
}
