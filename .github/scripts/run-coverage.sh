#!/bin/bash
  set -uo pipefail

  PROJECT_ROOT=$(pwd)

  run_gradle() {
      local dir=$1
      echo "=== Gradle: $dir ==="
      pushd "$dir" > /dev/null
      chmod +x gradlew
      ./gradlew \
          --init-script "$JACOCO_INIT_SCRIPT" \
          test jacocoTestReport \
          --continue \
          -x javadoc \
          --no-daemon || true
      popd > /dev/null
  }

  run_maven() {
      local dir=$1
      echo "=== Maven: $dir ==="
      pushd "$dir" > /dev/null
      local MVN="mvn"
      if [ -f "mvnw" ]; then
          chmod +x mvnw
          MVN="./mvnw"
      fi
      $MVN \
          org.jacoco:jacoco-maven-plugin:0.8.11:prepare-agent \
          test \
          org.jacoco:jacoco-maven-plugin:0.8.11:report \
          -Dmaven.test.failure.ignore=true \
          -q || true
      popd > /dev/null
  }

  # 1. Check root
  if [ -f "gradlew" ]; then
      run_gradle "$PROJECT_ROOT"
  elif [ -f "pom.xml" ]; then
      run_maven "$PROJECT_ROOT"
  else
      # 2. Scan immediate subdirectories (microservices layout)
      echo "No root build file found, scanning subdirectories..."
      found=false

      for dir in "$PROJECT_ROOT"/*/; do
          dir="${dir%/}"
          if [ -f "$dir/gradlew" ]; then
              run_gradle "$dir"
              found=true
          elif [ -f "$dir/pom.xml" ]; then
              run_maven "$dir"
              found=true
          fi
      done

      if [ "$found" = false ]; then
          echo "ERROR: No build tool found at root or in subdirectories" >&2
          exit 1
      fi
  fi