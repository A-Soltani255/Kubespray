#!/usr/bin/env bash
set -euo pipefail

# ---- config ----
IMAGES_DIR="${1:-/opt/container-images}"             # directory of *.tar or *.tar.gz
SRC_HUB="192.168.10.1:4000"                       # where they were originally tagged from
SRC_NS="kubespray"                                   # prefix after SRC_HUB (present in your names)
CLI="${CLI:-docker}"                                 # use 'docker' (default) or set CLI=nerdctl
PUSH="${PUSH:-0}"                                    # set PUSH=1 to push after retag

# upstream -> internal registry map
declare -A MAP=(
  ["docker.io"]="192.168.154.133:5000"
  ["registry.k8s.io"]="192.168.154.133:5001"
  ["quay.io"]="192.168.154.133:5002"
  ["ghcr.io"]="192.168.154.133:5003"
)

shopt -s nullglob

load_archive() {
  local f="$1"
  if [[ "$f" == *.tar.gz || "$f" == *.tgz ]]; then
    gunzip -c -- "$f" | $CLI load
  else
    $CLI load -i "$f"
  fi
}

echo "==> Scanning: $IMAGES_DIR"
for f in "$IMAGES_DIR"/*.tar "$IMAGES_DIR"/*.tar.gz "$IMAGES_DIR"/*.tgz; do
  [[ -e "$f" ]] || continue
  echo "--> Loading $f"
  # capture ALL image names printed by load
  mapfile -t LOADED < <(load_archive "$f" | awk -F': ' '/Loaded image/ {print $2}')

  for IMG in "${LOADED[@]}"; do
    # expected: 192.168.10.1:4000/kubespray/<upstream>/<path>:<tag>
    # strip hub and optional kubespray/ namespace
    STRIPPED="${IMG#${SRC_HUB}/}"
    STRIPPED="${STRIPPED#${SRC_NS}/}"

    UPSTREAM="${STRIPPED%%/*}"       # docker.io | registry.k8s.io | quay.io | ghcr.io
    REST="${STRIPPED#*/}"            # e.g. mirantis/k8s-netchecker-server:v1.2.2

    TARGET_BASE="${MAP[$UPSTREAM]:-}"
    if [[ -z "$TARGET_BASE" ]]; then
      echo "WARN: Unknown upstream '$UPSTREAM' in '$IMG' (skipping)"
      continue
    fi

    NEW="${TARGET_BASE}/${REST}"

    echo "Tagging: $IMG -> $NEW"
    $CLI tag "$IMG" "$NEW"

    if [[ "$PUSH" == "1" ]]; then
      echo "Pushing: $NEW"
      $CLI push "$NEW"
    fi
  done
done

echo "Done."




# This Bash script is designed to automate the process of loading, retagging, and optionally pushing Docker/container images that have been previously saved as archive files (.tar or .tar.gz).
# It first reads image archives from a specified directory (/opt/container-images by default) and loads them into the local container runtime (using docker or nerdctl).
# The script assumes the loaded images are currently tagged with a source hub and namespace (e.g., 192.168.154.133:4000/kubespray/).
# It then uses a hardcoded associative map to translate the original upstream registry (like docker.io or registry.k8s.io) found within the image name to a new internal registry address (e.g., 192.168.154.133:5000).
# Finally, the image is retagged with the new internal registry destination, and if the PUSH variable is set to 1, the newly tagged image is pushed to that internal repository.
