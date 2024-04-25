#!/bin/bash

set -e

BACKUP_DIR="tmp"
TMP_WORK_DIR="tmp/all_backup"
SPLIT_DIR=./tmp_split_backup
EXTRA_OC_ARGS="${EXTRA_OC_ARGS:-}"

SCRIPT_DIR=$(dirname $0)
KUBECONFIG_FILE="${SCRIPT_DIR}/.kubeconfig"

. ${SCRIPT_DIR}/lib/function.bash

set_scripts_version

###############
# Parse args
###############
printUsage() {
cat << EOF
Usage:
    $(basename ${0}) (backup|restore) [-f backupFile] [options]

Options:
    --help, -h                                 Show help
    --file, -f                                 Specify backup file
    --mapping, -m <mapping_file>               Specify mapping file for restore to multi tenant clusters
    --instance-name, -i <instance_name>        Instance name for a new Discovery instance. This name will be used if there is no Discovery instance when restore backup of Discovery 4.0.5 or older
    --cp4d-user-id <user_id>                   User ID to create Discovery instance. Default: admin user ID.
    --cp4d-user-name <user_name>               User name to create Discovery instance. Default: admin.
    --log-output-dir <directory_path>          Specify output directory of detailed component logs
    --continue-from <component_name>           Resume backup or restore from specified component. Values: wddata, etcd, postgresql, elastic, minio, archive, migration, post-restore
    --quiesce-on-error=[true|false]            If true, not unquiesce on error during backup or restore. Default false on backup, true on restore.
    --clean                                    Remove existing tmp directory before start backup or restore.

Options (Advanced):
Basically, you don't need these advanced options.

    --archive-on-local                         Archive the backup files of etcd and postgresql on local machine. Use this flag to reduce the disk usage on their pod or compress the files with specified option, but it might take much time.
    --backup-archive-option="<tar_option>"     Tar options for compression used on archiving the backup file. Default none.
    --datastore-archive-option="<tar_option>"  Tar options for compression used on archiving the backup files of ElasticSearch, MinIO and internal configuration. Default "-z".
    --postgresql-archive-option="<tar_option>" Tar options for compression used on archiving the backup files of postgres. Note that the backup files of postgresql are archived on its pod by default. Default "-z".
    --etcd-archive-option="<tar_option>"       Tar options used on archiving the backup files of etcd. Note that the backup files of etcd are archived on its pod by default. Default "-z".
    --skip-verify-archive                      Skip the all verifying process of the archive.
    --skip-verify-backup                       Skip verifying the backup file.
    --skip-verify-datastore-archive            Skip verifying the archive of datastores.
    --use-job                                  Use kubernetes job for backup/restore of ElasticSearch or MinIO. Use this flag if fail to transfer data to MinIO.
    --pvc <pvc_name>                           PVC name used as a temporary storage for backup/restore of ElasticSearch or MinIO. The size of PVC should be 2.5 ~ 3 times as large as a backup file of ElasticSearch or MinIO. If not defined, use emptyDir. It's size depends on ephemeral storage.
    --enable-multipart                         Enable multipart upload of MinIO client on kubernetes job.
    --file-storage-class <file_storage_class>  Name of file storage class used for PVC of ElasticSearch
    --elastic-shared-pvc <pvc_name>            Name of RWX PVC used for ElasticSearch
EOF
}

