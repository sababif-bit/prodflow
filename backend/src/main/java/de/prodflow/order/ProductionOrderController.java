package de.prodflow.order;

import jakarta.validation.Valid;
import jakarta.validation.constraints.FutureOrPresent;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;

@RestController
@RequestMapping("/api/production-orders")
public class ProductionOrderController {

    private final ProductionOrderService service;

    public ProductionOrderController(ProductionOrderService service) {
        this.service = service;
    }

    public record CreateOrderRequest(@NotNull Long productId,
                                     @NotNull @Positive BigDecimal quantity,
                                     @NotNull @FutureOrPresent LocalDate dueDate) {
    }

    public record OrderResponse(Long id, String orderNo, Long productId, String productCode,
                                String productName, BigDecimal quantity, LocalDate dueDate,
                                OrderStatus status) {
        static OrderResponse of(ProductionOrder o) {
            return new OrderResponse(o.getId(), o.getOrderNo(), o.getItem().getId(), o.getItem().getCode(),
                    o.getItem().getName(), o.getQuantity(), o.getDueDate(), o.getStatus());
        }
    }

    /** The production plan: all orders sorted by due date. */
    @GetMapping
    public List<OrderResponse> plan() {
        return service.plan().stream().map(OrderResponse::of).toList();
    }

    @GetMapping("/{id}")
    public OrderResponse get(@PathVariable Long id) {
        return OrderResponse.of(service.get(id));
    }

    /** Creates the order and immediately runs the material check. */
    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public MaterialCheckResult create(@Valid @RequestBody CreateOrderRequest req) {
        return service.create(req.productId(), req.quantity(), req.dueDate());
    }

    @PostMapping("/{id}/check-material")
    public MaterialCheckResult checkMaterial(@PathVariable Long id) {
        return service.checkMaterial(id);
    }

    @PostMapping("/{id}/complete")
    public OrderResponse complete(@PathVariable Long id) {
        return OrderResponse.of(service.complete(id));
    }
}
