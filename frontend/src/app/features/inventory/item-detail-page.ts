import { Component, computed, inject, input } from '@angular/core';
import { Router, RouterLink } from '@angular/router';
import { forkJoin, of, switchMap } from 'rxjs';
import { Button } from 'primeng/button';
import { Message } from 'primeng/message';
import { Skeleton } from 'primeng/skeleton';
import { Tag } from 'primeng/tag';
import { AuthService } from '../../core/auth/auth.service';
import { ItemsApi } from '../../shared/api/api-services';
import { ITEM_TYPE_LABEL, STOCK_NONE, STOCK_OK } from '../../shared/labels';
import { createLoadable } from '../../shared/util/loadable';
import { ErrorState, PageHeader, QtyPipe, StatusTag } from '../../shared/ui/ui-components';
import { BomTable } from './bom-table';
import { buildBomRows, producibleFromStock } from './bom-model';

@Component({
  selector: 'app-item-detail-page',
  imports: [
    PageHeader,
    ErrorState,
    StatusTag,
    QtyPipe,
    BomTable,
    RouterLink,
    Button,
    Message,
    Skeleton,
    Tag,
  ],
  template: `
    <nav class="mb-3 text-sm" aria-label="Brotkrumen">
      <a routerLink="/bestand">← Bestand & Artikel</a>
    </nav>

    @if (data.error(); as error) {
      <app-error-state [error]="error" (retry)="data.reload()" />
    } @else if (data.value(); as d) {
      <app-page-header [title]="d.item.code" [subtitle]="d.item.name">
        <p-tag [value]="typeLabel[d.item.type]" severity="secondary" />
        <app-status-tag [view]="d.item.qtyOnHand > 0 ? stockOk : stockNone" />
        @if (d.item.type === 'PRODUCT' && auth.can('order.create')) {
          <p-button label="Auftrag anlegen" icon="pi pi-plus" (onClick)="newOrder(d.item.id)" />
        }
      </app-page-header>

      <div class="grid gap-6 lg:grid-cols-3">
        <section class="pf-card p-4 lg:col-span-1" aria-labelledby="master-h">
          <h2 id="master-h" class="mb-3 mt-0 text-base">Stammdaten</h2>
          <dl class="m-0 grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-sm">
            <dt class="text-surface-500">Artikel</dt>
            <dd class="m-0 font-medium">{{ d.item.code }}</dd>
            <dt class="text-surface-500">Bezeichnung</dt>
            <dd class="m-0">{{ d.item.name }}</dd>
            <dt class="text-surface-500">Typ</dt>
            <dd class="m-0">{{ typeLabel[d.item.type] }}</dd>
            <dt class="text-surface-500">Einheit</dt>
            <dd class="m-0">{{ d.item.unit }}</dd>
            <dt class="text-surface-500">Bestand</dt>
            <dd class="tabular m-0 font-medium">{{ d.item.qtyOnHand | qty: d.item.unit }}</dd>
          </dl>
        </section>

        <section class="pf-card p-4 lg:col-span-2" aria-labelledby="bom-h">
          <h2 id="bom-h" class="mb-3 mt-0 text-base">Stückliste</h2>
          @if (d.item.type === 'MATERIAL') {
            <p-message
              severity="secondary"
              text="Materialien werden eingekauft und haben keine Stückliste."
            />
          } @else {
            <p-message
              severity="info"
              class="mb-4 block"
              text="Einstufige Stückliste: Es werden nur die direkten Komponenten berücksichtigt. Mehrstufige Stücklisten (Baugruppen mit Unterbaugruppen) sind noch nicht umgesetzt."
            />
            @if (rows().length === 0) {
              <p class="text-surface-500">
                Für dieses Produkt ist keine Stückliste hinterlegt – Aufträge können erst mit
                Stückliste angelegt werden.
              </p>
            } @else {
              @if (producible(); as p) {
                @if (p.pieces !== null) {
                  <div
                    class="mb-4 rounded-lg p-3"
                    style="background: var(--p-primary-50)"
                    role="status"
                  >
                    <span class="font-medium">Aus dem aktuellen Bestand produzierbar:</span>
                    <span class="tabular ml-1 text-lg font-semibold">{{ p.pieces }} Stück</span>
                    @if (p.limitedBy) {
                      <span class="ml-1 text-surface-600">(begrenzt durch {{ p.limitedBy }})</span>
                    }
                  </div>
                }
              }
              <app-bom-table [rows]="rows()" />
            }
          }
        </section>
      </div>
    } @else {
      <div class="grid gap-3" aria-busy="true" aria-label="Lädt">
        <p-skeleton height="3rem" width="20rem" />
        <p-skeleton height="12rem" />
      </div>
    }
  `,
})
export class ItemDetailPage {
  /** Bound from the route parameter :id. */
  readonly id = input.required<string>();

  protected readonly auth = inject(AuthService);
  private readonly api = inject(ItemsApi);
  private readonly router = inject(Router);

  protected readonly typeLabel = ITEM_TYPE_LABEL;
  protected readonly stockOk = STOCK_OK;
  protected readonly stockNone = STOCK_NONE;

  protected readonly data = createLoadable(
    () => {
      const id = Number(this.id());
      return this.api.get(id).pipe(
        switchMap((item) =>
          forkJoin({
            item: of(item),
            items: this.api.list(),
            bom: item.type === 'PRODUCT' ? this.api.bom(id) : of([]),
          }),
        ),
      );
    },
    () => this.id(),
  );

  protected readonly rows = computed(() => {
    const value = this.data.value();
    return value ? buildBomRows(value.bom, value.items) : [];
  });
  protected readonly producible = computed(() =>
    this.rows().length > 0 ? producibleFromStock(this.rows()) : null,
  );

  protected newOrder(productId: number): void {
    void this.router.navigate(['/auftraege'], { queryParams: { neu: 1, produkt: productId } });
  }
}
