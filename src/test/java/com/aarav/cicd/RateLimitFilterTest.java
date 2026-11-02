package com.aarav.cicd;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatIllegalArgumentException;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;

import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockFilterChain;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

class RateLimitFilterTest {

	/** A clock the test can move forward. */
	private static final class TestClock extends Clock {

		private Instant now = Instant.parse("2026-11-02T10:00:15Z");

		void advanceSeconds(long seconds) {
			now = now.plusSeconds(seconds);
		}

		@Override
		public Instant instant() {
			return now;
		}

		@Override
		public ZoneId getZone() {
			return ZoneOffset.UTC;
		}

		@Override
		public Clock withZone(ZoneId zone) {
			return this;
		}

	}

	private final TestClock clock = new TestClock();
	private final RateLimitFilter filter = new RateLimitFilter(3, clock);

	private MockHttpServletResponse send(String ip, String path) throws Exception {
		MockHttpServletRequest request = new MockHttpServletRequest("GET", path);
		request.setRemoteAddr(ip);
		MockHttpServletResponse response = new MockHttpServletResponse();
		filter.doFilter(request, response, new MockFilterChain());
		return response;
	}

	@Test
	void allowsRequestsUpToTheLimit() throws Exception {
		for (int i = 0; i < 3; i++) {
			assertThat(send("10.0.0.1", "/").getStatus()).isEqualTo(200);
		}
	}

	@Test
	void rejectsRequestsOverTheLimitWith429AndRetryAfter() throws Exception {
		for (int i = 0; i < 3; i++) {
			send("10.0.0.1", "/");
		}
		MockHttpServletResponse blocked = send("10.0.0.1", "/");

		assertThat(blocked.getStatus()).isEqualTo(429);
		// clock is 15 s into the minute, so the window resets in 45 s
		assertThat(blocked.getHeader("Retry-After")).isEqualTo("45");
		assertThat(blocked.getContentAsString()).contains("Too many requests");
	}

	@Test
	void countsEachClientSeparately() throws Exception {
		for (int i = 0; i < 3; i++) {
			send("10.0.0.1", "/");
		}
		assertThat(send("10.0.0.1", "/").getStatus()).isEqualTo(429);
		assertThat(send("10.0.0.2", "/").getStatus()).isEqualTo(200);
	}

	@Test
	void resetsInTheNextMinute() throws Exception {
		for (int i = 0; i < 4; i++) {
			send("10.0.0.1", "/");
		}
		clock.advanceSeconds(60);

		assertThat(send("10.0.0.1", "/").getStatus()).isEqualTo(200);
	}

	@Test
	void neverLimitsKubernetesHealthProbes() throws Exception {
		for (int i = 0; i < 10; i++) {
			assertThat(send("10.0.0.1", "/actuator/health/readiness").getStatus()).isEqualTo(200);
		}
		assertThat(send("10.0.0.1", "/").getStatus()).isEqualTo(200);
	}

	@Test
	void rejectsInvalidLimit() {
		assertThatIllegalArgumentException().isThrownBy(() -> new RateLimitFilter(0, clock));
	}

}
