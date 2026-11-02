package com.aarav.cicd;

import java.io.IOException;
import java.time.Clock;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import org.springframework.http.HttpStatus;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * Limits each client IP to a fixed number of requests per minute (fixed window).
 * Extra requests get HTTP 429 with a Retry-After header. Kubernetes health
 * probes (/actuator/**) are never limited.
 *
 * Counters live in memory, so each pod counts separately.
 */
public class RateLimitFilter extends OncePerRequestFilter {

	private static final long WINDOW_MILLIS = 60_000;
	private static final int MAX_TRACKED_CLIENTS = 10_000;

	private final int requestsPerMinute;
	private final Clock clock;
	private final Map<String, Window> windows = new ConcurrentHashMap<>();

	public RateLimitFilter(int requestsPerMinute, Clock clock) {
		if (requestsPerMinute < 1) {
			throw new IllegalArgumentException("requestsPerMinute must be at least 1");
		}
		this.requestsPerMinute = requestsPerMinute;
		this.clock = clock;
	}

	@Override
	protected boolean shouldNotFilter(HttpServletRequest request) {
		return request.getRequestURI().startsWith("/actuator/");
	}

	@Override
	protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response,
			FilterChain chain) throws ServletException, IOException {
		long now = clock.millis();
		long currentWindow = now / WINDOW_MILLIS;

		if (windows.size() > MAX_TRACKED_CLIENTS) {
			windows.values().removeIf(w -> w.id != currentWindow);
		}
		// getRemoteAddr() is the real client IP because the Service uses externalTrafficPolicy: Local.
		// X-Forwarded-For is ignored on purpose: clients can fake it.
		Window window = windows.compute(request.getRemoteAddr(),
				(ip, old) -> (old == null || old.id != currentWindow) ? new Window(currentWindow) : old);

		if (window.count.incrementAndGet() > requestsPerMinute) {
			long retryAfterSeconds = ((currentWindow + 1) * WINDOW_MILLIS - now + 999) / 1000;
			response.setStatus(HttpStatus.TOO_MANY_REQUESTS.value());
			response.setHeader("Retry-After", String.valueOf(retryAfterSeconds));
			response.setContentType("text/plain;charset=UTF-8");
			response.getWriter().write("Too many requests - try again in " + retryAfterSeconds + " seconds.\n");
			return;
		}
		chain.doFilter(request, response);
	}

	private static final class Window {

		private final long id;
		private final AtomicInteger count = new AtomicInteger();

		private Window(long id) {
			this.id = id;
		}

	}

}
