package de.prodflow.security;

import io.swagger.v3.oas.models.Components;
import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Info;
import io.swagger.v3.oas.models.security.OAuthFlow;
import io.swagger.v3.oas.models.security.OAuthFlows;
import io.swagger.v3.oas.models.security.Scopes;
import io.swagger.v3.oas.models.security.SecurityRequirement;
import io.swagger.v3.oas.models.security.SecurityScheme;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Declares the Keycloak login for Swagger UI. The endpoints are derived from the configured issuer
 * (the public Keycloak realm URL the browser uses), so every environment only sets OIDC_ISSUER_URI.
 */
@Configuration
public class OpenApiSecurityConfig {

    static final String SCHEME = "keycloak";

    @Bean
    OpenAPI prodflowOpenApi(SecurityProperties properties) {
        String oidc = properties.issuerUri() + "/protocol/openid-connect";
        OAuthFlow authorizationCode = new OAuthFlow()
                .authorizationUrl(oidc + "/auth")
                .tokenUrl(oidc + "/token")
                .scopes(new Scopes());
        return new OpenAPI()
                .info(new Info().title("ProdFlow API"))
                .components(new Components().addSecuritySchemes(SCHEME, new SecurityScheme()
                        .type(SecurityScheme.Type.OAUTH2)
                        .description("Keycloak login (Authorization Code + PKCE)")
                        .flows(new OAuthFlows().authorizationCode(authorizationCode))))
                .addSecurityItem(new SecurityRequirement().addList(SCHEME));
    }
}
