package de.prodflow.purchase;

import org.springframework.web.bind.annotation.*;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;

@RestController
@RequestMapping("/api/purchase-requests")
public class PurchaseRequestController {

    private final PurchaseRequestService service;

    public PurchaseRequestController(PurchaseRequestService service) {
        this.service = service;
    }

    public record PurchaseRequestResponse(Long id, Long itemId, String itemCode, String itemName, String unit,
                                          BigDecimal quantity, PurchaseRequestStatus status,
                                          String orderNo, LocalDateTime createdAt) {
        static PurchaseRequestResponse of(PurchaseRequest r) {
            return new PurchaseRequestResponse(r.getId(), r.getItem().getId(), r.getItem().getCode(),
                    r.getItem().getName(), r.getItem().getUnit(), r.getQuantity(), r.getStatus(),
                    r.getProductionOrder() == null ? null : r.getProductionOrder().getOrderNo(),
                    r.getCreatedAt());
        }
    }

    @GetMapping
    public List<PurchaseRequestResponse> list() {
        return service.findAll().stream().map(PurchaseRequestResponse::of).toList();
    }

    @PostMapping("/{id}/approve")
    public PurchaseRequestResponse approve(@PathVariable Long id) {
        return PurchaseRequestResponse.of(service.approve(id));
    }

    @PostMapping("/{id}/receive")
    public PurchaseRequestResponse receive(@PathVariable Long id) {
        return PurchaseRequestResponse.of(service.receive(id));
    }
}
