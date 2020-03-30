#!/bin/bash

set -euo pipefail

ROOT_DIR_WDDATA="$(cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" && pwd -P)"
typeset -r ROOT_DIR_WDDATA

# shellcheck source=lib/restore-utilites.bash
source "${ROOT_DIR_WDDATA}/lib/restore-updates.bash"

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
GATEWAY_POD=`kubectl get pods ${KUBECTL_ARGS}| grep "${RELEASE_NAME}-watson-discovery-gateway" | grep -v watson-discovery-gateway-test | cut -d ' ' -f 1 | sed -n 1p`

# backup wddata
if [ ${COMMAND} = 'backup' ] ; then
  BACKUP_FILE=${BACKUP_FILE:-"wddata_`date "+%Y%m%d_%H%M%S"`.backup"}
  echo "Start backup wddata..."
  kubectl exec ${GATEWAY_POD} ${KUBECTL_ARGS} --  bash -c 'if [ `ls mnt | wc -l | xargs` != "0" ] ; then tar zcf /tmp/'${WDDATA_BACKUP}' wexdata/* mnt/* --exclude ".nfs*" ; else tar zcf /tmp/'${WDDATA_BACKUP}' wexdata/* ; fi'
  kubectl cp "${GATEWAY_POD}:/tmp/${WDDATA_BACKUP}" "${BACKUP_FILE}" ${KUBECTL_ARGS}
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
  kubectl cp "${BACKUP_FILE}" "${GATEWAY_POD}:/tmp/${WDDATA_BACKUP}" ${KUBECTL_ARGS}
  kubectl exec ${GATEWAY_POD} ${KUBECTL_ARGS} -- bash -c "tar xf /tmp/${WDDATA_BACKUP} ; rm -f /tmp/${WDDATA_BACKUP}"
  echo "Restore Done"
  echo "Applying updates"
  ./lib/restore-updates.bash
  wddata_updates
  echo "Completed Updates"
  echo
fi
