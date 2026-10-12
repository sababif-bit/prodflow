package de.prodflow.order;

import java.math.BigDecimal;
import java.util.List;

/** Outcome of checking one production order against its BOM and current stock. */
public record MaterialCheckResult(Long orderId, OrderStatus status, List<Line> lines) {

    public record Line(String itemCode, String itemName, String unit,
                       BigDecimal required, BigDecimal available, BigDecimal shortage,
                       BigDecimal newlyRequested) {
    }

    public boolean hasShortage() {
        return lines.stream().anyMatch(l -> l.shortage().signum() > 0);
    }
}
