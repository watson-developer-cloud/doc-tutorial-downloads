#!/bin/bash

set -e

BACKUP_ARGS=""
BACKUP_DIR="tmp"
BACKUP_VERSION_FILE="tmp/version.txt"
TMP_WORK_DIR="tmp/all_backup"
SPLITE_DIR=./tmp_split_bakcup

printUsage() {
  echo "Usage: $(basename ${0}) [command] [releaseName] [-f backupFile]"
  exit 1
}

if [ $# -lt 2 ] ; then
  printUsage
fi

SCRIPT_DIR=$(dirname $0)

. ${SCRIPT_DIR}/lib/function.bash

set_scripts_version
export WD_VERSION=`get_version`
brlog "INFO" "Watson Discovery Version: ${WD_VERSION}"
validate_version


COMMAND=$1
shift
RELEASE_NAME=$1
shift
while getopts f:n: OPT
do
  case $OPT in
    "f" ) BACKUP_FILE="$OPTARG" ;;
    "n" ) KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$OPTARG"
          BACKUP_ARGS="-n $OPTARG" ;;
esac
done

if [ -d "${BACKUP_DIR}" ] ; then
  brlog "ERROR" "./${BACKUP_DIR} exists. Please remove it."
  exit 1
fi

if [ -d "${SPLITE_DIR}" ] ; then
  brlog "ERROR" "Please remove ${SPLITE_DIR}"
  exit 1
fi

export COMMAND=${COMMAND}
export RELEASE_NAME=${RELEASE_NAME}
export BACKUP_ARGS=${BACKUP_ARGS}
export SCRIPT_DIR=${SCRIPT_DIR}


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
    case "${COMP}" in
      "wddata" ) export RELEASE_NAME="core" ;;
      "etcd" | "postgresql" | "minio" ) export RELEASE_NAME="crust" ;;
      "hdp" | "elastic" ) export RELEASE_NAME="mantle" ;;
    esac
    "${SCRIPT_DIR}"/${COMP}-backup-restore.sh ${COMMAND} ${RELEASE_NAME} -f "${BACKUP_DIR}/${COMP}.backup" ${BACKUP_ARGS}
  done
}

stop_ingestion

if [ ${COMMAND} = 'backup' ] ; then
  if [ "${WD_VERSION}" = "2.1.3" ] ; then
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
  brlog "INFO" "Clean up"
  rm -rf "${BACKUP_DIR}"
  start_ingestion
  echo
  brlog "INFO" "Backup Script Complete"
  echo
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
  ALL_COMPONENT=("wddata" "etcd" "hdp" "postgresql" "elastic")
  if [ "${BACKUP_FILE_VERSION}" = "2.1.3" ] ; then
    ALL_COMPONENT=("wddata" "etcd" "postgresql" "elastic" "minio")
  fi
  export ALL_COMPONENT=${ALL_COMPONENT}
  run

  if [ "${BACKUP_FILE_VERSION}" != "${WD_VERSION}" ] ; then 
    ${SCRIPT_DIR}/run-migrator.sh "${BACKUP_DIR}/wddata.backup" ${BACKUP_ARGS}
  fi

  rm -rf "${BACKUP_DIR}"

  brlog "INFO" "Restarting central pods:"

  export RELEASE_NAME="mantle"
  HDP_POD=$(kubectl ${KUBECTL_ARGS} get pods -o jsonpath="{.items[0].metadata.name}" -l "release=${RELEASE_NAME},run=hdp-worker")

  export RELEASE_NAME="core"
  CORE_PODS=$(kubectl ${KUBECTL_ARGS} get pods -o jsonpath="{.items[*].metadata.name}" -l "release=${RELEASE_NAME},run in (gateway, management, ingestion-api)")

  start_ingestion
  kubectl delete pod ${KUBECTL_ARGS} ${CORE_PODS} ${HDP_POD}

  RANKER_MASTER_PODS=$(kubectl ${KUBECTL_ARGS} get pods -l component=master -o jsonpath="{.items[*].metadata.name}")
  kubectl delete pod ${KUBECTL_ARGS} ${RANKER_MASTER_PODS}

  ${SCRIPT_DIR}/post-restore.sh ${RELEASE_NAME}

  echo
  brlog "INFO" "Restore Script Complete"
  echo
fi