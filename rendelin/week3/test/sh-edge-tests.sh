#!/usr/bin/env bash
# build.sh edge-case test suite (fake docker in WSL; no real docker needed)
set -u
SCRIPT="/mnt/g/claude codex_workspace/开源计划/腾讯犀牛鸟开源计划/TencentDB-Agent-Memory/docker/hermes-version-compat/build.sh"
mkdir -p /tmp/fakebin /tmp/shout
cat > /tmp/fakebin/docker <<'EOF'
#!/usr/bin/env bash
echo "FAKE_DOCKER $*" >> /tmp/shout/docker.log
exit 0
EOF
chmod +x /tmp/fakebin/docker

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1  -> $2"; }

run() { # run <input-lines> <env-presets...>
    local input="$1"; shift
    rm -f /tmp/shout/docker.log /tmp/shout/out.log
    env -i PATH="/tmp/fakebin:/usr/bin:/bin" HOME=/root \
        "$@" bash "$SCRIPT" <<< "$input" > /tmp/shout/out.log 2>&1
    echo $?
}
envpreset() { # run with HERMES_VERSION preset (non-interactive, empty stdin)
    rm -f /tmp/shout/docker.log /tmp/shout/out.log
    env -i PATH="/tmp/fakebin:/usr/bin:/bin" HOME=/root \
        HERMES_VERSION="$1" MODEL_API_KEY=sk-x bash "$SCRIPT" < /dev/null > /tmp/shout/out.log 2>&1
    echo $?
}

echo '== S1 happy path (version+key via stdin, defaults for rest) =='
RC=$(run $'2026.8.18\nsk-secret\n\n\n\n')
[ "$RC" = 0 ] && ok 'RC=0' || bad 'RC=0' "rc=$RC"
grep -q 'FAKE_DOCKER build --build-arg HERMES_VERSION=v2026.8.18' /tmp/shout/docker.log && ok 'build v2026.8.18' || bad 'build version' "$(cat /tmp/shout/docker.log)"
grep -q 'run --rm -e MODEL_API_KEY ' /tmp/shout/docker.log && ok 'run -e MODEL_API_KEY (no value)' || bad 'run key env' "$(cat /tmp/shout/docker.log)"
grep -q 'sk-secret' /tmp/shout/docker.log && bad 'no key leak' 'LEAKED' || ok 'no key leak'

echo '== S2 empty version -> retry =='
RC=$(run $'\n2026.8.18\nsk-secret\n\n\n\n')
[ "$RC" = 0 ] && ok 'RC=0' || bad 'RC=0' "rc=$RC"
grep -q 'tags' /tmp/shout/out.log && ok 'tags URL shown' || bad 'tags URL' 'missing'

echo '== S3 multi-segment =='
RC=$(run $'2026.8.16.2\nsk-secret\n\n\n\n')
[ "$RC" = 0 ] && ok 'RC=0' || bad 'RC=0' "rc=$RC"
grep -q 'HERMES_VERSION=v2026.8.16.2' /tmp/shout/docker.log && ok 'v2026.8.16.2' || bad 'version' "$(cat /tmp/shout/docker.log)"

echo '== S4 env-preset invalid -> fast fail =='
RC=$(envpreset abc)
[ "$RC" = 1 ] && ok 'RC=1' || bad 'RC=1' "rc=$RC"
[ ! -f /tmp/shout/docker.log ] && ok 'no docker call' || bad 'no docker call' 'called'

echo '== S5 env-preset valid -> skips prompt =='
RC=$(envpreset v2026.8.18)
[ "$RC" = 0 ] && ok 'RC=0' || bad 'RC=0' "rc=$RC"

echo '== S6 missing API key -> error =='
RC=$(run $'2026.8.18\n\n\n\n\n')
[ "$RC" = 1 ] && ok 'RC=1' || bad 'RC=1' "rc=$RC"
grep -q 'API Key' /tmp/shout/out.log && ok 'key error msg' || bad 'key msg' 'missing'

echo '== S7 docker not found -> error =='
rm -f /tmp/shout/out.log
env -i PATH="/usr/bin:/bin" HOME=/root bash "$SCRIPT" <<< $'2026.8.18\nsk-x\n\n\n\n' > /tmp/shout/out.log 2>&1
RC=$?
[ "$RC" = 1 ] && ok 'RC=1' || bad 'RC=1' "rc=$RC"
grep -q 'docker' /tmp/shout/out.log && ok 'docker msg' || bad 'docker msg' 'missing'

echo '== S8 v-prefix accepted =='
RC=$(run $'v2026.8.18\nsk-secret\n\n\n\n')
[ "$RC" = 0 ] && ok 'RC=0' || bad 'RC=0' "rc=$RC"
grep -q 'HERMES_VERSION=v2026.8.18' /tmp/shout/docker.log && ok 'normalized' || bad 'normalize' 'missing'

echo
echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
