FROM mcr.microsoft.com/openjdk/jdk:21-mariner AS build
WORKDIR /workspace

# Install Maven (the openjdk image does not ship with it)
ARG MAVEN_VERSION=3.9.9
RUN tdnf install -y tar gzip ca-certificates && \
    curl -fsSL https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz \
        -o /tmp/maven.tar.gz && \
    tar -xzf /tmp/maven.tar.gz -C /opt && \
    ln -s /opt/apache-maven-${MAVEN_VERSION}/bin/mvn /usr/local/bin/mvn && \
    rm /tmp/maven.tar.gz

COPY pom.xml ./
RUN mvn -B -q dependency:go-offline
COPY src ./src
RUN mvn -B -q -DskipTests package

FROM mcr.microsoft.com/openjdk/jdk:21-mariner
WORKDIR /app
COPY --from=build /workspace/target/akv-pickup.jar /app/app.jar
EXPOSE 8080
ENV JAVA_OPTS=""
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar /app/app.jar"]
