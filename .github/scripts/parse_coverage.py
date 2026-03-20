#!/usr/bin/env python3
import argparse
import json
import xml.etree.ElementTree as ET
from pathlib import Path

def parse_jacoco_coverage(xml_path: Path) -> float | None:
    """Returns instruction coverage ratio [0.0, 1.0] or None on failure."""
    try:
        root = ET.parse(xml_path).getroot()
        for counter in root.findall('counter'):
            if counter.get('type') == 'INSTRUCTION':
                covered = int(counter.get('covered', 0))
                missed  = int(counter.get('missed', 0))
                total   = covered + missed
                return round(covered / total, 4) if total > 0 else 0.0
    except Exception as e:
        print(f"[warn] Could not parse JaCoCo XML {xml_path}: {e}")
    return None


def parse_junit_results(test_results_dir: Path) -> tuple[int, int, str]:
    """
    Scans Surefire / Gradle test-results XML files.
    Returns (total_tests, failed_tests, log_output).
    """
    if not test_results_dir.exists():
        return 0, 0, "No test result directory found"

    total, failed = 0, 0
    failure_messages: list[str] = []

    for xml_file in test_results_dir.rglob("TEST-*.xml"):
        try:
            root = ET.parse(xml_file).getroot()
            total  += int(root.get("tests",    0))
            failed += int(root.get("failures", 0)) + int(root.get("errors", 0))

            for failure in root.findall(".//failure"):
                msg = failure.get("message", "").strip()
                if msg:
                    failure_messages.append(msg[:300])
        except Exception as e:
            print(f"[warn] Could not parse test XML {xml_file}: {e}")

    log = f"Tests run: {total}, Failures: {failed}"
    if failure_messages:
        log += "\n\nFailure details:\n" + "\n---\n".join(failure_messages[:5])

    return total, failed, log


def module_name_from_path(module_dir: Path, project_dir: Path) -> str:
    """Returns the directory name relative to project root, or project name for root modules."""
    try:
        rel_parts = module_dir.relative_to(project_dir).parts
        return rel_parts[0] if rel_parts else project_dir.name
    except ValueError:
        return module_dir.name


def collect_gradle(project_dir: Path) -> list[dict]:
    results = []
    seen_modules: set[Path] = set()

    # Search for any JaCoCo XML under build/reports/jacoco/ (handles custom task names too)
    for jacoco_xml in project_dir.rglob("build/reports/jacoco/**/*.xml"):
        # Resolve module dir: go up from the xml to the module root (above build/)
        try:
            build_index = jacoco_xml.parts.index("build")
            module_dir = Path(*jacoco_xml.parts[:build_index])
        except (ValueError, TypeError):
            continue

        if module_dir in seen_modules:
            continue
        seen_modules.add(module_dir)

        name     = module_name_from_path(module_dir, project_dir)
        coverage = parse_jacoco_coverage(jacoco_xml)

        test_dir = module_dir / "build" / "test-results" / "test"
        total, failed, log = parse_junit_results(test_dir)

        results.append(_entry(name, coverage, total, failed, log))
    return results


def collect_maven(project_dir: Path) -> list[dict]:
    results = []
    # Maven default: target/site/jacoco/jacoco.xml
    for jacoco_xml in project_dir.rglob("target/site/jacoco/jacoco.xml"):
        module_dir = jacoco_xml.parents[3]  # .../module/target/site/jacoco/file → module
        name       = module_name_from_path(module_dir, project_dir)
        coverage   = parse_jacoco_coverage(jacoco_xml)

        test_dir   = module_dir / "target" / "surefire-reports"
        total, failed, log = parse_junit_results(test_dir)

        results.append(_entry(name, coverage, total, failed, log))
    return results


def _entry(module_name, coverage, total, failed, log_output) -> dict:
    return {
        "module_name": module_name,
        "coverage":    coverage,
        "total":       total,
        "failed":      failed,
        "log_output":  log_output,
    }

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", required=True, help="Path to student project root")
    parser.add_argument("--output",      required=True, help="Output JSON file path")
    args = parser.parse_args()

    project_dir = Path(args.project_dir)

    results = collect_gradle(project_dir)
    if not results:
        results = collect_maven(project_dir)

    # Fallback: no reports found at all — tests likely didn't run
    if not results:
        results = [_entry(
            module_name = project_dir.name,
            coverage    = None,
            total       = 0,
            failed      = 0,
            log_output  = "No JaCoCo reports found. Tests may not have run or the build failed entirely.",
        )]

    with open(args.output, "w") as f:
        json.dump(results, f, indent=2)

    print(f"Coverage artifact written to {args.output}")
    for r in results:
        cov = f"{r['coverage'] * 100:.1f}%" if r["coverage"] is not None else "N/A"
        print(f"  {r['module_name']}: coverage={cov}, tests={r['total']}, failed={r['failed']}")


if __name__ == "__main__":
    main()
