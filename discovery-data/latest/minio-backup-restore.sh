#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

source "${SCRIPT_DIR}/lib/restore-updates.bash"
source "${SCRIPT_DIR}/lib/function.bash"

# Setup the minio directories needed to create the backup file
OC_ARGS="${OC_ARGS:-}" 
MINIO_BACKUP="minio_backup.tar.gz"
MINIO_BACKUP_DIR="${MINIO_BACKUP_DIR:-minio_backup}"
TMP_WORK_DIR="tmp/minio_workspace"
BACKUP_RESTORE_IN_POD=${BACKUP_RESTORE_IN_POD-false}
CURRENT_COMPONENT="minio"
MINIO_ELASTIC_BACKUP=${MINIO_ELASTIC_BACKUP:-false}
DISABLE_MC_MULTIPART=${DISABLE_MC_MULTIPART:-true}
ELASTIC_BACKUP_BUCKET="elastic-backup"
SED_REG_OPT="$(get_sed_reg_opt)"
SCRIPT_DIR=${SCRIPT_DIR}

printUsage() {
  echo "Usage: $(basename ${0}) [command] [releaseName] [-f backupFile]"
  exit 1
}

if [ $# -lt 2 ] ; then
  printUsage
fi

COMMAND=$1
shift
TENANT_NAME=$1
shift
while getopts f:n: OPT
do
  case $OPT in
    "f" ) BACKUP_FILE="$OPTARG" ;;
    "n" ) OC_ARGS="${OC_ARGS} --namespace=$OPTARG" ;;
  esac
done

brlog "INFO" "MinIO:"
brlog "INFO" "Tenant name: $TENANT_NAME"

WD_VERSION="$(get_version)"
BACKUP_FILE=${BACKUP_FILE:-"minio_$(date "+%Y%m%d_%H%M%S").tar.gz"}
brlog "DEBUG" "WD_VERSION: $WD_VERSION"
brlog "DEBUG" "BACKUP_FILE: $BACKUP_FILE"

MINIO_ARCHIVE_OPTION="${MINIO_ARCHIVE_OPTION-$DATASTORE_ARCHIVE_OPTION}"
if [ -n "${MINIO_ARCHIVE_OPTION}" ] ; then
  read -a MINIO_TAR_OPTIONS <<< ${MINIO_ARCHIVE_OPTION}
else
  MINIO_TAR_OPTIONS=("")
fi
brlog "DEBUG" "MINIO_TAR_OPTIONS: ${MINIO_TAR_OPTIONS[@]}"
VERIFY_ARCHIVE=${VERIFY_ARCHIVE:-true}
VERIFY_DATASTORE_ARCHIVE=${VERIFY_DATASTORE_ARCHIVE:-$VERIFY_ARCHIVE}

setup_s3_env

rm -rf ${TMP_WORK_DIR}

mkdir -p "${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}"
mkdir -p "${BACKUP_RESTORE_LOG_DIR}"

if [ $(compare_version "${WD_VERSION}" "5.2.1") -ge 0 ] ; then
  brlog "DEBUG" "Using aws s3 cli for WD ${WD_VERSION}"

  # Prepare s3 pod.
  launch_s3_pod
  brlog "DEBUG" "S3 pod: ${POD}"
  BACKUP_RESTORE_DIR_IN_POD="/tmp/backup-restore-workspace"
  S3_BACKUP_DIR="s3_backup"
  S3_BACKUP="${MINIO_BACKUP}" # For backword compatibility.
  _oc_cp "${SCRIPT_DIR}/src" ${POD}:${BACKUP_RESTORE_DIR_IN_POD}/ ${OC_ARGS}
  _oc_cp "${SCRIPT_DIR}/lib" ${POD}:${BACKUP_RESTORE_DIR_IN_POD}/ ${OC_ARGS}
  _oc_cp "${SCRIPT_DIR}/src/s3-backup-restore-in-pod.sh" "${POD}:${BACKUP_RESTORE_DIR_IN_POD}/s3-backup-restore-in-pod.sh" ${OC_ARGS}
  
  if [ "${COMMAND}" = "restore" ] ; then
    brlog "INFO" "Transferring backup data ${BACKUP_FILE} into ${POD} ..."
    kube_cp_from_local ${POD} "${BACKUP_FILE}" "${BACKUP_RESTORE_DIR_IN_POD}/${S3_BACKUP_DIR}/${S3_BACKUP}" ${OC_ARGS}
  fi

  # Run the backup/restore script.
  brlog "INFO" "Running backup restore script in s3 pod ..."
  # TODO this takes a while without logging any message at stdout.
  run_cmd_in_pod ${POD} \
    "${BACKUP_RESTORE_DIR_IN_POD}/s3-backup-restore-in-pod.sh ${COMMAND} --log-level ${BACKUP_RESTORE_LOG_LEVEL} --backup-dir ${BACKUP_RESTORE_DIR_IN_POD}/${S3_BACKUP_DIR} --file ${S3_BACKUP}" \
    ${OC_ARGS}
  result=$(get_last_cmd_result_in_pod)
  brlog "DEBUG" "s3 br script result: ${result}"
  
  if [ "${COMMAND}" = "backup" ] ; then
    brlog "INFO" "Transferring backup data"
    kube_cp_to_local ${POD} "${BACKUP_FILE}" "${BACKUP_RESTORE_DIR_IN_POD}/${S3_BACKUP_DIR}/${S3_BACKUP}" ${OC_ARGS}
    if "${VERIFY_DATASTORE_ARCHIVE}" && brlog "INFO" "Verifying backup archive" && ! tar "${MINIO_TAR_OPTIONS[@]}" -tf ${BACKUP_FILE} &> /dev/null ; then
      brlog "ERROR" "Backup file is broken, or does not exist."
      exit 1
    fi
  fi

  # Cleanup.
  oc ${OC_ARGS} exec ${POD} -- bash -c "cd ${BACKUP_RESTORE_DIR_IN_POD}; ls | xargs rm -rf"
  oc ${OC_ARGS} delete -f "${S3_JOB_FILE}"
  rm -rf ${TMP_WORK_DIR}
  if [ -z "$(ls tmp)" ] ; then
    rm -rf tmp
  fi
  brlog "INFO" "Done"
  exit 0
