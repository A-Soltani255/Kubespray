#!/usr/bin/env bash
set -Eeuo pipefail

NEXUS_REPO="192.168.10.1:4000/kubespray"   # registry/repo prefix
# Please note that this registry (192.168.10.1:4000/kubespray) is just a sample. Depending on the registry this image belongs to, it must be changed in the offline environment and then pushed to its own specially created registry.
CURRENT_DIR="/opt"
IMAGES_LIST="${CURRENT_DIR}/kubespray/contrib/offline/tmp/images.list"
IMAGES_DIR="${CURRENT_DIR}/container-images"
IMAGES_ARCHIVE="${CURRENT_DIR}/container-images.tar.gz"

# Ensure the images list exists
if [[ ! -f "$IMAGES_LIST" ]]; then
  echo "Missing $IMAGES_LIST – run ./generate_list.sh first." >&2
  exit 1
fi

# Clean workspace
rm -rf "$IMAGES_DIR"
mkdir -p "$IMAGES_DIR"
rm -f "$IMAGES_ARCHIVE"

# Normalize list: strip CRLF, drop comments/blanks
normalize() {
  sed -e 's/\r$//' -e 's/#.*$//' -e '/^[[:space:]]*$/d'
}

# Pull, retag to your Nexus namespace, and save each as its own .tar.gz
normalize < "$IMAGES_LIST" | while IFS= read -r image; do
  echo "==> Pulling: $image"
  docker pull "$image"

  # Compute repo + tag safely (supports digest inputs too)
  new_ref=""
  if [[ "$image" == *@* ]]; then
    # e.g., registry.k8s.io/pause@sha256:deadbeef...
    base="${image%@*}"        # before @
    digest="${image##*@}"     # after @
    # turn digest into a tag-like suffix
    tag="sha256-${digest#*:}"
    new_ref="${NEXUS_REPO}/${base}:${tag}"
  else
    # e.g., registry.k8s.io/kube-apiserver:v1.29.0
    base="${image%:*}"        # before last :
    tag="${image##*:}"        # after last :
    new_ref="${NEXUS_REPO}/${base}:${tag}"
  fi

  echo "==> Retagging -> $new_ref"
  docker tag "$image" "$new_ref"  # ensure tag exists explicitly

  # Save to gz
  safe_name="$(printf '%s' "$new_ref" | sed 's#[/:@]#-#g')"
  echo "==> Saving: $new_ref -> $IMAGES_DIR/${safe_name}.tar.gz"
  docker save "$new_ref" | gzip > "$IMAGES_DIR/${safe_name}.tar.gz"

  # Optional: drop the original tag (keeps layers if still referenced)
  docker rmi "$image" || true
done

# Single archive (optional; else you can keep per-image tars)
tar -cvzf "$IMAGES_ARCHIVE" -C "$IMAGES_DIR" .

echo "Done. Per-image tars in $IMAGES_DIR, bundle at $IMAGES_ARCHIVE"
