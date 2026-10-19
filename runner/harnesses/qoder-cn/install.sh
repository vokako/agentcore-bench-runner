# Qoder CN CLI (qoderclicn) from a pinned offline bundle (npm install --os=linux --cpu=arm64
# --ignore-scripts of @qodercn-ai/qoderclicn@<version>, with its package-lock.json), stored at
# s3://$BENCH_BUCKET/$BENCH_ARTIFACTS/qoderclicn/<version>/ and vendor/harness/qoderclicn/<version>/.
# Runs after runner/install.sh, with /opt/bench-node on PATH.
QODER_VERSION=${BENCH_QODER_VERSION:-1.1.70}
ARCH=$(uname -m); case "$ARCH" in aarch64) ARCH=arm64;; x86_64) ARCH=x64;; esac
F=qoderclicn-$QODER_VERSION-linux-$ARCH.tgz
# Build and upload with scripts/build_harness_bundle.sh qoder-cn <version> <arm64|x64>.
node /opt/bench/aws.mjs get "$BENCH_ARTIFACTS/qoderclicn/$QODER_VERSION/SHA256SUMS" /tmp/qoder.sums
SHA=$(awk -v f="$F" '$2==f{print $1}' /tmp/qoder.sums)
[ -n "$SHA" ] || { echo "no $F in SHA256SUMS (run scripts/build_harness_bundle.sh qoder-cn $QODER_VERSION $ARCH)" >&2; exit 2; }
node /opt/bench/aws.mjs get "$BENCH_ARTIFACTS/qoderclicn/$QODER_VERSION/$F" /tmp/$F
GOT=$(node -e 'const c=require("crypto"),fs=require("fs");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' /tmp/$F)
[ "$GOT" = "$SHA" ] || { echo "qoderclicn bundle sha256 mismatch: $GOT" >&2; exit 2; }
mkdir -p /opt/bench-qoder && tar --no-same-owner -xzf /tmp/$F -C /opt/bench-qoder && rm -f /tmp/$F
# The token is read from Secrets Manager at run time (runner/aws.mjs secret).
cd /opt/bench && quiet npm install --silent @aws-sdk/client-secrets-manager && cd /
echo "qoder=$(node /opt/bench-qoder/qoderclicn/node_modules/@qodercn-ai/qoderclicn/bundle/qoderclicn.js --version 2>/dev/null | head -1)"
