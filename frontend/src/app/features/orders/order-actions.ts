import { inject, Injectable, signal } from '@angular/core';
import { ConfirmationService } from 'primeng/api';
import { NotificationService } from '../../core/notification.service';
import { OrdersApi } from '../../shared/api/api-services';
import { MaterialCheckResult, ProductionOrder } from '../../shared/models/api.models';

/**
 * The two state-changing actions on an order, shared by the list and the detail page:
 * material check (re-evaluates open orders; may create purchase requests) and completion (consumes stock).
 * Each action reports failures the same way and tells the caller when to reload.
 */
@Injectable({ providedIn: 'root' })
export class OrderActions {
  private readonly api = inject(OrdersApi);
  private readonly confirmation = inject(ConfirmationService);
  private readonly notify = inject(NotificationService);

  private readonly busyIds = signal<ReadonlySet<number>>(new Set());

  isBusy(orderId: number): boolean {
    return this.busyIds().has(orderId);
  }

  private setBusy(orderId: number, busy: boolean): void {
    this.busyIds.update((ids) => {
      const next = new Set(ids);
      if (busy) {
        next.add(orderId);
      } else {
        next.delete(orderId);
      }
      return next;
    });
  }

  checkMaterial(
    order: ProductionOrder,
    onResult: (result: MaterialCheckResult) => void,
    onDone: () => void,
  ): void {
    this.setBusy(order.id, true);
    this.api.checkMaterial(order.id).subscribe({
      next: (result) => {
        this.setBusy(order.id, false);
        onResult(result);
        onDone();
      },
      error: (error: unknown) => {
        this.setBusy(order.id, false);
        this.notify.error(error, `Materialprüfung ${order.orderNo}`);
        onDone();
      },
    });
  }

  complete(order: ProductionOrder, onDone: () => void): void {
    this.confirmation.confirm({
      header: 'Auftrag abschließen?',
      message: `${order.orderNo}: ${order.quantity} × ${order.productCode} gelten als gefertigt. Das Material wird aus dem Bestand gebucht und das Produkt eingebucht.`,
      icon: 'pi pi-question-circle',
      acceptLabel: 'Abschließen',
      rejectLabel: 'Abbrechen',
      accept: () => {
        this.setBusy(order.id, true);
        this.api.complete(order.id).subscribe({
          next: () => {
            this.setBusy(order.id, false);
            this.notify.success(`${order.orderNo} abgeschlossen`, 'Der Bestand wurde gebucht.');
            onDone();
          },
          error: (error: unknown) => {
            this.setBusy(order.id, false);
            this.notify.error(error, `Abschluss ${order.orderNo}`);
            onDone();
          },
        });
      },
    });
  }
}
