import { inject, Injectable } from '@angular/core';
import { MessageService } from 'primeng/api';
import { describeError } from './http/api-error';

/** Toast messages in German. Errors are translated by describeError so every screen reports failures the same way. */
@Injectable({ providedIn: 'root' })
export class NotificationService {
  private readonly messages = inject(MessageService);

  success(summary: string, detail?: string): void {
    this.messages.add({ severity: 'success', summary, detail, life: 5000 });
  }

  info(summary: string, detail?: string): void {
    this.messages.add({ severity: 'info', summary, detail, life: 6000 });
  }

  error(error: unknown, context?: string): void {
    const { title, detail } = describeError(error);
    this.messages.add({
      severity: 'error',
      summary: context ? `${context}: ${title}` : title,
      detail,
      life: 9000,
    });
  }
}
