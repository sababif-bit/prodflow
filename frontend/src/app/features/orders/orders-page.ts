import { DatePipe } from '@angular/common';
import { Component, computed, effect, inject, input, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Router, RouterLink } from '@angular/router';
import { forkJoin } from 'rxjs';
import { Button } from 'primeng/button';
import { IconField } from 'primeng/iconfield';
import { InputIcon } from 'primeng/inputicon';
import { InputText } from 'primeng/inputtext';
import { Message } from 'primeng/message';
import { PrimeTemplate } from 'primeng/api';
import { SelectButton } from 'primeng/selectbutton';
import { Skeleton } from 'primeng/skeleton';
import { TableModule } from 'primeng/table';
import { AuthService } from '../../core/auth/auth.service';
import { NotificationService } from '../../core/notification.service';
import { ItemsApi, OrdersApi } from '../../shared/api/api-services';
import { ORDER_STATUS, StatusView } from '../../shared/labels';
import { MaterialCheckResult, OrderStatus, ProductionOrder } from '../../shared/models/api.models';
import { createLoadable } from '../../shared/util/loadable';
import {
  EmptyState,
  ErrorState,
  PageHeader,
  QtyPipe,
  StatusTag,
} from '../../shared/ui/ui-components';
import { MaterialResultDialog } from './material-result-dialog';
import { OrderActions } from './order-actions';
import { OrderCreateDialog } from './order-create-dialog';
import { canCheckMaterial, canComplete, isOverdue } from './order-utils';

type StatusFilter = 'ALL' | OrderStatus;

