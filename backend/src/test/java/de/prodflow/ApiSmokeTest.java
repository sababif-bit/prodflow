package de.prodflow;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.transaction.annotation.Transactional;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** HTTP-level checks: health endpoint for the deployment, validation and error format. */
@SpringBootTest
@AutoConfigureMockMvc
@Import(TestcontainersConfig.class)
@Transactional
class ApiSmokeTest {

    @Autowired MockMvc mvc;

    @Test
    void healthEndpointIsUp() throws Exception {
        mvc.perform(get("/actuator/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UP"));
    }

    @Test
    void createItemReturns201() throws Exception {
        mvc.perform(post("/api/items").contentType(MediaType.APPLICATION_JSON).content("""
                        {"code":"SC-1","name":"Screw","unit":"pcs","type":"MATERIAL","qtyOnHand":10}
                        """))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.code").value("SC-1"));
    }

    @Test
    void invalidItemReturns400ProblemDetail() throws Exception {
        mvc.perform(post("/api/items").contentType(MediaType.APPLICATION_JSON).content("""
                        {"code":"","name":"Screw","unit":"pcs","type":"MATERIAL","qtyOnHand":-1}
                        """))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.detail").exists());
    }

    @Test
    void unknownOrderReturns404() throws Exception {
        mvc.perform(get("/api/production-orders/999999"))
                .andExpect(status().isNotFound());
    }
}
