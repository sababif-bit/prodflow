import { Component, computed, effect, inject, input, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { RouterLink } from '@angular/router';
import { Button } from 'primeng/button';
import { IconField } from 'primeng/iconfield';
import { InputIcon } from 'primeng/inputicon';
import { InputText } from 'primeng/inputtext';
import { PrimeTemplate } from 'primeng/api';
import { SelectButton } from 'primeng/selectbutton';
import { Skeleton } from 'primeng/skeleton';
import { TableModule } from 'primeng/table';
import { Tag } from 'primeng/tag';
import { ItemsApi } from '../../shared/api/api-services';
import { ITEM_TYPE_LABEL, STOCK_NONE, STOCK_OK } from '../../shared/labels';
import { Item, ItemType } from '../../shared/models/api.models';
import { createLoadable } from '../../shared/util/loadable';
import {
  EmptyState,
  ErrorState,
  PageHeader,
  QtyPipe,
  StatusTag,
} from '../../shared/ui/ui-components';

type TypeFilter = 'ALL' | ItemType;

@Component({
  selector: 'app-inventory-page',
  imports: [
    PageHeader,
    ErrorState,
    EmptyState,
    StatusTag,
    QtyPipe,
    RouterLink,
    FormsModule,
    Button,
    IconField,
    InputIcon,
    InputText,
    SelectButton,
    Skeleton,
    TableModule,
    PrimeTemplate,
    Tag,
  ],
  template: `
    <app-page-header
      title="Bestand & Artikel"
      subtitle="Materialien und Fertigprodukte mit aktuellem Lagerbestand"
    >
      <p-button
        label="Aktualisieren"
        icon="pi pi-refresh"
        severity="secondary"
        [outlined]="true"
        (onClick)="data.reload()"
      />
    </app-page-header>

    <div class="pf-card p-4">
      <div class="mb-4 flex flex-wrap items-center gap-3">
        <p-iconfield class="w-full sm:w-72">
          <p-inputicon class="pi pi-search" />
          <input
            pInputText
            type="search"
            class="w-full"
            placeholder="Code oder Bezeichnung suchen"
            aria-label="Artikel suchen"
            [ngModel]="search()"
            (ngModelChange)="search.set($event)"
          />
        </p-iconfield>
        <p-selectbutton
          [options]="typeOptions"
          optionLabel="label"
          optionValue="value"
          [allowEmpty]="false"
          aria-label="Artikeltyp filtern"
          [ngModel]="typeFilter()"
          (ngModelChange)="typeFilter.set($event)"
        />
        <p-selectbutton
          [options]="stockOptions"
          optionLabel="label"
          optionValue="value"
          [allowEmpty]="false"
          aria-label="Bestand filtern"
          [ngModel]="onlyNone() ? 'none' : 'all'"
          (ngModelChange)="onlyNone.set($event === 'none')"
        />
      </div>

      @if (data.error(); as error) {
        <app-error-state [error]="error" (retry)="data.reload()" />
      } @else if (data.loading() && !data.value()) {
        <div class="grid gap-2" aria-busy="true" aria-label="Lädt">
          @for (n of [1, 2, 3, 4, 5]; track n) {
            <p-skeleton height="2.5rem" />
          }
        </div>
      } @else {
        <div class="overflow-x-auto">
          <p-table
            [value]="filtered()"
            dataKey="id"
            [rowHover]="true"
            size="small"
            sortField="code"
            [sortOrder]="1"
            [paginator]="filtered().length > 12"
            [rows]="12"
            [tableStyle]="{ 'min-width': '44rem' }"
          >
            <ng-template pTemplate="header">
              <tr>
                <th pSortableColumn="code" scope="col">Artikel <p-sortIcon field="code" /></th>
                <th pSortableColumn="name" scope="col">Bezeichnung <p-sortIcon field="name" /></th>
                <th pSortableColumn="type" scope="col">Typ <p-sortIcon field="type" /></th>
                <th pSortableColumn="qtyOnHand" scope="col" class="text-right">
                  Bestand <p-sortIcon field="qtyOnHand" />
                </th>
                <th scope="col">Status</th>
                <th scope="col"><span class="sr-only">Aktionen</span></th>
              </tr>
            </ng-template>
            <ng-template pTemplate="body" let-item>
              <tr>
                <td class="font-medium">
                  <a [routerLink]="['/bestand', item.id]">{{ item.code }}</a>
                </td>
                <td>{{ item.name }}</td>
                <td><p-tag [value]="typeName(item.type)" severity="secondary" /></td>
                <td class="tabular text-right">{{ item.qtyOnHand | qty: item.unit }}</td>
                <td><app-status-tag [view]="item.qtyOnHand > 0 ? stockOk : stockNone" /></td>
                <td class="text-right">
                  <a [routerLink]="['/bestand', item.id]" class="text-sm">Details</a>
                </td>
              </tr>
            </ng-template>
            <ng-template pTemplate="emptymessage">
              <tr>
                <td colspan="6">
                  <app-empty-state
                    icon="pi pi-search"
                    title="Keine Artikel gefunden"
                    text="Passen Sie Suche oder Filter an."
                  />
                </td>
              </tr>
            </ng-template>
          </p-table>
        </div>
        <p class="mb-0 mt-3 text-sm text-surface-500">
          {{ filtered().length }} von {{ data.value()?.length ?? 0 }} Artikeln
        </p>
      }
    </div>
  `,
})
export class InventoryPage {
  /** ?stock=none and ?type=MATERIAL|PRODUCT are bound from the URL (links on the overview). */
  readonly stock = input<string>();
  readonly type = input<string>();

  private readonly api = inject(ItemsApi);
  protected readonly data = createLoadable(() => this.api.list());

  protected readonly search = signal('');
  protected readonly typeFilter = signal<TypeFilter>('ALL');
  protected readonly onlyNone = signal(false);

  protected readonly typeLabel = ITEM_TYPE_LABEL;

  protected typeName(type: ItemType): string {
    return ITEM_TYPE_LABEL[type];
  }
  protected readonly stockOk = STOCK_OK;
  protected readonly stockNone = STOCK_NONE;
  protected readonly typeOptions = [
    { label: 'Alle', value: 'ALL' },
    { label: 'Material', value: 'MATERIAL' },
    { label: 'Fertigprodukte', value: 'PRODUCT' },
  ];
  protected readonly stockOptions = [
    { label: 'Alle Bestände', value: 'all' },
    { label: 'Nur ohne Bestand', value: 'none' },
  ];

  protected readonly filtered = computed<Item[]>(() => {
    const term = this.search().trim().toLowerCase();
    const type = this.typeFilter();
    const none = this.onlyNone();
    return (this.data.value() ?? []).filter(
      (item) =>
        (type === 'ALL' || item.type === type) &&
        (!none || item.qtyOnHand <= 0) &&
        (!term || item.code.toLowerCase().includes(term) || item.name.toLowerCase().includes(term)),
    );
  });

  constructor() {
    effect(() => {
      if (this.stock() === 'none') {
        this.onlyNone.set(true);
      }
      const type = this.type();
      if (type === 'MATERIAL' || type === 'PRODUCT') {
        this.typeFilter.set(type);
      }
    });
  }
}
