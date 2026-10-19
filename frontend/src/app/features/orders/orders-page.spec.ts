import { registerLocaleData } from '@angular/common';
import localeDe from '@angular/common/locales/de';
import { LOCALE_ID, signal } from '@angular/core';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { ConfirmationService, MessageService } from 'primeng/api';
import { of } from 'rxjs';
import { vi } from 'vitest';
import { AuthService } from '../../core/auth/auth.service';
import { allows, Permission, Role } from '../../core/auth/permissions';
import { ItemsApi, OrdersApi } from '../../shared/api/api-services';
import { Item, ProductionOrder } from '../../shared/models/api.models';
import { OrdersPage } from './orders-page';

registerLocaleData(localeDe);

const order = (id: number, status: ProductionOrder['status']): ProductionOrder => ({
  id,
  orderNo: `FA-${String(id).padStart(5, '0')}`,
  productId: 1,
  productCode: 'MR-200',
  productName: 'Machine frame MR-200',
  quantity: 10,
  dueDate: '2099-01-01',
  status,
});
const ORDERS = [order(1, 'WAITING_MATERIAL'), order(2, 'RELEASED'), order(3, 'DONE')];
const ITEMS: Item[] = [
  {
    id: 1,
    code: 'MR-200',
    name: 'Machine frame MR-200',
    unit: 'pcs',
    type: 'PRODUCT',
    qtyOnHand: 0,
  },
];

async function render(
  roles: Role[],
  orders: Partial<OrdersApi> = {},
): Promise<ComponentFixture<OrdersPage>> {
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
      { provide: OrdersApi, useValue: { list: () => of(ORDERS), ...orders } },
      { provide: ItemsApi, useValue: { list: () => of(ITEMS) } },
    ],
  });
  const fixture = TestBed.createComponent(OrdersPage);
  fixture.detectChanges();
  await fixture.whenStable();
  fixture.detectChanges();
  return fixture;
}

const buttons = (fixture: ComponentFixture<unknown>, label: string): HTMLButtonElement[] =>
  Array.from((fixture.nativeElement as HTMLElement).querySelectorAll('button')).filter((b) =>
    b.textContent?.includes(label),
  );

describe('OrdersPage (role-aware actions)', () => {
  it('PLANNER: can create orders; "Material prüfen" only for the waiting order, "Abschließen" only for the released one', async () => {
    const fixture = await render(['PLANNER']);
    expect(buttons(fixture, 'Neuer Auftrag')).toHaveLength(1);
    expect(buttons(fixture, 'Material prüfen')).toHaveLength(1);
    expect(buttons(fixture, 'Abschließen')).toHaveLength(1);
  });

  it('PURCHASER: sees all orders but has no create or row actions, and the page says so', async () => {
    const fixture = await render(['PURCHASER']);
    const text = (fixture.nativeElement as HTMLElement).textContent ?? '';
    expect(text).toContain('FA-00001');
    expect(text).toContain('FA-00003');
    expect(text).toContain('der Planung vorbehalten');
    expect(buttons(fixture, 'Neuer Auftrag')).toHaveLength(0);
    expect(buttons(fixture, 'Material prüfen')).toHaveLength(0);
    expect(buttons(fixture, 'Abschließen')).toHaveLength(0);
  });

  it('shows each order with its German status', async () => {
    const text = ((await render(['PLANNER'])).nativeElement as HTMLElement).textContent ?? '';
    expect(text).toContain('Wartet auf Material');
    expect(text).toContain('Freigegeben');
    expect(text).toContain('Abgeschlossen');
  });

  it('"Material prüfen" calls the check for exactly that order and then reloads', async () => {
    const checkMaterial = vi
      .fn()
      .mockReturnValue(of({ orderId: 1, status: 'RELEASED', lines: [] }));
    const list = vi.fn().mockReturnValue(of(ORDERS));
    const fixture = await render(['PLANNER'], { list, checkMaterial });
    buttons(fixture, 'Material prüfen')[0].click();
    expect(checkMaterial).toHaveBeenCalledWith(1);
    expect(list).toHaveBeenCalledTimes(2);
  });

  it('"Abschließen" asks for confirmation before it completes anything', async () => {
    const complete = vi.fn().mockReturnValue(of(order(2, 'DONE')));
    const fixture = await render(['PLANNER'], { complete });
    const confirmation = TestBed.inject(ConfirmationService);
    const confirm = vi.spyOn(confirmation, 'confirm').mockImplementation(() => confirmation); // user has not accepted yet
    buttons(fixture, 'Abschließen')[0].click();
    expect(confirm).toHaveBeenCalledTimes(1);
    expect(complete).not.toHaveBeenCalled();
  });
});
