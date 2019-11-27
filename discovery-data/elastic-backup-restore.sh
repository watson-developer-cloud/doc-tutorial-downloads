#!/bin/bash

set -euo pipefail

ROOT_DIR_ELASTIC="$(cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" && pwd -P)"
typeset -r ROOT_DIR_ELASTIC

# shellcheck source=lib/restore-utilites.bash
source "${ROOT_DIR_ELASTIC}/lib/restore-updates.bash"

KUBECTL_ARGS=""
ELASTIC_REPO="my_backup"
ELASTIC_SNAPSHOT="snapshot"
ELASTIC_BACKUP="elastic_snapshot.tar.gz"

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

echo "Elastic: "
echo "Release name: $RELEASE_NAME"

ELASTIC_POD=`kubectl get pods ${KUBECTL_ARGS} | grep "${RELEASE_NAME}-watson-discovery-elastic" | grep -v watson-discovery-elastic-test | cut -d ' ' -f 1 | sed -n 1p`

# backup elastic search
if [ ${COMMAND} = 'backup' ] ; then
  BACKUP_FILE=${BACKUP_FILE:-"elastic_`date "+%Y%m%d_%H%M%S"`.snapshot"}
  echo "Start backup elasticsearch..."
  kubectl exec ${ELASTIC_POD} ${KUBECTL_ARGS} --  bash -c 'source ${WEX_HOME}/sbin/profile.sh && \
  cd ${ELASTIC_BACKUP_DIR} && \
  curl -XPUT -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'" -H "Content-Type: application/json" -d"{\"type\": \"fs\",\"settings\": {\"location\": \"${ELASTIC_BACKUP_DIR}\"}}" && \
  curl -XPUT -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'?wait_for_completion=true" -H "Content-Type: application/json" -d'"'"'{"indices": "*","ignore_unavailable": true,"include_global_state": false}'"'"' && \
  tar czf /tmp/'${ELASTIC_BACKUP}' ./*'
  kubectl cp "${ELASTIC_POD}:/tmp/${ELASTIC_BACKUP}" "${BACKUP_FILE}" ${KUBECTL_ARGS}
  kubectl exec ${ELASTIC_POD} ${KUBECTL_ARGS} --  bash -c 'source ${WEX_HOME}/sbin/profile.sh && \
  curl -XDELETE -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} ${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}' && \
  curl -XDELETE -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} ${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}' && \
  rm -rf ${ELASTIC_BACKUP_DIR}/* /tmp/'${ELASTIC_BACKUP}
  echo "Done: ${BACKUP_FILE}"
fi

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
  kubectl ${KUBECTL_ARGS} cp "${BACKUP_FILE}" "${ELASTIC_POD}:/tmp/${ELASTIC_BACKUP}"
  kubectl ${KUBECTL_ARGS} exec ${ELASTIC_POD} -- bash -c 'source ${WEX_HOME}/sbin/profile.sh && \
  cd ${ELASTIC_BACKUP_DIR} && \
  tar xvf /tmp/'${ELASTIC_BACKUP}' && \
  curl -XDELETE -k -u $ELASTIC_USER:$ELASTIC_PASSWORD "$ELASTIC_ENDPOINT/_all" && \
  curl -XPUT -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'" -H "Content-Type: application/json" -d"{\"type\": \"fs\",\"settings\": {\"location\": \"${ELASTIC_BACKUP_DIR}\"}}" && \
  curl -XPOST -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "{$ELASTIC_ENDPOINT}/_snapshot/my_backup/snapshot/_restore?wait_for_completion=true" && \
  curl -XDELETE -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} ${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}' && \
  curl -XDELETE -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} ${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}' && \
  rm -rf /tmp/'${ELASTIC_BACKUP}' ${ELASTIC_BACKUP_DIR}/*'
  echo "Restore Done"
  echo "Applying updates"
  ./lib/restore-updates.bash
  elastic_updates
  echo "Completed Updates"
  echo
fi
