package de.prodflow.purchase;

import de.prodflow.item.Item;
import de.prodflow.order.ProductionOrder;
import jakarta.persistence.*;

import java.math.BigDecimal;
import java.time.LocalDateTime;

@Entity
@Table(name = "purchase_request")
public class PurchaseRequest {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "item_id")
    private Item item;

    /** The order that caused the shortage; kept so purchasing knows why it has to buy. */
    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "production_order_id")
    private ProductionOrder productionOrder;

    @Column(nullable = false)
    private BigDecimal quantity;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private PurchaseRequestStatus status = PurchaseRequestStatus.OPEN;

    @Column(name = "created_at", nullable = false)
    private LocalDateTime createdAt = LocalDateTime.now();

    protected PurchaseRequest() {
    }

    public PurchaseRequest(Item item, ProductionOrder productionOrder, BigDecimal quantity) {
        this.item = item;
        this.productionOrder = productionOrder;
        this.quantity = quantity;
    }

    public void approve() { this.status = PurchaseRequestStatus.APPROVED; }
    public void markReceived() { this.status = PurchaseRequestStatus.RECEIVED; }

    public Long getId() { return id; }
    public Item getItem() { return item; }
    public ProductionOrder getProductionOrder() { return productionOrder; }
    public BigDecimal getQuantity() { return quantity; }
    public PurchaseRequestStatus getStatus() { return status; }
    public LocalDateTime getCreatedAt() { return createdAt; }
}