while [[ $# -gt 0 ]]
do
  OPT=$1
  case $OPT in
    -h | --help)
      printUsage
      exit 1
      ;;
    -t | --tenant)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      TENANT_NAME="$2"
      shift 1
      ;;
    -n | --namespace)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      EXTRA_OC_ARGS="${EXTRA_OC_ARGS} -n $2"
      shift 1
      ;;
    -f | --file)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      BACKUP_FILE="$2"
      shift 1
      ;;
    -m | --mapping)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      export MAPPING_FILE="$2"
      shift 1
      ;;
    -c | --continue-from)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      CONTINUE_FROM_COMPONENT="$2"
      shift 1
      ;;
    -i | --instance-name)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      INSTANCE_NAME="$2"
      shift 1
      ;;
    --log-output-dir)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      export BACKUP_RESTORE_LOG_DIR="$2"
      shift 1
      ;;
    --log-output-dir=*)
      export BACKUP_RESTORE_LOG_DIR="${1#--log-output-dir=}"
      ;;
    --cp4d-user-id)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      export ZEN_UID="$2"
      shift 1
      ;;
    --cp4d-user-id=*)
      export ZEN_UID="${1#--cp4d-user-id=}"
      ;;
    --cp4d-user-name)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      export ZEN_USER_NAME="$2"
      shift 1
      ;;
    --cp4d-user-name=*)
      export ZEN_USER_NAME="${1#--cp4d-user-name=}"
      ;;
    --archive-on-local)
      export ARCHIVE_ON_LOCAL=true
      ;;
    --backup-archive-option)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      export BACKUPFILE_ARCHIVE_OPTION="$2"
      shift 1
      ;;
    --backup-archive-option=*)
      BACKUPFILE_ARCHIVE_OPTION="${1#--backup-archive-option=}"
      ;;
    --datastore-archive-option)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      export DATASTORE_ARCHIVE_OPTION="$2"
      shift 1
      ;;
    --datastore-archive-option=*)
      export DATASTORE_ARCHIVE_OPTION="${1#--datastore-archive-option=}"
      ;;
    --postgresql-archive-option)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      export PG_ARCHIVE_OPTION="$2"
      shift 1
      ;;
    --postgresql-archive-option=*)
      export PG_ARCHIVE_OPTION="${1#--postgresql-archive-option=}"
      ;;
    --etcd-archive-option)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      export ETCD_ARCHIVE_OPTION="$2"
      shift 1
      ;;
    --etcd-archive-option=*)
      export ETCD_ARCHIVE_OPTION="${1#--etcd-archive-option=}"
      ;;
    --skip-verify-archive)
      export VERIFY_ARCHIVE=false
      ;;
    --skip-verify-backup)
      VERIFY_BACKUPFILE=false
      ;;
    --skip-verify-datastore-archive)
      export VERIFY_DATASTORE_ARCHIVE=false
      ;;
    --use-job)
      export BACKUP_RESTORE_IN_POD=true
      ;;
    --enable-multipart)
      export DISABLE_MC_MULTIPART=false
      ;;
    --pvc)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      export TMP_PVC_NAME="$2"
      shift 1
      ;;
    --pvc=*)
      export TMP_PVC_NAME="${1#--pvc=}"
      ;;
    --quiesce-on-error)
      export QUIESCE_ON_ERROR=true
      ;;
    --quiesce-on-error=*)
      export QUIESCE_ON_ERROR="${1#--quiesce-on-error=}"
      ;;
    --skip-quiesce)
      export SKIP_QUIESCE=true
      ;;
    --skip-quiesce=*)
      export SKIP_QUIESCE="${1#--skip-quiesce=}"
      ;;
    --file-storage-class)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      export FILE_STORAGE_CLASS="$2"
      shift 1
      ;;
    --file-storage-class=*)
      export FILE_STORAGE_CLASS="${1#--file-storage-class=}"
      ;;
    --elastic-shared-pvc)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      export ELASTIC_SHARED_PVC="$2"
      shift 1
      ;;
    --elastic-shared-pvc=*)
      export ELASTIC_SHARED_PVC="${1#--elastic-shared-pvc=}"
      ;;
    --clean)
      export CLEAN=true
      ;;
    --clean=*)
      export CLEAN="${1#--clean=}"
      ;;
    -- | -)
      shift 1
      param+=( "$@" )
      break
      ;;
    -*)
      brlog "ERROR" "illegal option: $1"
      exit 1
      ;;
    *)
      if [[ ! -z "$1" ]] && [[ ! "$1" =~ ^-+ ]]; then
        if [ "$1" = "backup" -o "$1" = "restore" ] ; then
          COMMAND=$1
        else
          brlog "ERROR" "illegal argument: $1"
          exit 1
        fi
      fi
      ;;
  esac
  shift 1
done

###############
# Constants
###############

TENANT_NAME="${TENANT_NAME:-wd}"
BACKUPFILE_ARCHIVE_OPTION="${BACKUPFILE_ARCHIVE_OPTION-}"
if [ -n "${BACKUPFILE_ARCHIVE_OPTION}" ] ; then
  read -a BACKUPFILE_TAR_OPTIONS <<< ${BACKUPFILE_ARCHIVE_OPTION}
else
  BACKUPFILE_TAR_OPTIONS=("")
fi
VERIFY_ARCHIVE=${VERIFY_ARCHIVE:-true}
VERIFY_BACKUPFILE=${VERIFY_BACKUPFILE:-$VERIFY_ARCHIVE}
SKIP_QUIESCE=${SKIP_QUIESCE:-false}

verify_args

export COMMAND=${COMMAND}
export TENANT_NAME=${TENANT_NAME}
export SCRIPT_DIR=${SCRIPT_DIR}
export OC_ARGS="${EXTRA_OC_ARGS}"
export CLEAN=${CLEAN:-false}

###############
# Function
###############

