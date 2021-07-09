#!/bin/bash

set -e

BACKUP_DIR="tmp"
BACKUP_VERSION_FILE="tmp/version.txt"
TMP_WORK_DIR="tmp/all_backup"
SPLITE_DIR=./tmp_split_backup
OC_ARGS="${OC_ARGS:-}"

TAB="$(printf '\t')"
printUsage() {
cat << EOF
Usage:
    $(basename ${0}) (backup|restore) [-f backupFile] [options]

Options:
    --help, -h                                 Show help
    --file, -f                                 Specify backup file
    --log-output-dir="<directory_path>"        Specify output directory of detailed component logs

Options (Advanced):
Basically, you don't need these advanced options.

    --archive-on-local                         Archive the backup files of etcd and postgresql on local machine. Use this flag to reduce the disk usage on their pod or compress the files with specified option, but it might take a long time.
    --backup-archive-option="<tar_option>"     Tar options for compression used for archiving the backup file. Default: none.
    --datastore-archive-option="<tar_option>"  Tar options for compression used for archiving the backup files of ElasticSearch, MinIO and internal configuration. Default "-z".
    --postgresql-archive-option="<tar_option>" Tar options for comporession used for archiving the backup files of postgres. Note that the backup files of postgresql are archived on its pod by default. Default "-z".
    --etcd-archive-option="<tar_option>"       Tar options used for archiving the backup files of etcd. Note that the backup files of etcd are archived on its pod by default. Default "-z".
    --skip-verify-archive                      Skip the all verifying process of the archive.
    --skip-verify-backup                       Skip verifying the backup file.
    --skip-verify-datastore-archive            Skip verifying the archive of datastores.
    --use-job                                  Use kubernetes job for backup/restore of ElasticSearch or MinIO. Use this flag if it fails to transfer data to MinIO.
    --pvc="<pvc_name>"                         PVC name used on job for backup/restore of ElasticSearch or MinIO. The size of PVC should be 2.5 ~ 3 times as large as a backup file of ElasticSearch or MinIO. If not defined, use emptyDir. Its size depends on ephemeral storage.
    --enable-multipart                         Enable multipart upload of MinIO client on kubernetes job.
EOF
}

SCRIPT_DIR=$(dirname $0)

. ${SCRIPT_DIR}/lib/function.bash

set_scripts_version

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
      shift 2
      ;;
    -n | --namespace)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      OC_ARGS="${OC_ARGS} -n $2"
      shift 2
      ;;
    -f | --file)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      BACKUP_FILE="$2"
      shift 2
      ;;
    --log-output-dir)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      export BACKUP_RESTORE_LOG_DIR="$2"
      shift 2
      ;;
    --log-output-dir=*)
      export BACKUP_RESTORE_LOG_DIR="${1#--log-output-dir=}"
      shift 1
      ;;
    --archive-on-local)
      export ARCHIVE_ON_LOCAL=true
      shift 1
      ;;
    --backup-archive-option)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      export BACKUPFILE_ARCHIVE_OPTION="$2"
      shift 2
      ;;
    --backup-archive-option=*)
      BACKUPFILE_ARCHIVE_OPTION="${1#--backup-archive-option=}"
      shift 1
      ;;
    --datastore-archive-option)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      export DATASTORE_ARCHIVE_OPTION="$2"
      shift 2
      ;;
    --datastore-archive-option=*)
      export DATASTORE_ARCHIVE_OPTION="${1#--datastore-archive-option=}"
      shift 1
      ;;
    --postgresql-archive-option)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      export PG_ARCHIVE_OPTION="$2"
      shift 2
      ;;
    --postgresql-archive-option=*)
      export PG_ARCHIVE_OPTION="${1#--postgresql-archive-option=}"
      shift 1
      ;;
    --etcd-archive-option)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      export ETCD_ARCHIVE_OPTION="$2"
      shift 2
      ;;
    --etcd-archive-option=*)
      export ETCD_ARCHIVE_OPTION="${1#--etcd-archive-option=}"
      shift 1
      ;;
    --skip-verify-archive)
      export VERIFY_ARCHIVE=false
      shift 1
      ;;
    --skip-verify-backup)
      VERIFY_BACKUPFILE=false
      shift 1
      ;;
    --skip-verify-datastore-archive)
      export VERIFY_DATASTORE_ARCHIVE=false
      shift 1
      ;;
    --use-job)
      export BACKUP_RESTORE_IN_POD=true
      shift 1
      ;;
    --enable-multipart)
      export DISABLE_MC_MULTIPART=false
      shift 1
      ;;
    --pvc)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      export JOB_PVC_NAME="$2"
      shift 2
      ;;
    --pvc=*)
      export JOB_PVC_NAME="${1#--pvc=}"
      shift 1
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
        fi
        shift 1
      fi
      ;;
    esac