@Component({
  selector: 'app-orders-page',
  imports: [
    PageHeader,
    ErrorState,
    EmptyState,
    StatusTag,
    QtyPipe,
    DatePipe,
    RouterLink,
    FormsModule,
    Button,
    IconField,
    InputIcon,
    InputText,
    Message,
    SelectButton,
    Skeleton,
    TableModule,
    PrimeTemplate,
    OrderCreateDialog,
    MaterialResultDialog,
  ],
  template: `
    <app-page-header
      title="Fertigungsaufträge"
      subtitle="Aufträge anlegen, Material prüfen und abschließen"
    >
      <p-button
        label="Aktualisieren"
        icon="pi pi-refresh"
        severity="secondary"
        [outlined]="true"
        (onClick)="data.reload()"
      />
      @if (auth.can('order.create')) {
        <p-button label="Neuer Auftrag" icon="pi pi-plus" (onClick)="openCreate()" />
      }
    </app-page-header>

    @if (!auth.can('order.create')) {
      <p-message
        severity="secondary"
        class="mb-4 block"
        text="Ihre Rolle kann Aufträge einsehen. Anlegen, Materialprüfung und Abschluss sind der Planung vorbehalten."
      />
    }

    <div class="pf-card p-4">
      <div class="mb-4 flex flex-wrap items-center gap-3">
        <p-iconfield class="w-full sm:w-72">
          <p-inputicon class="pi pi-search" />
          <input
            pInputText
            type="search"
            class="w-full"
            placeholder="Auftrag oder Produkt suchen"
            aria-label="Aufträge suchen"
            [ngModel]="search()"
            (ngModelChange)="search.set($event)"
          />
        </p-iconfield>
        <p-selectbutton
          [options]="statusOptions"
          optionLabel="label"
          optionValue="value"
          [allowEmpty]="false"
          aria-label="Status filtern"
          [ngModel]="statusFilter()"
          (ngModelChange)="statusFilter.set($event)"
        />
      </div>

      @if (data.error(); as error) {
        <app-error-state [error]="error" (retry)="data.reload()" />
      } @else if (data.loading() && !data.value()) {
        <div class="grid gap-2" aria-busy="true" aria-label="Lädt">
          @for (n of [1, 2, 3, 4]; track n) {
            <p-skeleton height="2.75rem" />
          }
        </div>
      } @else {
        <div class="overflow-x-auto">
          <p-table
            [value]="filtered()"
            dataKey="id"
            [rowHover]="true"
            size="small"
            sortField="dueDate"
            [sortOrder]="1"
            [paginator]="filtered().length > 10"
            [rows]="10"
            [tableStyle]="{ 'min-width': '52rem' }"
          >
            <ng-template pTemplate="header">
              <tr>
                <th pSortableColumn="orderNo" scope="col">
                  Auftrag <p-sortIcon field="orderNo" />
                </th>
                <th scope="col">Produkt</th>
                <th pSortableColumn="quantity" scope="col" class="text-right">
                  Menge <p-sortIcon field="quantity" />
                </th>
                <th pSortableColumn="dueDate" scope="col">Fällig <p-sortIcon field="dueDate" /></th>
                <th pSortableColumn="status" scope="col">Status <p-sortIcon field="status" /></th>
                <th scope="col" class="text-right"><span class="sr-only">Aktionen</span></th>
              </tr>
            </ng-template>
            <ng-template pTemplate="body" let-order>
              <tr>
                <td class="font-medium">
                  <a [routerLink]="['/auftraege', order.id]">{{ order.orderNo }}</a>
                </td>
                <td>
                  {{ order.productCode }}
                  <span class="text-surface-500">{{ order.productName }}</span>
                </td>
                <td class="tabular text-right">{{ order.quantity | qty }}</td>
                <td>
                  {{ order.dueDate | date: 'dd.MM.yyyy' }}
                  @if (overdue(order)) {
                    <span class="ml-1 text-sm font-medium" style="color: var(--pf-danger)"
                      ><i class="pi pi-exclamation-circle"></i> überfällig</span
                    >
                  }
                </td>
                <td><app-status-tag [view]="orderView(order.status)" /></td>
                <td class="whitespace-nowrap text-right">
                  @if (canCheck(order) && auth.can('order.checkMaterial')) {
                    <p-button
                      label="Material prüfen"
                      icon="pi pi-refresh"
                      size="small"
                      severity="secondary"
                      [text]="true"
                      [loading]="actions.isBusy(order.id)"
                      (onClick)="checkMaterial(order)"
                    />
                  }
                  @if (canFinish(order) && auth.can('order.complete')) {
                    <p-button
                      label="Abschließen"
                      icon="pi pi-check"
                      size="small"
                      [loading]="actions.isBusy(order.id)"
                      (onClick)="complete(order)"
                    />
                  }
                  <a [routerLink]="['/auftraege', order.id]" class="ml-2 text-sm">Details</a>
                </td>
              </tr>
            </ng-template>
            <ng-template pTemplate="emptymessage">
              <tr>
                <td colspan="6">
                  <app-empty-state
                    icon="pi pi-cog"
                    title="Keine Aufträge gefunden"
                    [text]="
                      data.value()?.orders?.length
                        ? 'Passen Sie Suche oder Filter an.'
                        : 'Es wurde noch kein Fertigungsauftrag angelegt.'
                    "
                  />
                </td>
              </tr>
            </ng-template>
          </p-table>
        </div>
        <p class="mb-0 mt-3 text-sm text-surface-500">
          {{ filtered().length }} von {{ data.value()?.orders?.length ?? 0 }} Aufträgen
        </p>
      }
    </div>

    <app-order-create-dialog
      [(visible)]="createVisible"
      [products]="items()"
      [preselectProductId]="preselect()"
      (created)="onCreated($event)"
    />
    <app-material-result-dialog
      [(visible)]="resultVisible"
      [result]="result()"
      [orderNo]="resultOrderNo()"
    />
  `,
})
export class OrdersPage {
  /** URL inputs: ?status=WAITING_MATERIAL filters, ?neu=1&produkt=<id> opens the create dialog. */
  readonly status = input<string>();
  readonly neu = input<string>();
  readonly produkt = input<string>();

