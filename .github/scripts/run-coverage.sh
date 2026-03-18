#!/bin/bash
  set -uo pipefail

  PROJECT_ROOT=$(pwd)
  REPO_NAME=$(basename "${REPO_URL:-student-repo}" .git)

  get_project_name() {
      local dir=$1

      for settings in "$dir/settings.gradle.kts" "$dir/settings.gradle"; do
          if [ -f "$settings" ]; then
              local name
              name=$(grep -oP 'rootProject\.name\s*=\s*["'"'"']\K[^"'"'"']+' "$settings" 2>/dev/null | head -1)
              [ -n "$name" ] && echo "$name" && return
          fi
      done

      if [ -f "$dir/pom.xml" ]; then
          local name
          name=$(python3 -c "
  import xml.etree.ElementTree as ET
  try:
      root = ET.parse('$dir/pom.xml').getroot()
      ns = (root.tag.split('}')[0].lstrip('{') + '}') if '}' in root.tag else ''
      aid = root.find(ns + 'artifactId')
      print(aid.text.strip() if aid is not None else '')
  except: pass
  " 2>/dev/null)
          [ -n "$name" ] && echo "$name" && return
      fi

      # Fallback: repo name for root, dirname for submodules
      if [ "$dir" = "$PROJECT_ROOT" ]; then
          echo "$REPO_NAME"
      else
          basename "$dir"
      fi
  }

  run_gradle() {
      local dir=$1
      echo "=== Gradle: $(get_project_name "$dir") ==="
      pushd "$dir" > /dev/null
      chmod +x gradlew
      ./gradlew \
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
      echo "=== Maven: $(get_project_name "$dir") ==="
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

  find_and_run() {
      local found=false

      while IFS= read -r gradlew_path; do
          run_gradle "$(dirname "$gradlew_path")"
          found=true
      done < <(find "$PROJECT_ROOT" \
          -name "gradlew" \
          -not -path "*/build/*" \
          -not -path "*/.gradle/*" \
          -not -path "*/.git/*" \
          | sort)


      while IFS= read -r pom_path; do
          local dir
          dir=$(dirname "$pom_path")
          local parent_dir
          parent_dir=$(dirname "$dir")

          if [ -f "$parent_dir/pom.xml" ]; then
              continue
          fi

          if [ -f "$dir/gradlew" ]; then
              continue
          fi

          run_maven "$dir"
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
  }