fi 

if "${BACKUP_RESTORE_IN_POD}" ; then
  BACKUP_RESTORE_DIR_IN_POD="/tmp/backup-restore-workspace"
  launch_s3_pod
  _oc_cp "${SCRIPT_DIR}/src" ${POD}:${BACKUP_RESTORE_DIR_IN_POD}/ ${OC_ARGS}
  _oc_cp "${SCRIPT_DIR}/lib" ${POD}:${BACKUP_RESTORE_DIR_IN_POD}/ ${OC_ARGS}
  _oc_cp "${SCRIPT_DIR}/src/minio-backup-restore-in-pod.sh" "${POD}:${BACKUP_RESTORE_DIR_IN_POD}/run.sh" ${OC_ARGS}

  if [ ${COMMAND} == "restore" ] ; then
    brlog "INFO" "Transferring backup data"
    kube_cp_from_local ${POD} "${BACKUP_FILE}" "${BACKUP_RESTORE_DIR_IN_POD}/${MINIO_BACKUP}" ${OC_ARGS}
  fi
  oc ${OC_ARGS} exec ${POD} -- touch /tmp/wexdata_copied
  brlog "INFO" "Waiting for ${COMMAND} job to be completed..."
  while :
  do
    ls_tmp="$(fetch_cmd_result ${POD} 'ls /tmp')"
    if echo "${ls_tmp}" | grep "backup-restore-complete" > /dev/null ; then
      brlog "INFO" "Completed ${COMMAND} job"
      break;
    else
      sleep 10
      oc ${OC_ARGS} logs ${POD} --since=12s 2>&1 | tee -a "${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log" | grep -v "^error: unexpected EOF$" | grep "^[0-9]\{4\}/[0-9]\{2\}/[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}" || true
    fi
  done
  if [ "${COMMAND}" = "backup" ] ; then
    brlog "INFO" "Transferring backup data"
    kube_cp_to_local ${POD} "${BACKUP_FILE}" "${BACKUP_RESTORE_DIR_IN_POD}/${MINIO_BACKUP}" ${OC_ARGS}
    if "${VERIFY_DATASTORE_ARCHIVE}" && brlog "INFO" "Verifying backup archive" && ! tar "${MINIO_TAR_OPTIONS[@]}" -tf ${BACKUP_FILE} &> /dev/null ; then
      brlog "ERROR" "Backup file is broken, or does not exist."
      oc ${OC_ARGS} exec ${POD} -- bash -c "cd ${BACKUP_RESTORE_DIR_IN_POD}; ls | xargs rm -rf"
      exit 1
    fi
  fi
  oc ${OC_ARGS} exec ${POD} -- bash -c "cd ${BACKUP_RESTORE_DIR_IN_POD}; ls | xargs rm -rf"
  oc ${OC_ARGS} delete -f "${S3_JOB_FILE}"
  rm -rf ${TMP_WORK_DIR}
  if [ -z "$(ls tmp)" ] ; then
    rm -rf tmp
  fi
  exit 0
fi

mkdir -p ${TMP_WORK_DIR}/.mc
if [ -n "${MC_COMMAND+UNDEF}" ] ; then
  MC=${MC_COMMAND}
else
  get_mc ${TMP_WORK_DIR}
  MC=${PWD}/${TMP_WORK_DIR}/mc
fi
export MINIO_CONFIG_DIR="${PWD}/${TMP_WORK_DIR}/.mc"
MC_OPTS=(--config-dir ${MINIO_CONFIG_DIR} --insecure)

# mc mirror command options.
MIRROR_OPTS=(--quiet)
# NOTE: --retry flag is currently a boolean flag and cannot specify the how many times to retry.
if [ "$(has_mc_mirror_retry)" -eq 1 ]; then
  MIRROR_OPTS+=("--retry")
fi
if [[ -z "${LOG_LEVEL_NUM:+UNDEF}" ]] || [ "$LOG_LEVEL_NUM" -ge 3 ]; then
  MIRROR_OPTS+=("--debug")
