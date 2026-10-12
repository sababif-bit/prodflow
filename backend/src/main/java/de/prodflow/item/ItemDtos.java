package de.prodflow.item;

import jakarta.validation.constraints.*;

import java.math.BigDecimal;

public final class ItemDtos {

    private ItemDtos() {
    }

    public record CreateItemRequest(
            @NotBlank @Size(max = 40) String code,
            @NotBlank @Size(max = 200) String name,
            @NotBlank @Size(max = 20) String unit,
            @NotNull ItemType type,
            @NotNull @PositiveOrZero BigDecimal qtyOnHand) {
    }

    public record UpdateItemRequest(
            @NotBlank @Size(max = 200) String name,
            @NotBlank @Size(max = 20) String unit) {
    }

    public record StockAdjustmentRequest(@NotNull @Positive BigDecimal quantity) {
    }

    public record ItemResponse(Long id, String code, String name, String unit,
                               ItemType type, BigDecimal qtyOnHand) {
        public static ItemResponse of(Item i) {
            return new ItemResponse(i.getId(), i.getCode(), i.getName(), i.getUnit(),
                    i.getType(), i.getQtyOnHand());
        }
    }
}
