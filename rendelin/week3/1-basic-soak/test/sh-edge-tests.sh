#!/usr/bin/env bash
# build.sh edge-case test suite (fake docker; no real docker needed)
# 被测脚本：仓库内 rendelin/week3/3-full-pipeline/build.sh（相对本文件定位，clone 即可用）
set -u
SCRIPT="$(cd "$(dirname "$0")/../../3-full-pipeline" && pwd)/build.sh"
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
RC=$(run $'2026.8.18\nsk-secret\n\n\n\n\n\n\n\n')
[ "$RC" = 0 ] && ok 'RC=0' || bad 'RC=0' "rc=$RC"
grep -q 'FAKE_DOCKER build --build-arg HERMES_VERSION=v2026.8.18' /tmp/shout/docker.log && ok 'build v2026.8.18' || bad 'build version' "$(cat /tmp/shout/docker.log)"
grep -q 'FAKE_DOCKER run.*-e MODEL_API_KEY=sk-secret' /tmp/shout/docker.log && ok 'run carries -e MODEL_API_KEY (value)' || bad 'run key env' 'missing'
# 密钥只允许出现在 docker run（运行时注入），不允许出现在 docker build 参数里
grep 'FAKE_DOCKER build' /tmp/shout/docker.log | grep -q 'sk-secret' && bad 'no key leak in build args' 'LEAKED' || ok 'no key leak in build args'

echo '== S2 empty version -> retry =='
RC=$(run $'\n2026.8.18\nsk-secret\n\n\n\n\n\n\n\n')
[ "$RC" = 0 ] && ok 'RC=0' || bad 'RC=0' "rc=$RC"
grep -q '版本号格式' /tmp/shout/out.log && ok 'version prompt shown' || bad 'version prompt' 'missing'

echo '== S3 multi-segment =='
RC=$(run $'2026.8.16.2\nsk-secret\n\n\n\n\n\n\n\n')
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
RC=$(run $'2026.8.18\n\n\n\n\n\n\n\n\n')
[ "$RC" = 1 ] && ok 'RC=1' || bad 'RC=1' "rc=$RC"
grep -q 'MODEL_API_KEY' /tmp/shout/out.log && ok 'key error msg' || bad 'key msg' 'missing'

echo '== S7 docker not found -> error =='
rm -f /tmp/shout/out.log
env -i PATH="/usr/bin:/bin" HOME=/root bash "$SCRIPT" <<< $'2026.8.18\nsk-x\n\n\n\n\n\n\n\n' > /tmp/shout/out.log 2>&1
RC=$?
[ "$RC" = 127 ] && ok 'RC=127 (docker: command not found)' || bad 'RC=127' "rc=$RC"
grep -q 'command not found' /tmp/shout/out.log && ok 'docker not found msg' || bad 'docker msg' 'missing'

echo '== S8 v-prefix accepted =='
RC=$(run $'v2026.8.18\nsk-secret\n\n\n\n\n\n\n\n')
[ "$RC" = 0 ] && ok 'RC=0' || bad 'RC=0' "rc=$RC"
grep -q 'HERMES_VERSION=v2026.8.18' /tmp/shout/docker.log && ok 'normalized' || bad 'normalize' 'missing'

echo
echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
