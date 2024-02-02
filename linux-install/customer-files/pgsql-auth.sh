#!/bin/bash

set -euo pipefail
IFS=$'\n\t '

readonly FILE_MARKER_BEGIN="#### Tableau Server on Kubernetes Configuration ####"
readonly FILE_MARKER_END="#### ####### ###### ## ########## ############# ####"
readonly CIDR_VARIABLE="__CIDR__"
readonly CONFIGURATION_CONTENT_STRICT="
host    all         datacatdbowner         __CIDR__          md5
host    all         tbladminviews          __CIDR__          md5
host    all         tblserveradminviews    __CIDR__          md5
host    all         datafetcheruser1       __CIDR__          md5
host    all         analyseruser1          __CIDR__          md5
host    all         nopiireaderuser1       __CIDR__          md5
host    all         insightsuser1          __CIDR__          md5
host    all         rails                  __CIDR__          md5
host    all         tblwgadmin             __CIDR__          md5
host    all         datacatdbowner         __CIDR__          md5
host    all         tbladminviews          __CIDR__          md5
host    all         tblserveradminviews    __CIDR__          md5
host    all         datafetcheruser1       __CIDR__          md5
host    all         analyseruser1          __CIDR__          md5
host    all         nopiireaderuser1       __CIDR__          md5
host    all         insightsuser1          __CIDR__          md5
host    all         rails                  __CIDR__          md5
host    all         tblwgadmin             __CIDR__          md5
host    all         datacatdbowner         __CIDR__          md5
host    all         tbladminviews          __CIDR__          md5
host    all         tblserveradminviews    __CIDR__          md5
host    all         datafetcheruser1       __CIDR__          md5
host    all         analyseruser1          __CIDR__          md5
host    all         nopiireaderuser1       __CIDR__          md5
host    all         insightsuser1          __CIDR__          md5
host    all         rails                  __CIDR__          md5
host    all         tblwgadmin             __CIDR__          md5
host    replication tblwgadmin             __CIDR__          md5
"

readonly CONFIGURATION_CONTENT_LENIENT="
host    all         all         0.0.0.0/0          md5
host    replication all         0.0.0.0/0          md5
"

say() {
  echo
  echo "==> $( date ) :: ${1:-}"
  echo
}

error() {
  echo
  echo "##> $( date ) :: ${1:-}"
  echo
}

apply-cidr-to-template() {
  local cidr="${1:-}"
  local template="${2:-}"

  [[ -z "${cidr}" ]] && (error "Need a CIDR to replace on the template."; exit 1)
  [[ -z "${template}" ]] && (error "Need a template to instantiate with CIDR."; exit 1)

  sed -E -e "s|${CIDR_VARIABLE}|${cidr}|g" <<<"${template}"
}

configuration-content() {
  local cidrs="${1:-}"

  echo "## ==> CIDRS: ${cidrs}"

  if [[ -z "${cidrs}" ]]; then
    echo "${CONFIGURATION_CONTENT_LENIENT}"
  else
    local cidr
    for cidr in ${cidrs}; do
      echo
      echo "## CIDR start: ${cidr}"
      apply-cidr-to-template "${cidr}" "${CONFIGURATION_CONTENT_STRICT}"
      echo "## CIDR end: ${cidr}"
      echo
    done
  fi
}

find-marker() {
  local file="${1:-}"
  local marker="${2:-}"
  local not_found_line="-1"

  [[ -z "${file}" ]] && (error "Need a file where to search for the marker."; exit 1)
  [[ -z "${marker}" ]] && (error "Need a marker to search for."; exit 1)

  local marker_line
  marker_line="$( grep -n "${marker}" "${file}" | sed -E -e "s/^([0-9]+):.*/\1/" )"

  local marker_line_count
  if [[ -z "${marker_line}" ]]; then
    marker_line_count="0"
  else
    marker_line_count="$( wc -l <<<"${marker_line}" )"
  fi

  if (( marker_line_count > 1 )); then
    (error "Found marker '${marker}' at multiple lines '$( xargs <<<"${marker_line}")' in file '${file}'"; exit 2)
  elif (( marker_line_count == 0 )); then
    echo "${not_found_line}"
  else
    echo "${marker_line}"
  fi
}

