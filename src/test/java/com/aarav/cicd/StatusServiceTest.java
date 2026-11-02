package com.aarav.cicd;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;

import org.junit.jupiter.api.Test;

class StatusServiceTest {

	private static final Clock START = Clock.fixed(Instant.parse("2026-11-01T06:00:00Z"), ZoneOffset.UTC);

	private static StatusService service(String commit, String deployedAt) {
		AppProperties properties = new AppProperties("1.0.0", "7", commit, deployedAt, "Production (AKS)",
				ZoneId.of("Asia/Kolkata"), new AppProperties.RateLimit(60));
		return new StatusService(properties, START);
	}

	@Test
	void reportsDeploymentDetails() {
		DeploymentStatus status = service("a1b2c3d", "2026-11-02T09:02:00Z").currentStatus();

		assertThat(status.status()).isEqualTo("LIVE");
		assertThat(status.version()).isEqualTo("1.0.0");
		assertThat(status.buildNumber()).isEqualTo("7");
		assertThat(status.stage()).isEqualTo("Production (AKS)");
		assertThat(status.podName()).isNotBlank();
	}

	@Test
	void shortensFullCommitHashToSevenCharacters() {
		assertThat(StatusService.shortCommit("0123456789abcdef0123456789abcdef01234567")).isEqualTo("0123456");
		assertThat(StatusService.shortCommit("abc")).isEqualTo("abc");
		assertThat(StatusService.shortCommit("")).isEqualTo("unknown");
		assertThat(StatusService.shortCommit(null)).isEqualTo("unknown");
	}

	@Test
	void showsDeployTimeInIndianStandardTime() {
		assertThat(service("x", "2026-11-02T09:02:00Z").currentStatus().deployedAt())
				.isEqualTo("02 Nov 2026, 14:32 IST");
	}

	@Test
	void fallsBackToStartTimeWhenDeployTimeIsMissingOrInvalid() {
		assertThat(service("x", "").currentStatus().deployedAt()).isEqualTo("01 Nov 2026, 11:30 IST");
		assertThat(service("x", "not-a-date").currentStatus().deployedAt()).isEqualTo("01 Nov 2026, 11:30 IST");
	}

}
