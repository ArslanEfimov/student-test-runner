#!/bin/bash
set -uo pipefail

if [ -f "gradlew" ]; then
    echo "Build tool: Gradle"
    chmod +x gradlew
    ./gradlew \
        --init-script "$JACOCO_INIT_SCRIPT" \
        test jacocoTestReport \
        --continue \
        -x javadoc \
        --no-daemon

elif [ -f "pom.xml" ]; then
    echo "Build tool: Maven"

    MVN="mvn"
    if [ -f "mvnw" ]; then
        chmod +x mvnw
        MVN="./mvnw"
    fi

    $MVN \
        org.jacoco:jacoco-maven-plugin:0.8.11:prepare-agent \
        test \
        org.jacoco:jacoco-maven-plugin:0.8.11:report \
        -Dmaven.test.failure.ignore=true \
        -q

else
    echo "ERROR: No supported build tool found (expected gradlew or pom.xml at project root)" >&2
    exit 1
fi
