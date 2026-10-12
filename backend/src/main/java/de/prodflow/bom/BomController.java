package de.prodflow.bom;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

import java.math.BigDecimal;
import java.util.List;

@RestController
@RequestMapping("/api/items/{productId}/bom")
public class BomController {

    private final BomService service;

    public BomController(BomService service) {
        this.service = service;
    }

    public record BomLineRequest(@NotNull Long componentId, @NotNull @Positive BigDecimal qtyPer) {
    }

    public record BomLineResponse(Long id, Long componentId, String componentCode,
                                  String componentName, String unit, BigDecimal qtyPer) {
        static BomLineResponse of(BomLine l) {
            return new BomLineResponse(l.getId(), l.getChild().getId(), l.getChild().getCode(),
                    l.getChild().getName(), l.getChild().getUnit(), l.getQtyPer());
        }
    }

    @GetMapping
    public List<BomLineResponse> get(@PathVariable Long productId) {
        return service.getBom(productId).stream().map(BomLineResponse::of).toList();
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public BomLineResponse addLine(@PathVariable Long productId, @Valid @RequestBody BomLineRequest req) {
        return BomLineResponse.of(service.addOrUpdateLine(productId, req.componentId(), req.qtyPer()));
    }

    @DeleteMapping("/{lineId}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void removeLine(@PathVariable Long productId, @PathVariable Long lineId) {
        service.removeLine(productId, lineId);
    }
}
