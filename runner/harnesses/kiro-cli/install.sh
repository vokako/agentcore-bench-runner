# Kiro CLI from the official release zip ($BENCH_KIRO_VERSION pins a release, default 2.29.0, the version the
# published results used; BENCH_KIRO_VERSION=latest for the newest) (x86_64 or aarch64; musl build when glibc < 2.34).
# Unzipped with node (task images often lack unzip); binaries go to /opt/bench-kiro/bin.
ARCH=$(uname -m)
GLIBC=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$')
SUFFIX=-musl
if [ -n "$GLIBC" ] && awk "BEGIN{exit !($GLIBC >= 2.34)}"; then SUFFIX=""; fi
fetch "https://desktop-release.q.us-east-1.amazonaws.com/${BENCH_KIRO_VERSION:-2.29.0}/kirocli-${ARCH}-linux${SUFFIX}.zip" /tmp/kirocli.zip
cd /opt/bench && quiet npm install --silent extract-zip @aws-sdk/client-secrets-manager && cd /
mkdir -p /opt/bench-kiro
node -e 'require("/opt/bench/node_modules/extract-zip")("/tmp/kirocli.zip", {dir: "/opt/bench-kiro"}).catch(e => { console.error(e); process.exit(1); })'
mkdir -p /opt/bench-kiro/bin && cp /opt/bench-kiro/kirocli/bin/* /opt/bench-kiro/bin/ && chmod +x /opt/bench-kiro/bin/*
rm -f /tmp/kirocli.zip
mkdir -p /root/.kiro/agents
printf '%s\n' '{"name":"benchmark","description":"Benchmark agent with all tools allowed","tools":["*"],"allowedTools":["*"]}' > /root/.kiro/agents/benchmark.json
echo "kiro=$(/opt/bench-kiro/bin/kiro-cli --version 2>/dev/null | head -1) build=${ARCH}${SUFFIX}"
