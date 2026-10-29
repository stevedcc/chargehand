. "$(dirname "$0")/lib.sh"
# chargehand-lane verify (scripts/lane.sh) on a real rootless Podman: suites offline, restore online,
# services reachable by name, nothing left behind. Uses a throwaway alpine image built from
# tests/fixtures/lane-demo/Containerfile (not the runner image) and the demo project next to it.
# Opt-in, it is slow and needs the network: HARNESS_TESTS_REAL_RUNTIME=1 and the current user's
# rootless Podman socket. Run it alone (where there is a machine-wide suite lock, through it).
# The lane removes every container and network labelled chargehand=1, so this file refuses to run
# while any exist: they would belong to someone else.
if [ "${HARNESS_TESTS_REAL_RUNTIME:-0}" != 1 ] || ! command -v podman >/dev/null \
    || [ ! -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock" ]; then
    echo "  skip  real-runtime lane tests (need HARNESS_TESTS_REAL_RUNTIME=1 and a rootless Podman socket)"
    exit 0
fi
[ "$(podman info --format '{{.Host.Security.Rootless}}')" = true ] \
    || { echo "  FAIL  Podman is not rootless; these tests run only on a rootless Podman"; exit 1; }

# labelled: every container and network labelled chargehand=1, one name per line.
labelled() {
    podman ps -a --filter label=chargehand=1 --format '{{.Names}}'
    podman network ls --filter label=chargehand=1 --format '{{.Name}}'
}
[ -z "$(labelled)" ] || { echo "  FAIL  containers or networks labelled chargehand=1 exist already: $(labelled | tr '\n' ' ')"; exit 1; }
! podman container exists db || { echo "  FAIL  a container named db exists already (the demo service's name)"; exit 1; }

# setup_home gives every test a throwaway HOME; Podman keeps its storage under HOME, so point it at
# the real one explicitly.
REAL_TMP="$(mktemp -d)" REAL_HOME="$HOME"
DEMO_TAG="localhost/chargehand-lane-demo:test-$$"
# Podman refuses to run once HOME is gone (the last test's is removed), hence the real HOME here.
trap 'HOME="$REAL_HOME" podman rmi "$DEMO_TAG" >/dev/null || echo "  could not remove the test image $DEMO_TAG" >&2
      rm -rf "$REAL_TMP"' EXIT
printf '[storage]\ndriver = "%s"\ngraphroot = "%s"\nrunroot = "%s"\n' \
    "$(podman info --format '{{.Store.GraphDriverName}}')" "$(podman info --format '{{.Store.GraphRoot}}')" \
    "$(podman info --format '{{.Store.RunRoot}}')" > "$REAL_TMP/storage.conf"
export CONTAINERS_STORAGE_CONF="$REAL_TMP/storage.conf"

mkdir -p "$REAL_TMP/ctx"
cp "$HARNESS_ROOT/tests/fixtures/lane-demo/Containerfile" "$HARNESS_ROOT/images/runner/chargehand-run" "$REAL_TMP/ctx/"
podman build -q -t "$DEMO_TAG" "$REAL_TMP/ctx" >/dev/null || { echo "  FAIL  could not build the demo image"; exit 1; }
DEMO_DIGEST="$(podman image inspect --format '{{.Digest}}' "$DEMO_TAG")"
DEMO_IMAGE="localhost/chargehand-lane-demo@$DEMO_DIGEST"

# real_setup [jq-filter]: lane.json (Podman, project "demo": restore and build do nothing, one suite
# that passes), and a bare repo holding the demo project under refs/verify/ (as the requester pushes).
real_setup() {
    jq -n --arg img "$DEMO_IMAGE" '{
        runtime: "podman", cpus: 1, memory: "512m",
        repos_dir: "~/lane/repos", work_dir: "~/lane/work", verify_timeout_min: 2,
        projects: { demo: {
            runner_image: $img, restore: "true", build: "true", tests: ["bash tests/pass.sh"],
            test_filter: "Passed!|Failed!", summary_pattern: "^(Passed|Failed)!" } } }' \
        | jq --arg img "$DEMO_IMAGE" "${1:-.}" > "$HARNESS_CONFIG_DIR/lane.json"
    local seed="$TEST_TMP/seed" repo="$HOME/lane/repos/demo.git"
    cp -r "$HARNESS_ROOT/tests/fixtures/lane-demo/project" "$seed"
    git init -q "$seed"
    git -C "$seed" add -A
    git -C "$seed" -c user.name=t -c user.email=t@example.invalid commit -q -m "lane demo"
    SHA="$(git -C "$seed" rev-parse HEAD)"; SHA7="${SHA:0:7}"
    git init -q --bare "$repo"
    git -C "$seed" push -q "$repo" "$SHA:refs/verify/$SHA"
}
DB_SERVICE='.projects.demo.services = [{ name: "db", image: $img, ready: ["nc", "-z", "127.0.0.1", "5432"], ready_timeout_sec: 30 }]'
# verify: runs the controller; output (stderr folded in) in OUT, exit code in RC.
verify() { OUT="$(bash "$HARNESS_ROOT/scripts/lane.sh" verify --project demo "$SHA" 2>&1)"; RC=$?; }
# assert_clean: no container or network of the run remains, nor its run directory.
assert_clean() {
    assert_eq "no labelled container or network left" "$(labelled)" ""
    assert_eq "run dir removed" "$([ -e "$HOME/lane/work/run-$SHA7" ] && echo there || echo gone)" "gone"
}

test_real_pass() {
    real_setup; verify
    assert_eq "exit" "$RC" "0"
    assert_contains "start line" "$OUT" "Verifying $SHA7 lane demo"
    assert_contains "suite output" "$OUT" "Passed!  - Failed: 0, Passed: 1"
    assert_contains "runner digest" "$OUT" "digests: runner=$DEMO_DIGEST"
    assert_clean
}
test_real_no_outbound_in_suites() {
    real_setup '.projects.demo.tests = ["bash tests/offline.sh"]'; verify
    assert_eq "exit" "$RC" "0"
    assert_contains "suite saw no network" "$OUT" "Passed!  - no outbound network"
    assert_clean
}
test_real_restore_has_outbound() {
    real_setup '.projects.demo.restore = "wget -q -T 10 -O /dev/null https://example.com"'; verify
    assert_eq "exit" "$RC" "0"
    assert_not_contains "restore passed" "$OUT" "RESTORE FAILED"
    assert_clean
}
test_real_service_reachable() {
    real_setup "$DB_SERVICE | .projects.demo.tests = [\"bash tests/db.sh\"]"; verify
    assert_eq "exit" "$RC" "0"
    assert_contains "suite reached db by name" "$OUT" "Passed!  - reached db:5432"
    assert_contains "service digest" "$OUT" "db=$DEMO_DIGEST"
    assert_clean
}
test_real_no_leftovers() {
    real_setup "$DB_SERVICE | .projects.demo.tests = [\"bash tests/pass.sh\", \"bash tests/fail.sh\"]"; verify
    assert_eq "a failing suite exits 10" "$RC" "10"
    assert_contains "failing suite named" "$OUT" "suite 2: exit code 1"
    assert_clean
    verify
    assert_eq "a second run of the same commit" "$RC" "10"
    assert_clean
}

run_tests
