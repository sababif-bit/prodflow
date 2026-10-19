import { Component, computed, input } from '@angular/core';
import { OrderStatus } from '../../shared/models/api.models';

type StepState = 'done' | 'current' | 'todo';

interface Step {
  label: string;
  state: StepState;
}

/** Order life as three steps: material, release, completion. The current state decides which steps are done. */
export function orderSteps(status: OrderStatus): Step[] {
  const rank: Record<OrderStatus, number> = {
    CREATED: 0,
    WAITING_MATERIAL: 0,
    RELEASED: 1,
    DONE: 2,
  };
  const current = rank[status];
  const materialLabel = status === 'WAITING_MATERIAL' ? 'Wartet auf Material' : 'Materialprüfung';
  const stateOf = (index: number): StepState =>
    status === 'DONE' || index < current ? 'done' : index === current ? 'current' : 'todo';
  return [
    { label: materialLabel, state: stateOf(0) },
    { label: 'Freigegeben', state: stateOf(1) },
    { label: 'Abgeschlossen', state: status === 'DONE' ? 'done' : 'todo' },
  ];
}

@Component({
  selector: 'app-order-progress',
  template: `
    <ol class="m-0 flex list-none flex-wrap gap-2 p-0" aria-label="Auftragsfortschritt">
      @for (step of steps(); track step.label; let last = $last) {
        <li
          class="flex items-center gap-2"
          [attr.aria-current]="step.state === 'current' ? 'step' : null"
        >
          <span
            class="inline-flex h-7 w-7 items-center justify-center rounded-full text-xs font-semibold"
            [style.background]="
              step.state === 'done'
                ? 'var(--pf-ok-bg)'
                : step.state === 'current'
                  ? 'var(--pf-warn-bg)'
                  : 'var(--p-surface-100)'
            "
            [style.color]="
              step.state === 'done'
                ? 'var(--pf-ok)'
                : step.state === 'current'
                  ? 'var(--pf-warn)'
                  : 'var(--p-surface-500)'
            "
          >
            <i
              [class]="
                step.state === 'done'
                  ? 'pi pi-check'
                  : step.state === 'current'
                    ? 'pi pi-clock'
                    : 'pi pi-circle'
              "
            ></i>
          </span>
          <span [class]="step.state === 'todo' ? 'text-surface-400' : 'font-medium'">{{
            step.label
          }}</span>
          <span class="sr-only">{{
            step.state === 'done'
              ? '(erledigt)'
              : step.state === 'current'
                ? '(aktuell)'
                : '(offen)'
          }}</span>
          @if (!last) {
            <span class="mx-1 h-px w-6 bg-surface-300" aria-hidden="true"></span>
          }
        </li>
      }
    </ol>
  `,
})
export class OrderProgress {
  readonly status = input.required<OrderStatus>();
  protected readonly steps = computed(() => orderSteps(this.status()));
}