content-on-file-is-same() {
  local file="${1:-}"
  local begin_maker_line="${2:-}"
  local end_marker_line="${3:-}"
  local content="${4:-}"

  [[ -z "${file}" ]] && (error "Need a file where to search for the marker."; exit 1)
  [[ -z "${begin_maker_line}" ]] && (error "Need a beginning marker line number."; exit 1)
  [[ -z "${end_marker_line}" ]] && (error "Need a ending marker line number."; exit 1)
  [[ -z "${content}" ]] && (error "Need content to compare to."; exit 1)

  local line_after_end_marker="$(( end_marker_line + 1 ))"
  local content_on_file
  content_on_file="$( sed -n "${begin_maker_line},${end_marker_line}p;${line_after_end_marker}q" "${file}")"

  [[ "${content_on_file}" = "${content}" ]]
}

remove-config-from-file() {
  local file="${1:-}"
  local begin_maker_line="${2:-}"
  local end_marker_line="${3:-}"

  [[ -z "${file}" ]] && (error "Need a file where to search for the marker."; exit 1)
  [[ -z "${begin_maker_line}" ]] && (error "Need a beginning marker line number."; exit 1)
  [[ -z "${end_marker_line}" ]] && (error "Need a ending marker line number."; exit 1)

  sed -i.bak -e "${begin_maker_line},${end_marker_line}d" "${file}"
}

full-file-content() {
  local cidrs="${1:-}"

  echo "${FILE_MARKER_BEGIN}"
  echo;
  configuration-content "${cidrs}"
  echo;
  echo "${FILE_MARKER_END}"
}

write-config-to-file() {
  local file="${1:-}"
  local content="${2:-}"

  [[ -z "${file}" ]] && (error "Need a file to write the content to."; exit 1)
  [[ -z "${content}" ]] && (error "Need content to write to the file."; exit 1)

  echo "${content}" >> "${file}"
}

main() {
  local cidrs=${1:-}
  local file=${2:-}

  [[ -z "${file}" ]] && (error "Need a file to process."; exit 1)

  local begin_maker_line
  begin_maker_line="$( find-marker "${file}" "${FILE_MARKER_BEGIN}" )"
  [[ "${?}" -gt 0 ]] && (error "Error searching for begin marker '${FILE_MARKER_BEGIN}' in file '${file}'"; exit 1)

  local end_marker_line
  end_marker_line="$( find-marker "${file}" "${FILE_MARKER_END}" )"
  [[ "${?}" -gt 0 ]] && (error "Error searching for end marker '${FILE_MARKER_END}' in file '${file}'"; exit 1)

  local required_config_content
  required_config_content="$( full-file-content "${cidrs}" )"

  if [[ "${begin_maker_line}" = "-1" && "${end_marker_line}" = "-1" ]]; then
    # No markers found, process the file like it's new and add the content
    say "Writing initial config to file ${file}"
    write-config-to-file "${file}" "${required_config_content}"
  elif [[ "${begin_maker_line}" != "-1" && "${end_marker_line}" != "-1" ]]; then
    # Found both markers, process the file like it's known, check the content and re-add it if needed
    if ! content-on-file-is-same "${file}" "${begin_maker_line}" "${end_marker_line}" "${required_config_content}"; then
      say "Found config mismatch on file ${file}, writing correct configuration"
      remove-config-from-file "${file}" "${begin_maker_line}" "${end_marker_line}"
      write-config-to-file "${file}" "${required_config_content}"
    else
      say "Config on file ${file} is correct"
    fi
  else
    error "Only found one of the two markers (begin or end): begin at line ${begin_maker_line}; end at line ${end_marker_line}"
    exit 1
  fi
}

CIDRS=${1:-}
FILE=${2:-}

[[ -z "${CIDRS}" ]] && (say "No CIDRs provided, will run in non-strict mode (will open up permissions).";)
[[ -z "${FILE}" ]] && (error "Need a pg_hba.conf file to work on."; exit 1)

main "${CIDRS}" "${FILE}"
