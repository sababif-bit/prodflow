import { DatePipe } from '@angular/common';
import { Component, computed, inject } from '@angular/core';
import { Router, RouterLink } from '@angular/router';
import { forkJoin } from 'rxjs';
import { Button } from 'primeng/button';
import { Skeleton } from 'primeng/skeleton';
import { AuthService } from '../../core/auth/auth.service';
import { ItemsApi, OrdersApi, PurchaseRequestsApi } from '../../shared/api/api-services';
import { ORDER_STATUS, PURCHASE_STATUS } from '../../shared/labels';
import { createLoadable } from '../../shared/util/loadable';
import {
  EmptyState,
  ErrorState,
  PageHeader,
  QtyPipe,
  StatTile,
  StatusTag,
} from '../../shared/ui/ui-components';
import { computeDashboardStats } from './dashboard-stats';

@Component({
  selector: 'app-dashboard-page',
  imports: [
    PageHeader,
    StatTile,
    ErrorState,
    EmptyState,
    StatusTag,
    QtyPipe,
    DatePipe,
    RouterLink,
    Button,
    Skeleton,
  ],
  template: `
    <app-page-header
      title="Übersicht"
      subtitle="Aktueller Stand aus Fertigung, Einkauf und Bestand – direkt aus dem System"
    >
      <p-button
        label="Aktualisieren"
        icon="pi pi-refresh"
        severity="secondary"
        [outlined]="true"
        (onClick)="data.reload()"
      />
      @if (auth.can('order.create')) {
        <p-button label="Neuer Auftrag" icon="pi pi-plus" (onClick)="newOrder()" />
      }
    </app-page-header>

    @if (data.error(); as error) {
      <app-error-state [error]="error" (retry)="data.reload()" />
    } @else if (stats(); as s) {
      <section aria-labelledby="orders-h" class="mb-6">
        <h2 id="orders-h" class="mb-3 mt-0 text-base text-surface-600">Fertigungsaufträge</h2>
        <div class="grid grid-cols-2 gap-4 lg:grid-cols-4">
          <app-stat-tile
            label="Aufträge gesamt"
            [value]="s.orders.total"
            icon="pi pi-cog"
            link="/auftraege"
          />
          <app-stat-tile
            label="Wartet auf Material"
            [value]="s.orders.waiting"
            icon="pi pi-clock"
            [tone]="s.orders.waiting > 0 ? 'warn' : 'neutral'"
            hint="Fehlmenge, Einkauf nötig"
            link="/auftraege"
            [queryParams]="{ status: 'WAITING_MATERIAL' }"
          />
          <app-stat-tile
            label="Freigegeben"
            [value]="s.orders.released"
            icon="pi pi-check-circle"
            hint="Material vollständig – kann abgeschlossen werden"
            link="/auftraege"
            [queryParams]="{ status: 'RELEASED' }"
          />
          <app-stat-tile
            label="Abgeschlossen"
            [value]="s.orders.done"
            icon="pi pi-verified"
            tone="ok"
            link="/auftraege"
            [queryParams]="{ status: 'DONE' }"
          />
        </div>
      </section>

      <section aria-labelledby="stock-h" class="mb-6">
        <h2 id="stock-h" class="mb-3 mt-0 text-base text-surface-600">Einkauf und Bestand</h2>
        <div class="grid grid-cols-2 gap-4 lg:grid-cols-4">
          <app-stat-tile
            label="Offene Bestellanforderungen"
            [value]="s.purchase.open"
            icon="pi pi-inbox"
            [tone]="s.purchase.open > 0 ? 'warn' : 'neutral'"
            hint="warten auf Genehmigung"
            link="/bestellanforderungen"
            [queryParams]="{ status: 'OPEN' }"
          />
          <app-stat-tile
            label="Genehmigt"
            [value]="s.purchase.approved"
            icon="pi pi-thumbs-up"
            hint="Wareneingang ausstehend"
            link="/bestellanforderungen"
            [queryParams]="{ status: 'APPROVED' }"
          />
          <app-stat-tile
            label="Material ohne Bestand"
            [value]="s.materialsOutOfStock.length"
            icon="pi pi-exclamation-triangle"
            [tone]="s.materialsOutOfStock.length > 0 ? 'danger' : 'ok'"
            [hint]="'von ' + s.inventory.materials + ' Materialien'"
            link="/bestand"
            [queryParams]="{ stock: 'none' }"
          />
          <app-stat-tile
            label="Artikel"
            [value]="s.inventory.items"
            icon="pi pi-box"
            [hint]="
              s.inventory.materials + ' Materialien · ' + s.inventory.products + ' Fertigprodukte'
            "
            link="/bestand"
          />
        </div>
      </section>

      <div class="grid gap-6 lg:grid-cols-2">
        <section class="pf-card p-4" aria-labelledby="todo-orders-h">
          <h2 id="todo-orders-h" class="mb-3 mt-0 text-base">Aufträge mit Handlungsbedarf</h2>
          @if (s.waitingOrders.length === 0 && s.releasedOrders.length === 0) {
            <app-empty-state
              icon="pi pi-check-circle"
              title="Nichts offen"
              text="Kein Auftrag wartet auf Material oder auf den Abschluss."
            />
          } @else {
            <ul class="m-0 list-none divide-y p-0" style="--tw-divide-color: var(--pf-border)">
              @for (order of s.waitingOrders; track order.id) {
                <li class="flex flex-wrap items-center justify-between gap-2 py-2.5">
                  <a [routerLink]="['/auftraege', order.id]" class="font-medium">{{
                    order.orderNo
                  }}</a>
                  <span class="text-sm text-surface-500"
                    >{{ order.productCode }} · {{ order.quantity | qty }} · fällig
                    {{ order.dueDate | date: 'dd.MM.yyyy' }}</span
                  >
                  <app-status-tag [view]="orderStatus.WAITING_MATERIAL" />
                </li>
              }
              @for (order of s.releasedOrders; track order.id) {
                <li class="flex flex-wrap items-center justify-between gap-2 py-2.5">
                  <a [routerLink]="['/auftraege', order.id]" class="font-medium">{{
                    order.orderNo
                  }}</a>
                  <span class="text-sm text-surface-500"
                    >{{ order.productCode }} · {{ order.quantity | qty }} · fällig
                    {{ order.dueDate | date: 'dd.MM.yyyy' }}</span
                  >
                  <app-status-tag [view]="orderStatus.RELEASED" />
                </li>
              }
            </ul>
          }
        </section>

        <section class="pf-card p-4" aria-labelledby="todo-purchase-h">
          <h2 id="todo-purchase-h" class="mb-3 mt-0 text-base">
            Bestellanforderungen in Bearbeitung
          </h2>
          @if (s.activeRequests.length === 0) {
            <app-empty-state
              icon="pi pi-check-circle"
              title="Nichts offen"
              text="Es gibt keine offenen oder genehmigten Bestellanforderungen."
            />
          } @else {
            <ul class="m-0 list-none divide-y p-0" style="--tw-divide-color: var(--pf-border)">
              @for (request of s.activeRequests; track request.id) {
                <li class="flex flex-wrap items-center justify-between gap-2 py-2.5">
                  <a
                    routerLink="/bestellanforderungen"
                    [queryParams]="{ status: request.status }"
                    class="font-medium"
                    >Nr. {{ request.id }}</a
                  >
                  <span class="text-sm text-surface-500"
                    >{{ request.itemCode }} · {{ request.quantity | qty: request.unit }}
                    @if (request.orderNo) {
                      · {{ request.orderNo }}
                    }
                  </span>
                  <app-status-tag [view]="purchaseStatus[request.status]" />
                </li>
              }
            </ul>
          }
        </section>
      </div>

      @if (s.materialsOutOfStock.length > 0) {
        <section class="pf-card mt-6 p-4" aria-labelledby="out-h">
          <h2 id="out-h" class="mb-3 mt-0 text-base">Material ohne Bestand</h2>
          <div class="flex flex-wrap gap-2">
            @for (item of s.materialsOutOfStock; track item.id) {
              <a
                [routerLink]="['/bestand', item.id]"
                class="rounded-full border px-3 py-1 text-sm no-underline"
                style="border-color: var(--pf-border)"
              >
                {{ item.code }} · {{ item.name }}
              </a>
            }
          </div>
        </section>
      }
    } @else {
      <div class="grid grid-cols-2 gap-4 lg:grid-cols-4" aria-busy="true" aria-label="Lädt">
        @for (n of placeholders; track n) {
          <p-skeleton height="6.5rem" borderRadius="10px" />
        }
      </div>
    }
  `,
})
export class DashboardPage {
  protected readonly auth = inject(AuthService);
  private readonly router = inject(Router);
  private readonly orders = inject(OrdersApi);
  private readonly requests = inject(PurchaseRequestsApi);
  private readonly items = inject(ItemsApi);

  protected readonly orderStatus = ORDER_STATUS;
  protected readonly purchaseStatus = PURCHASE_STATUS;
  protected readonly placeholders = [1, 2, 3, 4, 5, 6, 7, 8];

  protected readonly data = createLoadable(() =>
    forkJoin({
      orders: this.orders.list(),
      requests: this.requests.list(),
      items: this.items.list(),
    }),
  );
  protected readonly stats = computed(() => {
    const value = this.data.value();
    return value ? computeDashboardStats(value.orders, value.requests, value.items) : null;
  });

  protected newOrder(): void {
    void this.router.navigate(['/auftraege'], { queryParams: { neu: 1 } });
  }
}
