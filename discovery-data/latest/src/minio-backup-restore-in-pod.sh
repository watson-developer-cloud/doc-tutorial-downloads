#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

source "${SCRIPT_DIR}/lib/restore-updates.bash"
source "${SCRIPT_DIR}/lib/function.bash"

# Setup the minio directories needed to create the backup file
OC_ARGS="${OC_ARGS:-}" 
MINIO_BACKUP="minio_backup.tar.gz"
MINIO_BACKUP_DIR="${MINIO_BACKUP_DIR:-minio_backup}"
TMP_WORK_DIR="/tmp/backup-restore-workspace"
CURRENT_COMPONENT="minio"
MINIO_ELASTIC_BACKUP=${MINIO_ELASTIC_BACKUP:-false}
ELASTIC_BACKUP_BUCKET="elastic-backup"
SED_REG_OPT="$(get_sed_reg_opt)"
SCRIPT_DIR=${SCRIPT_DIR}

printUsage() {
  echo "Usage: $(basename ${0}) [command] [releaseName] [-f backupFile]"
  exit 1
}

COMMAND=$1
shift

if [ -n "${MINIO_ARCHIVE_OPTION}" ] ; then
  read -a MINIO_TAR_OPTIONS <<< ${MINIO_ARCHIVE_OPTION}
else
  MINIO_TAR_OPTIONS=("")
fi
VERIFY_DATASTORE_ARCHIVE=${VERIFY_DATASTORE_ARCHIVE-true}

mkdir -p ${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}
mkdir -p ${TMP_WORK_DIR}/.mc
MC=mc
export MINIO_CONFIG_DIR="${TMP_WORK_DIR}/.mc"
MC_OPTS=(--config-dir "${MINIO_CONFIG_DIR}" --insecure)
MC_MIRROR_OPTS=()
if "${DISABLE_MC_MULTIPART:-true}" ; then
  MC_MIRROR_OPTS+=( "--disable-multipart" )
fi

BUCKET_SUFFIX="${BUCKET_SUFFIX:-}"

# backup
if [ "${COMMAND}" = "backup" ] ; then
  brlog "INFO" "Start backup minio"
  brlog "INFO" "Backup data..."
  ${MC} "${MC_OPTS[@]}" --quiet config host add wdminio ${S3_ENDPOINT_URL} ${S3_ACCESS_KEY} ${S3_SECRET_KEY} > /dev/null
  EXCLUDE_OBJECTS=$(cat "${SCRIPT_DIR}/src/minio_exclude_paths")
  if [ $(compare_version "$(get_version)" "4.7.0") -ge 0 ] ; then
    EXCLUDE_OBJECTS+=$'\n'
    EXCLUDE_OBJECTS+="$(cat "${SCRIPT_DIR}/src/mcg_exclude_paths")"
  fi
  for bucket in $(${MC} "${MC_OPTS[@]}" ls wdminio | sed ${SED_REG_OPT} "s|.*[0-9]+B\ (.*)/.*|\1|g" | grep -v ${ELASTIC_BACKUP_BUCKET})
  do
    EXTRA_MC_MIRROR_COMMAND=()
    ORG_IFS=${IFS}
    IFS=$'\n'
    base_bucket_name=${bucket%"${BUCKET_SUFFIX}"}
    for line in ${EXCLUDE_OBJECTS}
    do
      if [[ ${line} == ${base_bucket_name}* ]] ; then
        if [ "${line#"$base_bucket_name" }" = "*" ] ; then
          brlog "DEBUG" "SKIP ${bucket}"
          continue 2
        fi
        EXTRA_MC_MIRROR_COMMAND+=( "--exclude" "${line#"$base_bucket_name" }" )
      fi
    done
    IFS=${ORG_IFS}
    cd ${TMP_WORK_DIR}
    set +e
    while true;
    do
      ${MC} "${MC_OPTS[@]}" --quiet mirror "${MC_MIRROR_OPTS[@]}" "${EXTRA_MC_MIRROR_COMMAND[@]}" wdminio/${bucket} ${MINIO_BACKUP_DIR}/${bucket} 2>&1
      RC=$?
      echo "RC=${RC}"
      if [ $RC -eq 0 ] ; then
        break
      fi
      brlog "WARN" "Some file could not be transfered. Retrying..."
    done
    set -e
    cd - > /dev/null
  done
  brlog "INFO" "Archiving data..."
  tar "${MINIO_TAR_OPTIONS[@]}" -cf ${MINIO_BACKUP} -C "${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}" .
  rm -rf "${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}"
