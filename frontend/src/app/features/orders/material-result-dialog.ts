import { Component, computed, input, model } from '@angular/core';
import { RouterLink } from '@angular/router';
import { Button } from 'primeng/button';
import { Dialog } from 'primeng/dialog';
import { Message } from 'primeng/message';
import { PrimeTemplate } from 'primeng/api';
import { TableModule } from 'primeng/table';
import { ORDER_STATUS } from '../../shared/labels';
import { MaterialCheckResult } from '../../shared/models/api.models';
import { QtyPipe, StatusTag } from '../../shared/ui/ui-components';

/** Shows what the material check found: per component required, available, shortage and what was newly requested. */
@Component({
  selector: 'app-material-result-dialog',
  imports: [Dialog, TableModule, PrimeTemplate, QtyPipe, StatusTag, Message, Button, RouterLink],
  template: `
    <p-dialog
      [header]="'Materialprüfung' + (orderNo() ? ' · ' + orderNo() : '')"
      [(visible)]="visible"
      [modal]="true"
      [draggable]="false"
      [style]="{ width: '46rem', maxWidth: '95vw' }"
    >
      @if (result(); as r) {
        <div class="mb-3 flex items-center gap-2">
          <span class="text-surface-500">Ergebnis:</span>
          <app-status-tag [view]="statusView()" />
        </div>
        @if (shortages() === 0) {
          <p-message
            severity="success"
            class="mb-4 block"
            text="Alle Materialien sind in ausreichender Menge vorhanden. Der Auftrag ist freigegeben."
          />
        } @else {
          <p-message
            severity="warn"
            class="mb-4 block"
            [text]="
              shortages() === 1
                ? 'Bei 1 Material fehlt Bestand. ' + requestedText()
                : 'Bei ' + shortages() + ' Materialien fehlt Bestand. ' + requestedText()
            "
          />
        }
        <div class="overflow-x-auto">
          <p-table [value]="r.lines" size="small" [tableStyle]="{ 'min-width': '36rem' }">
            <ng-template pTemplate="header">
              <tr>
                <th scope="col">Material</th>
                <th scope="col" class="text-right">Benötigt</th>
                <th scope="col" class="text-right">Vorhanden</th>
                <th scope="col" class="text-right">Fehlmenge</th>
                <th scope="col" class="text-right">Neu angefordert</th>
              </tr>
            </ng-template>
            <ng-template pTemplate="body" let-line>
              <tr>
                <td>
                  <span class="font-medium">{{ line.itemCode }}</span
                  ><span class="ml-2 text-surface-500">{{ line.itemName }}</span>
                </td>
                <td class="tabular text-right">{{ line.required | qty: line.unit }}</td>
                <td class="tabular text-right">{{ line.available | qty: line.unit }}</td>
                <td
                  class="tabular text-right"
                  [style.color]="line.shortage > 0 ? 'var(--pf-danger)' : null"
                  [class.font-semibold]="line.shortage > 0"
                >
                  {{ line.shortage > 0 ? (line.shortage | qty: line.unit) : '–' }}
                </td>
                <td class="tabular text-right">
                  {{ line.newlyRequested > 0 ? (line.newlyRequested | qty: line.unit) : '–' }}
                </td>
              </tr>
            </ng-template>
          </p-table>
        </div>
      }
      <ng-template pTemplate="footer">
        @if (shortages() > 0) {
          <a routerLink="/bestellanforderungen" (click)="visible.set(false)"
            ><p-button
              type="button"
              label="Zu den Bestellanforderungen"
              icon="pi pi-shopping-cart"
              severity="secondary"
              [outlined]="true"
          /></a>
        }
        <p-button type="button" label="Schließen" (onClick)="visible.set(false)" />
      </ng-template>
    </p-dialog>
  `,
})
export class MaterialResultDialog {
  readonly visible = model(false);
  readonly result = input<MaterialCheckResult | null>(null);
  readonly orderNo = input<string | null>(null);

  protected readonly shortages = computed(
    () => this.result()?.lines.filter((line) => line.shortage > 0).length ?? 0,
  );
  protected readonly statusView = computed(() => ORDER_STATUS[this.result()?.status ?? 'CREATED']);
  protected readonly requestedText = computed(() => {
    const created = this.result()?.lines.filter((line) => line.newlyRequested > 0).length ?? 0;
    return created > 0
      ? `Das System hat ${created === 1 ? 'eine Bestellanforderung' : created + ' Bestellanforderungen'} angelegt.`
      : 'Die Fehlmenge ist bereits durch offene Bestellanforderungen abgedeckt.';
  });
}
