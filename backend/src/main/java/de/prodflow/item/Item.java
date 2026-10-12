package de.prodflow.item;

import jakarta.persistence.*;

import java.math.BigDecimal;

@Entity
@Table(name = "item")
public class Item {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, unique = true)
    private String code;

    @Column(nullable = false)
    private String name;

    @Column(nullable = false)
    private String unit;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private ItemType type;

    @Column(name = "qty_on_hand", nullable = false)
    private BigDecimal qtyOnHand = BigDecimal.ZERO;

    /** Optimistic locking: two parallel stock updates cannot silently overwrite each other. */
    @Version
    private Long version;

    protected Item() {
    }

    public Item(String code, String name, String unit, ItemType type, BigDecimal qtyOnHand) {
        this.code = code;
        this.name = name;
        this.unit = unit;
        this.type = type;
        this.qtyOnHand = qtyOnHand;
    }

    public void addStock(BigDecimal qty) {
        this.qtyOnHand = this.qtyOnHand.add(qty);
    }

    public void removeStock(BigDecimal qty) {
        if (qtyOnHand.compareTo(qty) < 0) {
            throw new IllegalStateException("Stock of " + code + " would become negative");
        }
        this.qtyOnHand = this.qtyOnHand.subtract(qty);
    }

    public void update(String name, String unit) {
        this.name = name;
        this.unit = unit;
    }

    public Long getId() { return id; }
    public String getCode() { return code; }
    public String getName() { return name; }
    public String getUnit() { return unit; }
    public ItemType getType() { return type; }
    public BigDecimal getQtyOnHand() { return qtyOnHand; }
    public Long getVersion() { return version; }
}
