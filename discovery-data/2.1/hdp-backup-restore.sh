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


echo "HDP: "
echo "Release name: $RELEASE_NAME"

HDP_POD=`kubectl get pods ${KUBECTL_ARGS} -o jsonpath='{.items[0].metadata.name}' -l release=${RELEASE_NAME},helm.sh/chart=hdp,run=hdp-nn`

# backup hadoop
if [ ${COMMAND} = 'backup' ] ; then
  BACKUP_FILE=${BACKUP_FILE:-"hadoop_`date "+%Y%m%d_%H%M%S"`.backup"}
  echo "Start backup hadoop..."
  kubectl exec ${HDP_POD} ${KUBECTL_ARGS} --  bash -c "cd /tmp && \
  rm -rf ${HDP_BACKUP_DIR} ${HDP_BACKUP} && \
  mkdir -p ${HDP_BACKUP_DIR} && \
  hdfs dfs -copyToLocal /user ./${HDP_BACKUP_DIR}/ && \
  tar zcf ${HDP_BACKUP} ${HDP_BACKUP_DIR}"
  wait_cmd ${HDP_POD} "tar zcf" ${KUBECTL_ARGS}
  kube_cp_to_local ${HDP_POD} "${BACKUP_FILE}" "${HDP_BACKUP}" ${KUBECTL_ARGS}
  kubectl exec ${HDP_POD} ${KUBECTL_ARGS} -- bash -c "rm -rf ${HDP_BACKUP} /tmp/${HDP_BACKUP_DIR}"
  echo "Done: ${BACKUP_FILE}"
fi

# restore hadoop
if [ ${COMMAND} = 'restore' ] ; then
  if [ -z ${BACKUP_FILE} ] ; then
    printUsage
  fi
  if [ ! -e "${BACKUP_FILE}" ] ; then
    echo "no such file: ${BACKUP_FILE}"
    echo "Nothing to Restore"
    echo
    exit 1
  fi
  echo "Start restore hadoop: ${BACKUP_FILE}"
  kube_cp_from_local ${HDP_POD} "${BACKUP_FILE}" "${HDP_BACKUP}" ${KUBECTL_ARGS}
  kubectl exec ${HDP_POD} ${KUBECTL_ARGS} -- bash -c "cd /tmp && \
  rm -rf ${HDP_BACKUP_DIR}/* && \
  tar xf ${HDP_BACKUP} && \
  hdfs dfs -rm -r '/*' && \
  hdfs dfs -copyFromLocal ${HDP_BACKUP_DIR}/* / && \
  rm -rf ${HDP_BACKUP} ${HDP_BACKUP_DIR}"
  wait_cmd ${HDP_POD} "hdfs dfs -copyFromLocal" ${KUBECTL_ARGS}
  echo "Done"
  echo "Applying updates"
  . ./lib/restore-updates.bash
  hdp_updates
  echo "Completed Updates"
  echo
fi
