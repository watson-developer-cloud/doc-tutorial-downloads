#!/bin/bash

set -euo pipefail

ROOT_DIR_ELASTIC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
typeset -r ROOT_DIR_ELASTIC

# shellcheck source=lib/restore-utilites.bash
source "${ROOT_DIR_ELASTIC}/lib/restore-updates.bash"
source "${ROOT_DIR_ELASTIC}/lib/function.bash"

KUBECTL_ARGS=""
ELASTIC_REPO="my_backup"
ELASTIC_SNAPSHOT="snapshot"
ELASTIC_SNAPSHOT_PATH="es_snapshots"
ELASTIC_BACKUP="elastic_snapshot.tar.gz"
ELASTIC_BACKUP_DIR="elastic_backup"
ELASTIC_BACKUP_BUCKET="elastic-backup"
ELASTIC_REQUEST_TIMEOUT="30m"
TMP_WORK_DIR="tmp/elastic_workspace"
MINIO_SCRIPTS=${ROOT_DIR_ELASTIC}/minio-backup-restore.sh
MINIO_RELEASE_NAME=crust
MINIO_FORWARD_PORT=${MINIO_FORWARD_PORT:-39001}
SCRIPT_DIR=${ROOT_DIR_ELASTIC}
DATASTORE_ARCHIVE_OPTION="${DATASTORE_ARCHIVE_OPTION--z}"
ELASTIC_ARCHIVE_OPTION="${ELASTIC_ARCHIVE_OPTION-$DATASTORE_ARCHIVE_OPTION}"
if [ -n "${ELASTIC_ARCHIVE_OPTION}" ] ; then
  read -a ELASTIC_TAR_OPTIONS <<< ${ELASTIC_ARCHIVE_OPTION}
else
  ELASTIC_TAR_OPTIONS=("")
fi
VERIFY_ARCHIVE=${VERIFY_ARCHIVE:-true}
VERIFY_DATASTORE_ARCHIVE=${VERIFY_DATASTORE_ARCHIVE:-$VERIFY_ARCHIVE}