done


TENANT_NAME="${TENANT_NAME:-wd}"
BACKUPFILE_ARCHIVE_OPTION="${BACKUPFILE_ARCHIVE_OPTION-}"
if [ -n "${BACKUPFILE_ARCHIVE_OPTION}" ] ; then
  read -a BACKUPFILE_TAR_OPTIONS <<< ${BACKUPFILE_ARCHIVE_OPTION}
else
  BACKUPFILE_TAR_OPTIONS=("")
fi
VERIFY_ARCHIVE=${VERIFY_ARCHIVE:-true}
VERIFY_BACKUPFILE=${VERIFY_BACKUPFILE:-$VERIFY_ARCHIVE}

verify_args

export WD_VERSION=`get_version`
brlog "INFO" "Watson Discovery Version: ${WD_VERSION}"
validate_version

if [ -d "${BACKUP_DIR}" ] ; then
  brlog "ERROR" "./${BACKUP_DIR} exists. Please remove it."
  exit 1
fi

if [ -d "${SPLITE_DIR}" ] ; then
  brlog "ERROR" "Please remove ${SPLITE_DIR}"
  exit 1
fi

export COMMAND=${COMMAND}
export TENANT_NAME=${TENANT_NAME}
export SCRIPT_DIR=${SCRIPT_DIR}
export OC_ARGS=${OC_ARGS}

brlog "INFO" "Getting mc command for backup/restore of MinIO and ElasticSearch"
rm -rf ${TMP_WORK_DIR}
mkdir -p ${TMP_WORK_DIR}
if [ -n "${MC_COMMAND+UNDEF}" ] ; then
  MC_COMMAND=${MC_COMMAND}
else
  get_mc ${TMP_WORK_DIR}
  MC_COMMAND=${PWD}/${TMP_WORK_DIR}/mc
fi
export MC_COMMAND=${MC_COMMAND}

mkdir -p "${BACKUP_RESTORE_LOG_DIR}"
brlog "INFO" "Component log directory: ${BACKUP_RESTORE_LOG_DIR}"

run () {
  for COMP in ${ALL_COMPONENT[@]}
  do
    "${SCRIPT_DIR}"/${COMP}-backup-restore.sh ${COMMAND} ${TENANT_NAME} -f "${BACKUP_DIR}/${COMP}.backup"
  done
}

quiesce

if [ ${COMMAND} = 'backup' ] ; then
  if [  `compare_version "${WD_VERSION}" "2.1.3"` -ge 0 ] ; then
    ALL_COMPONENT=("wddata" "etcd" "postgresql" "elastic" "minio")
  else
    ALL_COMPONENT=("wddata" "etcd" "hdp" "postgresql" "elastic")
  fi
  export ALL_COMPONENT=${ALL_COMPONENT}
  BACKUP_FILE=${BACKUP_FILE:-"watson-discovery_`date "+%Y%m%d_%H%M%S"`.backup"}
  mkdir -p "${BACKUP_DIR}"
  run
  rm -rf ${TMP_WORK_DIR}
  echo -n "${WD_VERSION}" > ${BACKUP_VERSION_FILE}
  brlog "INFO" "Archiving all backup files..."
  tar ${BACKUPFILE_TAR_OPTIONS[@]} -cf "${BACKUP_FILE}" "${BACKUP_DIR}"
  brlog "INFO" "Checking backup file list"
  BACKUP_FILES=`ls ${BACKUP_DIR}`
  for COMP in ${ALL_COMPONENT[@]}
  do
    if ! echo "${BACKUP_FILES}" | grep ${COMP} > /dev/null ; then
      brlog "ERROR" "${COMP}.backup does not exist."
      exit 1
    fi
  done
  brlog "INFO" "OK"
  if "${VERIFY_BACKUPFILE}" && brlog "INFO" "Verifying backup archive" && ! tar ${BACKUPFILE_TAR_OPTIONS[@]} -tvf ${BACKUP_FILE} ; then
    brlog "ERROR" "Backup file is broken, or does not exist."
    exit 1
  fi
fi

if [ ${COMMAND} = 'restore' ] ; then
  tar ${BACKUPFILE_TAR_OPTIONS[@]} -xf "${BACKUP_FILE}"
  export BACKUP_FILE_VERSION=`get_backup_version`
  ALL_COMPONENT=("wddata" "etcd" "postgresql" "elastic" "minio")
  export ALL_COMPONENT=${ALL_COMPONENT}
  run
fi

unquiesce

if [ "$COMMAND" = "restore" ] ; then
  ./post-restore.sh ${TENANT_NAME}
fi

brlog "INFO" "Clean up"

rm -rf "${BACKUP_DIR}"

echo
brlog "INFO" "Backup/Restore Script Complete"
echo