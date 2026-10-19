import { DatePipe } from '@angular/common';
import { Component, computed, inject, input, signal } from '@angular/core';
import { RouterLink } from '@angular/router';
import { forkJoin, of, switchMap } from 'rxjs';
import { Button } from 'primeng/button';
import { Message } from 'primeng/message';
import { PrimeTemplate } from 'primeng/api';
import { Skeleton } from 'primeng/skeleton';
import { TableModule } from 'primeng/table';
import { AuthService } from '../../core/auth/auth.service';
import { ItemsApi, OrdersApi, PurchaseRequestsApi } from '../../shared/api/api-services';
import { ORDER_STATUS, PURCHASE_STATUS, StatusView } from '../../shared/labels';
import { MaterialCheckResult, PurchaseRequestStatus } from '../../shared/models/api.models';
import { createLoadable } from '../../shared/util/loadable';
import { ErrorState, PageHeader, QtyPipe, StatusTag } from '../../shared/ui/ui-components';
import { buildBomRows, requirementsFor } from '../inventory/bom-model';
import { MaterialResultDialog } from './material-result-dialog';
import { OrderActions } from './order-actions';
import { OrderProgress } from './order-progress';
import { canCheckMaterial, canComplete, isOverdue } from './order-utils';

@Component({
  selector: 'app-order-detail-page',
  imports: [
    PageHeader,
    ErrorState,
    StatusTag,
    QtyPipe,
    DatePipe,
    RouterLink,
    Button,
    Message,
    Skeleton,
    TableModule,
    PrimeTemplate,
    OrderProgress,
    MaterialResultDialog,
  ],
  template: `
    <nav class="mb-3 text-sm" aria-label="Brotkrumen">
      <a routerLink="/auftraege">← Fertigungsaufträge</a>
    </nav>

    @if (data.error(); as error) {
      <app-error-state [error]="error" (retry)="data.reload()" />
    } @else if (data.value(); as d) {
      <app-page-header
        [title]="d.order.orderNo"
        [subtitle]="d.order.quantity + ' × ' + d.order.productCode + ' – ' + d.order.productName"
      >
        <app-status-tag [view]="statusView[d.order.status]" />
        @if (canCheck() && auth.can('order.checkMaterial')) {
          <p-button
            label="Material prüfen"
            icon="pi pi-refresh"
            severity="secondary"
            [outlined]="true"
            [loading]="actions.isBusy(d.order.id)"
            (onClick)="checkMaterial()"
          />
        }
        @if (canFinish() && auth.can('order.complete')) {
          <p-button
            label="Auftrag abschließen"
            icon="pi pi-check"
            [loading]="actions.isBusy(d.order.id)"
            (onClick)="complete()"
          />
        }
      </app-page-header>

      <section class="pf-card mb-6 p-4" aria-label="Fortschritt">
        <app-order-progress [status]="d.order.status" />
        @if (overdue()) {
          <p class="mb-0 mt-3 text-sm font-medium" style="color: var(--pf-danger)">
            <i class="pi pi-exclamation-circle"></i> Das Fälligkeitsdatum ist überschritten.
          </p>
        }
      </section>

      <div class="grid gap-6 lg:grid-cols-3">
        <section class="pf-card p-4" aria-labelledby="od-h">
          <h2 id="od-h" class="mb-3 mt-0 text-base">Auftragsdaten</h2>
          <dl class="m-0 grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-sm">
            <dt class="text-surface-500">Auftrag</dt>
            <dd class="m-0 font-medium">{{ d.order.orderNo }}</dd>
            <dt class="text-surface-500">Produkt</dt>
            <dd class="m-0">
              <a [routerLink]="['/bestand', d.order.productId]">{{ d.order.productCode }}</a> ·
              {{ d.order.productName }}
            </dd>
            <dt class="text-surface-500">Menge</dt>
            <dd class="tabular m-0">{{ d.order.quantity | qty }}</dd>
            <dt class="text-surface-500">Fällig</dt>
            <dd class="m-0">{{ d.order.dueDate | date: 'dd.MM.yyyy' }}</dd>
          </dl>
          @if (!auth.can('order.complete')) {
            <p-message
              severity="secondary"
              class="mt-4 block"
              text="Anlegen, Materialprüfung und Abschluss sind der Planung vorbehalten."
            />
          }
        </section>

        <section class="pf-card p-4 lg:col-span-2" aria-labelledby="req-h">
          <h2 id="req-h" class="mb-1 mt-0 text-base">Materialbedarf</h2>
          @if (d.order.status === 'DONE') {
            <p class="m-0 text-surface-500">
              Der Auftrag ist abgeschlossen; das Material wurde aus dem Bestand gebucht.
            </p>
          } @else if (requirements().length === 0) {
            <p class="m-0 text-surface-500">Für dieses Produkt ist keine Stückliste hinterlegt.</p>
          } @else {
            <p class="mb-3 mt-0 text-sm text-surface-500">
              Berechnet aus der (einstufigen) Stückliste und dem heutigen Bestand. Verbindlich ist
              die Materialprüfung des Systems.
            </p>
            <div class="overflow-x-auto">
              <p-table
                [value]="requirements()"
                size="small"
                [tableStyle]="{ 'min-width': '34rem' }"
              >
                <ng-template pTemplate="header">
                  <tr>
                    <th scope="col">Material</th>
                    <th scope="col" class="text-right">Benötigt</th>
                    <th scope="col" class="text-right">Bestand</th>
                    <th scope="col" class="text-right">Fehlmenge</th>
                  </tr>
                </ng-template>
                <ng-template pTemplate="body" let-row>
                  <tr>
                    <td>
                      <span class="font-medium">{{ row.code }}</span
                      ><span class="ml-2 text-surface-500">{{ row.name }}</span>
                    </td>
                    <td class="tabular text-right">{{ row.required | qty: row.unit }}</td>
                    <td class="tabular text-right">{{ row.available | qty: row.unit }}</td>
                    <td
                      class="tabular text-right"
                      [style.color]="row.shortage > 0 ? 'var(--pf-danger)' : null"
                      [class.font-semibold]="row.shortage > 0"
                    >
                      {{ row.shortage > 0 ? (row.shortage | qty: row.unit) : '–' }}
                    </td>
                  </tr>
                </ng-template>
              </p-table>
            </div>
          }
        </section>
      </div>

      <section class="pf-card mt-6 p-4" aria-labelledby="pr-h">
        <h2 id="pr-h" class="mb-3 mt-0 text-base">Bestellanforderungen zu diesem Auftrag</h2>
        @if (d.requests.length === 0) {
          <p class="m-0 text-surface-500">
            Für diesen Auftrag wurde nichts bestellt – es gab keine Fehlmenge oder sie ist
            anderweitig abgedeckt.
          </p>
        } @else {
          <div class="overflow-x-auto">
            <p-table [value]="d.requests" size="small" [tableStyle]="{ 'min-width': '30rem' }">
              <ng-template pTemplate="header">
                <tr>
                  <th scope="col">Nr.</th>
                  <th scope="col">Material</th>
                  <th scope="col" class="text-right">Menge</th>
                  <th scope="col">Status</th>
                </tr>
              </ng-template>
              <ng-template pTemplate="body" let-request>
                <tr>
                  <td>
                    <a
                      routerLink="/bestellanforderungen"
                      [queryParams]="{ status: request.status }"
                      >{{ request.id }}</a
                    >
                  </td>
                  <td>
                    {{ request.itemCode }}
                    <span class="text-surface-500">{{ request.itemName }}</span>
                  </td>
                  <td class="tabular text-right">{{ request.quantity | qty: request.unit }}</td>
                  <td><app-status-tag [view]="purchaseView(request.status)" /></td>
                </tr>
              </ng-template>
            </p-table>
          </div>
        }
      </section>

      <app-material-result-dialog
        [(visible)]="resultVisible"
        [result]="result()"
        [orderNo]="d.order.orderNo"
      />
    } @else {
      <div class="grid gap-3" aria-busy="true" aria-label="Lädt">
        <p-skeleton height="3rem" width="22rem" />
        <p-skeleton height="5rem" />
        <p-skeleton height="12rem" />
      </div>
    }
  `,
})
export class OrderDetailPage {
  /** Bound from the route parameter :id. */
  readonly id = input.required<string>();