fi

# backup
if [ "${COMMAND}" = "backup" ] ; then
  brlog "INFO" "Start backup minio"
  brlog "INFO" "Backup data..."
  start_minio_port_forward
  mc_set_alias
  EXCLUDE_OBJECTS=$(cat "${SCRIPT_DIR}/src/minio_exclude_paths")
  if [ $(compare_version "${WD_VERSION}" "4.7.0") -ge 0 ] ; then
    EXCLUDE_OBJECTS+=$'\n'
    EXCLUDE_OBJECTS+="$(cat "${SCRIPT_DIR}/src/mcg_exclude_paths")"
  fi
  for bucket in ${S3_BUCKETS//,/ }
  do
    if [ "${bucket}" == "${ELASTIC_BACKUP_BUCKET}" ] ; then
      continue
    fi
    EXTRA_MC_MIRROR_COMMAND=()
    ORG_IFS=${IFS}
    IFS=$'\n'
    for line in ${EXCLUDE_OBJECTS}
    do
      base_bucket_name=${bucket%"${BUCKET_SUFFIX}"}
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
    "${MC}" "${MC_OPTS[@]}" mirror "${MIRROR_OPTS[@]}" "${EXTRA_MC_MIRROR_COMMAND[@]}" wdminio/${bucket} ${MINIO_BACKUP_DIR}/${bucket} &>> "${SCRIPT_DIR}/${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log"
    RC=$?
    echo "RC=${RC}" >> "${SCRIPT_DIR}/${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log"
    if [ $RC -ne 0 ] ; then
      brlog "ERROR" "Some file could not be transfered. Consider to use '--use-job' and '--pvc' option. Please see help (--help) for details."
      exit 1
    fi
    set -e
    cd - > /dev/null
  done
  stop_minio_port_forward
  brlog "INFO" "Archiving data..."
  tar "${MINIO_TAR_OPTIONS[@]}" -cf ${BACKUP_FILE} -C ${TMP_WORK_DIR}/${MINIO_BACKUP_DIR} .
  if "${VERIFY_DATASTORE_ARCHIVE}" && brlog "INFO" "Verifying backup archive" && ! tar "${MINIO_TAR_OPTIONS[@]}" -tf ${BACKUP_FILE} &> /dev/null ; then
    brlog "ERROR" "Backup file is broken, or does not exist."
    exit 1
  fi
  brlog "INFO" "Done"
fi

# restore
if [ "${COMMAND}" = "restore" ] ; then
  if [ -z ${BACKUP_FILE} ] ; then
    printUsage
  fi
  if [ ! -e "${BACKUP_FILE}" ] ; then
    brlog "WARN" "no such file: ${BACKUP_FILE}"
    brlog "WARN" "Nothing to Restore"
    echo
    exit 1
  fi
  brlog "INFO" "Start restore minio: ${BACKUP_FILE}"
  brlog "INFO" "Extracting archive..."
  tar "${MINIO_TAR_OPTIONS[@]}" -xf ${BACKUP_FILE} -C ${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}
  brlog "INFO" "Restoring data..."
  start_minio_port_forward
  mc_set_alias
  for bucket_path in "${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}"/*
  do
    bucket="$(basename "${bucket_path}")"
    brlog "DEBUG" "Restoring bucket '$bucket' ..."
    if [ -n "${BUCKET_SUFFIX}" ] && [[ "${bucket}" != *"${BUCKET_SUFFIX}"  ]] ; then
      mv "${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}/${bucket}" "${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}/${bucket}${BUCKET_SUFFIX}"
      bucket="${bucket}${BUCKET_SUFFIX}"
    fi
    if "${MC}" "${MC_OPTS[@]}" ls wdminio | grep ${bucket} > /dev/null ; then
      if [ -n "$("${MC}" "${MC_OPTS[@]}" ls wdminio/${bucket}/)" ] ; then
        "${MC}" "${MC_OPTS[@]}" --quiet rm --recursive --force --dangerous "wdminio/${bucket}/" > /dev/null
      fi
      if [ "${bucket}" = "discovery-dfs" ] ; then
        continue
      fi
      set +e
      "${MC}" "${MC_OPTS[@]}" mirror "${MIRROR_OPTS[@]}" ${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}/${bucket} wdminio/${bucket} &>> "${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log"
      RC=$?
      echo "RC=${RC}" >> "${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log"
      if [ $RC -ne 0 ] ; then
        brlog "ERROR" "Some files could not be transferred. Please consider to use '--use-job' and '--pvc' option. See help (--help) for details."
        exit 1
      fi
      set -e
    fi
  done
  stop_minio_port_forward
  brlog "INFO" "Done"
  brlog "INFO" "Restart setup jobs"
  brlog "INFO" "Applying updates"
  . ./lib/restore-updates.bash
  minio_updates
  brlog "INFO" "Completed Updates"
  echo
fi

rm -rf ${TMP_WORK_DIR}
if [ -z "$(ls tmp)" ] ; then
  rm -rf tmp
fi