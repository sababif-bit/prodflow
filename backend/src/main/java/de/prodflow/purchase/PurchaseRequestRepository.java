package de.prodflow.purchase;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;

import java.math.BigDecimal;
import java.util.Collection;
import java.util.List;

public interface PurchaseRequestRepository extends JpaRepository<PurchaseRequest, Long> {

    @Query("select r from PurchaseRequest r join fetch r.item left join fetch r.productionOrder order by r.id desc")
    List<PurchaseRequest> findAllWithDetails();

    /**
     * Quantity already requested (and not yet received) for one order and one item.
     * Used to avoid duplicate purchase requests when an order is checked again.
     */
    @Query("""
            select coalesce(sum(r.quantity), 0) from PurchaseRequest r
            where r.productionOrder.id = :orderId and r.item.id = :itemId and r.status in :statuses
            """)
    BigDecimal sumQuantity(Long orderId, Long itemId, Collection<PurchaseRequestStatus> statuses);

    List<PurchaseRequest> findByProductionOrderId(Long orderId);
}
