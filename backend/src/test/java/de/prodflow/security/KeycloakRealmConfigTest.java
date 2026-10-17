package de.prodflow.security;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.ValueSource;

import java.io.IOException;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Guards the Keycloak realm import (keycloak/prodflow-realm.json): demo users with least privilege,
 * no real secrets in Git (passwords only as environment placeholders), a dedicated Swagger demo client
 * with longer-lived tokens, and an unchanged short-lived client reserved for the future Angular frontend.
 * Whether Keycloak resolves the placeholders at runtime is checked by smoke-auth.sh.
 */
class KeycloakRealmConfigTest {

    private static final Path REALM_FILE = Path.of("..", "keycloak", "prodflow-realm.json");
    private static final String APP_URL = "${PRODFLOW_APP_URL}";
    private static final String WEB_CLIENT = "prodflow-web";
    private static final String SWAGGER_CLIENT = "prodflow-swagger";

    private static JsonNode realm;

    @BeforeAll
    static void loadRealm() throws IOException {
        realm = new ObjectMapper().readTree(REALM_FILE.toFile());
    }

    @ParameterizedTest(name = "{0} has only role {1}")
    @CsvSource({"planner, PLANNER", "purchaser, PURCHASER", "admin, ADMIN"})
    void demoUserHasExactlyItsRole(String username, String role) {
        JsonNode user = user(username);
        assertThat(user.path("enabled").asBoolean()).isTrue();
        assertThat(texts(user.path("realmRoles"))).containsExactly(role);
    }

    @ParameterizedTest(name = "{0} password is an env placeholder")
    @CsvSource({"planner, DEMO_PLANNER_PASSWORD", "purchaser, DEMO_PURCHASER_PASSWORD", "admin, DEMO_ADMIN_PASSWORD"})
    void demoUserPasswordIsOnlyAPlaceholder(String username, String variable) {
        JsonNode credentials = user(username).path("credentials");
        assertThat(credentials).hasSize(1);
        JsonNode password = credentials.get(0);
        assertThat(password.path("type").asText()).isEqualTo("password");
        assertThat(password.path("temporary").asBoolean()).isFalse();
        assertThat(password.path("value").asText()).isEqualTo("${" + variable + "}");
    }

    @Test
    void realmAccessTokensStayShortLived() {
        assertThat(realm.path("accessTokenLifespan").asInt()).isEqualTo(300);
    }

    @Test
    void webClientStaysUnchangedForAngular() {
        JsonNode web = client(WEB_CLIENT);
        assertPublicPkceWithoutPasswordGrant(web);
        assertThat(texts(web.path("redirectUris"))).containsExactly("http://localhost:4200/*");
        assertThat(texts(web.path("webOrigins"))).containsExactly("http://localhost:4200");
        assertThat(web.path("attributes").has("access.token.lifespan")).isFalse();
    }

    @Test
    void swaggerClientIsPublicPkceWithoutPasswordGrant() {
        JsonNode swagger = client(SWAGGER_CLIENT);
        assertPublicPkceWithoutPasswordGrant(swagger);
        assertThat(swagger.path("implicitFlowEnabled").asBoolean()).isFalse();
        assertThat(swagger.path("serviceAccountsEnabled").asBoolean()).isFalse();
    }

    @Test
    void swaggerClientAllowsOnlySwaggerRedirectAndOrigin() {
        JsonNode swagger = client(SWAGGER_CLIENT);
        assertThat(texts(swagger.path("redirectUris"))).containsExactly(APP_URL + "/swagger-ui/oauth2-redirect.html");
        assertThat(texts(swagger.path("webOrigins"))).containsExactly(APP_URL);
    }

    @Test
    void swaggerClientTokensLastThirtyMinutes() {
        assertThat(client(SWAGGER_CLIENT).path("attributes").path("access.token.lifespan").asText()).isEqualTo("1800");
    }

    @ParameterizedTest(name = "{0} tokens target the API")
    @ValueSource(strings = {WEB_CLIENT, SWAGGER_CLIENT})
    void clientTokensTargetTheApi(String clientId) {
        List<JsonNode> audienceMappers = new ArrayList<>();
        client(clientId).path("protocolMappers").forEach(mapper -> {
            if ("oidc-audience-mapper".equals(mapper.path("protocolMapper").asText())) {
                audienceMappers.add(mapper);
            }
        });
        assertThat(audienceMappers).hasSize(1);
        JsonNode config = audienceMappers.get(0).path("config");
        assertThat(config.path("included.client.audience").asText()).isEqualTo("prodflow-api");
        assertThat(config.path("access.token.claim").asText()).isEqualTo("true");
    }

    private static void assertPublicPkceWithoutPasswordGrant(JsonNode client) {
        assertThat(client.path("publicClient").asBoolean()).isTrue();
        assertThat(client.path("standardFlowEnabled").asBoolean()).isTrue();
        assertThat(client.path("directAccessGrantsEnabled").asBoolean()).isFalse();
        assertThat(client.path("attributes").path("pkce.code.challenge.method").asText()).isEqualTo("S256");
    }

    private static JsonNode user(String username) {
        for (JsonNode user : realm.path("users")) {
            if (username.equals(user.path("username").asText())) {
                return user;
            }
        }
        throw new AssertionError("Demo user '" + username + "' missing in " + REALM_FILE);
    }

    private static JsonNode client(String clientId) {
        for (JsonNode client : realm.path("clients")) {
            if (clientId.equals(client.path("clientId").asText())) {
                return client;
            }
        }
        throw new AssertionError("Client '" + clientId + "' missing in " + REALM_FILE);
    }

    private static List<String> texts(JsonNode array) {
        List<String> values = new ArrayList<>();
        array.forEach(node -> values.add(node.asText()));
        return values;
    }
}
