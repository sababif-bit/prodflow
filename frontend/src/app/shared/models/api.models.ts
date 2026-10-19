/**
 * Typed mirror of the Spring Boot REST contract (backend/src/main/java/de/prodflow/**).
 * Decimal quantities arrive as JSON numbers; dates as ISO strings (yyyy-MM-dd / local date-time).
 * Keep in sync with /v3/api-docs; a generated client is a planned improvement (see docs/frontend-architecture.md).
 */

export type ItemType = 'MATERIAL' | 'PRODUCT';
export type OrderStatus = 'CREATED' | 'WAITING_MATERIAL' | 'RELEASED' | 'DONE';
export type PurchaseRequestStatus = 'OPEN' | 'APPROVED' | 'RECEIVED';

export interface Item {
  id: number;
  code: string;
  name: string;
  unit: string;
  type: ItemType;
  qtyOnHand: number;
}

/** One line of a single-level bill of materials: "to make 1 x parent you need qtyPer x component". */
export interface BomLine {
  id: number;
  componentId: number;
  componentCode: string;
  componentName: string;
  unit: string;
  qtyPer: number;
}

export interface ProductionOrder {
  id: number;
  orderNo: string;
  productId: number;
  productCode: string;
  productName: string;
  quantity: number;
  dueDate: string;
  status: OrderStatus;
}

export interface CreateOrderRequest {
  productId: number;
  quantity: number;
  dueDate: string;
}

export interface MaterialCheckLine {
  itemCode: string;
  itemName: string;
  unit: string;
  required: number;
  available: number;
  shortage: number;
  newlyRequested: number;
}

export interface MaterialCheckResult {
  orderId: number;
  status: OrderStatus;
  lines: MaterialCheckLine[];
}

export interface PurchaseRequest {
  id: number;
  itemId: number;
  itemCode: string;
  itemName: string;
  unit: string;
  quantity: number;
  status: PurchaseRequestStatus;
  orderNo: string | null;
  createdAt: string;
}

/** RFC 7807 problem detail as produced by GlobalExceptionHandler. */
export interface ProblemDetail {
  type?: string;
  title?: string;
  status?: number;
  detail?: string;
  instance?: string;
}

export interface VersionInfo {
  revision: string;
}
