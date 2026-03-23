#!/bin/bash
  set -uo pipefail                                                                                                                                                       
                                                                                                                                                                           
  PROJECT_ROOT=$(pwd)                                                                                                                                                    
                                                                                                                                                                           

  run_gradle() {
      local dir=$1
      local gradle_cmd=${2:-./gradlew}
      echo "=== Gradle: $dir ==="
      pushd "$dir" > /dev/null
      [ "$gradle_cmd" = "./gradlew" ] && chmod +x gradlew
      # Run tests; the init-script's finalizedBy will trigger jacocoTestReport automatically.
      # -x jacocoTestCoverageVerification: skip coverage thresholds (student may set high %).
      # --continue: collect partial coverage even when some tests fail (e.g. infra deps missing).
      $gradle_cmd \
          --init-script "$JACOCO_INIT_SCRIPT" \
          test \
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

      # -Dmaven.test.failure.ignore=true: collect coverage even when tests fail.
      # No -q: keep output visible so failures are diagnosable.
      if grep -q "jacoco-maven-plugin" pom.xml 2>/dev/null; then
          $MVN test org.jacoco:jacoco-maven-plugin:report \
              -Dmaven.test.failure.ignore=true || true
      else
          $MVN org.jacoco:jacoco-maven-plugin:0.8.11:prepare-agent \
              test \
              org.jacoco:jacoco-maven-plugin:0.8.11:report \
              -Dmaven.test.failure.ignore=true || true
      fi
      popd > /dev/null
  }

  find_and_run() {
      local found=false
      local -a gradle_dirs=()
      local -a maven_dirs=()

     
      while IFS= read -r gradlew_path; do
          gradle_dirs+=("$(dirname "$gradlew_path")")
          found=true
      done < <(find "$PROJECT_ROOT" \
          -name "gradlew" \
          -not -path "*/build/*" \
          -not -path "*/.gradle/*" \
          -not -path "*/.git/*" \
          | sort)

     
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
              # install into local ~/.m2 so inter-module dependencies resolve
              $MVN install -DskipTests || true
              popd > /dev/null
          done
      fi

      
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
