package de.prodflow.web;

import de.prodflow.security.SecurityProperties;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * Runtime configuration of the SPA (GET /config.json): where the browser signs in. Derived from the SAME public issuer URL the
 * backend validates tokens against (OIDC_ISSUER_URI), so the compiled assets contain no environment-specific value and the frontend
 * can never point at a different identity provider than the one this backend trusts. Public data only (no secrets exist: the
 * client is public and uses PKCE). Never cached, because it differs per environment.
 */
@RestController
class FrontendConfigController {

    private static final String REALM_MARKER = "/realms/";

    private final Map<String, Map<String, String>> config;

    FrontendConfigController(SecurityProperties security,
                             @Value("${prodflow.frontend.client-id:prodflow-web}") String clientId) {
        this.config = Map.of("keycloak", keycloak(security.issuerUri(), clientId));
    }

    @GetMapping("/config.json")
    ResponseEntity<Map<String, Map<String, String>>> config() {
        return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(config);
    }

    /** "https://auth.example.org/realms/prodflow" -> url "https://auth.example.org", realm "prodflow". Fails at start-up when the issuer has another shape. */
    static Map<String, String> keycloak(String issuerUri, String clientId) {
        String issuer = issuerUri.endsWith("/") ? issuerUri.substring(0, issuerUri.length() - 1) : issuerUri;
        int marker = issuer.lastIndexOf(REALM_MARKER);
        String realm = marker < 0 ? "" : issuer.substring(marker + REALM_MARKER.length());
        if (marker <= 0 || realm.isEmpty() || realm.contains("/")) {
            throw new IllegalStateException("prodflow.security.issuer-uri must look like https://<host>/realms/<realm> but is: " + issuerUri);
        }
        return Map.of("url", issuer.substring(0, marker), "realm", realm, "clientId", clientId);
    }
}
