FROM ibm-semeru-runtimes:open-17-jdk-centos7 AS builder
COPY . .
RUN ./gradlew clean assemble

FROM ibm-semeru-runtimes:open-17-jdk-centos7 AS runtime
RUN mkdir /opt/app
COPY --from=builder build/libs/slate.jar /opt/app/app.jar
EXPOSE 8080
CMD ["java", "-jar", "/opt/app/app.jar"]