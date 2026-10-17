package de.prodflow.common;

import de.prodflow.TestcontainersConfig;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * The deployment pipeline verifies a release by asking the running application which commit it was built from (Issue #10).
 * The endpoint is public on purpose and exposes only that one value; /actuator/info stays ADMIN-only.
 */
@SpringBootTest(properties = "prodflow.revision=0123456789abcdef0123456789abcdef01234567")
@AutoConfigureMockMvc
@Import(TestcontainersConfig.class)
class VersionEndpointTest {

    @Autowired MockMvc mvc;

    @Test
    void anonymousCallerGetsTheBuildRevisionAndNothingElse() throws Exception {
        mvc.perform(get("/version"))
                .andExpect(status().isOk())
                .andExpect(content().contentTypeCompatibleWith("application/json"))
                .andExpect(jsonPath("$.revision").value("0123456789abcdef0123456789abcdef01234567"))
                .andExpect(jsonPath("$.length()").value(1));
    }

    @Test
    void onlyGetIsPublic() throws Exception {
        mvc.perform(post("/version")).andExpect(status().isUnauthorized());
    }

    @Test
    void subPathsStayProtected() throws Exception {
        mvc.perform(get("/version/details")).andExpect(status().isUnauthorized());
    }
}
