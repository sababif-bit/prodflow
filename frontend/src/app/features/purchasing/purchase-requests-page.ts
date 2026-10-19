import { DatePipe } from '@angular/common';
import { Component, computed, effect, inject, input, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { RouterLink } from '@angular/router';
import { Button } from 'primeng/button';
import { Message } from 'primeng/message';
import { ConfirmationService, PrimeTemplate } from 'primeng/api';
import { SelectButton } from 'primeng/selectbutton';
import { Skeleton } from 'primeng/skeleton';
import { TableModule } from 'primeng/table';
import { AuthService } from '../../core/auth/auth.service';
import { NotificationService } from '../../core/notification.service';
import { PurchaseRequestsApi } from '../../shared/api/api-services';
import { PURCHASE_STATUS, StatusView } from '../../shared/labels';
import { PurchaseRequest, PurchaseRequestStatus } from '../../shared/models/api.models';
import { createLoadable } from '../../shared/util/loadable';
import {
  EmptyState,
  ErrorState,
  PageHeader,
  QtyPipe,
  StatusTag,
} from '../../shared/ui/ui-components';

type StatusFilter = 'ALL' | PurchaseRequestStatus;

@Component({
  selector: 'app-purchase-requests-page',
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
    Message,
    SelectButton,
    Skeleton,
    TableModule,
    PrimeTemplate,
  ],
  template: `
    <app-page-header
      title="Bestellanforderungen"
      subtitle="Fehlmengen aus Fertigungsaufträgen: genehmigen und Wareneingang buchen"
    >
      <p-button
        label="Aktualisieren"
        icon="pi pi-refresh"
        severity="secondary"
        [outlined]="true"
        (onClick)="data.reload()"
      />
    </app-page-header>

    @if (!auth.can('purchase.approve')) {
      <p-message
        severity="secondary"
        class="mb-4 block"
        text="Funktionstrennung: Genehmigung und Wareneingang sind dem Einkauf vorbehalten. Ihre Rolle kann Bestellanforderungen einsehen."
      />
    }

    <div class="pf-card p-4">
      <div class="mb-4">
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
          @for (n of [1, 2, 3]; track n) {
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
            sortField="id"
            [sortOrder]="1"
            [paginator]="filtered().length > 10"
            [rows]="10"
            [tableStyle]="{ 'min-width': '52rem' }"
          >
            <ng-template pTemplate="header">
              <tr>
                <th pSortableColumn="id" scope="col">Nr. <p-sortIcon field="id" /></th>
                <th scope="col">Material</th>
                <th pSortableColumn="quantity" scope="col" class="text-right">
                  Menge <p-sortIcon field="quantity" />
                </th>
                <th scope="col">Auftrag</th>
                <th pSortableColumn="status" scope="col">Status <p-sortIcon field="status" /></th>
                <th pSortableColumn="createdAt" scope="col">
                  Angelegt <p-sortIcon field="createdAt" />
                </th>
                <th scope="col" class="text-right"><span class="sr-only">Aktionen</span></th>
              </tr>
            </ng-template>
            <ng-template pTemplate="body" let-request>
              <tr>
                <td class="font-medium">{{ request.id }}</td>
                <td>
                  {{ request.itemCode }}
                  <span class="text-surface-500">{{ request.itemName }}</span>
                </td>
                <td class="tabular text-right">{{ request.quantity | qty: request.unit }}</td>
                <td>
                  @if (request.orderNo) {
                    <a routerLink="/auftraege" [queryParams]="{ status: 'WAITING_MATERIAL' }">{{
                      request.orderNo
                    }}</a>
                  } @else {
                    –
                  }
                </td>
                <td><app-status-tag [view]="view(request.status)" /></td>
                <td class="whitespace-nowrap">
                  {{ request.createdAt | date: 'dd.MM.yyyy HH:mm' }}
                </td>
                <td class="whitespace-nowrap text-right">
                  @if (request.status === 'OPEN' && auth.can('purchase.approve')) {
                    <p-button
                      label="Genehmigen"
                      icon="pi pi-thumbs-up"
                      size="small"
                      [loading]="busy().has(request.id)"
                      (onClick)="approve(request)"
                    />
                  }
                  @if (request.status === 'APPROVED' && auth.can('purchase.receive')) {
                    <p-button
                      label="Wareneingang buchen"
                      icon="pi pi-box"
                      size="small"
                      [loading]="busy().has(request.id)"
                      (onClick)="receive(request)"
                    />
                  }
                </td>
              </tr>
            </ng-template>
            <ng-template pTemplate="emptymessage">
              <tr>
                <td colspan="7">
                  <app-empty-state
                    icon="pi pi-shopping-cart"
                    title="Keine Bestellanforderungen"
                    [text]="
                      data.value()?.length
                        ? 'Für diesen Filter gibt es keine Einträge.'
                        : 'Es gibt noch keine Fehlmenge. Anforderungen entstehen automatisch bei der Materialprüfung.'
                    "
                  />
                </td>
              </tr>
            </ng-template>
          </p-table>
        </div>
      }
    </div>
  `,
})
export class PurchaseRequestsPage {
  /** ?status=OPEN etc. bound from the URL. */
  readonly status = input<string>();

