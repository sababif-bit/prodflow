package de.prodflow.item;

import de.prodflow.item.ItemDtos.*;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/items")
public class ItemController {

    private final ItemService service;

    public ItemController(ItemService service) {
        this.service = service;
    }

    @GetMapping
    public List<ItemResponse> list() {
        return service.findAll().stream().map(ItemResponse::of).toList();
    }

    @GetMapping("/{id}")
    public ItemResponse get(@PathVariable Long id) {
        return ItemResponse.of(service.get(id));
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public ItemResponse create(@Valid @RequestBody CreateItemRequest req) {
        return ItemResponse.of(service.create(req));
    }

    @PutMapping("/{id}")
    public ItemResponse update(@PathVariable Long id, @Valid @RequestBody UpdateItemRequest req) {
        return ItemResponse.of(service.update(id, req));
    }

    @PostMapping("/{id}/stock")
    public ItemResponse addStock(@PathVariable Long id, @Valid @RequestBody StockAdjustmentRequest req) {
        return ItemResponse.of(service.addStock(id, req.quantity()));
    }
}
