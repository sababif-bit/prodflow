package de.prodflow.security;

import java.util.Set;

/** The three application roles, defined as realm roles in Keycloak with exactly these names. */
public final class Roles {

    public static final String ADMIN = "ADMIN";
    public static final String PLANNER = "PLANNER";
    public static final String PURCHASER = "PURCHASER";

    /** Only these realm roles grant anything; Keycloak defaults like offline_access are ignored. */
    public static final Set<String> ALL = Set.of(ADMIN, PLANNER, PURCHASER);

    private Roles() {
    }
}
