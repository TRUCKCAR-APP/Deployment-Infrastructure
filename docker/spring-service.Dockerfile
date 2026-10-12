# syntax=docker/dockerfile:1.7
# =============================================================================
# Imagen genérica para los microservicios Spring Boot de TruckDar (Java 21).
# Se construye con el directorio de cada servicio como contexto (ver docker-compose.yml);
# las exclusiones están en spring-service.Dockerfile.dockerignore.
# =============================================================================
FROM maven:3.9.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml .
COPY src ./src
# Caché de dependencias compartida entre servicios y entre builds.
RUN --mount=type=cache,target=/root/.m2 mvn -q -B package -DskipTests \
 && cp "$(ls target/*.jar | grep -v -- '-plain.jar' | head -n 1)" /app.jar

FROM eclipse-temurin:21-jre
WORKDIR /app
RUN groupadd --system truckdar && useradd --system --gid truckdar --home /app truckdar
COPY --from=build /app.jar /app/app.jar
USER truckdar
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=70 -XX:+ExitOnOutOfMemoryError"
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