  protected readonly auth = inject(AuthService);
  protected readonly actions = inject(OrderActions);
  private readonly ordersApi = inject(OrdersApi);
  private readonly itemsApi = inject(ItemsApi);
  private readonly notify = inject(NotificationService);
  private readonly router = inject(Router);

  protected readonly data = createLoadable(() =>
    forkJoin({ orders: this.ordersApi.list(), items: this.itemsApi.list() }),
  );
  protected readonly items = computed(() => this.data.value()?.items ?? []);

  protected readonly search = signal('');
  protected readonly statusFilter = signal<StatusFilter>('ALL');
  protected readonly createVisible = signal(false);
  protected readonly preselect = signal<number | null>(null);
  protected readonly resultVisible = signal(false);
  protected readonly result = signal<MaterialCheckResult | null>(null);

  protected readonly statusView = ORDER_STATUS;

  protected orderView(status: OrderStatus): StatusView {
    return ORDER_STATUS[status];
  }
  protected readonly statusOptions = [
    { label: 'Alle', value: 'ALL' },
    { label: 'Wartet auf Material', value: 'WAITING_MATERIAL' },
    { label: 'Freigegeben', value: 'RELEASED' },
    { label: 'Abgeschlossen', value: 'DONE' },
  ];

  protected readonly filtered = computed<ProductionOrder[]>(() => {
    const term = this.search().trim().toLowerCase();
    const status = this.statusFilter();
    return (this.data.value()?.orders ?? []).filter(
      (order) =>
        (status === 'ALL' || order.status === status) &&
        (!term ||
          order.orderNo.toLowerCase().includes(term) ||
          order.productCode.toLowerCase().includes(term) ||
          order.productName.toLowerCase().includes(term)),
    );
  });
  protected readonly resultOrderNo = computed(() => {
    const id = this.result()?.orderId;
    return this.data.value()?.orders.find((order) => order.id === id)?.orderNo ?? null;
  });

  private createFromUrlHandled = false;

  constructor() {
    effect(() => {
      const status = this.status();
      if (status === 'WAITING_MATERIAL' || status === 'RELEASED' || status === 'DONE') {
        this.statusFilter.set(status);
      }
    });
    effect(() => {
      // ?neu=1 opens the create dialog once the data is there; the parameter is then removed so a reload does not reopen it
      if (
        this.neu() &&
        !this.createFromUrlHandled &&
        this.data.value() &&
        this.auth.can('order.create')
      ) {
        this.createFromUrlHandled = true;
        this.preselect.set(this.produkt() ? Number(this.produkt()) : null);
        this.createVisible.set(true);
        void this.router.navigate([], {
          queryParams: { neu: null, produkt: null },
          queryParamsHandling: 'merge',
          replaceUrl: true,
        });
      }
    });
  }

  protected openCreate(): void {
    this.preselect.set(null);
    this.createVisible.set(true);
  }

  protected overdue(order: ProductionOrder): boolean {
    return isOverdue(order.dueDate, order.status);
  }
  protected canCheck(order: ProductionOrder): boolean {
    return canCheckMaterial(order.status);
  }
  protected canFinish(order: ProductionOrder): boolean {
    return canComplete(order.status);
  }

  protected onCreated(result: MaterialCheckResult): void {
    this.result.set(result);
    this.resultVisible.set(true);
    this.notify.success(
      'Auftrag angelegt',
      result.status === 'RELEASED'
        ? 'Material vollständig – Auftrag freigegeben.'
        : 'Es fehlt Material – siehe Materialprüfung.',
    );
    this.data.reload();
  }

  protected checkMaterial(order: ProductionOrder): void {
    this.actions.checkMaterial(
      order,
      (result) => {
        this.result.set(result);
        this.resultVisible.set(true);
      },
      () => this.data.reload(),
    );
  }

  protected complete(order: ProductionOrder): void {
    this.actions.complete(order, () => this.data.reload());
  }
}
