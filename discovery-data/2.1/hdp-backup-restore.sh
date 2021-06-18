#!/bin/bash

set -euo pipefail

ROOT_HDP="$(cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" && pwd -P)"
typeset -r ROOT_HDP

# shellcheck source=lib/restore-utilites.bash
source "${ROOT_HDP}/lib/restore-updates.bash"
source "${ROOT_HDP}/lib/function.bash"

KUBECTL_ARGS=""
HDP_BACKUP="/tmp/hdp_backup.tar.gz"
HDP_BACKUP_DIR="hdp_backup"

printUsage() {
  echo "Usage: $(basename ${0}) [command] [releaseName] [-f backupFile] [-n namespace]"
  exit 1
}

if [ $# -lt 2 ] ; then
  printUsage
fi

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


brlog "INFO" "HDP: "
brlog "INFO" "Release name: $RELEASE_NAME"

HDP_POD=`kubectl get pods ${KUBECTL_ARGS} -o jsonpath='{.items[0].metadata.name}' -l release=${RELEASE_NAME},helm.sh/chart=hdp,run=hdp-nn`

# backup hadoop
if [ ${COMMAND} = 'backup' ] ; then
  BACKUP_FILE=${BACKUP_FILE:-"hadoop_`date "+%Y%m%d_%H%M%S"`.backup"}
  brlog "INFO" "Start backup hadoop..."
  kubectl exec ${HDP_POD} ${KUBECTL_ARGS} --  bash -c "cd /tmp && \
  rm -rf ${HDP_BACKUP_DIR} ${HDP_BACKUP} && \
  mkdir -p ${HDP_BACKUP_DIR} && \
  hdfs dfs -copyToLocal /user ./${HDP_BACKUP_DIR}/"
  wait_cmd ${HDP_POD} "hdfs dfs -copyToLocal" ${KUBECTL_ARGS}
  brlog "INFO" "Archiving data..."
  kubectl exec ${HDP_POD} ${KUBECTL_ARGS} --  bash -c "cd /tmp && \
  tar zcf ${HDP_BACKUP} ${HDP_BACKUP_DIR}"
  wait_cmd ${HDP_POD} "tar zcf" ${KUBECTL_ARGS}
  brlog "INFO" "Transferring archive..."
  kube_cp_to_local ${HDP_POD} "${BACKUP_FILE}" "${HDP_BACKUP}" ${KUBECTL_ARGS}
  kubectl exec ${HDP_POD} ${KUBECTL_ARGS} -- bash -c "rm -rf ${HDP_BACKUP} /tmp/${HDP_BACKUP_DIR}"
  brlog "INFO" "Verifying backup..."
  if ! tar tf ${BACKUP_FILE} &> /dev/null ; then
    brlog "ERROR" "Backup file is broken, or does not exist."
    exit 1
  fi
  brlog "INFO" "Done: ${BACKUP_FILE}"
fi

# restore hadoop
if [ ${COMMAND} = 'restore' ] ; then
  if [ -z ${BACKUP_FILE} ] ; then
    printUsage
  fi
  if [ ! -e "${BACKUP_FILE}" ] ; then
    brlog "WARN" "no such file: ${BACKUP_FILE}"
    brlog "WARN" "Nothing to Restore"
    echo
    exit 1
  fi
  brlog "INFO" "Start restore hadoop: ${BACKUP_FILE}"
  brlog "INFO" "Transferring archive..."
  kube_cp_from_local ${HDP_POD} "${BACKUP_FILE}" "${HDP_BACKUP}" ${KUBECTL_ARGS}
  brlog "INFO" "Extracting data..."
  kubectl exec ${HDP_POD} ${KUBECTL_ARGS} -- bash -c "cd /tmp && \
  rm -rf ${HDP_BACKUP_DIR}/* && \
  tar xf ${HDP_BACKUP}"
  wait_cmd ${HDP_POD} "tar xf" ${KUBECTL_ARGS}
  brlog "INFO" "Restoring data..."
  kubectl exec ${HDP_POD} ${KUBECTL_ARGS} -- bash -c "cd /tmp && \
  hdfs dfs -rm -r '/*' && \
  hdfs dfs -copyFromLocal ${HDP_BACKUP_DIR}/* / && \
  rm -rf ${HDP_BACKUP} ${HDP_BACKUP_DIR}"
  wait_cmd ${HDP_POD} "hdfs dfs -copyFromLocal" ${KUBECTL_ARGS}
  brlog "INFO" "Done"
  brlog "INFO" "Applying updates"
  . ./lib/restore-updates.bash
  hdp_updates
  brlog "INFO" "Completed Updates"
  echo
fi
