import { Component, input, output, Pipe, PipeTransform } from '@angular/core';
import { RouterLink } from '@angular/router';
import { Button } from 'primeng/button';
import { Tag } from 'primeng/tag';
import { describeError } from '../../core/http/api-error';
import { StatusView } from '../labels';

/** Status chip: text + icon + color, never color alone. */
@Component({
  selector: 'app-status-tag',
  imports: [Tag],
  template: `<p-tag [value]="view().label" [severity]="view().severity" [icon]="view().icon" />`,
})
export class StatusTag {
  readonly view = input.required<StatusView>();
}

@Component({
  selector: 'app-page-header',
  template: `
    <header class="mb-6 flex flex-wrap items-start justify-between gap-3">
      <div>
        <h1 class="m-0 text-2xl">{{ title() }}</h1>
        @if (subtitle()) {
          <p class="mb-0 mt-1 text-surface-500">{{ subtitle() }}</p>
        }
      </div>
      <div class="flex flex-wrap items-center gap-2"><ng-content /></div>
    </header>
  `,
})
export class PageHeader {
  readonly title = input.required<string>();
  readonly subtitle = input<string>();
}

export type Tone = 'neutral' | 'warn' | 'ok' | 'danger';

/** One real number with a label; links to the screen that explains it. */
@Component({
  selector: 'app-stat-tile',
  imports: [RouterLink],
  host: { class: 'block h-full' },
  template: `
    <a
      class="pf-card group block h-full p-4 no-underline transition-shadow hover:shadow-md"
      [routerLink]="link()"
      [queryParams]="queryParams()"
      [attr.aria-label]="label() + ': ' + value()"
    >
      <div class="flex items-center justify-between">
        <span class="text-sm font-medium text-surface-500">{{ label() }}</span>
        <i [class]="icon() + ' text-lg'" [style.color]="color()"></i>
      </div>
      <div class="tabular mt-2 text-3xl font-semibold text-surface-900">{{ value() }}</div>
      @if (hint()) {
        <div class="mt-1 text-sm text-surface-500">{{ hint() }}</div>
      }
    </a>
  `,
})
export class StatTile {
  readonly label = input.required<string>();
  readonly value = input.required<string | number>();
  readonly hint = input<string>();
  readonly icon = input('pi pi-chart-bar');
  readonly tone = input<Tone>('neutral');
  readonly link = input<string | string[]>('/');
  readonly queryParams = input<Record<string, string>>();

  color(): string {
    switch (this.tone()) {
      case 'warn':
        return 'var(--pf-warn)';
      case 'ok':
        return 'var(--pf-ok)';
      case 'danger':
        return 'var(--pf-danger)';
      default:
        return 'var(--p-primary-color)';
    }
  }
}

@Component({
  selector: 'app-empty-state',
  template: `
    <div class="flex flex-col items-center gap-2 px-4 py-10 text-center">
      <i [class]="icon() + ' text-3xl text-surface-400'"></i>
      <div class="font-medium text-surface-800">{{ title() }}</div>
      @if (text()) {
        <p class="m-0 max-w-md text-surface-500">{{ text() }}</p>
      }
      <ng-content />
    </div>
  `,
})
export class EmptyState {
  readonly icon = input('pi pi-inbox');
  readonly title = input.required<string>();
  readonly text = input<string>();
}

@Component({
  selector: 'app-error-state',
  imports: [Button],
  template: `
    <div class="pf-card flex flex-col items-center gap-2 px-4 py-10 text-center" role="alert">
      <i class="pi pi-exclamation-circle text-3xl" style="color: var(--pf-danger)"></i>
      <div class="font-medium">{{ message().title }}</div>
      <p class="m-0 max-w-md text-surface-500">{{ message().detail }}</p>
      <p-button
        label="Erneut versuchen"
        icon="pi pi-refresh"
        severity="secondary"
        [outlined]="true"
        (onClick)="retry.emit()"
      />
    </div>
  `,
})
export class ErrorState {
  readonly error = input.required<unknown>();
  readonly retry = output<void>();

  message(): { title: string; detail: string } {
    return describeError(this.error());
  }
}

/** 12,5 kg · German number format, at most 3 decimals (quantities are decimal in the backend). */
@Pipe({ name: 'qty' })
export class QtyPipe implements PipeTransform {
  private static readonly format = new Intl.NumberFormat('de-DE', { maximumFractionDigits: 3 });

  transform(value: number | null | undefined, unit?: string | null): string {
    if (value === null || value === undefined) {
      return '–';
    }
    const text = QtyPipe.format.format(value);
    return unit ? `${text} ${unit}` : text;
  }
}
