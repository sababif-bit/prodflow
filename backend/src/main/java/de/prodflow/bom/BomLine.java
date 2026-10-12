package de.prodflow.bom;

import de.prodflow.item.Item;
import jakarta.persistence.*;

import java.math.BigDecimal;

/**
 * One line of a bill of materials: "to make 1 x parent, you need qtyPer x child".
 * Parent and child are both items, so a child can later have its own BOM (multi-level).
 */
@Entity
@Table(name = "bom_line")
public class BomLine {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "parent_item_id")
    private Item parent;

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "child_item_id")
    private Item child;

    @Column(name = "qty_per", nullable = false)
    private BigDecimal qtyPer;

    protected BomLine() {
    }

    public BomLine(Item parent, Item child, BigDecimal qtyPer) {
        this.parent = parent;
        this.child = child;
        this.qtyPer = qtyPer;
    }

    public void changeQtyPer(BigDecimal qtyPer) {
        this.qtyPer = qtyPer;
    }

    public Long getId() { return id; }
    public Item getParent() { return parent; }
    public Item getChild() { return child; }
    public BigDecimal getQtyPer() { return qtyPer; }
}
