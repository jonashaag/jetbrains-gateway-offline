#!/bin/bash

set -euo pipefail

jetbrains_cache_dir="$HOME/.cache/JetBrains"
remote_dev_cache_dir="$jetbrains_cache_dir"/RemoteDev-PY
remote_dev_cache_dir_exists=$(test -e "$remote_dev_cache_dir" && echo true || echo false)

cache_dir_is_on_compatible_filesystem() {
  mkdir -p "$remote_dev_cache_dir"/jb_gateway_probe
  cd "$remote_dev_cache_dir"
  python <<EOF
import shutil, socket
try:
    socket.socket(socket.AF_UNIX).bind("jb_gateway_probe/probe.sock")
finally:
    shutil.rmtree("jb_gateway_probe", ignore_errors=True)
EOF
}

if ! ( cache_dir_is_on_compatible_filesystem ) 2>/dev/null; then
  if $remote_dev_cache_dir_exists; then
    echo "Error: Your JetBrains Remote Dev cache directory is on an unsupported filesystem, likely a network filesystem."
    echo "This script can automatically fix this, but you'll need to remove that directory first:"
    echo "  rm -rf $remote_dev_cache_dir"
    exit 1
  else
    mkdir -p /tmp/jb_gateway/RemoteDev-PY
    rm -rf "$remote_dev_cache_dir"
    ln -s /tmp/jb_gateway/RemoteDev-PY "$jetbrains_cache_dir"
  fi
fi

get_pycharm_path() {
    files=($pycharm_path_pattern)
    pycharm_path=${files[0]}
}

project_dir="${1:-}"
if [ -z "${project_dir}" ]; then
    project_dir="${JETBRAINS_GATEWAY_DEFAULT_PROJECT:-}"
fi
while [ -z "${project_dir}" ] || ! [ -d "${project_dir}" ]; do
    if ! [ -z "${project_dir}" ]; then
        echo "${project_dir} does not exist"
    fi
    echo "Please input the path to the directory containing the PyCharm project."
    read -r project_dir
    echo "To avoid this prompt in the future, add the following to your ~/.bashrc:"
    echo "export JETBRAINS_GATEWAY_DEFAULT_PROJECT=\"${project_dir}\""
done

pycharm_path_pattern="/opt/pycharm-*"
get_pycharm_path

running_processes="$(pgrep -f "$pycharm_path" || true)"
if [ -n "$running_processes" ]; then
    echo -e "Found running PyCharm instances, PIDs:\n$running_processes"
    echo "Press any key to kill those processes and continue, or Ctrl+C to abort."
    read
    kill $running_processes
    for pid in $running_processes; do
        echo -n "Waiting for process $pid to exit... "
        while [ -e /proc/$pid ]; do sleep 0.1; done
        echo "done."
    done
fi

if [ "$pycharm_path" = "$pycharm_path_pattern" ]; then
    # when file globs don't get expanded, the pycharm folder doesn't exists
    latest_pycharm="$(ls -1 ~/pycharm*.tar.gz ~/pycharm*.tar.zst 2>/dev/null | head -n 1 || true)"
    if [ -n "$latest_pycharm" ]; then
      if which zstd >/dev/null 2>/dev/null || echo "$latest_pycharm" | grep -q "zst$"; then
        latest_pycharm_zst="$(echo "$latest_pycharm" | sed "s/gz$/zst/")"
        if ! [ -f "$latest_pycharm_zst" ]; then
          echo "Re-packing $latest_pycharm as .zst for faster decompression..."
          gunzip -ck "$latest_pycharm" | zstd -v9 > "$latest_pycharm_zst"
        fi
        echo "Extracting $latest_pycharm_zst..."
        zstd -vcd "$latest_pycharm_zst" | tar xf - -C /opt
      else
        echo "Extracting $latest_pycharm..."
        tar xzf "$latest_pycharm" -C /opt
      fi
    else
      echo "Cannot find \`~/pycharm-*.tar.gz\`."
      echo "1. Download the PyCharm Linux installation from \`https://www.jetbrains.com/pycharm/download/download-thanks.html?platform=linux\`."
      echo "3. Run \`scp pycharm-*.tar.gz myhostname:~/\` to upload it to this machine."
      echo "4. Restart this program."
      exit 1
    fi
    get_pycharm_path
fi

echo "Using ${pycharm_path} for the PyCharm installation..."

set -m  # Enable bash job control for "fg"

REMOTE_DEV_NON_INTERACTIVE=1 \
  nice -n -15 \
    "$pycharm_path"/bin/remote-dev-server.sh \
      run \
      "${project_dir}" \
      --ssh-link-port 2222 \
      --ssh-link-host localhost \
      --ssh-link-user root \
      -l 0.0.0.0 \
  >"$pycharm_path"/stdout.log 2>"$pycharm_path"/stderr.log \
  &
pid=$!

echo "Started PyCharm as PID $pid. stdout/stderr will be forwarded to $pycharm_path/stdout.log and $pycharm_path/stderr.log."
echo "Waiting for PyCharm to start..."
while true; do
    gateway_link="$(grep --text -Eo "https://code-with-me.jetbrains.+" "$pycharm_path/stdout.log" || true)"
    if [ -n "$gateway_link" ]; then
        break
    fi
    sleep 1
done
echo
echo "********************************************************************************"
echo
echo "Click this link to join the session:"
echo
echo "$gateway_link"
echo
echo "********************************************************************************"
echo

echo "Putting PyCharm into foreground..."
fg
