package de.prodflow.web;

import de.prodflow.TestcontainersConfig;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.MockMvc;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.http.HttpMethod.POST;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.head;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.request;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.forwardedUrl;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * The Angular SPA is served by the backend (same origin, same image). Files and client-side routes are public GETs,
 * runtime configuration comes from the issuer, and EVERYTHING else keeps the deny-by-default behavior
 * (the API matrix itself is covered by AuthorizationMatrixTest). Test files live in src/test/resources/static.
 */
@SpringBootTest(properties = "prodflow.security.issuer-uri=https://auth.example.org/realms/prodflow")
@AutoConfigureMockMvc
@Import(TestcontainersConfig.class)
class FrontendServingTest {

    @Autowired MockMvc mvc;

    @Test
    void rootAndIndexServeTheApplicationShellAnonymously() throws Exception {
        mvc.perform(get("/")).andExpect(status().isOk());
        mvc.perform(get("/index.html")).andExpect(status().isOk()).andExpect(content().string(org.hamcrest.Matchers.containsString("<app-root>")));
        mvc.perform(head("/index.html")).andExpect(status().isOk());
    }

    @ParameterizedTest
    @ValueSource(strings = {"/uebersicht", "/auftraege", "/auftraege/7", "/bestellanforderungen", "/bestand", "/bestand/3", "/keine-berechtigung"})
    void clientSideRoutesFallBackToIndexHtml(String route) throws Exception {
        mvc.perform(get(route)).andExpect(status().isOk()).andExpect(forwardedUrl("/index.html"));
    }

    @ParameterizedTest
    @ValueSource(strings = {"/main-TESTHASH.js", "/styles-TESTHASH.css", "/media/font-TESTHASH.woff2", "/favicon.svg"})
    void compiledAssetsArePublic(String path) throws Exception {
        mvc.perform(get(path)).andExpect(status().isOk());
    }

    @Test
    void runtimeConfigurationIsDerivedFromTheIssuerAndNeverCached() throws Exception {
        mvc.perform(get("/config.json"))
                .andExpect(status().isOk())
                .andExpect(content().contentTypeCompatibleWith("application/json"))
                .andExpect(header().string("Cache-Control", org.hamcrest.Matchers.containsString("no-store")))
                .andExpect(jsonPath("$.keycloak.url").value("https://auth.example.org"))
                .andExpect(jsonPath("$.keycloak.realm").value("prodflow"))
                .andExpect(jsonPath("$.keycloak.clientId").value("prodflow-web"))
                .andExpect(jsonPath("$.length()").value(1))
                .andExpect(jsonPath("$.keycloak.length()").value(3));
    }

    @ParameterizedTest
    @ValueSource(strings = {"/unknown", "/uebersicht/deep/path", "/static/index.html", "/.env", "/main-TESTHASH.js.map", "/media/sub/font.woff2",
            "/api/items", "/api/unknown", "/actuator/info", "/actuator/env"})
    void everythingElseStaysDeniedByDefault(String path) throws Exception {
        mvc.perform(get(path)).andExpect(status().isUnauthorized());
    }

    @ParameterizedTest
    @ValueSource(strings = {"/", "/index.html", "/config.json", "/uebersicht", "/main-TESTHASH.js"})
    void frontendResourcesAreReadOnly(String path) throws Exception {
        mvc.perform(request(POST, path)).andExpect(status().isUnauthorized());
    }

    @Test
    void anAuthenticatedUserWithoutRolesStillCannotReachUnlistedPaths() throws Exception {
        mvc.perform(get("/unknown").with(jwt().authorities(new SimpleGrantedAuthority("ROLE_ADMIN")))).andExpect(status().isForbidden());
    }

    @Test
    void operationalAndApiDocumentationEndpointsAreUnchanged() throws Exception {
        mvc.perform(get("/actuator/health")).andExpect(status().isOk());
        mvc.perform(get("/version")).andExpect(status().isOk()).andExpect(jsonPath("$.revision").exists());
        mvc.perform(get("/v3/api-docs")).andExpect(status().isOk());
        // Swagger UI keeps its own redirect/page and is not swallowed by the SPA fallback
        var swagger = mvc.perform(get("/swagger-ui.html")).andReturn().getResponse();
        assertThat(swagger.getStatus()).isIn(200, 302);
        assertThat(swagger.getForwardedUrl()).isNotEqualTo("/index.html");
    }

    @Test
    void issuerMustLookLikeARealmUrl() {
        assertThat(FrontendConfigController.keycloak("https://a.example/realms/prodflow/", "c"))
                .containsEntry("url", "https://a.example").containsEntry("realm", "prodflow");
        assertThat(FrontendConfigController.keycloak("https://a.example/auth/realms/r", "c"))
                .containsEntry("url", "https://a.example/auth").containsEntry("realm", "r");
        assertThatThrownBy(() -> FrontendConfigController.keycloak("https://a.example", "c")).isInstanceOf(IllegalStateException.class);
        assertThatThrownBy(() -> FrontendConfigController.keycloak("https://a.example/realms/", "c")).isInstanceOf(IllegalStateException.class);
        assertThatThrownBy(() -> FrontendConfigController.keycloak("/realms/x", "c")).isInstanceOf(IllegalStateException.class);
    }

    @Test
    void dotSegmentTricksAreRejectedByTheFirewall() throws Exception {
        mvc.perform(get("/auftraege/../api/items")).andExpect(status().is4xxClientError());
    }
}
