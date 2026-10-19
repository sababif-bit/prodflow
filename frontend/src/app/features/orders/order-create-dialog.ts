import { Component, computed, inject, input, model, output, signal } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { Button } from 'primeng/button';
import { DatePicker } from 'primeng/datepicker';
import { Dialog } from 'primeng/dialog';
import { InputNumber } from 'primeng/inputnumber';
import { Message } from 'primeng/message';
import { Select } from 'primeng/select';
import { describeError } from '../../core/http/api-error';
import { OrdersApi } from '../../shared/api/api-services';
import { Item, MaterialCheckResult } from '../../shared/models/api.models';
import { addDays, startOfToday, toIsoDate } from './order-utils';

/**
 * Create a production order. The backend immediately runs the material check, so the answer (released, or waiting with
 * the shortage and the purchase requests it created) is handed to the caller, who shows it.
 */
@Component({
  selector: 'app-order-create-dialog',
  imports: [Dialog, ReactiveFormsModule, Select, InputNumber, DatePicker, Button, Message],
  template: `
    <p-dialog
      header="Neuen Fertigungsauftrag anlegen"
      [(visible)]="visible"
      [modal]="true"
      [draggable]="false"
      [style]="{ width: '30rem', maxWidth: '95vw' }"
      (onShow)="prepare()"
    >
      <form [formGroup]="form" (ngSubmit)="submit()" class="grid gap-4" novalidate>
        <div class="grid gap-1.5">
          <label for="order-product" class="font-medium">Produkt</label>
          <p-select
            inputId="order-product"
            formControlName="productId"
            [options]="productOptions()"
            optionLabel="label"
            optionValue="id"
            placeholder="Produkt wählen"
            [filter]="true"
            appendTo="body"
            styleClass="w-full"
            [invalid]="invalid('productId')"
          />
          @if (invalid('productId')) {
            <small class="text-red-700" role="alert">Bitte ein Produkt wählen.</small>
          }
          @if (productOptions().length === 0) {
            <small class="text-surface-500">Es gibt keine Fertigprodukte.</small>
          }
        </div>

        <div class="grid gap-1.5">
          <label for="order-qty" class="font-medium">Menge</label>
          <p-inputnumber
            inputId="order-qty"
            formControlName="quantity"
            [min]="0.001"
            [minFractionDigits]="0"
            [maxFractionDigits]="3"
            locale="de-DE"
            styleClass="w-full"
            [invalid]="invalid('quantity')"
          />
          @if (invalid('quantity')) {
            <small class="text-red-700" role="alert">Die Menge muss größer als 0 sein.</small>
          }
        </div>

        <div class="grid gap-1.5">
          <label for="order-due" class="font-medium">Fälligkeitsdatum</label>
          <p-datepicker
            inputId="order-due"
            formControlName="dueDate"
            dateFormat="dd.mm.yy"
            [minDate]="today"
            [showIcon]="true"
            appendTo="body"
            styleClass="w-full"
            [invalid]="invalid('dueDate')"
          />
          @if (invalid('dueDate')) {
            <small class="text-red-700" role="alert"
              >Das Datum darf nicht in der Vergangenheit liegen.</small
            >
          }
        </div>

        @if (serverError(); as e) {
          <p-message severity="error" [text]="e.title + ': ' + e.detail" />
        }

        <div class="mt-2 flex justify-end gap-2">
          <p-button
            type="button"
            label="Abbrechen"
            severity="secondary"
            [text]="true"
            (onClick)="visible.set(false)"
          />
          <p-button
            type="submit"
            label="Anlegen und Material prüfen"
            icon="pi pi-check"
            [loading]="saving()"
          />
        </div>
      </form>
    </p-dialog>
  `,
})
export class OrderCreateDialog {
  readonly visible = model(false);
  readonly products = input.required<readonly Item[]>();
  readonly preselectProductId = input<number | null>(null);
  /** Emits the material-check result of the freshly created order. */
  readonly created = output<MaterialCheckResult>();

  private readonly api = inject(OrdersApi);

  protected readonly today = startOfToday();
  protected readonly saving = signal(false);
  protected readonly serverError = signal<{ title: string; detail: string } | null>(null);
  protected readonly productOptions = computed(() =>
    this.products()
      .filter((item) => item.type === 'PRODUCT')
      .map((item) => ({ id: item.id, label: `${item.code} – ${item.name}` })),
  );

  protected readonly form = new FormGroup({
    productId: new FormControl<number | null>(null, Validators.required),
    quantity: new FormControl<number | null>(1, [Validators.required, Validators.min(0.001)]),
    dueDate: new FormControl<Date | null>(addDays(startOfToday(), 14), Validators.required),
  });

  protected prepare(): void {
    this.serverError.set(null);
    this.form.reset({
      productId: this.preselectProductId(),
      quantity: 1,
      dueDate: addDays(startOfToday(), 14),
    });
  }

  protected invalid(name: 'productId' | 'quantity' | 'dueDate'): boolean {
    const control = this.form.controls[name];
    return control.invalid && (control.touched || control.dirty);
  }

  protected submit(): void {
    this.form.markAllAsTouched();
    const { productId, quantity, dueDate } = this.form.getRawValue();
    if (this.form.invalid || productId === null || quantity === null || dueDate === null) {
      return;
    }
    if (toIsoDate(dueDate) < toIsoDate(this.today)) {
      this.form.controls.dueDate.setErrors({ past: true });
      return;
    }
    this.saving.set(true);
    this.serverError.set(null);
    this.api.create({ productId, quantity, dueDate: toIsoDate(dueDate) }).subscribe({
      next: (result) => {
        this.saving.set(false);
        this.visible.set(false);
        this.created.emit(result);
      },
      error: (error: unknown) => {
        this.saving.set(false);
        this.serverError.set(describeError(error));
      },
    });
  }
}