  protected readonly auth = inject(AuthService);
  protected readonly actions = inject(OrderActions);
  private readonly ordersApi = inject(OrdersApi);
  private readonly itemsApi = inject(ItemsApi);
  private readonly requestsApi = inject(PurchaseRequestsApi);

  protected readonly statusView = ORDER_STATUS;
  protected readonly purchaseStatus = PURCHASE_STATUS;

  protected purchaseView(status: PurchaseRequestStatus): StatusView {
    return PURCHASE_STATUS[status];
  }
  protected readonly resultVisible = signal(false);
  protected readonly result = signal<MaterialCheckResult | null>(null);

  protected readonly data = createLoadable(
    () =>
      this.ordersApi.get(Number(this.id())).pipe(
        switchMap((order) =>
          forkJoin({
            order: of(order),
            requests: this.requestsApi.list(),
            items: this.itemsApi.list(),
            bom: order.status === 'DONE' ? of([]) : this.itemsApi.bom(order.productId),
          }),
        ),
        // only the requests that belong to this order
        switchMap((value) =>
          of({
            ...value,
            requests: value.requests.filter((request) => request.orderNo === value.order.orderNo),
          }),
        ),
      ),
    () => this.id(),
  );

  protected readonly requirements = computed(() => {
    const value = this.data.value();
    return value ? requirementsFor(buildBomRows(value.bom, value.items), value.order.quantity) : [];
  });
  protected readonly canCheck = computed(() => {
    const status = this.data.value()?.order.status;
    return status ? canCheckMaterial(status) : false;
  });
  protected readonly canFinish = computed(() => {
    const status = this.data.value()?.order.status;
    return status ? canComplete(status) : false;
  });
  protected readonly overdue = computed(() => {
    const order = this.data.value()?.order;
    return order ? isOverdue(order.dueDate, order.status) : false;
  });

  protected checkMaterial(): void {
    const order = this.data.value()?.order;
    if (order) {
      this.actions.checkMaterial(
        order,
        (result) => {
          this.result.set(result);
          this.resultVisible.set(true);
        },
        () => this.data.reload(),
      );
    }
  }

  protected complete(): void {
    const order = this.data.value()?.order;
    if (order) {
      this.actions.complete(order, () => this.data.reload());
    }
  }
}
