package de.prodflow.bom;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;

import java.util.List;
import java.util.Optional;

public interface BomLineRepository extends JpaRepository<BomLine, Long> {

    @Query("select b from BomLine b join fetch b.child where b.parent.id = :parentId order by b.child.code")
    List<BomLine> findByParentId(Long parentId);

    Optional<BomLine> findByParentIdAndChildId(Long parentId, Long childId);
}
