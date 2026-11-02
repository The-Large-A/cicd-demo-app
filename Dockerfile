# Runtime image for cicd-demo-app.
# The jar is built and tested by Maven earlier in the pipeline; this image only packages
# that same tested jar ("build once, promote the artifact"). Build it with:
#   ./mvnw package && docker build -t cicd-demo-app:local .
FROM eclipse-temurin:21.0.13_9-jre-alpine-3.24

LABEL org.opencontainers.image.title="cicd-demo-app" \
      org.opencontainers.image.description="CIA 2 CI/CD demo status page"

# Run as an unprivileged user (UID matches runAsUser in k8s/deployment.yaml)
RUN addgroup -S -g 10001 app && adduser -S -D -H -u 10001 -G app app

WORKDIR /app
COPY --chown=10001:10001 target/cicd-demo-app.jar app.jar

USER 10001
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
  CMD wget -qO /dev/null http://localhost:8080/actuator/health/liveness || exit 1

# Size the heap from the container memory limit and restart cleanly on OOM
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-XX:+ExitOnOutOfMemoryError", "-jar", "/app/app.jar"]