run () {
  for COMP in ${ALL_COMPONENT[@]}
  do
    CURRENT_COMPONENT=${COMP}
    "${SCRIPT_DIR}"/${COMP}-backup-restore.sh ${COMMAND} ${TENANT_NAME} -f "${BACKUP_DIR}/${COMP}.backup"
  done
}


###############
# Prerequisite
###############

disable_trap

oc_login_as_scripts_user

export WD_VERSION=${WD_VERSION:-$(get_version)}
brlog "INFO" "Watson Discovery Version: ${WD_VERSION}"

validate_version

if [ -z "${CONTINUE_FROM_COMPONENT+UNDEF}" ] && [ -d "${BACKUP_DIR}" ] ; then
  if "${CLEAN}" ; then
    rm -rf "./${BACKUP_DIR}"
  else
    brlog "ERROR" "./${BACKUP_DIR} exists. Please remove it."
    exit 1
  fi
fi

if [ -d "${SPLIT_DIR}" ] ; then
  if "${CLEAN}" ; then
    rm -rf "${SPLIT_DIR}"
  else
    brlog "ERROR" "Please remove ${SPLIT_DIR}"
    exit 1
  fi
fi

###############
# Main
###############

rm -rf ${TMP_WORK_DIR}
mkdir -p ${TMP_WORK_DIR}

mkdir -p "${BACKUP_RESTORE_LOG_DIR}"
brlog "INFO" "Component log directory: ${BACKUP_RESTORE_LOG_DIR}"
CURRENT_COMPONENT="pre-process"
check_datastore_available
create_elastic_shared_pvc

if ! "${BACKUP_RESTORE_IN_POD:-false}" ; then
  brlog "INFO" "Getting mc command for backup/restore of MinIO and ElasticSearch"
  if [ -n "${MC_COMMAND+UNDEF}" ] ; then
    MC_COMMAND=${MC_COMMAND}
  else
    get_mc ${TMP_WORK_DIR}
    MC_COMMAND=${PWD}/${TMP_WORK_DIR}/mc
  fi
  export MC_COMMAND=${MC_COMMAND}
fi


if [ ${COMMAND} = 'backup' ] ; then
  if [ $(compare_version "${WD_VERSION}" "4.0.6") -ge 0 ] ; then
    create_backup_instance_mappings
  fi
  if [ "${CONTINUE_FROM_COMPONENT:-}" != "archive" ] ; then
    if ! "${SKIP_QUIESCE}" ; then
      quiesce
    fi
  fi
  if [ $(compare_version "${WD_VERSION}" "2.1.3") -ge 0 ] ; then
    ALL_COMPONENT=("wddata" "etcd" "postgresql" "elastic" "minio")
  else
    ALL_COMPONENT=("wddata" "etcd" "hdp" "postgresql" "elastic")
  fi
  export ALL_COMPONENT
  export VERIFY_COMPONENT=( "${ALL_COMPONENT[@]}")
  BACKUP_FILE=${BACKUP_FILE:-"watson-discovery_$(date "+%Y%m%d_%H%M%S").backup"}
  mkdir -p "${BACKUP_DIR}"
  if [ -n "${CONTINUE_FROM_COMPONENT:+UNDEF}" ] ; then
    for comp in "${ALL_COMPONENT[@]}"
    do
      if [ "${comp}" = "${CONTINUE_FROM_COMPONENT}" ] ; then
        break
      fi
      ALL_COMPONENT=("${ALL_COMPONENT[@]:1}")
    done
  fi
  run
  CURRENT_COMPONENT="archive"
  rm -rf ${TMP_WORK_DIR}
  echo -n "${WD_VERSION}" > ${BACKUP_VERSION_FILE}
  brlog "INFO" "Archiving all backup files..."
  tar "${BACKUPFILE_TAR_OPTIONS[@]}" -cf "${BACKUP_FILE}" "${BACKUP_DIR}"
  brlog "INFO" "Checking backup file list"
  BACKUP_FILES=$(ls ${BACKUP_DIR})
  for COMP in "${VERIFY_COMPONENT[@]}"
  do
    if ! echo "${BACKUP_FILES}" | grep ${COMP} > /dev/null ; then
      brlog "ERROR" "${COMP}.backup does not exists."
      exit 1
    fi
  done
  brlog "INFO" "OK"
  if "${VERIFY_BACKUPFILE}" && brlog "INFO" "Verifying backup archive" && ! tar "${BACKUPFILE_TAR_OPTIONS[@]}" -tvf ${BACKUP_FILE} ; then
    brlog "ERROR" "Backup file is broken, or does not exist."
    exit 1
  fi
fi

