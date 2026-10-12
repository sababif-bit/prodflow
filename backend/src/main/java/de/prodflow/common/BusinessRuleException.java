package de.prodflow.common;

/** A request that is valid in form but breaks a business rule (HTTP 409). */
public class BusinessRuleException extends RuntimeException {
    public BusinessRuleException(String message) {
        super(message);
    }
}
