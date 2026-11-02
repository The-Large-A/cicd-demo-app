package com.aarav.cicd;

import static org.hamcrest.Matchers.containsString;
import static org.hamcrest.Matchers.matchesPattern;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.test.web.servlet.MockMvc;

/** Starts the whole app (controller, template, rate limiter, actuator) and calls it over MockMvc. */
@SpringBootTest(properties = {
		"app.build-number=42",
		"app.git-commit=0123456789abcdef",
		"app.deployed-at=2026-11-02T09:02:00Z",
		"app.stage=Test"
})
@AutoConfigureMockMvc
class CicdDemoAppApplicationTests {

	@Autowired
	private MockMvc mockMvc;

	@Test
	void statusPageShowsTheAppIsLiveWithDeploymentDetails() throws Exception {
		mockMvc.perform(get("/"))
				.andExpect(status().isOk())
				.andExpect(content().contentTypeCompatibleWith("text/html"))
				.andExpect(content().string(containsString("LIVE")))
				.andExpect(content().string(containsString("#42")))
				.andExpect(content().string(containsString("0123456")))
				.andExpect(content().string(containsString("02 Nov 2026, 14:32 IST")));
	}

	@Test
	void statusApiReturnsJsonForThePipelineSmokeTest() throws Exception {
		mockMvc.perform(get("/api/status"))
				.andExpect(status().isOk())
				.andExpect(jsonPath("$.status").value("LIVE"))
				// version comes from pom.xml through Maven resource filtering
				.andExpect(jsonPath("$.version").value(matchesPattern("\\d+\\.\\d+\\.\\d+")))
				.andExpect(jsonPath("$.buildNumber").value("42"))
				.andExpect(jsonPath("$.gitCommit").value("0123456"));
	}

	@Test
	void healthProbesReportUp() throws Exception {
		mockMvc.perform(get("/actuator/health/liveness")).andExpect(jsonPath("$.status").value("UP"));
		mockMvc.perform(get("/actuator/health/readiness")).andExpect(jsonPath("$.status").value("UP"));
	}

	@Test
	void onlyHealthAndInfoActuatorEndpointsAreExposed() throws Exception {
		mockMvc.perform(get("/actuator/env")).andExpect(status().isNotFound());
		mockMvc.perform(get("/actuator/info")).andExpect(status().isOk());
	}

}
