#!/bin/bash

say() {
  echo
  echo "==> ${1}"
  echo
}

set -euo pipefail
IFS=$'\n\t'

target_dir="${1:-}"

if [[ -z "${target_dir}" ]]; then
  target_dir="/tmp/backup"
  say "No backup target directory provided, defaulting to ${target_dir}"
fi

backup_dir="${target_dir}/$(date +%Y%m%d_%H%M%S)"
say "Creating backup dir at ${backup_dir}"
mkdir -p "${backup_dir}"

settings_backup="${backup_dir}/settings.json"
say "Exporting settings to ${settings_backup}"
tsm settings export -f "${settings_backup}"

content_backup_target_dir="/var/opt/tableau/tableau_server/data/tabsvc/files/backups"
content_backup_file="backup.tsbak"
rm -f "${content_backup_target_dir}/${content_backup_file}"
say "Exporting content to ${content_backup_file}"
tsm maintenance backup -f "${content_backup_file}" --multithreaded
mv "${content_backup_target_dir}/${content_backup_file}" "${backup_dir}"

say "Backup complete and available at ${backup_dir}"
ls -al "${backup_dir}"
