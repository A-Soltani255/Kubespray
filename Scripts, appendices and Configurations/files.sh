#!/bin/bash

CURRENT_DIR=$( dirname "$(readlink -f "$0")" )
OFFLINE_FILES_DIR_NAME="offline-files"
OFFLINE_FILES_DIR="${CURRENT_DIR}/${OFFLINE_FILES_DIR_NAME}"
OFFLINE_FILES_ARCHIVE="${CURRENT_DIR}/offline-files.tar.gz"
FILES_LIST=${FILES_LIST:-"${CURRENT_DIR}/kubespray/contrib/offline/tmp/files.list"}

# Ensure the files list exists
if [ ! -f "${FILES_LIST}" ]; then
    echo "${FILES_LIST} should exist, run ./generate_list.sh first."
    exit 1
fi

# Clean up previous files and directories
rm -rf "${OFFLINE_FILES_DIR}"
rm     "${OFFLINE_FILES_ARCHIVE}"
mkdir  "${OFFLINE_FILES_DIR}"

# Download each file from the list
while read -r url; do
  if ! wget -x -P "${OFFLINE_FILES_DIR}" "${url}"; then
    exit 1
  fi
done < "${FILES_LIST}"

# Archive the downloaded files
tar -czvf "${OFFLINE_FILES_ARCHIVE}" "${OFFLINE_FILES_DIR_NAME}"