printUsage() {
  echo "Usage: $(basename ${0}) [command] [releaseName] [-f backupFile]"
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

MINIO_SVC=`kubectl ${KUBECTL_ARGS} get svc -l release=${MINIO_RELEASE_NAME},helm.sh/chart=minio -o jsonpath="{.items[*].metadata.name}" | tr '[[:space:]]' '\n' | grep headless`
MINIO_PORT=`kubectl ${KUBECTL_ARGS} get svc ${MINIO_SVC} -o jsonpath="{.spec.ports[0].port}"`
MINIO_SECRET=`kubectl ${KUBECTL_ARGS} get secret -l release=${MINIO_RELEASE_NAME} -o jsonpath="{.items[*].metadata.name}" | tr -s '[[:space:]]' '\n' | grep minio`
MINIO_ACCESS_KEY=`kubectl get ${KUBECTL_ARGS} secret ${MINIO_SECRET} --template '{{.data.accesskey}}' | base64 --decode`
MINIO_SECRET_KEY=`kubectl get ${KUBECTL_ARGS} secret ${MINIO_SECRET} --template '{{.data.secretkey}}' | base64 --decode`
MINIO_ENDPOINT_URL=${MINIO_ENDPOINT_URL:-https://localhost:$MINIO_FORWARD_PORT}

rm -rf ${TMP_WORK_DIR}
mkdir -p ${TMP_WORK_DIR}/.mc
if [ -n "${MC_COMMAND+UNDEF}" ] ; then
  MC=${MC_COMMAND}
else
  get_mc ${TMP_WORK_DIR}
  MC=${TMP_WORK_DIR}/mc
fi
export MINIO_CONFIG_DIR="${PWD}/${TMP_WORK_DIR}/.mc"
MC_OPTS=(--config-dir ${MINIO_CONFIG_DIR} --quiet --insecure)

# backup elastic search
if [ ${COMMAND} = 'backup' ] ; then
  BACKUP_FILE=${BACKUP_FILE:-"elastic_`date "+%Y%m%d_%H%M%S"`.snapshot"}
  brlog "INFO" "Start backup elasticsearch..."
  mkdir -p ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}
  start_minio_port_forward
  ${MC} ${MC_OPTS[@]} config host add wdminio ${MINIO_ENDPOINT_URL} ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} > /dev/null
  ${MC} ${MC_OPTS[@]} rm --recursive --force --dangerous wdminio/${ELASTIC_BACKUP_BUCKET}/ > /dev/null
  stop_minio_port_forward
  brlog "INFO" "Taking snapshot..."
  kubectl exec ${ELASTIC_POD} ${KUBECTL_ARGS} --  bash -c 'if [[ ! -v ES_PORT ]] ; then if [ -d "/opt/tls/elastic" ] ; then export ES_PORT=9100 ; else export ES_PORT=9200 ; fi ; fi && \
  export ELASTIC_ENDPOINT="http://localhost:${ES_PORT}" && \
  S3_IP=`curl -kv "https://$S3_HOST:$S3_PORT/minio/health/ready" 2>&1 | grep Connected | sed -E "s/.*\(([0-9.]+)\).*/\1/g"` && \
  curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" -H "Content-Type: application/json" -d"{\"type\":\"s3\",\"settings\":{\"bucket\":\"${S3_ELASTIC_BACKUP_BUCKET}\",\"region\":\"us-east-1\",\"protocol\":\"https\",\"endpoint\":\"https://${S3_IP}:${S3_PORT}\",\"base_path\":\"es_snapshots\",\"compress\":\"true\",\"server_side_encryption\":\"false\",\"storage_class\":\"reduced_redundancy\"}}" && \
  curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'?wait_for_completion=true&master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" -H "Content-Type: application/json" -d'"'"'{"indices": "*","ignore_unavailable": true,"include_global_state": false}'"'"
  wait_cmd ${ELASTIC_POD} "curl -XPUT -s -k -u" ${KUBECTL_ARGS}
  echo
  brlog "INFO" "Transferring snapshot from MinIO"
  start_minio_port_forward
  ${MC} ${MC_OPTS[@]} mirror wdminio/${ELASTIC_BACKUP_BUCKET} ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET} > /dev/null
  stop_minio_port_forward
  brlog "INFO" "Archiving sanpshot..."
  tar ${ELASTIC_TAR_OPTIONS[@]} -cf ${BACKUP_FILE} -C ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET}/${ELASTIC_SNAPSHOT_PATH} .
  brlog "INFO" "Clean up"
  kubectl exec ${ELASTIC_POD} ${KUBECTL_ARGS} --  bash -c 'if [[ ! -v ES_PORT ]] ; then if [ -d "/opt/tls/elastic" ] ; then export ES_PORT=9100 ; else export ES_PORT=9200 ; fi ; fi && \
  export ELASTIC_ENDPOINT="http://localhost:${ES_PORT}" && \
  curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" && \
  curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'"'
  wait_cmd ${ELASTIC_POD} "curl -XDELETE -s -k -u" ${KUBECTL_ARGS}
  echo
  start_minio_port_forward
  ${MC} ${MC_OPTS[@]} rm --recursive --force --dangerous wdminio/${ELASTIC_BACKUP_BUCKET}/ > /dev/null
  stop_minio_port_forward
  if "${VERIFY_DATASTORE_ARCHIVE}" && brlog "INFO" "Verifying backup archive" && ! tar ${ELASTIC_TAR_OPTIONS[@]} -tf ${BACKUP_FILE} &> /dev/null ; then
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

  ELASTIC_CLIENT_TYPE="sts"
  ELASTIC_RESOURCE=`kubectl get ${ELASTIC_CLIENT_TYPE} ${KUBECTL_ARGS} -o jsonpath="{.items[0].metadata.name}" -l release=${RELEASE_NAME},helm.sh/chart=elastic,role=client`
  ELASTIC_REPLICAS=`kubectl get ${ELASTIC_CLIENT_TYPE} ${KUBECTL_ARGS} -o jsonpath='{.items[0].spec.replicas}' -l release=${RELEASE_NAME},helm.sh/chart=elastic,role=client`

  brlog "INFO" "Extracting Archive..."
  mkdir -p ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET}/${ELASTIC_SNAPSHOT_PATH}
  tar ${ELASTIC_TAR_OPTIONS[@]} -xf ${BACKUP_FILE} -C ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET}/${ELASTIC_SNAPSHOT_PATH}
  brlog "INFO" "Transferring data to MinIO..."
  start_minio_port_forward
  ${MC} ${MC_OPTS[@]} config host add wdminio ${MINIO_ENDPOINT_URL} ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} > /dev/null
  ${MC} ${MC_OPTS[@]} rm --recursive --force --dangerous wdminio/${ELASTIC_BACKUP_BUCKET}/ > /dev/null
  ${MC} ${MC_OPTS[@]} mirror ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET} wdminio/${ELASTIC_BACKUP_BUCKET} > /dev/null
  stop_minio_port_forward

  scale_resource ${ELASTIC_CLIENT_TYPE} ${ELASTIC_RESOURCE} 0 true
  trap "scale_resource ${ELASTIC_CLIENT_TYPE} ${ELASTIC_RESOURCE} ${ELASTIC_REPLICAS} false"  0 1 2 3 15

  brlog "INFO" "Restoring snapshot..."
  kubectl ${KUBECTL_ARGS} exec ${ELASTIC_POD} -- bash -c 'if [[ ! -v ES_PORT ]] ; then if [ -d "/opt/tls/elastic" ] ; then export ES_PORT=9100 ; else export ES_PORT=9200 ; fi ; fi && \
  export ELASTIC_ENDPOINT="http://localhost:${ES_PORT}" && \
  S3_IP=`curl -kv "https://$S3_HOST:$S3_PORT/minio/health/ready" 2>&1 | grep Connected | sed -E "s/.*\(([0-9.]+)\).*/\1/g"` && \
  curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_cluster/settings" -H "Content-Type: application/json" -d"{\"transient\": {\"discovery.zen.commit_timeout\": \"'${ELASTIC_REQUEST_TIMEOUT}'\", \"discovery.zen.publish_timeout\": \"'${ELASTIC_REQUEST_TIMEOUT}'\"}}" && \
  curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_all?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" && \
  curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" -H "Content-Type: application/json" -d"{\"type\":\"s3\",\"settings\":{\"bucket\":\"${S3_ELASTIC_BACKUP_BUCKET}\",\"region\":\"us-east-1\",\"protocol\":\"https\",\"endpoint\":\"https://${S3_IP}:${S3_PORT}\",\"base_path\":\"es_snapshots\",\"compress\":\"true\",\"server_side_encryption\":\"false\",\"storage_class\":\"reduced_redundancy\"}}" && \
  curl -XPOST -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "{$ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'/_restore?wait_for_completion=true&master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" -H "Content-Type: application/json" -d"{\"indices\": \"*,-application_logs-*\", \"expand_wildcards\": \"all\", \"allow_no_indices\": \"true\"}" && \
  curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" && \
  curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" && \
  curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_cluster/settings" -H "Content-Type: application/json" -d"{\"transient\": {\"discovery.zen.commit_timeout\": null, \"discovery.zen.publish_timeout\": null}}"'
  wait_cmd ${ELASTIC_POD} "curl -X" ${KUBECTL_ARGS}
  echo

  scale_resource ${ELASTIC_CLIENT_TYPE} ${ELASTIC_RESOURCE} ${ELASTIC_REPLICAS} false
  trap 0 1 2 3 15

  brlog "INFO" "Clean up"
  start_minio_port_forward
  ${MC} ${MC_OPTS[@]} rm --recursive --force --dangerous wdminio/${ELASTIC_BACKUP_BUCKET}/ > /dev/null
  stop_minio_port_forward
  echo 
  brlog "INFO" "Restore Done"
  brlog "INFO" "Applying updates"
  . ./lib/restore-updates.bash
  elastic_updates
  brlog "INFO" "Completed Updates"
  echo
fi

rm -rf ${TMP_WORK_DIR}
if [ -z "$(ls tmp)" ] ; then
  rm -rf tmp
fi