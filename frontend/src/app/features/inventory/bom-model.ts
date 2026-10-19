import { BomLine, Item } from '../../shared/models/api.models';

/**
 * View model of a bill of materials.
 *
 * TODAY the backend implements a SINGLE-LEVEL BOM only (GET /api/items/{id}/bom returns the direct components; material
 * check and completion do not explode sub-assemblies). This model is deliberately shaped like a tree node so that the
 * table can later be replaced by a PrimeNG TreeTable without touching callers: `children` is always empty for now and
 * `level` is always 0. Do not present it as a multi-level BOM until the backend explodes levels, rolls quantities up and
 * detects cycles (planned, see docs/frontend-architecture.md).
 */
export interface BomRow {
  id: number;
  level: number;
  itemId: number;
  code: string;
  name: string;
  unit: string;
  /** Quantity of this component needed for ONE piece of the parent. */
  qtyPer: number;
  /** Current stock of the component; null when the item list did not contain it. */
  qtyOnHand: number | null;
  children: BomRow[];
}

export function buildBomRows(lines: readonly BomLine[], items: readonly Item[]): BomRow[] {
  const stock = new Map(items.map((item) => [item.id, item.qtyOnHand]));
  return lines.map((line) => ({
    id: line.id,
    level: 0,
    itemId: line.componentId,
    code: line.componentCode,
    name: line.componentName,
    unit: line.unit,
    qtyPer: line.qtyPer,
    qtyOnHand: stock.get(line.componentId) ?? null,
    children: [],
  }));
}

export interface Producible {
  /** How many pieces of the parent the CURRENT stock of components allows (whole pieces); null when it cannot be determined. */
  pieces: number | null;
  /** Code of the component that limits it. */
  limitedBy: string | null;
}

/** "Can I produce it?" from today's stock: min over components of floor(stock / qtyPer). Single level only. */
export function producibleFromStock(rows: readonly BomRow[]): Producible {
  if (rows.length === 0 || rows.some((row) => row.qtyOnHand === null)) {
    return { pieces: null, limitedBy: null };
  }
  let pieces = Number.POSITIVE_INFINITY;
  let limitedBy: string | null = null;
  for (const row of rows) {
    const possible = Math.floor((row.qtyOnHand as number) / row.qtyPer + 1e-9);
    if (possible < pieces) {
      pieces = possible;
      limitedBy = row.code;
    }
  }
  return { pieces, limitedBy };
}

export interface RequirementRow {
  code: string;
  name: string;
  unit: string;
  required: number;
  available: number | null;
  shortage: number | null;
}

/** Requirement of a quantity of the parent against today's stock (read-only calculation, single level). */
export function requirementsFor(rows: readonly BomRow[], quantity: number): RequirementRow[] {
  return rows.map((row) => {
    const required = round3(row.qtyPer * quantity);
    const available = row.qtyOnHand;
    return {
      code: row.code,
      name: row.name,
      unit: row.unit,
      required,
      available,
      shortage: available === null ? null : round3(Math.max(required - available, 0)),
    };
  });
}

function round3(value: number): number {
  return Math.round(value * 1000) / 1000;
}
