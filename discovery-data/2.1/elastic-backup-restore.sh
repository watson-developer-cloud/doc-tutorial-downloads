#!/bin/bash

set -euo pipefail

ROOT_DIR_ELASTIC="$(cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" && pwd -P)"
typeset -r ROOT_DIR_ELASTIC

# shellcheck source=lib/restore-utilites.bash
source "${ROOT_DIR_ELASTIC}/lib/restore-updates.bash"
source "${ROOT_DIR_ELASTIC}/lib/function.bash"

KUBECTL_ARGS=""
ELASTIC_REPO="my_backup"
ELASTIC_SNAPSHOT="snapshot"
ELASTIC_BACKUP="elastic_snapshot.tar.gz"
ELASTIC_REQUEST_TIMEOUT="30m" 

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

brlog "INFO" "Elastic: "
brlog "INFO" "Release name: $RELEASE_NAME"

ELASTIC_POD=""

# Check whether data node exists. If exists, this is WD 2.1.2 or later, and perform backup/restore on data node.
# If not, use elastic pod.
if [ `kubectl get pods ${KUBECTL_ARGS} -l release=${RELEASE_NAME},helm.sh/chart=elastic,role=data | grep -c "^" || true` != '0' ] ; then
  brlog "INFO" 'ElasticSearch data nodes exist. Backup/Restore will be performed on them.'
  ELASTIC_POD=`kubectl get pods ${KUBECTL_ARGS} -o jsonpath="{.items[0].metadata.name}" -l release=${RELEASE_NAME},helm.sh/chart=elastic,role=data`
else
  brlog "INFO" "ElasticSearch data nodes do not exist. Backup/Restore will be performed on normal ElasticSearch pod."
  ELASTIC_POD=`kubectl get pods ${KUBECTL_ARGS} -o jsonpath="{.items[0].metadata.name}" -l release=${RELEASE_NAME},helm.sh/chart=elastic`
fi

# backup elastic search
if [ ${COMMAND} = 'backup' ] ; then
  BACKUP_FILE=${BACKUP_FILE:-"elastic_`date "+%Y%m%d_%H%M%S"`.snapshot"}
  brlog "INFO" "Start backup elasticsearch"
  brlog "INFO" "Taking snapshot..."
  kubectl exec ${ELASTIC_POD} ${KUBECTL_ARGS} --  bash -c 'if [[ ! -v ES_PORT ]] ; then if [ -d "/opt/tls/elastic" ] ; then export ES_PORT=9100 ; else export ES_PORT=9200 ; fi ; fi && \
  export ELASTIC_ENDPOINT="http://localhost:${ES_PORT}" && \
  cd ${ELASTIC_BACKUP_DIR} && \
  rm -rf ${ELASTIC_BACKUP_DIR}/* /tmp/'${ELASTIC_BACKUP}' && \
  curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" -H "Content-Type: application/json" -d"{\"type\": \"fs\",\"settings\": {\"location\": \"${ELASTIC_BACKUP_DIR}\"}}" && \
  curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'?wait_for_completion=true&master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" -H "Content-Type: application/json" -d'"'"'{"indices": "*","ignore_unavailable": true,"include_global_state": false}'"'"
  wait_cmd ${ELASTIC_POD} "curl -XPUT -s -k -u" ${KUBECTL_ARGS}
  echo
  brlog "INFO" "Archiving snapshot..."
  kubectl exec ${ELASTIC_POD} ${KUBECTL_ARGS} --  bash -c 'cd ${ELASTIC_BACKUP_DIR} && \
  tar czf /tmp/'${ELASTIC_BACKUP}' ./*'
  wait_cmd ${ELASTIC_POD} "tar czf" ${KUBECTL_ARGS}
  brlog "INFO" "Transferring archive..."
  kube_cp_to_local ${ELASTIC_POD} "${BACKUP_FILE}" "/tmp/${ELASTIC_BACKUP}" ${KUBECTL_ARGS}
  brlog "INFO" "Clean up snapshot..."
  kubectl exec ${ELASTIC_POD} ${KUBECTL_ARGS} --  bash -c 'if [[ ! -v ES_PORT ]] ; then if [ -d "/opt/tls/elastic" ] ; then export ES_PORT=9100 ; else export ES_PORT=9200 ; fi ; fi && \
  export ELASTIC_ENDPOINT="http://localhost:${ES_PORT}" && \
  curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" && \
  curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" && \
  rm -rf ${ELASTIC_BACKUP_DIR}/* /tmp/'${ELASTIC_BACKUP}
  echo
  brlog "INFO" "Verifying backup..."
  if ! tar tf ${BACKUP_FILE} &> /dev/null ; then
    brlog "ERROR" "Backup file is broken, or does not exist."
    exit 1
  fi
  echo
  brlog "INFO" "Done: ${BACKUP_FILE}"
fi

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
  brlog "INFO" "Transferring archive..."
  kube_cp_from_local ${ELASTIC_POD} "${BACKUP_FILE}" "/tmp/${ELASTIC_BACKUP}" ${KUBECTL_ARGS}
  brlog "INFO" "Extracting archive..."
  kubectl ${KUBECTL_ARGS} exec ${ELASTIC_POD} -- bash -c 'cd ${ELASTIC_BACKUP_DIR} && \
  rm -rf ${ELASTIC_BACKUP_DIR}/* && \
  tar xf /tmp/'${ELASTIC_BACKUP}
  wait_cmd ${ELASTIC_POD} "tar xf /tmp" ${KUBECTL_ARGS}
  brlog "INFO" "Restoring snapshot..."
  kubectl ${KUBECTL_ARGS} exec ${ELASTIC_POD} -- bash -c 'if [[ ! -v ES_PORT ]] ; then if [ -d "/opt/tls/elastic" ] ; then export ES_PORT=9100 ; else export ES_PORT=9200 ; fi ; fi && \
  export ELASTIC_ENDPOINT="http://localhost:${ES_PORT}" && \
  cd ${ELASTIC_BACKUP_DIR} && \
  curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_cluster/settings" -H "Content-Type: application/json" -d"{\"transient\": {\"discovery.zen.commit_timeout\": \"'${ELASTIC_REQUEST_TIMEOUT}'\", \"discovery.zen.publish_timeout\": \"'${ELASTIC_REQUEST_TIMEOUT}'\"}}" && \
  curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_all?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" && \
  curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" -H "Content-Type: application/json" -d"{\"type\": \"fs\",\"settings\": {\"location\": \"${ELASTIC_BACKUP_DIR}\"}}" && \
  curl -XPOST -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "{$ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'/_restore?wait_for_completion=true&master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" -H "Content-Type: application/json" -d"{\"indices\": \"*,-application_logs-*\", \"expand_wildcards\": \"all\", \"allow_no_indices\": \"true\"}" && \
  curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" && \
  curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" && \
  curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_cluster/settings" -H "Content-Type: application/json" -d"{\"transient\": {\"discovery.zen.commit_timeout\": null, \"discovery.zen.publish_timeout\": null}}" && \
  rm -rf /tmp/'${ELASTIC_BACKUP}' ${ELASTIC_BACKUP_DIR}/*'
  wait_cmd ${ELASTIC_POD} "curl -XPUT" ${KUBECTL_ARGS}
  echo 
  brlog "INFO" "Restore Done"
  brlog "INFO" "Applying updates"
  . ./lib/restore-updates.bash
  elastic_updates
  brlog "INFO" "Completed Updates"
  echo
fi
