import { BomLine, Item } from '../../shared/models/api.models';
import { buildBomRows, producibleFromStock, requirementsFor } from './bom-model';

/**
 * The numbers are the demo scenario of backend/src/main/resources/db/demo/V100__demo_data.sql and the demo script:
 * MR-200 needs 4 SC-M8, 2 PL-ST3, 3.5 m PR-40, 8 BR-L60 per piece; stock 25 / 30 / 50 / 100.
 */
const ITEMS: Item[] = [
  { id: 2, code: 'SC-M8', name: 'Hex screw M8x30', unit: 'pcs', type: 'MATERIAL', qtyOnHand: 25 },
  {
    id: 3,
    code: 'PL-ST3',
    name: 'Steel plate 3 mm 400x300',
    unit: 'pcs',
    type: 'MATERIAL',
    qtyOnHand: 30,
  },
  {
    id: 4,
    code: 'PR-40',
    name: 'Aluminium profile 40x40',
    unit: 'm',
    type: 'MATERIAL',
    qtyOnHand: 50,
  },
  {
    id: 5,
    code: 'BR-L60',
    name: 'Angle bracket L60',
    unit: 'pcs',
    type: 'MATERIAL',
    qtyOnHand: 100,
  },
];
const BOM: BomLine[] = [
  {
    id: 1,
    componentId: 2,
    componentCode: 'SC-M8',
    componentName: 'Hex screw M8x30',
    unit: 'pcs',
    qtyPer: 4,
  },
  {
    id: 2,
    componentId: 3,
    componentCode: 'PL-ST3',
    componentName: 'Steel plate 3 mm 400x300',
    unit: 'pcs',
    qtyPer: 2,
  },
  {
    id: 3,
    componentId: 4,
    componentCode: 'PR-40',
    componentName: 'Aluminium profile 40x40',
    unit: 'm',
    qtyPer: 3.5,
  },
  {
    id: 4,
    componentId: 5,
    componentCode: 'BR-L60',
    componentName: 'Angle bracket L60',
    unit: 'pcs',
    qtyPer: 8,
  },
];

describe('BOM view model (single level)', () => {
  it('joins components with their current stock and is shaped like a tree node (level 0, no children yet)', () => {
    const rows = buildBomRows(BOM, ITEMS);
    expect(rows).toHaveLength(4);
    expect(rows[0]).toMatchObject({
      code: 'SC-M8',
      qtyPer: 4,
      qtyOnHand: 25,
      level: 0,
      children: [],
    });
    expect(rows.every((row) => row.level === 0 && row.children.length === 0)).toBe(true);
  });

  it('marks stock as unknown (null) when the item list does not contain a component', () => {
    expect(buildBomRows(BOM, ITEMS.slice(1))[0].qtyOnHand).toBeNull();
  });
});

describe('producibleFromStock', () => {
  it('is the smallest of floor(stock / qtyPer): 6 pieces, limited by SC-M8 (25/4 = 6.25; others allow 15, 14, 12)', () => {
    expect(producibleFromStock(buildBomRows(BOM, ITEMS))).toEqual({
      pieces: 6,
      limitedBy: 'SC-M8',
    });
  });

  it('is 0 when a component has no stock', () => {
    const noScrews = ITEMS.map((i) => (i.code === 'SC-M8' ? { ...i, qtyOnHand: 0 } : i));
    expect(producibleFromStock(buildBomRows(BOM, noScrews))).toEqual({
      pieces: 0,
      limitedBy: 'SC-M8',
    });
  });

  it('handles decimal quantities exactly (7 m of a 3.5 m part is exactly 2 pieces, not 1)', () => {
    const rows = buildBomRows([BOM[2]], [{ ...ITEMS[2], qtyOnHand: 7 }]);
    expect(producibleFromStock(rows).pieces).toBe(2);
  });

  it('says "unknown" instead of guessing when stock or BOM is missing', () => {
    expect(producibleFromStock([])).toEqual({ pieces: null, limitedBy: null });
    expect(producibleFromStock(buildBomRows(BOM, ITEMS.slice(1))).pieces).toBeNull();
  });
});

describe('requirementsFor (read-only preview of the material check)', () => {
  it('10 pieces need 40 / 20 / 35 / 80 and leave a shortage of 15 SC-M8 only (the documented demo result)', () => {
    const result = requirementsFor(buildBomRows(BOM, ITEMS), 10);
    expect(result.map((r) => [r.code, r.required, r.available, r.shortage])).toEqual([
      ['SC-M8', 40, 25, 15],
      ['PL-ST3', 20, 30, 0],
      ['PR-40', 35, 50, 0],
      ['BR-L60', 80, 100, 0],
    ]);
  });

  it('keeps shortage null when the stock is unknown', () => {
    expect(requirementsFor(buildBomRows(BOM, ITEMS.slice(1)), 10)[0].shortage).toBeNull();
  });
});
