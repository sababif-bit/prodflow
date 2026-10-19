import { ItemType, OrderStatus, PurchaseRequestStatus } from './models/api.models';

/** German wording and visual encoding of states, in one place (consistent with the project glossary). */
export type TagSeverity = 'success' | 'secondary' | 'info' | 'warn' | 'danger' | 'contrast';

export interface StatusView {
  label: string;
  severity: TagSeverity;
  icon: string;
}

export const ORDER_STATUS: Readonly<Record<OrderStatus, StatusView>> = {
  CREATED: { label: 'Angelegt', severity: 'secondary', icon: 'pi pi-file' },
  WAITING_MATERIAL: { label: 'Wartet auf Material', severity: 'warn', icon: 'pi pi-clock' },
  RELEASED: { label: 'Freigegeben', severity: 'info', icon: 'pi pi-check-circle' },
  DONE: { label: 'Abgeschlossen', severity: 'success', icon: 'pi pi-verified' },
};

/** The order in which an order moves through its life (used for the progress display). */
export const ORDER_FLOW: readonly OrderStatus[] = [
  'CREATED',
  'WAITING_MATERIAL',
  'RELEASED',
  'DONE',
];

export const PURCHASE_STATUS: Readonly<Record<PurchaseRequestStatus, StatusView>> = {
  OPEN: { label: 'Offen', severity: 'warn', icon: 'pi pi-inbox' },
  APPROVED: { label: 'Genehmigt', severity: 'info', icon: 'pi pi-thumbs-up' },
  RECEIVED: { label: 'Wareneingang gebucht', severity: 'success', icon: 'pi pi-box' },
};

export const ITEM_TYPE_LABEL: Readonly<Record<ItemType, string>> = {
  MATERIAL: 'Material',
  PRODUCT: 'Fertigprodukt',
};

export const STOCK_NONE: StatusView = {
  label: 'Kein Bestand',
  severity: 'danger',
  icon: 'pi pi-exclamation-triangle',
};
export const STOCK_OK: StatusView = {
  label: 'Auf Lager',
  severity: 'success',
  icon: 'pi pi-check',
};
