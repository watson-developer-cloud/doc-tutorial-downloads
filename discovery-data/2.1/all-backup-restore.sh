#!/bin/bash

set -e

BACKUP_ARGS=""
BACKUP_DIR="tmp"
SPLITE_DIR=./tmp_split_bakcup

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

if [ -d "${BACKUP_DIR}" ] ; then
  echo "WARNING: ./${BACKUP_DIR} exists. Please remove it."
  exit 1
fi

if [ -d "${SPLITE_DIR}" ] ; then
  echo "WARNING: Please remove ${SPLITE_DIR}"
  exit 1
fi

# Check the sequetial installation. If discovery has multiple release but only a gateway release, it should be the sequetial installation.
IS_SEQ_INS=false
RELEASE_NUM=`kubectl get pod ${KUBECTL_ARGS} -o jsonpath="{.items[*].metadata.labels.release}" -l "app.kubernetes.io/name=discovery" | tr ' ' '\n' | uniq | wc -l`
if [ ${RELEASE_NUM} -gt 1 ] ; then
  GATEWAY_RELEASE_NUM=`kubectl get pod ${KUBECTL_ARGS} -o jsonpath="{.items[*].metadata.labels.release}" -l "app.kubernetes.io/name=discovery,run=gateway" | tr ' ' '\n' | uniq | wc -l`
  if [ ${GATEWAY_RELEASE_NUM} == 1 ] ; then
    IS_SEQ_INS=true
  fi
fi

export ALL_COMPONENT=${ALL_COMPONENT}
export COMMAND=${COMMAND}
export RELEASE_NAME=${RELEASE_NAME}
export BACKUP_ARGS=${BACKUP_ARGS}
export SCRIPT_DIR=${SCRIPT_DIR}
export IS_SEQ_INS=${IS_SEQ_INS}

run () {
  for COMP in ${ALL_COMPONENT[@]}
  do
    if "${IS_SEQ_INS}" ; then
      case "${COMP}" in
        "wddata" ) export RELEASE_NAME="core" ;;
        "etcd" | "postgresql" ) export RELEASE_NAME="bedrock" ;;
        "hdp" | "elastic" ) export RELEASE_NAME="substrate" ;;
      esac
    fi

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

  INGESTION_RELEASE_NAME=${RELEASE_NAME}
  if "${IS_SEQ_INS}" ; then
    INGESTION_RELEASE_NAME="core"
  fi
  INGESTION_RESOURCE_NAME=`kubectl get sts ${KUBECTL_ARGS} -o jsonpath='{.items[0].metadata.name}' -l release=${RELEASE_NAME},run=ingestion`
  ORG_INGESTION_POD_NUM=`kubectl get sts ${KUBECTL_ARGS} -o jsonpath='{.items[0].spec.replicas}' -l release=${RELEASE_NAME},run=ingestion`
  if [ ${ORG_INGESTION_POD_NUM} -eq 0 ] ; then
    ORG_INGESTION_POD_NUM=1
  fi
  trap "kubectl ${KUBECTL_ARGS} scale sts ${INGESTION_RESOURCE_NAME} --replicas=${ORG_INGESTION_POD_NUM}" 0 1 2 3 15
  echo "Change replicas of ${INGESTION_RESOURCE_NAME} to 0".
  kubectl ${KUBECTL_ARGS} scale sts ${INGESTION_RESOURCE_NAME} --replicas=0
  echo "Waiting for ${INGESTION_RESOURCE_NAME} to be scaled..."
  while :
  do
    if [ `kubectl get pod ${KUBECTL_ARGS} -l release=${INGESTION_RELEASE_NAME},run=ingestion | wc -l` = '0' ] ; then
      break
    else
      sleep 1
    fi
  done
  echo "Complete scale."

  tar xf "${BACKUP_FILE}"
  run
  rm -rf "${BACKUP_DIR}"

  echo "Restarting central pods:"

  if "${IS_SEQ_INS}" ; then
    export RELEASE_NAME="substrate"
  fi

  HDP_POD=$(kubectl ${KUBECTL_ARGS} get pods -o jsonpath="{.items[0].metadata.name}" -l "release=${RELEASE_NAME},run=hdp-worker")

  if "${IS_SEQ_INS}" ; then
    export RELEASE_NAME="core"
  fi

  CORE_PODS=$(kubectl ${KUBECTL_ARGS} get pods -o jsonpath="{.items[*].metadata.name}" -l "release=${RELEASE_NAME},run in (gateway, ingestion, orchestrator)")

  kubectl delete pod ${KUBECTL_ARGS} ${CORE_PODS} ${HDP_POD}

  RANKER_MASTER_PODS=$(kubectl ${KUBECTL_ARGS} get pods -l component=master -o jsonpath="{.items[*].metadata.name}")
  kubectl delete pod ${KUBECTL_ARGS} ${RANKER_MASTER_PODS}

  echo

  echo "Restore replicas of ${INGESTION_RESOURCE_NAME}"
  kubectl ${KUBECTL_ARGS} scale sts ${INGESTION_RESOURCE_NAME} --replicas=${ORG_INGESTION_POD_NUM}
  trap 0 1 2 3 15

  ./post-restore.sh ${RELEASE_NAME}

  echo
  echo "Restore Script Complete"
  echo
fi