package de.prodflow.purchase;

import de.prodflow.common.BusinessRuleException;
import de.prodflow.common.NotFoundException;
import de.prodflow.order.ProductionOrderService;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Service
@Transactional
public class PurchaseRequestService {

    private final PurchaseRequestRepository requests;
    private final ProductionOrderService orderService;

    public PurchaseRequestService(PurchaseRequestRepository requests, ProductionOrderService orderService) {
        this.requests = requests;
        this.orderService = orderService;
    }

    @Transactional(readOnly = true)
    public List<PurchaseRequest> findAll() {
        return requests.findAllWithDetails();
    }

    public PurchaseRequest get(Long id) {
        return requests.findById(id).orElseThrow(() -> new NotFoundException("Purchase request " + id + " not found"));
    }

    public PurchaseRequest approve(Long id) {
        PurchaseRequest request = get(id);
        if (request.getStatus() != PurchaseRequestStatus.OPEN) {
            throw new BusinessRuleException("Only OPEN requests can be approved (request is " + request.getStatus() + ")");
        }
        request.approve();
        return request;
    }

    /**
     * Goods receipt: books the material into stock and re-checks every waiting order,
     * so orders are released automatically as soon as their material is complete.
     */
    public PurchaseRequest receive(Long id) {
        PurchaseRequest request = get(id);
        if (request.getStatus() != PurchaseRequestStatus.APPROVED) {
            throw new BusinessRuleException("Only APPROVED requests can be received (request is " + request.getStatus() + ")");
        }
        request.getItem().addStock(request.getQuantity());
        request.markReceived();
        orderService.recheckWaitingOrders();
        return request;
    }
}
