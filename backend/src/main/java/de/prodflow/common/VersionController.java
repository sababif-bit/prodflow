package de.prodflow.common;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * Public build information for the deployment check (Issue #10): the commit the running image was built from.
 * The value is injected at image build time (Dockerfile ARG GIT_SHA -> APP_REVISION); "unknown" for local runs.
 * Deliberately separate from /actuator/info (ADMIN-only) so nothing else is exposed.
 */
@RestController
class VersionController {

    private final String revision;

    VersionController(@Value("${prodflow.revision:unknown}") String revision) {
        this.revision = revision;
    }

    @GetMapping("/version")
    Map<String, String> version() {
        return Map.of("revision", revision);
    }
}