fi

# restore
if [ "${COMMAND}" = "restore" ] ; then
  if [ -z ${MINIO_BACKUP} ] ; then
    printUsage
  fi
  brlog "INFO" "Extracting archive..."
  tar "${MINIO_TAR_OPTIONS[@]}" -xf ${MINIO_BACKUP} -C ${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}
  rm -f ${MINIO_BACKUP}
  brlog "INFO" "Restoring data..."
  ${MC} "${MC_OPTS[@]}" --quiet config host add wdminio ${S3_ENDPOINT_URL} ${S3_ACCESS_KEY} ${S3_SECRET_KEY} > /dev/null
  for bucket_path in "${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}"/*
  do
    bucket="$(basename "${bucket_path}")"
    if [ -n "${BUCKET_SUFFIX}" ] && [[ "${bucket}" != *"${BUCKET_SUFFIX}"  ]] ; then
      mv "${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}/${bucket}" "${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}/${bucket}${BUCKET_SUFFIX}"
      bucket="${bucket}${BUCKET_SUFFIX}"
    fi
    if ${MC} "${MC_OPTS[@]}" ls wdminio | grep ${bucket} > /dev/null ; then
      if [ -n "$(${MC} "${MC_OPTS[@]}" ls wdminio/${bucket}/)" ] ; then
        ${MC} "${MC_OPTS[@]}" --quiet rm --recursive --force --dangerous "wdminio/${bucket}/" > /dev/null
      fi
      if [ "${bucket}" = "discovery-dfs" ] || [ "${bucket}" = "ranker-wire-all" ] ; then
        brlog "INFO" "    Skip ${bucket}"
        continue
      fi
      if [ -z "$(ls -A "${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}/${bucket}")" ] ; then
        brlog "INFO" "    No data in ${bucket}"
        continue
      fi
      brlog "INFO" "    Restore ${bucket}"
      set +e
      if [[ ${S3_ENDPOINT_URL} == *"minio"* ]] ; then
        MC_MIRROR_OPTS=( ${MC_MIRROR_OPTS[@]} "--recursive" )
        MC_MIRROR_COMMAND="cp"
      else
        MC_MIRROR_COMMAND="mirror"
      fi
      while true;
      do
        ${MC} "${MC_OPTS[@]}" ${MC_MIRROR_COMMAND} --quiet "${MC_MIRROR_OPTS[@]}" ${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}/${bucket}/ wdminio/${bucket}/ 2>&1
        RC=$?
        echo "RC=${RC}"
        if [ $RC -eq 0 ] ; then
          if [[ ${S3_ENDPOINT_URL} == *"minio"* ]] ; then
            MC_MIRROR_OPTS=( "${MC_MIRROR_OPTS[@]/--continue}" )
          fi
          break
        else
          if [[ ${S3_ENDPOINT_URL} == *"minio"* ]] ; then
            # Add --continue option to resume. This is available for only MinIO.
            if [[ ! " ${MC_MIRROR_OPTS[*]} " =~ " --continue " ]]; then
              MC_MIRROR_OPTS+=( "--continue" )
            fi
          fi
        fi
        brlog "WARN" "Some file could not be transfered. Retrying..."
      done
      set -e
    fi
  done
  brlog "INFO" "Done"
  echo
fi