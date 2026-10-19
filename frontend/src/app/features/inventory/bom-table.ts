import { Component, input } from '@angular/core';
import { RouterLink } from '@angular/router';
import { PrimeTemplate } from 'primeng/api';
import { TableModule } from 'primeng/table';
import { STOCK_NONE, STOCK_OK } from '../../shared/labels';
import { QtyPipe, StatusTag } from '../../shared/ui/ui-components';
import { BomRow } from './bom-model';

/**
 * Read-only, single-level BOM table.
 * Extension point: when the backend delivers a multi-level structure (BomRow.children), swap this component for a
 * PrimeNG TreeTable with the same row model; the page and its callers stay unchanged.
 */
@Component({
  selector: 'app-bom-table',
  imports: [TableModule, PrimeTemplate, QtyPipe, StatusTag, RouterLink],
  template: `
    <div class="overflow-x-auto">
      <p-table [value]="rows()" dataKey="id" size="small" [tableStyle]="{ 'min-width': '38rem' }">
        <ng-template pTemplate="header">
          <tr>
            <th scope="col">Komponente</th>
            <th scope="col" class="text-right">Menge je Stück</th>
            <th scope="col" class="text-right">Bestand heute</th>
            <th scope="col" class="text-right">Reicht für</th>
            <th scope="col">Status</th>
          </tr>
        </ng-template>
        <ng-template pTemplate="body" let-row>
          <tr>
            <td>
              <a [routerLink]="['/bestand', row.itemId]" class="font-medium">{{ row.code }}</a>
              <span class="ml-2 text-surface-500">{{ row.name }}</span>
            </td>
            <td class="tabular text-right">{{ row.qtyPer | qty: row.unit }}</td>
            <td class="tabular text-right">{{ row.qtyOnHand | qty: row.unit }}</td>
            <td class="tabular text-right">{{ fits(row) }}</td>
            <td class="whitespace-nowrap">
              <app-status-tag [view]="row.qtyOnHand !== null && row.qtyOnHand > 0 ? ok : none" />
            </td>
          </tr>
        </ng-template>
      </p-table>
    </div>
  `,
})
export class BomTable {
  readonly rows = input.required<BomRow[]>();
  protected readonly ok = STOCK_OK;
  protected readonly none = STOCK_NONE;

  /** How many pieces of the parent this component's stock alone covers. */
  protected fits(row: BomRow): string {
    if (row.qtyOnHand === null) {
      return '–';
    }
    return `${Math.floor(row.qtyOnHand / row.qtyPer + 1e-9)} Stück`;
  }
}
