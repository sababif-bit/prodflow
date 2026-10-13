package de.prodflow.security;

import jakarta.validation.constraints.NotBlank;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.validation.annotation.Validated;

/**
 * OIDC settings for validating access tokens.
 *
 * @param issuerUri expected "iss" claim - the public Keycloak realm URL
 * @param jwkSetUri URL of the realm's signing keys (may be an internal address)
 * @param audience  required value in the "aud" claim
 */
@Validated
@ConfigurationProperties(prefix = "prodflow.security")
public record SecurityProperties(
        @NotBlank String issuerUri,
        @NotBlank String jwkSetUri,
        @NotBlank String audience) {
}
