#!/usr/bin/env bash
# The NEXUS_REPO value on this script should be exactly like the images.sh script
NEXUS_REPO="192.168.10.1:4000/kubespray"
IMAGES_LIST="/opt/kubespray/images.list"
OUT="/opt/missing_images.txt"

mapfile -t missing < <(
  sed -e 's/\r$//' -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$IMAGES_LIST" \
  | awk 'NF' \
  | while read -r img; do
      docker image inspect "$img" >/dev/null 2>&1 \
      || docker image inspect "${NEXUS_REPO}/${img}" >/dev/null 2>&1 \
      || echo "$img"
    done
)

printf '%s\n' "${missing[@]}" | tee "$OUT"
echo "Missing: ${#missing[@]}   (saved to $OUT)"

# This script is designed to verify the local availability of required Docker images by checking an images.list file.
# It iterates through the list, first looking for each image under its base name, and if that fails, checking a secondary location prefixed with the configured NEXUS_REPO address.
# Any images that are not found in either location are compiled into a Bash array called missing.
# Finally, the script prints this list of missing images to the console and saves it to the /opt/missing_images.txt file, concluding with a count of the total missing images.
