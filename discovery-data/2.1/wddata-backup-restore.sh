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

brlog "INFO" "WDData: "
brlog "INFO" "Release name: $RELEASE_NAME"
GATEWAY_POD=`kubectl get pods ${KUBECTL_ARGS} -o jsonpath="{.items[0].metadata.name}" -l release=${RELEASE_NAME},run=gateway`
ORG_KUBECTL_ARGS=${KUBECTL_ARGS} 

# If the number of gateway's container is greater than 1, this is WD 2.1.2 or later. Then, we use management pod to get backup/restore.
if [ `kubectl get pods ${KUBECTL_ARGS} -o jsonpath="{.items[0].spec.containers[*].name}" -l release=${RELEASE_NAME},run=gateway | wc -w` -gt 1 ] ; then
  export KUBECTL_ARGS="${KUBECTL_ARGS} -c management"
fi

# backup wddata
if [ ${COMMAND} = 'backup' ] ; then
  BACKUP_FILE=${BACKUP_FILE:-"wddata_`date "+%Y%m%d_%H%M%S"`.backup"}
  brlog "INFO" "Start backup wddata..."
  kubectl exec ${GATEWAY_POD} ${KUBECTL_ARGS} --  bash -c 'rm -f /tmp/'${WDDATA_BACKUP}' && \
  tar zcf /tmp/'${WDDATA_BACKUP}' --exclude ".nfs*" --exclude wexdata/logs --exclude "wexdata/zing/data/crawler/*/temp" wexdata/* ; code=$?; if [ $code -ne 0 -a $code -ne 1 ] ; then echo "Fatal Error"; exit $code; fi'
  wait_cmd ${GATEWAY_POD} "tar zcf" ${KUBECTL_ARGS}
  brlog "INFO" "Transferring archive..."
  kube_cp_to_local ${GATEWAY_POD} "${BACKUP_FILE}" "/tmp/${WDDATA_BACKUP}" ${KUBECTL_ARGS}
  kubectl exec ${GATEWAY_POD} ${KUBECTL_ARGS} --  bash -c "rm -f /tmp/${WDDATA_BACKUP}"
  brlog "INFO" "Verifying backup..."
  if ! tar tf ${BACKUP_FILE} &> /dev/null ; then
    brlog "ERROR" "Backup file is broken, or does not exist."
    exit 1
  fi
  brlog "INFO" "Done: ${BACKUP_FILE}"
fi

#restore wddata
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
  brlog "INFO" "Start restore wddata: ${BACKUP_FILE}"
  brlog "INFO" "Transferring archive..."
  kube_cp_from_local ${GATEWAY_POD} "${BACKUP_FILE}" "/tmp/${WDDATA_BACKUP}" ${KUBECTL_ARGS}
  brlog "INFO" "Restoring data..."
  kubectl exec ${GATEWAY_POD} ${KUBECTL_ARGS} -- bash -c "tar xf /tmp/${WDDATA_BACKUP} --exclude *.lck ; rm -f /tmp/${WDDATA_BACKUP}"
  wait_cmd ${GATEWAY_POD} "tar xf" ${KUBECTL_ARGS}
  brlog "INFO" "Restore Done"
  brlog "INFO" "Applying updates"
  . ./lib/restore-updates.bash
  wddata_updates
  brlog "INFO" "Completed Updates"
  echo
fi

export KUBECTL_ARGS=${ORG_KUBECTL_ARGS}