  protected readonly auth = inject(AuthService);
  private readonly api = inject(PurchaseRequestsApi);
  private readonly confirmation = inject(ConfirmationService);
  private readonly notify = inject(NotificationService);

  protected readonly data = createLoadable(() => this.api.list());
  protected readonly statusFilter = signal<StatusFilter>('ALL');
  protected readonly busy = signal<ReadonlySet<number>>(new Set());
  protected readonly statusView = PURCHASE_STATUS;

  protected view(status: PurchaseRequestStatus): StatusView {
    return PURCHASE_STATUS[status];
  }
  protected readonly statusOptions = [
    { label: 'Alle', value: 'ALL' },
    { label: 'Offen', value: 'OPEN' },
    { label: 'Genehmigt', value: 'APPROVED' },
    { label: 'Wareneingang gebucht', value: 'RECEIVED' },
  ];

  protected readonly filtered = computed<PurchaseRequest[]>(() => {
    const status = this.statusFilter();
    return (this.data.value() ?? []).filter(
      (request) => status === 'ALL' || request.status === status,
    );
  });

  constructor() {
    effect(() => {
      const status = this.status();
      if (status === 'OPEN' || status === 'APPROVED' || status === 'RECEIVED') {
        this.statusFilter.set(status);
      }
    });
  }

  protected approve(request: PurchaseRequest): void {
    this.confirmation.confirm({
      header: 'Bestellanforderung genehmigen?',
      message: `Nr. ${request.id}: ${request.quantity} ${request.unit} ${request.itemCode} werden zur Beschaffung freigegeben.`,
      icon: 'pi pi-question-circle',
      acceptLabel: 'Genehmigen',
      rejectLabel: 'Abbrechen',
      accept: () =>
        this.run(
          request,
          this.api.approve(request.id),
          `Nr. ${request.id} genehmigt`,
          'Der Wareneingang kann jetzt gebucht werden.',
          'Genehmigung',
        ),
    });
  }

  protected receive(request: PurchaseRequest): void {
    this.confirmation.confirm({
      header: 'Wareneingang buchen?',
      message: `Nr. ${request.id}: ${request.quantity} ${request.unit} ${request.itemCode} gelten als geliefert. Der Bestand steigt, wartende Aufträge werden automatisch neu geprüft.`,
      icon: 'pi pi-question-circle',
      acceptLabel: 'Wareneingang buchen',
      rejectLabel: 'Abbrechen',
      accept: () =>
        this.run(
          request,
          this.api.receive(request.id),
          `Nr. ${request.id}: Wareneingang gebucht`,
          'Bestand erhöht; wartende Aufträge wurden vom System neu geprüft.',
          'Wareneingang',
        ),
    });
  }

  private run(
    request: PurchaseRequest,
    call: ReturnType<PurchaseRequestsApi['approve']>,
    summary: string,
    detail: string,
    context: string,
  ): void {
    this.busy.update((ids) => new Set(ids).add(request.id));
    call.subscribe({
      next: () => {
        this.busy.update((ids) => {
          const next = new Set(ids);
          next.delete(request.id);
          return next;
        });
        this.notify.success(summary, detail);
        this.data.reload();
      },
      error: (error: unknown) => {
        this.busy.update((ids) => {
          const next = new Set(ids);
          next.delete(request.id);
          return next;
        });
        this.notify.error(error, context);
        this.data.reload();
      },
    });
  }
}
