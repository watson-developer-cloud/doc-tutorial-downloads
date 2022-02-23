#!/usr/bin/env bash
set -euo pipefail

TMP_WORK_DIR="/tmp/backup-restore-workspace"


show_help(){
cat << EOS
Usage: $0 [options]

Options:
  -h, --help              Print help info
  -s, --source            Source name where create data
  -t, --target            Loop count to create data
EOS
}

while (( $# > 0 )); do
  case "$1" in
    -h | --help )
      show_help
      exit 0
      ;;
    -s | --source )
      shift
      source="$1"
      ;;
    -t | --target )
      shift
      target="$1"
      ;;
    * )
      if [[ -z "$action" ]]; then
        action="$1"
      else
        echo "Invalid argument."
        show_help
        exit 1
      fi
      ;;
  esac
  shift
done

if [ -z "${source+UNDEF}" ] ; then
  echo "Source tenant ID not defined"
  exit 1
fi

if [ -z "${target+UNDEF}" ] ; then
  echo "Target tenant ID not defined"
  exit 1
fi

mkdir -p ${TMP_WORK_DIR}/.mc
MC=mc
export MINIO_CONFIG_DIR="${TMP_WORK_DIR}/.mc"
MC_OPTS=(--config-dir ${MINIO_CONFIG_DIR} --insecure)

${MC} ${MC_OPTS[@]} --quiet config host add wdminio ${MINIO_ENDPOINT_URL} ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} > /dev/null

for LOCATION in "cnm/mt" "common/mt" "exported-documents"; do
  FOLDERS=$( (${MC} ${MC_OPTS[@]} --quiet --json ls "wdminio/${LOCATION}/${source}" || echo '{}') | jq -r '.key|values')
  for FOLDER in ${FOLDERS[@]}; do
    ${MC} ${MC_OPTS[@]} --quiet cp --recursive wdminio/${LOCATION}/${source}/${FOLDER} wdminio/${LOCATION}/${target}/${FOLDER}
    ${MC} ${MC_OPTS[@]} --quiet rm --recursive --force wdminio/${LOCATION}/${source}/${FOLDER}
  done
done
rm -rf ${TMP_WORK_DIR}/*