import { registerLocaleData } from '@angular/common';
import localeDe from '@angular/common/locales/de';
import { LOCALE_ID, signal } from '@angular/core';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { ConfirmationService, MessageService } from 'primeng/api';
import { of, throwError } from 'rxjs';
import { vi } from 'vitest';
import { AuthService } from '../../core/auth/auth.service';
import { allows, Permission, Role } from '../../core/auth/permissions';
import { ApiError } from '../../core/http/api-error';
import { PurchaseRequestsApi } from '../../shared/api/api-services';
import { PurchaseRequest } from '../../shared/models/api.models';
import { PurchaseRequestsPage } from './purchase-requests-page';

registerLocaleData(localeDe);

const request = (id: number, status: PurchaseRequest['status']): PurchaseRequest => ({
  id,
  itemId: 2,
  itemCode: 'SC-M8',
  itemName: 'Hex screw M8x30',
  unit: 'pcs',
  quantity: 15,
  status,
  orderNo: 'FA-00001',
  createdAt: '2026-10-19T10:00:00',
});
const REQUESTS = [request(1, 'OPEN'), request(2, 'APPROVED'), request(3, 'RECEIVED')];

async function render(
  roles: Role[],
  api: Partial<PurchaseRequestsApi>,
): Promise<ComponentFixture<PurchaseRequestsPage>> {
  TestBed.configureTestingModule({
    providers: [
      provideRouter([]),
      { provide: LOCALE_ID, useValue: 'de-DE' },
      MessageService,
      ConfirmationService,
      {
        provide: AuthService,
        useValue: { can: (p: Permission) => allows(roles, p), roles: signal(roles) },
      },
      { provide: PurchaseRequestsApi, useValue: api },
    ],
  });
  const fixture = TestBed.createComponent(PurchaseRequestsPage);
  fixture.detectChanges();
  await fixture.whenStable();
  fixture.detectChanges();
  return fixture;
}

const buttons = (fixture: ComponentFixture<unknown>, label: string): HTMLButtonElement[] =>
  Array.from((fixture.nativeElement as HTMLElement).querySelectorAll('button')).filter((b) =>
    b.textContent?.includes(label),
  );

describe('PurchaseRequestsPage (role-aware actions)', () => {
  it('PLANNER: sees the requests but no approve/receive action, and is told why (separation of duties)', async () => {
    const fixture = await render(['PLANNER'], { list: () => of(REQUESTS) });
    const text = (fixture.nativeElement as HTMLElement).textContent ?? '';
    expect(text).toContain('SC-M8');
    expect(text).toContain('Funktionstrennung');
    expect(buttons(fixture, 'Genehmigen')).toHaveLength(0);
    expect(buttons(fixture, 'Wareneingang buchen')).toHaveLength(0);
  });

  it('PURCHASER: approve only on the OPEN request, goods receipt only on the APPROVED one, nothing on RECEIVED', async () => {
    const fixture = await render(['PURCHASER'], { list: () => of(REQUESTS) });
    expect(buttons(fixture, 'Genehmigen')).toHaveLength(1);
    expect(buttons(fixture, 'Wareneingang buchen')).toHaveLength(1);
    expect((fixture.nativeElement as HTMLElement).textContent).not.toContain('Funktionstrennung');
  });

  it('asks for confirmation, then approves and reloads the list', async () => {
    const approve = vi.fn().mockReturnValue(of(request(1, 'APPROVED')));
    const list = vi.fn().mockReturnValue(of(REQUESTS));
    const fixture = await render(['PURCHASER'], { list, approve });
    const confirmation = TestBed.inject(ConfirmationService);
    const confirm = vi.spyOn(confirmation, 'confirm').mockImplementation((c) => {
      c.accept?.();
      return confirmation;
    });

    buttons(fixture, 'Genehmigen')[0].click();

    expect(confirm).toHaveBeenCalledTimes(1);
    expect(approve).toHaveBeenCalledWith(1);
    expect(list).toHaveBeenCalledTimes(2); // initial load + reload after the change
  });

  it('does nothing when the user cancels the confirmation', async () => {
    const approve = vi.fn();
    const fixture = await render(['PURCHASER'], { list: () => of(REQUESTS), approve });
    vi.spyOn(TestBed.inject(ConfirmationService), 'confirm').mockImplementation(() =>
      TestBed.inject(ConfirmationService),
    );
    buttons(fixture, 'Genehmigen')[0].click();
    expect(approve).not.toHaveBeenCalled();
  });

  it('shows the German 403 message and reloads when the backend refuses', async () => {
    const approve = vi.fn().mockReturnValue(throwError(() => new ApiError(403, 'forbidden', '')));
    const fixture = await render(['PURCHASER'], { list: () => of(REQUESTS), approve });
    const messages = vi.spyOn(TestBed.inject(MessageService), 'add');
    const confirmation = TestBed.inject(ConfirmationService);
    vi.spyOn(confirmation, 'confirm').mockImplementation((c) => {
      c.accept?.();
      return confirmation;
    });

    buttons(fixture, 'Genehmigen')[0].click();

    expect(messages).toHaveBeenCalledWith(
      expect.objectContaining({ severity: 'error', summary: 'Genehmigung: Keine Berechtigung' }),
    );
  });
});
