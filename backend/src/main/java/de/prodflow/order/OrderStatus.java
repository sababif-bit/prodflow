package de.prodflow.order;

/** CREATED -> WAITING_MATERIAL -> RELEASED -> DONE (WAITING_MATERIAL is skipped if stock is sufficient). */
public enum OrderStatus {
    CREATED,
    WAITING_MATERIAL,
    RELEASED,
    DONE
}
