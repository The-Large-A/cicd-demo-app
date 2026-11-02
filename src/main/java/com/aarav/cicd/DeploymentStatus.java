package com.aarav.cicd;

/** What the status page and /api/status report about the running deployment. */
public record DeploymentStatus(
		String status,
		String version,
		String buildNumber,
		String gitCommit,
		String deployedAt,
		String stage,
		String podName) {
}
