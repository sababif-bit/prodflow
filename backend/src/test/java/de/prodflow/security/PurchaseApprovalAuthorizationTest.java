package de.prodflow.security;

import de.prodflow.TestcontainersConfig;
import de.prodflow.bom.BomService;
import de.prodflow.item.Item;
import de.prodflow.item.ItemDtos.CreateItemRequest;
import de.prodflow.item.ItemService;
import de.prodflow.item.ItemType;
import de.prodflow.order.ProductionOrderService;
import de.prodflow.purchase.PurchaseRequest;
import de.prodflow.purchase.PurchaseRequestRepository;
import de.prodflow.purchase.PurchaseRequestStatus;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Separation of duties on a real OPEN purchase request (the matrix test uses a non-existent id):
 * anonymous 401, planner 403 without side effects, purchaser 2xx and the request is approved.
 */
@SpringBootTest
@AutoConfigureMockMvc
@Import(TestcontainersConfig.class)
@Transactional
class PurchaseApprovalAuthorizationTest {

    @Autowired MockMvc mvc;
    @Autowired ItemService itemService;
    @Autowired BomService bomService;
    @Autowired ProductionOrderService orderService;
    @Autowired PurchaseRequestRepository purchaseRepository;
    @Autowired EntityManager entityManager;

    Long requestId;

    @BeforeEach
    void createOpenPurchaseRequest() {
        Item product = itemService.create(new CreateItemRequest("A", "Product A", "pcs", ItemType.PRODUCT, BigDecimal.ZERO));
        Item screw = itemService.create(new CreateItemRequest("SCREW", "Screw M8", "pcs", ItemType.MATERIAL, new BigDecimal("25")));
        bomService.addOrUpdateLine(product.getId(), screw.getId(), new BigDecimal("4"));
        Long orderId = orderService.create(product.getId(), new BigDecimal("10"), LocalDate.now().plusDays(30)).orderId();
        requestId = purchaseRepository.findByProductionOrderId(orderId).get(0).getId();
    }

    @Test
    void anonymousCannotApprove() throws Exception {
        mvc.perform(post("/api/purchase-requests/{id}/approve", requestId)).andExpect(status().isUnauthorized());
        assertThat(persistedStatus()).isEqualTo(PurchaseRequestStatus.OPEN);
    }

    @Test
    void plannerCannotApprove() throws Exception {
        mvc.perform(post("/api/purchase-requests/{id}/approve", requestId).with(role(Roles.PLANNER)))
                .andExpect(status().isForbidden());
        assertThat(persistedStatus()).isEqualTo(PurchaseRequestStatus.OPEN);
    }

    @Test
    void purchaserApproves() throws Exception {
        mvc.perform(post("/api/purchase-requests/{id}/approve", requestId).with(role(Roles.PURCHASER)))
                .andExpect(status().is2xxSuccessful());
        assertThat(persistedStatus()).isEqualTo(PurchaseRequestStatus.APPROVED);
    }

    /** Flushes to PostgreSQL and clears the persistence context, so the status is re-read from the database. */
    private PurchaseRequestStatus persistedStatus() {
        entityManager.flush();
        entityManager.clear();
        return purchaseRepository.findById(requestId).map(PurchaseRequest::getStatus).orElseThrow();
    }

    private static RequestPostProcessor role(String role) {
        return jwt().authorities(new SimpleGrantedAuthority("ROLE_" + role));
    }
}
