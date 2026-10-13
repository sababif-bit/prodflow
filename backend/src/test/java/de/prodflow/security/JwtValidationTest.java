package de.prodflow.security;

import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtException;
import org.springframework.security.oauth2.jwt.JwtValidationException;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;

import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.interfaces.RSAPrivateKey;
import java.security.interfaces.RSAPublicKey;
import java.time.Instant;
import java.util.Date;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Real RS256-signed tokens run through a NimbusJwtDecoder with the production validator,
 * so signature, expiry, issuer and audience are checked exactly as at runtime
 * (only the key comes from a local key pair instead of Keycloak's JWKS endpoint).
 */
class JwtValidationTest {

    private static final String ISSUER = "https://prodflow.example.com/auth/realms/prodflow";
    private static final String AUDIENCE = "prodflow-api";

    private static KeyPair keys;
    private static NimbusJwtDecoder decoder;

    @BeforeAll
    static void setUp() throws Exception {
        KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
        generator.initialize(2048);
        keys = generator.generateKeyPair();
        decoder = NimbusJwtDecoder.withPublicKey((RSAPublicKey) keys.getPublic()).build();
        decoder.setJwtValidator(SecurityConfig.tokenValidator(ISSUER, AUDIENCE));
    }

    @Test
    void acceptsValidToken() throws Exception {
        Jwt jwt = decoder.decode(sign(keys, c -> { }));

        assertThat(jwt.getIssuer().toString()).isEqualTo(ISSUER);
        assertThat(jwt.getAudience()).contains(AUDIENCE);
    }

    @Test
    void acceptsAudienceListContainingApi() throws Exception {
        // Keycloak typically sends several audiences, e.g. ["prodflow-api", "account"]
        Jwt jwt = decoder.decode(sign(keys, c -> c.audience(List.of("account", AUDIENCE))));

        assertThat(jwt.getAudience()).contains(AUDIENCE);
    }

    @Test
    void rejectsWrongIssuer() throws Exception {
        String token = sign(keys, c -> c.issuer("https://evil.example.com/realms/prodflow"));

        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtValidationException.class);
    }

    @Test
    void rejectsIssuerThatOnlyDiffersByInternalHostname() throws Exception {
        // The classic Docker mistake: token issued via the internal URL is not accepted
        String token = sign(keys, c -> c.issuer("http://keycloak:8080/realms/prodflow"));

        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtValidationException.class);
    }

    @Test
    void rejectsWrongAudience() throws Exception {
        String token = sign(keys, c -> c.audience("another-app"));

        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtValidationException.class);
    }

    @Test
    void rejectsMissingAudience() throws Exception {
        String token = sign(keys, c -> c.audience((List<String>) null));

        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtValidationException.class);
    }

    @Test
    void rejectsExpiredToken() throws Exception {
        String token = sign(keys, c -> c
                .issueTime(Date.from(Instant.now().minusSeconds(3600)))
                .expirationTime(Date.from(Instant.now().minusSeconds(600))));

        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtValidationException.class);
    }

    @Test
    void rejectsTokenSignedWithAnotherKey() throws Exception {
        KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
        generator.initialize(2048);
        String token = sign(generator.generateKeyPair(), c -> { });

        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtException.class);
    }

    /** Builds a valid token; the customizer breaks exactly one aspect per test. */
    private static String sign(KeyPair keyPair, Consumer<JWTClaimsSet.Builder> customizer) throws Exception {
        Instant now = Instant.now();
        JWTClaimsSet.Builder claims = new JWTClaimsSet.Builder()
                .issuer(ISSUER)
                .audience(AUDIENCE)
                .subject("user-id")
                .issueTime(Date.from(now))
                .expirationTime(Date.from(now.plusSeconds(300)))
                .claim("preferred_username", "planner")
                .claim("realm_access", Map.of("roles", List.of("PLANNER")));
        customizer.accept(claims);

        SignedJWT jwt = new SignedJWT(new JWSHeader(JWSAlgorithm.RS256), claims.build());
        jwt.sign(new RSASSASigner((RSAPrivateKey) keyPair.getPrivate()));
        return jwt.serialize();
    }
}
