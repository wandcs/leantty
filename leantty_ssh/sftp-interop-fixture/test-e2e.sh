#!/usr/bin/env bash
set -euo pipefail

fixture_dir=$(mktemp -d)
server_pid=''
cleanup() {
  if [[ -n "$server_pid" ]]; then
    sudo -n kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$fixture_dir"
}
trap cleanup EXIT

fixture_user=$(id -un)
fixture_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
host_key="$fixture_dir/host_ed25519"
client_key="$fixture_dir/client_ed25519"
authorized_keys="$fixture_dir/authorized_keys"
remote_dir="$fixture_dir/remote"
sshd_config="$fixture_dir/sshd_config"
sshd_log="$fixture_dir/sshd.log"

ssh-keygen -q -t ed25519 -N '' -f "$host_key"
ssh-keygen -q -t ed25519 -N '' -f "$client_key"
cp "$client_key.pub" "$authorized_keys"
chmod 600 "$authorized_keys"
mkdir -m 700 "$remote_dir"

cat >"$sshd_config" <<EOF
Port $fixture_port
ListenAddress 127.0.0.1
AddressFamily inet
HostKey $host_key
PidFile $fixture_dir/sshd.pid
AuthorizedKeysFile $authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PermitRootLogin no
AllowUsers $fixture_user
Subsystem sftp internal-sftp
LogLevel VERBOSE
EOF

sudo -n /usr/sbin/sshd -D -e -f "$sshd_config" >"$sshd_log" 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do
  if bash -c "</dev/tcp/127.0.0.1/$fixture_port" >/dev/null 2>&1; then
    break
  fi
  if ! sudo -n kill -0 "$server_pid" >/dev/null 2>&1; then
    cat "$sshd_log" >&2
    exit 1
  fi
  sleep 0.1
done

cargo run --quiet --locked --manifest-path "$(dirname "$0")/Cargo.toml" -- \
  127.0.0.1 "$fixture_port" "$fixture_user" "$client_key" "$remote_dir"

if find "$remote_dir" -mindepth 1 -print -quit | grep -q .; then
  echo 'SFTP fixture left remote files behind' >&2
  exit 1
fi

echo "SFTP E2E SUCCESS: OpenSSH $(ssh -V 2>&1 | awk '{print $1}')"
