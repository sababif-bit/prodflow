# ---- Build stage: compile and package with Maven (tests run in CI, not here) ----
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build
COPY pom.xml .
RUN mvn -B -q dependency:go-offline
COPY src ./src
RUN mvn -B -q package -DskipTests

# ---- Runtime stage: only the JRE and the jar -> small image, smaller attack surface ----
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
RUN addgroup -S app && adduser -S app -G app
COPY --from=build /build/target/prodflow.jar app.jar
# build revision: shown by GET /version and as OCI label; passed by CI (--build-arg GIT_SHA=<commit>)
ARG GIT_SHA=unknown
ENV APP_REVISION=${GIT_SHA}
LABEL org.opencontainers.image.revision=${GIT_SHA}
USER app
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD wget -qO- http://localhost:8080/actuator/health | grep -q '"status":"UP"' || exit 1
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "app.jar"]
