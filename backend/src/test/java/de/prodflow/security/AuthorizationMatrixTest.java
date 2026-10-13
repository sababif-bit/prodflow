package de.prodflow.security;

import de.prodflow.TestcontainersConfig;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.http.HttpMethod;
import org.springframework.http.MediaType;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Set;
import java.util.stream.Stream;

import static de.prodflow.security.Roles.*;
import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.http.HttpMethod.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.request;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Executable version of the authorization matrix in docs/architecture.md.
 * Every endpoint is called anonymously (401), with a token without application roles (403)
 * and with each role (permitted = anything except 401/403, otherwise 403).
 * "Permitted" requests may legitimately end in 400/404 - here only the security decision matters.
 */
@SpringBootTest
@AutoConfigureMockMvc
@Import(TestcontainersConfig.class)
@Transactional
class AuthorizationMatrixTest {

    private static final String ID = "999999";

    @Autowired MockMvc mvc;

    record Rule(HttpMethod method, String path, Set<String> allowed) {
        @Override
        public String toString() {
            return method + " " + path + " -> " + allowed;
        }
    }

    static Stream<Rule> matrix() {
        Set<String> everyone = Set.of(ADMIN, PLANNER, PURCHASER);
        Set<String> planning = Set.of(ADMIN, PLANNER);
        Set<String> purchasing = Set.of(ADMIN, PURCHASER);
        Set<String> adminOnly = Set.of(ADMIN);
        return Stream.of(
                new Rule(GET, "/api/items", everyone),
                new Rule(GET, "/api/items/" + ID, everyone),
                new Rule(POST, "/api/items", planning),
                new Rule(PUT, "/api/items/" + ID, planning),
                new Rule(POST, "/api/items/" + ID + "/stock", adminOnly),
                new Rule(GET, "/api/items/" + ID + "/bom", everyone),
                new Rule(POST, "/api/items/" + ID + "/bom", planning),
                new Rule(DELETE, "/api/items/" + ID + "/bom/" + ID, planning),
                new Rule(GET, "/api/production-orders", everyone),
                new Rule(GET, "/api/production-orders/" + ID, everyone),
                new Rule(POST, "/api/production-orders", planning),
                new Rule(POST, "/api/production-orders/" + ID + "/check-material", planning),
                new Rule(POST, "/api/production-orders/" + ID + "/complete", planning),
                new Rule(GET, "/api/purchase-requests", everyone),
                new Rule(POST, "/api/purchase-requests/" + ID + "/approve", purchasing),
                new Rule(POST, "/api/purchase-requests/" + ID + "/receive", purchasing),
                new Rule(GET, "/actuator/info", adminOnly));
    }

    @ParameterizedTest(name = "anonymous 401: {0}")
    @MethodSource("matrix")
    void anonymousRequestsAreRejectedWith401(Rule rule) throws Exception {
        mvc.perform(call(rule)).andExpect(status().isUnauthorized());
    }

    @ParameterizedTest(name = "no app role 403: {0}")
    @MethodSource("matrix")
    void validTokenWithoutApplicationRoleIsForbidden(Rule rule) throws Exception {
        mvc.perform(call(rule).with(jwt().authorities(List.of())))
                .andExpect(status().isForbidden());
    }

    @ParameterizedTest(name = "roles: {0}")
    @MethodSource("matrix")
    void eachRoleGetsExactlyItsPermissions(Rule rule) throws Exception {
        for (String role : Roles.ALL) {
            int status = mvc.perform(call(rule).with(jwt().authorities(new SimpleGrantedAuthority("ROLE_" + role))))
                    .andReturn().getResponse().getStatus();
            if (rule.allowed().contains(role)) {
                assertThat(status).as("%s should be allowed for %s", rule, role).isNotIn(401, 403);
            } else {
                assertThat(status).as("%s should be forbidden for %s", rule, role).isEqualTo(403);
            }
        }
    }

    @Test
    void unmappedPathsAreDeniedByDefault() throws Exception {
        mvc.perform(request(GET, "/api/unknown")).andExpect(status().isUnauthorized());
        mvc.perform(request(GET, "/api/unknown").with(jwt().authorities(new SimpleGrantedAuthority("ROLE_ADMIN"))))
                .andExpect(status().isForbidden());
    }

    @Test
    void healthAndApiDocsArePublic() throws Exception {
        mvc.perform(request(GET, "/actuator/health")).andExpect(status().isOk());
        mvc.perform(request(GET, "/v3/api-docs")).andExpect(status().isOk());
    }

    private static MockHttpServletRequestBuilder call(Rule rule) {
        return request(rule.method(), rule.path())
                .contentType(MediaType.APPLICATION_JSON)
                .content("{}");
    }
}
