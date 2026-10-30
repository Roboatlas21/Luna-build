#!/usr/bin/env bash
# Run independent source-check families without hiding later failures.
# Usage: bash ci/scripts/validate-snapshot.sh GROUP [WORKSPACE]
set -uo pipefail

GROUP="${1:?validation group required}"
WORKSPACE="${2:-$PWD}"
LOG_DIR="${SOURCE_VALIDATION_LOG_DIR:-${RUNNER_TEMP:-/tmp}/source-validation}"
mkdir -p "$LOG_DIR" || exit 1
failures=0
checks=0

run_checked() {
  local label="$1"; shift
  local code
  checks=$((checks + 1))
  printf '\n::group::%s / %s\n' "$GROUP" "$label"
  "$@" 2>&1 | tee "$LOG_DIR/${GROUP}-${label}.log"
  code=${PIPESTATUS[0]}
  printf '::endgroup::\n'
  if [[ "$code" -ne 0 ]]; then
    printf 'SOURCE_CHECK_FAIL group=%s check=%s code=%s\n' "$GROUP" "$label" "$code" >&2
    failures=$((failures + 1))
  else
    printf 'SOURCE_CHECK_PASS group=%s check=%s\n' "$GROUP" "$label"
  fi
}

require_luna_files() {
  local missing=0
  for required in \
    resources/launchscripts/coreelec/launch.sh \
    resources/launchscripts/coreelec/kodi-watchdog.sh \
    resources/launchscripts/coreelec/tsync.sh \
    resources/launchscripts/coreelec/aml-recovery.sh \
    resources/launchscripts/coreelec/hang-diagnostics.sh \
    resources/lib/util/resumestate.py \
    resources/lib/util/hdmigamemode.py; do
    if [[ ! -f "$required" ]]; then
      printf 'Missing Luna snapshot dependency: %s\n' "$required" >&2
      missing=1
    fi
  done
  return "$missing"
}

verify_moonlight_package() {
  local missing=0
  test -f third_party/moonlight-common-c/src/Limelight.h || missing=1
  test -s third_party/SDL_GameControllerDB/gamecontrollerdb.txt || missing=1
  grep -Fq 'runtime_manifest.py' packaging/coreelec-ng/collect-native.sh || missing=1
  grep -Fq 'install_pkg/moonlight-embedded-2.7.1-ng-local' packaging/coreelec-ng/collect-native.sh || missing=1
  grep -Fq 'ENABLE_CORE_ELEC_AUDIO_MAPPING=ON' packaging/coreelec-ng/package.mk || missing=1
  grep -Fq 'ENABLE_FFMPEG=OFF' packaging/coreelec-ng/package.mk || missing=1
  return "$missing"
}

case "$GROUP" in
  moonlight-vfm)
    cd "$WORKSPACE/moonlight" || exit 2
    run_checked vfm_host bash tests/test_vfm_host.sh
    run_checked evdev_syntax bash -c 'cc -std=gnu99 -Wall -Wextra -Werror=implicit-function-declaration -Werror=incompatible-pointer-types -Werror=return-type -fsyntax-only -Ithird_party/moonlight-common-c/src $(pkg-config --cflags libevdev libudev) src/input/evdev.c'
    ;;
  moonlight-audio)
    cd "$WORKSPACE/moonlight" || exit 2
    run_checked bounded_writer bash tests/test_alsa_bounded_write.sh
    run_checked init_failures python3 tests/test_alsa_init.py
    run_checked diagnostics bash tests/test_stream_diagnostics.sh
    # Use Bash only for the pkg-config substitution; preserve -Werror.
    run_checked syntax bash -c 'cc -std=gnu99 -Wall -Wextra -Werror -Wno-unused-parameter -fsyntax-only -Ithird_party/moonlight-common-c/src $(pkg-config --cflags alsa opus) src/audio/alsa.c'
    ;;
  moonlight-packaging)
    cd "$WORKSPACE/moonlight" || exit 2
    # Includes the full Apollo HTTP/TLS pairing and production decoder-loop regressions.
    run_checked native_python python3 -m unittest discover -s tests -v
    # Cross-repository pin failures must surface before multi-hour ARM32 work.
    run_checked source_pins python3 packaging/coreelec-ng/vfm/check-source-pins.py "$WORKSPACE/snapshot/moonlight-build/source-lock.json"
    run_checked source_pin_tests python3 -m unittest discover -s tests -p test_vfm_source_pins.py -v
    run_checked native_cache_key python3 "$WORKSPACE/ci/scripts/native-dependency-key.py" "$WORKSPACE/moonlight"
    run_checked native_cache_key_tests python3 "$WORKSPACE/ci/scripts/test-native-dependency-key.py"
    for script in \
      packaging/coreelec-ng/prepare-build.sh \
      packaging/coreelec-ng/collect-native.sh \
      packaging/coreelec-ng/build-stage.sh \
      packaging/coreelec-ng/fix-rtmpdump-source.sh \
      packaging/coreelec-ng/patch-host-flags.sh \
      packaging/coreelec-ng/check-host-tools.sh \
      packaging/coreelec-ng/vfm/prepare-build.sh \
      packaging/coreelec-ng/vfm/smoke-runtime.sh; do
      run_checked "syntax_$(basename "$(dirname "$script")")_$(basename "$script" .sh)" bash -n "$script"
    done
    run_checked rtmpdump bash tests/test_rtmpdump_source.sh
    run_checked host_portability bash tests/test_host_portability.sh
    run_checked staged_build bash tests/test_coreelec_ng_build_stage.sh
    run_checked artifact_collector bash tests/test_coreelec_ng_collect_native.sh
    run_checked manifest python3 -m unittest discover -s tests -p test_runtime_manifest.py -v
    run_checked runtime_python_syntax python3 -m py_compile tests/test_vfm_runtime_build.py
    run_checked runtime python3 -m unittest discover -s tests -p test_vfm_runtime_build.py -v
    run_checked recipe_contract verify_moonlight_package
    ;;
  luna-python)
    cd "$WORKSPACE/luna" || exit 2
    run_checked snapshot_dependencies require_luna_files
    run_checked compile python3 -m compileall -q addon.py resources/lib
    run_checked unittest python3 -m unittest discover -s tests -v
    ;;
  luna-launch)
    cd "$WORKSPACE/luna" || exit 2
    for script in resources/launchscripts/coreelec/launch.sh \
                  resources/launchscripts/coreelec/kodi-watchdog.sh \
                  resources/launchscripts/coreelec/hang-diagnostics.sh \
                  resources/launchscripts/coreelec/aml-recovery.sh \
                  resources/launchscripts/coreelec/tsync.sh; do
      run_checked "syntax_$(basename "$script" .sh)" sh -n "$script"
    done
    run_checked launch_integration bash tests/test_launch.sh
    run_checked aml_recovery bash tests/test_aml_recovery.sh
    ;;
  *)
    printf 'Unknown source validation group: %s\n' "$GROUP" >&2
    exit 2
    ;;
esac

printf '\nSOURCE_VALIDATION_SUMMARY group=%s total=%s failed=%s\n' \
  "$GROUP" "$checks" "$failures"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  if (( failures )); then verdict=FAIL; else verdict=PASS; fi
  printf '| %s | %s | %s / %s |\n' "$GROUP" "$verdict" "$failures" "$checks" >> "$GITHUB_STEP_SUMMARY"
fi
(( failures == 0 ))
