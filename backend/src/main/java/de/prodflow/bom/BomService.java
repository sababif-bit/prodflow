package de.prodflow.bom;

import de.prodflow.common.BusinessRuleException;
import de.prodflow.common.NotFoundException;
import de.prodflow.item.Item;
import de.prodflow.item.ItemService;
import de.prodflow.item.ItemType;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.List;

@Service
@Transactional
public class BomService {

    private final BomLineRepository bomLines;
    private final ItemService itemService;

    public BomService(BomLineRepository bomLines, ItemService itemService) {
        this.bomLines = bomLines;
        this.itemService = itemService;
    }

    @Transactional(readOnly = true)
    public List<BomLine> getBom(Long productId) {
        itemService.get(productId);
        return bomLines.findByParentId(productId);
    }

    /** Adds a component, or updates its quantity if it is already in the BOM. */
    public BomLine addOrUpdateLine(Long productId, Long componentId, BigDecimal qtyPer) {
        Item product = itemService.get(productId);
        Item component = itemService.get(componentId);

        if (product.getType() != ItemType.PRODUCT) {
            throw new BusinessRuleException("Only items of type PRODUCT can have a BOM");
        }
        if (product.getId().equals(component.getId())) {
            throw new BusinessRuleException("An item cannot be a component of itself");
        }

        return bomLines.findByParentIdAndChildId(productId, componentId)
                .map(line -> {
                    line.changeQtyPer(qtyPer);
                    return line;
                })
                .orElseGet(() -> bomLines.save(new BomLine(product, component, qtyPer)));
    }

    public void removeLine(Long productId, Long lineId) {
        BomLine line = bomLines.findById(lineId)
                .filter(l -> l.getParent().getId().equals(productId))
                .orElseThrow(() -> new NotFoundException("BOM line " + lineId + " not found"));
        bomLines.delete(line);
    }
}
