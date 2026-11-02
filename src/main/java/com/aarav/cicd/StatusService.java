package com.aarav.cicd;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.time.Clock;
import java.time.Instant;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.util.Locale;

import org.springframework.stereotype.Service;

@Service
public class StatusService {

	private static final DateTimeFormatter DISPLAY_FORMAT =
			DateTimeFormatter.ofPattern("dd MMM yyyy, HH:mm z", Locale.ENGLISH);

	private final AppProperties properties;
	private final Instant startedAt;
	private final String podName;

	public StatusService(AppProperties properties, Clock clock) {
		this.properties = properties;
		this.startedAt = clock.instant();
		this.podName = resolveHostName();
	}

	public DeploymentStatus currentStatus() {
		return new DeploymentStatus(
				"LIVE",
				properties.version(),
				properties.buildNumber(),
				shortCommit(properties.gitCommit()),
				formatDeployedAt(properties.deployedAt()),
				properties.stage(),
				podName);
	}

	static String shortCommit(String commit) {
		if (commit == null || commit.isBlank()) {
			return "unknown";
		}
		return commit.length() > 7 ? commit.substring(0, 7) : commit;
	}

	/** Formats the ISO-8601 deploy time from the pipeline; falls back to the app start time. */
	String formatDeployedAt(String deployedAt) {
		Instant instant = startedAt;
		if (deployedAt != null && !deployedAt.isBlank()) {
			try {
				instant = Instant.parse(deployedAt);
			}
			catch (DateTimeParseException ex) {
				// keep the start time; a bad value should never break the page
			}
		}
		return DISPLAY_FORMAT.format(instant.atZone(properties.timeZone()));
	}

	/** Inside Kubernetes the host name is the pod name. */
	private static String resolveHostName() {
		try {
			return InetAddress.getLocalHost().getHostName();
		}
		catch (UnknownHostException ex) {
			return "unknown";
		}
	}

}
