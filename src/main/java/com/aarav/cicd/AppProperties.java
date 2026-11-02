package com.aarav.cicd;

import java.time.ZoneId;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Deployment details shown on the status page. Jenkins/Ansible set these as
 * environment variables when the app is deployed (see application.yml).
 */
@ConfigurationProperties(prefix = "app")
public record AppProperties(
		String version,
		String buildNumber,
		String gitCommit,
		String deployedAt,
		String stage,
		ZoneId timeZone,
		RateLimit rateLimit) {

	public record RateLimit(int requestsPerMinute) {
	}

}
