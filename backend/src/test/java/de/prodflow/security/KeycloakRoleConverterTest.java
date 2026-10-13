package de.prodflow.security;

import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.AbstractAuthenticationToken;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.oauth2.jwt.Jwt;

import java.util.Collection;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class KeycloakRoleConverterTest {

    private final KeycloakRoleConverter converter = new KeycloakRoleConverter();

    @Test
    void mapsOnlyKnownRealmRoles() {
        Jwt jwt = token(Map.of("realm_access", Map.of("roles",
                List.of("PLANNER", "offline_access", "uma_authorization", "default-roles-prodflow"))));

        assertThat(names(converter.convert(jwt))).containsExactly("ROLE_PLANNER");
    }

    @Test
    void mapsMultipleRoles() {
        Jwt jwt = token(Map.of("realm_access", Map.of("roles", List.of("ADMIN", "PURCHASER"))));

        assertThat(names(converter.convert(jwt))).containsExactlyInAnyOrder("ROLE_ADMIN", "ROLE_PURCHASER");
    }

    @Test
    void roleNamesAreCaseSensitive() {
        Jwt jwt = token(Map.of("realm_access", Map.of("roles", List.of("admin", "Planner"))));

        assertThat(converter.convert(jwt)).isEmpty();
    }

    @Test
    void missingRealmAccessGivesNoAuthorities() {
        assertThat(converter.convert(token(Map.of("scope", "openid")))).isEmpty();
    }

    @Test
    void malformedRolesClaimGivesNoAuthorities() {
        Jwt jwt = token(Map.of("realm_access", Map.of("roles", "ADMIN")));

        assertThat(converter.convert(jwt)).isEmpty();
    }

    @Test
    void scopesDoNotBecomeRoles() {
        // Without our converter Spring would map "scope" to SCOPE_* authorities; they must grant nothing here
        Jwt jwt = token(Map.of("scope", "ADMIN PLANNER"));

        assertThat(converter.convert(jwt)).isEmpty();
    }

    @Test
    void authenticationUsesPreferredUsernameAsPrincipal() {
        Jwt jwt = token(Map.of(
                "preferred_username", "planner",
                "realm_access", Map.of("roles", List.of("PLANNER"))));

        AbstractAuthenticationToken authentication = new SecurityConfig().jwtAuthenticationConverter().convert(jwt);

        assertThat(authentication.getName()).isEqualTo("planner");
        assertThat(names(authentication.getAuthorities())).containsExactly("ROLE_PLANNER");
    }

    private static Jwt token(Map<String, Object> claims) {
        Jwt.Builder builder = Jwt.withTokenValue("test-token").header("alg", "RS256").subject("user-id");
        claims.forEach(builder::claim);
        return builder.build();
    }

    private static List<String> names(Collection<? extends GrantedAuthority> authorities) {
        return authorities.stream().map(GrantedAuthority::getAuthority).toList();
    }
}
