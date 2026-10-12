package de.prodflow;

import de.prodflow.bom.BomService;
import de.prodflow.common.BusinessRuleException;
import de.prodflow.item.Item;
import de.prodflow.item.ItemDtos.CreateItemRequest;
import de.prodflow.item.ItemService;
import de.prodflow.item.ItemType;
import de.prodflow.order.MaterialCheckResult;
import de.prodflow.order.OrderStatus;
import de.prodflow.order.ProductionOrderService;
import de.prodflow.purchase.PurchaseRequest;
import de.prodflow.purchase.PurchaseRequestRepository;
import de.prodflow.purchase.PurchaseRequestService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Acceptance criteria of the MVP business workflow (see docs/architecture.md).
 * Scenario: product A needs 4 screws and 2 plates per unit; 25 screws and 30 plates in stock.
 */
@SpringBootTest
@Import(TestcontainersConfig.class)
@Transactional
class ProductionWorkflowTest {

    @Autowired ItemService itemService;
    @Autowired BomService bomService;
    @Autowired ProductionOrderService orderService;
    @Autowired PurchaseRequestService purchaseService;
    @Autowired PurchaseRequestRepository purchaseRepository;

    Item productA;
    Item screw;
    Item plate;

    @BeforeEach
    void setUp() {
        productA = itemService.create(new CreateItemRequest("A", "Product A", "pcs", ItemType.PRODUCT, bd(0)));
        screw = itemService.create(new CreateItemRequest("SCREW", "Screw M8", "pcs", ItemType.MATERIAL, bd(25)));
        plate = itemService.create(new CreateItemRequest("PLATE", "Steel plate", "pcs", ItemType.MATERIAL, bd(30)));
        bomService.addOrUpdateLine(productA.getId(), screw.getId(), bd(4));
        bomService.addOrUpdateLine(productA.getId(), plate.getId(), bd(2));
    }

    @Test
    @DisplayName("AC1: shortage puts the order on WAITING_MATERIAL and creates a purchase request for exactly the missing quantity")
    void shortageCreatesPurchaseRequest() {
        MaterialCheckResult result = createOrder(10);

        assertThat(result.status()).isEqualTo(OrderStatus.WAITING_MATERIAL);
        List<PurchaseRequest> requests = purchaseRepository.findByProductionOrderId(result.orderId());
        assertThat(requests).hasSize(1);
        assertThat(requests.get(0).getItem().getCode()).isEqualTo("SCREW");
        assertThat(requests.get(0).getQuantity()).isEqualByComparingTo("15");
    }

    @Test
    @DisplayName("AC1b: enough stock releases the order immediately without any purchase request")
    void sufficientStockReleasesOrder() {
        MaterialCheckResult result = createOrder(5);

        assertThat(result.status()).isEqualTo(OrderStatus.RELEASED);
        assertThat(purchaseRepository.findByProductionOrderId(result.orderId())).isEmpty();
    }

    @Test
    @DisplayName("AC2: checking the same order again does not create a duplicate purchase request")
    void recheckDoesNotDuplicateRequests() {
        MaterialCheckResult first = createOrder(10);

        MaterialCheckResult second = orderService.checkMaterial(first.orderId());

        assertThat(second.status()).isEqualTo(OrderStatus.WAITING_MATERIAL);
        assertThat(purchaseRepository.findByProductionOrderId(first.orderId())).hasSize(1);
    }

    @Test
    @DisplayName("AC3: goods receipt increases stock and releases the waiting order automatically")
    void goodsReceiptReleasesOrder() {
        MaterialCheckResult created = createOrder(10);
        PurchaseRequest request = purchaseRepository.findByProductionOrderId(created.orderId()).get(0);

        purchaseService.approve(request.getId());
        purchaseService.receive(request.getId());

        assertThat(itemService.get(screw.getId()).getQtyOnHand()).isEqualByComparingTo("40");
        assertThat(orderService.get(created.orderId()).getStatus()).isEqualTo(OrderStatus.RELEASED);
    }

    @Test
    @DisplayName("AC4: completing an order consumes material and books the finished product into stock")
    void completeConsumesMaterial() {
        MaterialCheckResult created = createOrder(5);

        orderService.complete(created.orderId());

        assertThat(orderService.get(created.orderId()).getStatus()).isEqualTo(OrderStatus.DONE);
        assertThat(itemService.get(screw.getId()).getQtyOnHand()).isEqualByComparingTo("5");
        assertThat(itemService.get(plate.getId()).getQtyOnHand()).isEqualByComparingTo("20");
        assertThat(itemService.get(productA.getId()).getQtyOnHand()).isEqualByComparingTo("5");
    }

    @Test
    @DisplayName("Rules: a purchase request must be approved before goods can be received")
    void receiveRequiresApproval() {
        MaterialCheckResult created = createOrder(10);
        PurchaseRequest request = purchaseRepository.findByProductionOrderId(created.orderId()).get(0);

        assertThatThrownBy(() -> purchaseService.receive(request.getId()))
                .isInstanceOf(BusinessRuleException.class);
    }

    @Test
    @DisplayName("Known MVP limit: without reservations a second order can use the stock - completion is blocked, not stock going negative")
    void competingOrdersCannotDriveStockNegative() {
        MaterialCheckResult first = createOrder(5);   // needs 20 screws -> RELEASED
        MaterialCheckResult second = createOrder(5);  // also sees 25 screws -> RELEASED

        orderService.complete(first.orderId());       // 5 screws left

        assertThatThrownBy(() -> orderService.complete(second.orderId()))
                .isInstanceOf(BusinessRuleException.class)
                .hasMessageContaining("SCREW");
        assertThat(itemService.get(screw.getId()).getQtyOnHand()).isEqualByComparingTo("5");
    }

    private MaterialCheckResult createOrder(int qty) {
        return orderService.create(productA.getId(), bd(qty), LocalDate.now().plusDays(7));
    }

    private static BigDecimal bd(double value) {
        return BigDecimal.valueOf(value);
    }
}
