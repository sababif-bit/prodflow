import { Routes } from '@angular/router';
import { requirePermission } from './core/auth/permission.guard';
import { Shell } from './layout/shell';
import { ForbiddenPage, NotFoundPage } from './features/system/system-pages';

/** German URLs; every feature page is loaded lazily. */
export const routes: Routes = [
  {
    path: '',
    component: Shell,
    children: [
      { path: '', pathMatch: 'full', redirectTo: 'uebersicht' },
      {
        path: 'uebersicht',
        title: 'Übersicht',
        canActivate: [requirePermission('order.read')],
        loadComponent: () =>
          import('./features/dashboard/dashboard-page').then((m) => m.DashboardPage),
      },
      {
        path: 'auftraege',
        title: 'Fertigungsaufträge',
        canActivate: [requirePermission('order.read')],
        loadComponent: () => import('./features/orders/orders-page').then((m) => m.OrdersPage),
      },
      {
        path: 'auftraege/:id',
        title: 'Auftrag',
        canActivate: [requirePermission('order.read')],
        loadComponent: () =>
          import('./features/orders/order-detail-page').then((m) => m.OrderDetailPage),
      },
      {
        path: 'bestellanforderungen',
        title: 'Bestellanforderungen',
        canActivate: [requirePermission('purchase.read')],
        loadComponent: () =>
          import('./features/purchasing/purchase-requests-page').then(
            (m) => m.PurchaseRequestsPage,
          ),
      },
      {
        path: 'bestand',
        title: 'Bestand & Artikel',
        canActivate: [requirePermission('item.read')],
        loadComponent: () =>
          import('./features/inventory/inventory-page').then((m) => m.InventoryPage),
      },
      {
        path: 'bestand/:id',
        title: 'Artikel',
        canActivate: [requirePermission('item.read')],
        loadComponent: () =>
          import('./features/inventory/item-detail-page').then((m) => m.ItemDetailPage),
      },
      { path: 'keine-berechtigung', title: 'Keine Berechtigung', component: ForbiddenPage },
    ],
  },
  { path: '**', title: 'Nicht gefunden', component: NotFoundPage },
];
