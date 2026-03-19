#!/bin/bash
  set -uo pipefail                                                                                                                                                       
                                                                                                                                                                           
  PROJECT_ROOT=$(pwd)                                                                                                                                                    
                                                                                                                                                                           
  # ---------------------------------------------------------------------------                                                                                            
  # Runners
  # ---------------------------------------------------------------------------

  run_gradle() {
      local dir=$1
      local gradle_cmd=${2:-./gradlew}
      echo "=== Gradle: $dir ==="
      pushd "$dir" > /dev/null
      [ "$gradle_cmd" = "./gradlew" ] && chmod +x gradlew
      $gradle_cmd \
          --init-script "$JACOCO_INIT_SCRIPT" \
          test jacocoTestReport \
          -x jacocoTestCoverageVerification \
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

      if grep -q "jacoco-maven-plugin" pom.xml 2>/dev/null; then
          $MVN test org.jacoco:jacoco-maven-plugin:report \
              -Dmaven.test.failure.ignore=true \
              -q || true
      else
          $MVN org.jacoco:jacoco-maven-plugin:0.8.11:prepare-agent \
              test \
              org.jacoco:jacoco-maven-plugin:0.8.11:report \
              -Dmaven.test.failure.ignore=true \
              -q || true
      fi
      popd > /dev/null
  }

  # ---------------------------------------------------------------------------
  # Discovery
  # ---------------------------------------------------------------------------

  find_and_run() {
      local found=false
      local -a gradle_dirs=()
      local -a maven_dirs=()

      # Gradle: only roots have gradlew
      while IFS= read -r gradlew_path; do
          gradle_dirs+=("$(dirname "$gradlew_path")")
          found=true
      done < <(find "$PROJECT_ROOT" \
          -name "gradlew" \
          -not -path "*/build/*" \
          -not -path "*/.gradle/*" \
          -not -path "*/.git/*" \
          | sort)

      # Gradle fallback: build file present but no gradlew
      if [ ${#gradle_dirs[@]} -eq 0 ]; then
          for marker in "settings.gradle" "settings.gradle.kts" "build.gradle" "build.gradle.kts"; do
              if [ -f "$PROJECT_ROOT/$marker" ]; then
                  echo "WARNING: gradlew not found, using system gradle"
                  gradle_dirs+=("$PROJECT_ROOT")
                  found=true
                  break
              fi
          done
      fi

      # Maven: skip submodules and dirs already covered by Gradle
      while IFS= read -r pom_path; do
          local dir
          dir=$(dirname "$pom_path")
          [ -f "$(dirname "$dir")/pom.xml" ] && continue
          [ -f "$dir/gradlew" ] && continue
          maven_dirs+=("$dir")
          found=true
      done < <(find "$PROJECT_ROOT" \
          -name "pom.xml" \
          -not -path "*/target/*" \
          -not -path "*/.git/*" \
          | sort)

      if [ "$found" = false ]; then
          echo "ERROR: No supported build tool found" >&2
          exit 1
      fi

      # Phase 1: pre-build without tests (only when multiple independent modules)
      if [ ${#gradle_dirs[@]} -gt 1 ]; then
          echo "=== Gradle: pre-building all modules ==="
          for dir in "${gradle_dirs[@]}"; do
              pushd "$dir" > /dev/null
              chmod +x gradlew
              ./gradlew publishToMavenLocal -x test --no-daemon -q 2>/dev/null \
                  || ./gradlew assemble -x test --no-daemon -q || true
              popd > /dev/null
          done
      fi

      if [ ${#maven_dirs[@]} -gt 1 ]; then
          echo "=== Maven: pre-building all modules ==="
          for dir in "${maven_dirs[@]}"; do
              local MVN="mvn"
              [ -f "$dir/mvnw" ] && chmod +x "$dir/mvnw" && MVN="$dir/mvnw"
              pushd "$dir" > /dev/null
              $MVN install -DskipTests -q || true
              popd > /dev/null
          done
      fi

      # Phase 2: tests with coverage
      for dir in "${gradle_dirs[@]}"; do
          if [ -f "$dir/gradlew" ]; then
              run_gradle "$dir" "./gradlew"
          else
              run_gradle "$dir" "gradle"
          fi
      done

      for dir in "${maven_dirs[@]}"; do
          run_maven "$dir"
      done
  }

  find_and_run