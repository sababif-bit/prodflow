package de.prodflow.order;

import de.prodflow.item.Item;
import jakarta.persistence.*;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.LocalDateTime;

@Entity
@Table(name = "production_order")
public class ProductionOrder {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "order_no", nullable = false, unique = true)
    private String orderNo;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "item_id")
    private Item item;

    @Column(nullable = false)
    private BigDecimal quantity;

    @Column(name = "due_date", nullable = false)
    private LocalDate dueDate;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private OrderStatus status = OrderStatus.CREATED;

    @Column(name = "created_at", nullable = false)
    private LocalDateTime createdAt = LocalDateTime.now();

    protected ProductionOrder() {
    }

    public ProductionOrder(String orderNo, Item item, BigDecimal quantity, LocalDate dueDate) {
        this.orderNo = orderNo;
        this.item = item;
        this.quantity = quantity;
        this.dueDate = dueDate;
    }

    public boolean isOpenForMaterialCheck() {
        return status == OrderStatus.CREATED || status == OrderStatus.WAITING_MATERIAL;
    }

    public void markWaitingForMaterial() { this.status = OrderStatus.WAITING_MATERIAL; }
    public void release() { this.status = OrderStatus.RELEASED; }
    public void complete() { this.status = OrderStatus.DONE; }

    public Long getId() { return id; }
    public String getOrderNo() { return orderNo; }
    public Item getItem() { return item; }
    public BigDecimal getQuantity() { return quantity; }
    public LocalDate getDueDate() { return dueDate; }
    public OrderStatus getStatus() { return status; }
    public LocalDateTime getCreatedAt() { return createdAt; }
}
