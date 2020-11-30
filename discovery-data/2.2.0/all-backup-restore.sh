#!/bin/bash

set -e

BACKUP_DIR="tmp"
BACKUP_VERSION_FILE="tmp/version.txt"
TMP_WORK_DIR="tmp/all_backup"
SPLITE_DIR=./tmp_split_bakcup
OC_ARGS="${OC_ARGS:-}"
TENANT_NAME="${TENANT_NAME:-wd}"

printUsage() {
  echo "Usage: $(basename ${0}) command [-t tenantName] [-f backupFile]"
  exit 1
}

if [ $# -lt 2 ] ; then
  printUsage
fi

SCRIPT_DIR=$(dirname $0)

. ${SCRIPT_DIR}/lib/function.bash

set_scripts_version


COMMAND=$1
shift
while getopts f:n:t: OPT
do
  case $OPT in
    "f" ) BACKUP_FILE="$OPTARG" ;;
    "n" ) ;;
    "t" ) TENANT_NAME="$OPTARG";;
esac
done

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
  tar zcf "${BACKUP_FILE}" "${BACKUP_DIR}"
  brlog "INFO" "Verifying backup..."
  BACKUP_FILES=`ls ${BACKUP_DIR}`
  for COMP in ${ALL_COMPONENT[@]}
  do
    if ! echo "${BACKUP_FILES}" | grep ${COMP} > /dev/null ; then
      brlog "ERROR" "${COMP}.backup does not exists."
      exit 1
    fi
  done
  if ! tar tvf ${BACKUP_FILE} ; then
    brlog "ERROR" "Backup file is broken, or does not exist."
    exit 1
  fi
fi

if [ ${COMMAND} = 'restore' ] ; then
  if [ -z "${BACKUP_FILE}" ] ; then
    printUsage
  fi
  if [ ! -e "${BACKUP_FILE}" ] ; then
    brlog "ERROR" "no such file: ${BACKUP_FILE}"
    echo
    exit 1
  fi

  tar xf "${BACKUP_FILE}"
  export BACKUP_FILE_VERSION=`get_backup_version`
  ALL_COMPONENT=("wddata" "etcd" "postgresql" "elastic" "minio")
  export ALL_COMPONENT=${ALL_COMPONENT}
  run
fi

brlog "INFO" "Clean up"

rm -rf "${BACKUP_DIR}"

unquiesce

echo
brlog "INFO" "Backup/Restore Script Complete"
echo