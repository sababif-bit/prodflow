package de.prodflow.item;

import de.prodflow.common.BusinessRuleException;
import de.prodflow.common.NotFoundException;
import de.prodflow.item.ItemDtos.CreateItemRequest;
import de.prodflow.item.ItemDtos.UpdateItemRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.List;

@Service
@Transactional
public class ItemService {

    private final ItemRepository items;

    public ItemService(ItemRepository items) {
        this.items = items;
    }

    @Transactional(readOnly = true)
    public List<Item> findAll() {
        return items.findAll();
    }

    @Transactional(readOnly = true)
    public Item get(Long id) {
        return items.findById(id).orElseThrow(() -> new NotFoundException("Item " + id + " not found"));
    }

    public Item create(CreateItemRequest req) {
        if (items.existsByCode(req.code())) {
            throw new BusinessRuleException("Item code " + req.code() + " already exists");
        }
        return items.save(new Item(req.code(), req.name(), req.unit(), req.type(), req.qtyOnHand()));
    }

    public Item update(Long id, UpdateItemRequest req) {
        Item item = get(id);
        item.update(req.name(), req.unit());
        return item;
    }

    /** Manual stock correction, e.g. after an inventory count. */
    public Item addStock(Long id, BigDecimal qty) {
        Item item = get(id);
        item.addStock(qty);
        return item;
    }
}
