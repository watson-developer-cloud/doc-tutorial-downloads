#!/bin/bash

BACKUP_ARGS=""
BACKUP_DIR="tmp"

printUsage() {
  echo "Usage: $(basename ${0}) [command] [releaseName] [-f backupFile] [-n namespace]"
  exit 1
}

if [ $# -lt 2 ] ; then
  printUsage
fi

SCRIPT_DIR=$(dirname $0)

COMMAND=$1
shift
RELEASE_NAME=$1
shift
while getopts f:n: OPT
do
  case $OPT in
    "f" ) BACKUP_FILE="$OPTARG" ;;
    "n" ) KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$OPTARG" ;;
esac
done 

ALL_COMPONENT=("wddata" "etcd" "hdp" "postgresql" "elastic")

export ALL_COMPONENT=${ALL_COMPONENT}
export COMMAND=${COMMAND}
export RELEASE_NAME=${RELEASE_NAME}
export BACKUP_ARGS=${BACKUP_ARGS}
export SCRIPT_DIR=${SCRIPT_DIR}

run () {
  for COMP in ${ALL_COMPONENT[@]}
  do
    "${SCRIPT_DIR}"/${COMP}-backup-restore.sh ${COMMAND} ${RELEASE_NAME} -f "${BACKUP_DIR}/${COMP}.backup" ${BACKUP_ARGS}
  done
}

if [ ${COMMAND} = 'backup' ] ; then
  BACKUP_FILE=${BACKUP_FILE:-"watson-discovery_`date "+%Y%m%d_%H%M%S"`.backup"}
  mkdir -p "${BACKUP_DIR}"
  run
  tar zcf "${BACKUP_FILE}" "${BACKUP_DIR}"
  rm -rf "${BACKUP_DIR}"
  echo
  echo "Backup Script Complete"
  echo
fi

if [ ${COMMAND} = 'restore' ] ; then
  if [ -z "${BACKUP_FILE}" ] ; then
    printUsage
  fi
  if [ ! -e "${BACKUP_FILE}" ] ; then
    echo "no such file: ${BACKUP_FILE}"
    echo
    exit 1
  fi
  tar xf "${BACKUP_FILE}"
  run
  rm -rf "${BACKUP_DIR}"

  echo "Restarting central pods:"
  CORE_PODS=$(kubectl ${KUBECTL_ARGS} get pods | grep "${RELEASE_NAME}-watson-discovery" | grep -e "gateway" -e "ingestion" -e "orchestrator" | grep -v "watson-discovery-*-test" | cut -d ' ' -f 1)

  kubectl delete pod ${CORE_PODS} 

  RANKER_MASTER_PODS=$(kubectl ${KUBECTL_ARGS} get pods -l component=master -o jsonpath="{.items[*].metadata.name}")
  kubectl delete pod ${RANKER_MASTER_PODS}

  echo
  echo "Restore Script Complete"
  echo
fi