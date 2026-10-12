package de.prodflow.item;

import org.springframework.data.jpa.repository.JpaRepository;

public interface ItemRepository extends JpaRepository<Item, Long> {
    boolean existsByCode(String code);
}
