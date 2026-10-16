package de.prodflow.security;

import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.oauth2.core.DelegatingOAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.jwt.*;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationConverter;
import org.springframework.security.web.SecurityFilterChain;

import java.util.Collection;

import static de.prodflow.security.Roles.*;
import static org.springframework.http.HttpMethod.*;

/**
 * ProdFlow is an OAuth2 resource server: it does not log anyone in, it only validates
 * access tokens issued by Keycloak and enforces the authorization matrix below
 * (see docs/architecture.md). Everything not listed is denied.
 */
@Configuration
@EnableWebSecurity
@EnableConfigurationProperties(SecurityProperties.class)
public class SecurityConfig {

    private static final String[] ALL_ROLES = {ADMIN, PLANNER, PURCHASER};

    @Bean
    SecurityFilterChain securityFilterChain(HttpSecurity http,
                                            JwtAuthenticationConverter jwtAuthenticationConverter) throws Exception {
        http
                // Stateless API with bearer tokens in the Authorization header: no session, no cookies,
                // so CSRF protection does not apply.
                .csrf(csrf -> csrf.disable())
                .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .authorizeHttpRequests(auth -> auth
                        // --- public ---
                        .requestMatchers(GET, "/actuator/health", "/actuator/health/**").permitAll()
                        // build revision for the deployment check (Issue #10); exposes nothing else
                        .requestMatchers(GET, "/version").permitAll()
                        // API docs: switched off in production via springdoc properties (separate step)
                        .requestMatchers(GET, "/v3/api-docs", "/v3/api-docs/**",
                                "/swagger-ui.html", "/swagger-ui/**").permitAll()
                        // Spring's error page, so permitted requests that fail get their real status
                        .requestMatchers("/error").permitAll()

                        // --- admin ---
                        .requestMatchers(GET, "/actuator/info").hasRole(ADMIN)
                        .requestMatchers(POST, "/api/items/*/stock").hasRole(ADMIN)

                        // --- master data: items and BOMs ---
                        .requestMatchers(GET, "/api/items", "/api/items/*", "/api/items/*/bom").hasAnyRole(ALL_ROLES)
                        .requestMatchers(POST, "/api/items", "/api/items/*/bom").hasAnyRole(ADMIN, PLANNER)
                        .requestMatchers(PUT, "/api/items/*").hasAnyRole(ADMIN, PLANNER)
                        .requestMatchers(DELETE, "/api/items/*/bom/*").hasAnyRole(ADMIN, PLANNER)

                        // --- production orders ---
                        .requestMatchers(GET, "/api/production-orders", "/api/production-orders/*").hasAnyRole(ALL_ROLES)
                        .requestMatchers(POST, "/api/production-orders",
                                "/api/production-orders/*/check-material",
                                "/api/production-orders/*/complete").hasAnyRole(ADMIN, PLANNER)

                        // --- purchasing (separation of duties: planners cannot approve) ---
                        .requestMatchers(GET, "/api/purchase-requests").hasAnyRole(ALL_ROLES)
                        .requestMatchers(POST, "/api/purchase-requests/*/approve",
                                "/api/purchase-requests/*/receive").hasAnyRole(ADMIN, PURCHASER)

                        // --- deny by default ---
                        .anyRequest().denyAll())
                .oauth2ResourceServer(oauth2 -> oauth2.jwt(jwt -> jwt.jwtAuthenticationConverter(jwtAuthenticationConverter)));
        return http.build();
    }

    /** Signature from the realm keys, plus expiry, issuer and audience checks. */
    @Bean
    JwtDecoder jwtDecoder(SecurityProperties properties) {
        NimbusJwtDecoder decoder = NimbusJwtDecoder.withJwkSetUri(properties.jwkSetUri()).build();
        decoder.setJwtValidator(tokenValidator(properties.issuerUri(), properties.audience()));
        return decoder;
    }

    @Bean
    JwtAuthenticationConverter jwtAuthenticationConverter() {
        JwtAuthenticationConverter converter = new JwtAuthenticationConverter();
        converter.setJwtGrantedAuthoritiesConverter(new KeycloakRoleConverter());
        converter.setPrincipalClaimName("preferred_username");
        return converter;
    }

    /**
     * Expiry/not-before (with Spring's default clock skew) and exact issuer, plus a required audience.
     * Package-visible and static so the rules can be unit-tested without a running Keycloak.
     */
    static OAuth2TokenValidator<Jwt> tokenValidator(String issuerUri, String audience) {
        OAuth2TokenValidator<Jwt> audienceValidator = new JwtClaimValidator<Collection<String>>(
                JwtClaimNames.AUD, aud -> aud != null && aud.contains(audience));
        return new DelegatingOAuth2TokenValidator<>(
                JwtValidators.createDefaultWithIssuer(issuerUri),
                audienceValidator);
    }
}
