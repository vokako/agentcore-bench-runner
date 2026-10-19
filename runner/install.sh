# Common install inside the task sandbox; the harness's own install.sh is appended.
# Only adds Node.js (under /opt/bench-node), the in-sandbox AWS helper and the harness; the task environment
# is otherwise untouched. No package manager is used: in Runtime Instances mode the
# container runs as root with no Linux capabilities, so apt cannot switch users.
set -e

if [ -d /etc/apt/apt.conf.d ]; then
  # apt normally downloads as the unprivileged _apt user into _apt-owned dirs.
  # Without CAP_SETUID / CAP_DAC_OVERRIDE neither works, so keep apt as root and
  # give it a root-owned download cache. Only apt's own config is touched.
  mkdir -p /var/cache/bench-apt/archives/partial
  cat > /etc/apt/apt.conf.d/99-bench-root <<'APTCONF'
APT::Sandbox::User "root";
Dir::Cache "/var/cache/bench-apt/";
APTCONF
fi

fetch() {  # fetch <url> <dest>, with whatever the image already has
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,urllib.request; urllib.request.urlretrieve(sys.argv[1], sys.argv[2])' "$1" "$2"
  elif [ -x /opt/bench/busybox ]; then /opt/bench/busybox wget -qO "$2" "$1"
  else echo "no downloader in image (curl/wget/python3)" >&2; return 1
  fi
}

# Always use our own Node under /opt/bench-node, even when the image has one: the task's
# node/npm (e.g. Debian's "nodejs" without npm, or an old version) is the task's business.
if [ ! -x /opt/bench-node/bin/node ]; then
  ARCH=$(uname -m); case "$ARCH" in x86_64) ARCH=x64;; aarch64) ARCH=arm64;; esac
  NODE_VERSION=v22.23.2
  # .tar.gz rather than .tar.xz: many task images ship without xz.
  fetch "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${ARCH}.tar.gz" /tmp/node.tar.gz
  # --no-same-owner: without CAP_CHOWN, tar as root cannot restore the archive's uid.
  mkdir -p /opt/bench-node && tar --no-same-owner -xzf /tmp/node.tar.gz -C /opt/bench-node --strip-components=1
  rm -f /tmp/node.tar.gz
fi
export PATH=/opt/bench-node/bin:$PATH

quiet() { "$@" > /tmp/.bench-npm.log 2>&1 || { tail -20 /tmp/.bench-npm.log; return 1; }; }
# AWS SDK for the in-sandbox helper (runner/aws.mjs): S3 upload/download, stop session.
mkdir -p /opt/bench && cd /opt/bench
[ -f package.json ] || quiet npm init -y
quiet npm install --silent @aws-sdk/client-s3 @aws-sdk/client-bedrock-agentcore
echo "node=$(node --version)"
cd /
# Harness-specific install is appended here by bench.py (runner/harnesses/<name>/install.sh).
