package de.prodflow.order;

import de.prodflow.bom.BomLine;
import de.prodflow.bom.BomLineRepository;
import de.prodflow.common.BusinessRuleException;
import de.prodflow.common.NotFoundException;
import de.prodflow.item.Item;
import de.prodflow.item.ItemService;
import de.prodflow.item.ItemType;
import de.prodflow.purchase.PurchaseRequest;
import de.prodflow.purchase.PurchaseRequestRepository;
import de.prodflow.purchase.PurchaseRequestStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.EnumSet;
import java.util.List;

/**
 * Production order workflow:
 * create -> material check (shortages become purchase requests) -> released -> completed.
 */
@Service
@Transactional
public class ProductionOrderService {

    /** Requests that are still "on the way" and count against a shortage. */
    private static final EnumSet<PurchaseRequestStatus> PENDING =
            EnumSet.of(PurchaseRequestStatus.OPEN, PurchaseRequestStatus.APPROVED);

    private final ProductionOrderRepository orders;
    private final BomLineRepository bomLines;
    private final PurchaseRequestRepository purchaseRequests;
    private final ItemService itemService;

    public ProductionOrderService(ProductionOrderRepository orders, BomLineRepository bomLines,
                                  PurchaseRequestRepository purchaseRequests, ItemService itemService) {
        this.orders = orders;
        this.bomLines = bomLines;
        this.purchaseRequests = purchaseRequests;
        this.itemService = itemService;
    }

    @Transactional(readOnly = true)
    public List<ProductionOrder> plan() {
        return orders.findAllAsPlan();
    }

    @Transactional(readOnly = true)
    public ProductionOrder get(Long id) {
        return orders.findById(id).orElseThrow(() -> new NotFoundException("Production order " + id + " not found"));
    }

    public MaterialCheckResult create(Long productId, BigDecimal quantity, LocalDate dueDate) {
        Item product = itemService.get(productId);
        if (product.getType() != ItemType.PRODUCT) {
            throw new BusinessRuleException("Production orders can only be created for PRODUCT items");
        }
        if (bomLines.findByParentId(productId).isEmpty()) {
            throw new BusinessRuleException("Product " + product.getCode() + " has no BOM");
        }
        String orderNo = "FA-%05d".formatted(orders.count() + 1);
        ProductionOrder order = orders.save(new ProductionOrder(orderNo, product, quantity, dueDate));
        return checkMaterial(order);
    }

    public MaterialCheckResult checkMaterial(Long orderId) {
        return checkMaterial(get(orderId));
    }

    /**
     * Explodes the BOM (single level in the MVP) and compares requirements with stock.
     * For every shortage a purchase request is created - but only for the part that is
     * not already covered by an open or approved request for this order (no duplicates).
     */
    MaterialCheckResult checkMaterial(ProductionOrder order) {
        if (!order.isOpenForMaterialCheck()) {
            throw new BusinessRuleException("Order " + order.getOrderNo() + " is already " + order.getStatus());
        }

        List<MaterialCheckResult.Line> lines = new ArrayList<>();
        for (BomLine bomLine : bomLines.findByParentId(order.getItem().getId())) {
            Item component = bomLine.getChild();
            BigDecimal required = order.getQuantity().multiply(bomLine.getQtyPer());
            BigDecimal available = component.getQtyOnHand();
            BigDecimal shortage = required.subtract(available).max(BigDecimal.ZERO);

            BigDecimal alreadyRequested = purchaseRequests.sumQuantity(order.getId(), component.getId(), PENDING);
            BigDecimal toRequest = shortage.subtract(alreadyRequested).max(BigDecimal.ZERO);
            if (toRequest.signum() > 0) {
                purchaseRequests.save(new PurchaseRequest(component, order, toRequest));
            }

            lines.add(new MaterialCheckResult.Line(component.getCode(), component.getName(), component.getUnit(),
                    required, available, shortage, toRequest));
        }

        MaterialCheckResult result = new MaterialCheckResult(order.getId(), order.getStatus(), lines);
        if (result.hasShortage()) {
            order.markWaitingForMaterial();
        } else {
            order.release();
        }
        return new MaterialCheckResult(order.getId(), order.getStatus(), lines);
    }

    /** Called after goods receipt: waiting orders are checked again, most urgent first. */
    public void recheckWaitingOrders() {
        for (ProductionOrder order : orders.findByStatusOrderByDueDateAscIdAsc(OrderStatus.WAITING_MATERIAL)) {
            checkMaterial(order);
        }
    }

    /**
     * Completes a released order and consumes its material.
     * Stock is checked again because the MVP has no reservations: another order may have
     * used the material in the meantime (see docs/architecture.md, stretch goal "reservations").
     */
    public ProductionOrder complete(Long orderId) {
        ProductionOrder order = get(orderId);
        if (order.getStatus() != OrderStatus.RELEASED) {
            throw new BusinessRuleException("Only RELEASED orders can be completed (order is " + order.getStatus() + ")");
        }
        List<BomLine> bom = bomLines.findByParentId(order.getItem().getId());
        for (BomLine line : bom) {
            BigDecimal required = order.getQuantity().multiply(line.getQtyPer());
            if (line.getChild().getQtyOnHand().compareTo(required) < 0) {
                throw new BusinessRuleException("Not enough " + line.getChild().getCode()
                        + " in stock anymore - it was used by another order. Run the material check again.");
            }
        }
        for (BomLine line : bom) {
            line.getChild().removeStock(order.getQuantity().multiply(line.getQtyPer()));
        }
        order.getItem().addStock(order.getQuantity());
        order.complete();
        return order;
    }
}
