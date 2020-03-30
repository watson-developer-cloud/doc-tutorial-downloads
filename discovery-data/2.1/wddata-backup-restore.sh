#!/bin/bash

set -euo pipefail

ROOT_DIR_WDDATA="$(cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" && pwd -P)"
typeset -r ROOT_DIR_WDDATA

# shellcheck source=lib/restore-utilites.bash
source "${ROOT_DIR_WDDATA}/lib/restore-updates.bash"
source "${ROOT_DIR_WDDATA}/lib/function.bash"

KUBECTL_ARGS=""
WDDATA_BACKUP="wddata.tar.gz"

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

echo "WDData: "
echo "Release name: $RELEASE_NAME"
GATEWAY_POD=`kubectl get pods ${KUBECTL_ARGS} -o jsonpath="{.items[0].metadata.name}" -l release=${RELEASE_NAME},run=gateway`
ORG_KUBECTL_ARGS=${KUBECTL_ARGS} 

# If the number of gateway's container is greater than 1, this is WD 2.1.2 or later. Then, we use management pod to get backup/restore.
if [ `kubectl get pods ${KUBECTL_ARGS} -o jsonpath="{.items[0].spec.containers[*].name}" -l release=${RELEASE_NAME},run=gateway | wc -w` -gt 1 ] ; then
  export KUBECTL_ARGS="${KUBECTL_ARGS} -c management"
fi

# backup wddata
if [ ${COMMAND} = 'backup' ] ; then
  BACKUP_FILE=${BACKUP_FILE:-"wddata_`date "+%Y%m%d_%H%M%S"`.backup"}
  echo "Start backup wddata..."
  kubectl exec ${GATEWAY_POD} ${KUBECTL_ARGS} --  bash -c 'rm -f /tmp/'${WDDATA_BACKUP}' && \
  if [ `ls mnt | wc -l | xargs` != "0" ] ; then tar zcf /tmp/'${WDDATA_BACKUP}' --exclude ".nfs*" --exclude wexdata/logs wexdata/* mnt/* ; else tar zcf /tmp/'${WDDATA_BACKUP}' --exclude ".nfs*" --exclude wexdata/logs wexdata/* ; fi; code=$?; if [ $code -ne 0 -a $code -ne 1 ] ; then echo "Fatal Error"; exit $code; fi'
  wait_cmd ${GATEWAY_POD} "tar zcf" ${KUBECTL_ARGS}
  kube_cp_to_local ${GATEWAY_POD} "${BACKUP_FILE}" "/tmp/${WDDATA_BACKUP}" ${KUBECTL_ARGS}
  kubectl exec ${GATEWAY_POD} ${KUBECTL_ARGS} --  bash -c "rm -f /tmp/${WDDATA_BACKUP}"
  echo "Done: ${BACKUP_FILE}"
fi

#restore wddata
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
  echo "Start restore wddata: ${BACKUP_FILE}"
  kube_cp_from_local ${GATEWAY_POD} "${BACKUP_FILE}" "/tmp/${WDDATA_BACKUP}" ${KUBECTL_ARGS}
  kubectl exec ${GATEWAY_POD} ${KUBECTL_ARGS} -- bash -c "tar xf /tmp/${WDDATA_BACKUP} --exclude *.lck ; rm -f /tmp/${WDDATA_BACKUP}"
  wait_cmd ${GATEWAY_POD} "tar xf" ${KUBECTL_ARGS}
  echo "Restore Done"
  echo "Applying updates"
  . ./lib/restore-updates.bash
  wddata_updates
  echo "Completed Updates"
  echo
fi

export KUBECTL_ARGS=${ORG_KUBECTL_ARGS}
