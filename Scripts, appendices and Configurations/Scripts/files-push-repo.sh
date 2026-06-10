#!/bin/bash
# Nexus Yum Repository Multi-Directory Uploader (RPMs + optional repodata) with Resume Support

## ========================
## CONFIGURATION
## ========================
NEXUS_URL="https://nexus.soltani.co/repository/Rocky-10.1"   # no trailing slash
NEXUS_USER="Rocky-10.1_repository_user"
NEXUS_PASS="Rocky-10.1_repository_password"

# Each entry: "local_path nexus_repo_name"
REPOS=(
  "/opt/mnt/appstream             AppStream"
  "/opt/mnt/baseos                BaseOS"
  "/opt/mnt/epel                  EPEL"
  "/opt/mnt/epel-cisco-openh264   Epel-Cisco-Openh264"
  "/opt/mnt/extras                Extras"
  "/opt/mnt/docker-ce-stable      Docker-Ce-Stable"
)

INCLUDE_REPODATA=true                 # set false to skip repodata
BATCH_SIZE=500
SLEEP_BETWEEN_BATCHES=10
LOG_FILE="uploaded_files.log"
## ========================

set -o pipefail
touch "$LOG_FILE"

upload_file() {
  local file="$1"
  local repo_name="$2"
  local base_dir="$3"

  # relative path (preserve Packages/… and repodata/…)
  local rel_path="${file#$base_dir/}"

  # already uploaded?
  if grep -Fxq "$repo_name/$rel_path" "$LOG_FILE"; then
    echo "✅ Skipping (already uploaded): $repo_name/$rel_path"
    return 0
  fi

  local target_url="$NEXUS_URL/$repo_name/$rel_path"

  echo "⬆️  Uploading to [$repo_name]: $rel_path"
  # retry a few times; treat non-2xx as failure
  http_code=$(
    curl -sS --fail --retry 5 --retry-delay 2 \
      -u "$NEXUS_USER:$NEXUS_PASS" \
      --upload-file "$file" \
      -o /dev/null -w "%{http_code}" \
      "$target_url" || echo "000"
  )

  if [[ "$http_code" =~ ^20[0-9]$ ]]; then
    echo "$repo_name/$rel_path" >> "$LOG_FILE"
    echo "✅ Uploaded: $repo_name/$rel_path"
    return 0
  else
    echo "❌ Failed ($http_code): $repo_name/$rel_path"
    return 1
  fi
}

for entry in "${REPOS[@]}"; do
  src_dir=$(echo "$entry" | awk '{print $1}')
  repo_name=$(echo "$entry" | awk '{print $2}')
  echo "📂 Processing local dir: $src_dir  →  Nexus repo: $repo_name"

  # queue RPMs
  mapfile -t files < <(find "$src_dir" -type f -name "*.rpm" | sort)

  # optionally queue repodata/* files
  if [[ "$INCLUDE_REPODATA" == true && -d "$src_dir/repodata" ]]; then
    while IFS= read -r f; do files+=("$f"); done < <(find "$src_dir/repodata" -type f | sort)
  fi

  count=0
  for f in "${files[@]}"; do
    upload_file "$f" "$repo_name" "$src_dir"
    ((count++))
    if (( count % BATCH_SIZE == 0 )); then
      echo "⏳ Batch complete, sleeping $SLEEP_BETWEEN_BATCHES seconds…"
      sleep "$SLEEP_BETWEEN_BATCHES"
    fi
  done
done

echo "🎉 Finished. Successful uploads recorded in: $LOG_FILE"




# This script is a robust multi-directory uploader designed to synchronize local RPM package files and their associated repository metadata to a remote Nexus Repository Manager instance.
# It iterates through a configured list of local source directories (like /opt/mnt/appstream and /opt/mnt/baseos) and uploads all .rpm files—and optionally any files within the repodata subdirectory—to their corresponding Nexus Yum repositories.
# Crucially, the script features resume support: it maintains an uploaded_files.log file to track successful transfers, allowing it to skip files that were previously uploaded, and it handles the workload by uploading files in batches of 500, pausing briefly after each batch to manage resource usage.