if [ "${COMMAND}" = 'restore' ] ; then
  if [ -z "${CONTINUE_FROM_COMPONENT:+UNDEF}" ] || [ ! -f "${BACKUP_VERSION_FILE}" ] ; then
    brlog "INFO" "Extract archive"
    tar "${BACKUPFILE_TAR_OPTIONS[@]}" -xf "${BACKUP_FILE}"
  fi
  export BACKUP_FILE_VERSION=$(get_backup_version)
  launch_utils_job "wd-backup-restore-util-job"
  trap_add "oc ${OC_ARGS} delete job wd-backup-restore-util-job --ignore-not-found"
  get_job_pod "app.kubernetes.io/component=wd-backup-restore"
  wait_job_running ${POD}
  if [ $(compare_version "${BACKUP_FILE_VERSION}" "4.0.6") -ge 0 ] ; then
    if ! check_instance_mappings ; then
      brlog "ERROR" "Incorrect instance mapping."
      brlog "INFO" "You can restart ${COMMAND} with '--continue-from' option like:"
      brlog "INFO" "./all-backup-restore.sh ${COMMAND} -f ${BACKUP_FILE} --continue-from wddata"
      exit 1
    fi
  else
    if ! check_instance_exists ; then
      brlog "INFO" "Watson Discovery instance does not exist"
      if [ -z "${INSTANCE_NAME+NONDEF}" ] ; then
        brlog "ERROR" "Undefined Discovery instance name. Please use --instance-name option or provision Discovery instance on CP4D UI"
        brlog "INFO" "You can restart ${COMMAND} with adding '--continue-from' option:"
        brlog "INFO" "ex) ./all-backup-restore.sh ${COMMAND} -f ${BACKUP_FILE} --continue-from wddata"
        exit 1
      fi
      instance_id=$(create_service_instance "${INSTANCE_NAME}")
      if [ -n "${instance_id}" ] ; then
        brlog "INFO" "Created Discovery service instance. Name: ${INSTANCE_NAME}, ID: ${instance_id}"
      else
        brlog "ERROR" "Failed to create Discovery service instance"
        brlog "INFO" "You can restart ${COMMAND} with adding '--continue-from' option like:"
        brlog "INFO" "ex) ./all-backup-restore.sh ${COMMAND} -f ${BACKUP_FILE} --continue-from wddata"
        exit 1
      fi
    fi
  fi
  oc ${OC_ARGS} delete job wd-backup-restore-util-job
  trap_remove "oc ${OC_ARGS} delete job wd-backup-restore-util-job --ignore-not-found"
  if [ "${CONTINUE_FROM_COMPONENT:-}" != "post-restore" ] ; then
    if ! "${SKIP_QUIESCE}" ; then
      quiesce
    fi
  fi
  ALL_COMPONENT=("wddata" "etcd" "postgresql" "elastic" "minio")
  if [ -n "${CONTINUE_FROM_COMPONENT:+UNDEF}" ] ; then
    for comp in "${ALL_COMPONENT[@]}"
    do
      if [ "${comp}" = "${CONTINUE_FROM_COMPONENT}" ] ; then
        break
      fi
      ALL_COMPONENT=("${ALL_COMPONENT[@]:1}")
    done
  fi
  export ALL_COMPONENT=${ALL_COMPONENT}
  run
  CURRENT_COMPONENT=migration
  if [ "${CONTINUE_FROM_COMPONENT:-}" != "post-restore" ] ; then
    if require_st_mt_migration ; then
      ${SCRIPT_DIR}/st-mt-migration.sh ${TENANT_NAME}
    fi
    if require_mt_mt_migration ; then
      ${SCRIPT_DIR}/mt-mt-migration.sh -i ${TENANT_NAME}
    fi
  fi
  if [ $(compare_version "${WD_VERSION}" "4.7.0") -ge 0 ] ; then
    restart_job_list="enrichment-model-copy orchestrator-setup"
    if [ $(compare_version "${WD_VERSION}" "4.7.1") -ge 0 ] ; then
      restart_job_list="${restart_job_list} sdu-db-init"
    fi
    restart_job "${restart_job_list}"
  fi
fi

if ! "${SKIP_QUIESCE}" ; then
  unquiesce
fi

if [ "$COMMAND" = "restore" ] ; then
  CURRENT_COMPONENT="post-restore"
  ${SCRIPT_DIR}/post-restore.sh ${TENANT_NAME}
fi

brlog "INFO" "Clean up"

delete_service_account "${BACKUP_RESTORE_SA}"
rm -f "${KUBECONFIG_FILE}"
unset KUBECONFIG
rm -rf "${BACKUP_DIR}"

disable_trap

echo
brlog "INFO" "Backup/Restore Script Complete"
echo