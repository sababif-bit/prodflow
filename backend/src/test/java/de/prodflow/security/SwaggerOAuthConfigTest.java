package de.prodflow.security;

import de.prodflow.TestcontainersConfig;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.test.web.servlet.MockMvc;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Swagger UI is the demo client: it must log in through Keycloak with Authorization Code + PKCE
 * and always ask for credentials again (prompt=login), so an SSO session of a previous demo user is never reused silently.
 * Switching to another user needs a Keycloak logout or a second browser window (verified by scripts/smoke-auth.ps1).
 * Checks what springdoc actually serves, not just the configuration properties.
 */
@SpringBootTest
@AutoConfigureMockMvc
@Import(TestcontainersConfig.class)
class SwaggerOAuthConfigTest {

    private static final String ISSUER = "http://localhost:8180/realms/prodflow";

    @Autowired MockMvc mvc;

    @Test
    void apiDocsDeclareKeycloakAuthorizationCodeFlow() throws Exception {
        mvc.perform(get("/v3/api-docs"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.components.securitySchemes.keycloak.type").value("oauth2"))
                .andExpect(jsonPath("$.components.securitySchemes.keycloak.flows.authorizationCode.authorizationUrl")
                        .value(ISSUER + "/protocol/openid-connect/auth"))
                .andExpect(jsonPath("$.components.securitySchemes.keycloak.flows.authorizationCode.tokenUrl")
                        .value(ISSUER + "/protocol/openid-connect/token"))
                .andExpect(jsonPath("$.security[0].keycloak").isArray());
    }

    @Test
    void swaggerUiUsesPublicPkceClientAndAlwaysShowsLogin() throws Exception {
        String initializer = mvc.perform(get("/swagger-ui/swagger-initializer.js"))
                .andExpect(status().isOk())
                .andReturn().getResponse().getContentAsString();

        String compact = initializer.replaceAll("\\s", "");
        assertThat(compact).contains("\"clientId\":\"prodflow-swagger\"");
        assertThat(compact).contains("\"usePkceWithAuthorizationCodeGrant\":true");
        assertThat(compact).contains("\"additionalQueryStringParams\":{\"prompt\":\"login\"}");
        assertThat(compact).doesNotContain("clientSecret");
    }
}
