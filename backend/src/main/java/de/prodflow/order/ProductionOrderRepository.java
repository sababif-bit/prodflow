package de.prodflow.order;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;

import java.util.List;

public interface ProductionOrderRepository extends JpaRepository<ProductionOrder, Long> {

    /** The production plan: all orders, most urgent first. */
    @Query("select o from ProductionOrder o join fetch o.item order by o.dueDate, o.id")
    List<ProductionOrder> findAllAsPlan();

    List<ProductionOrder> findByStatusOrderByDueDateAscIdAsc(OrderStatus status);
}
