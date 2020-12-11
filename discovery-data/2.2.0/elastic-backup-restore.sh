#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
typeset -r SCRIPT_DIR

# shellcheck source=lib/restore-utilites.bash
source "${SCRIPT_DIR}/lib/restore-updates.bash"
source "${SCRIPT_DIR}/lib/function.bash"

OC_ARGS="${OC_ARGS:-}"
ELASTIC_REPO="my_backup"
ELASTIC_SNAPSHOT="snapshot"
ELASTIC_SNAPSHOT_PATH="es_snapshots"
ELASTIC_BACKUP="elastic_snapshot.tar.gz"
ELASTIC_BACKUP_DIR="elastic_backup"
ELASTIC_BACKUP_BUCKET="elastic-backup"
ELASTIC_REQUEST_TIMEOUT="30m"
ELASTIC_STATUS_CHECK_INTERVAL=${ELASTIC_STATUS_CHECK_INTERVAL:-60}
ELASTIC_WAIT_GREEN_STATE=${ELASTIC_WAIT_GREEN_STATE:-"false"}
TMP_WORK_DIR="tmp/elastic_workspace"
MINIO_SCRIPTS=${SCRIPT_DIR}/minio-backup-restore.sh
MINIO_FORWARD_PORT=${MINIO_FORWARD_PORT:-39001}

printUsage() {
  echo "Usage: $(basename ${0}) [command] [releaseName] [-f backupFile]"
  exit 1
}

if [ $# -lt 2 ] ; then
  printUsage
fi

COMMAND=$1
shift
TENANT_NAME=$1
shift
while getopts f:n: OPT
do
  case $OPT in
    "f" ) BACKUP_FILE="$OPTARG" ;;
    "n" ) OC_ARGS="${OC_ARGS} --namespace=$OPTARG" ;;
  esac
done

brlog "INFO" "Elastic: "
brlog "INFO" "Tenant name: $TENANT_NAME"

ELASTIC_POD=`oc get pods ${OC_ARGS} -o jsonpath="{.items[0].metadata.name}" -l tenant=${TENANT_NAME},app=elastic,ibm-es-data=True`

MINIO_SVC=`oc ${OC_ARGS} get svc -l release=${TENANT_NAME}-minio,helm.sh/chart=ibm-minio -o jsonpath="{.items[*].metadata.name}" | tr '[[:space:]]' '\n' | grep headless`
MINIO_PORT=`oc ${OC_ARGS} get svc ${MINIO_SVC} -o jsonpath="{.spec.ports[0].port}"`
MINIO_SECRET=`oc ${OC_ARGS} get secret -l tenant=${TENANT_NAME},run=minio-auth -o jsonpath="{.items[*].metadata.name}" | tr -s '[[:space:]]' '\n' | grep minio`
MINIO_ACCESS_KEY=`oc get ${OC_ARGS} secret ${MINIO_SECRET} --template '{{.data.accesskey}}' | base64 --decode`
MINIO_SECRET_KEY=`oc get ${OC_ARGS} secret ${MINIO_SECRET} --template '{{.data.secretkey}}' | base64 --decode`
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
  BACKUP_SCRIPTS="elastic_backup.sh"
  brlog "INFO" "Start backup elasticsearch..."
  mkdir -p ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}
  start_minio_port_forward
  ${MC} ${MC_OPTS[@]} config host add wdminio ${MINIO_ENDPOINT_URL} ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} > /dev/null
  ${MC} ${MC_OPTS[@]} rm --recursive --force --dangerous wdminio/${ELASTIC_BACKUP_BUCKET}/ > /dev/null
  stop_minio_port_forward
  brlog "INFO" "Taking snapshot..."
  run_cmd_in_pod ${ELASTIC_POD} 'S3_IP=`curl -kv "https://$S3_HOST:$S3_PORT/minio/health/ready" 2>&1 | grep Connected | sed -E "s/.*\(([0-9.]+)\).*/\1/g"` && \
  curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" -H "Content-Type: application/json" -d"{\"type\":\"s3\",\"settings\":{\"bucket\":\"${S3_ELASTIC_BACKUP_BUCKET}\",\"region\":\"us-east-1\",\"protocol\":\"https\",\"endpoint\":\"https://${S3_IP}:${S3_PORT}\",\"base_path\":\"es_snapshots\",\"compress\":\"true\",\"server_side_encryption\":\"false\",\"storage_class\":\"reduced_redundancy\"}}" | grep acknowledged && \
  curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" -H "Content-Type: application/json" -d'"'"'{"indices": "*","ignore_unavailable": true,"include_global_state": false}'"'"' | grep accepted && echo' ${OC_ARGS} -c elasticsearch
  brlog "INFO" "Requested snapshot"
  while true;
  do
    snapshot_status=`fetch_cmd_result ${ELASTIC_POD} 'curl -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'" | jq -r ".snapshots[0].state"' ${OC_ARGS} -c elasticsearch`
    if [ "${snapshot_status}" = "SUCCESS" ] ; then
      brlog "INFO" "Snapshot successfully finished."
      brlog "INFO" "`fetch_cmd_result ${ELASTIC_POD} 'curl -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'" | jq -r ".snapshots[0]"' ${OC_ARGS} -c elasticsearch`"
      brlog "INFO" "Transfering snapshot from MinIO"
      start_minio_port_forward
      ${MC} ${MC_OPTS[@]} mirror wdminio/${ELASTIC_BACKUP_BUCKET} ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET} > /dev/null
      stop_minio_port_forward
      brlog "INFO" "Archiving sanpshot..."
      tar zcf ${BACKUP_FILE} -C ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET}/${ELASTIC_SNAPSHOT_PATH} .
      break;
    elif [ "${snapshot_status}" = "FAILED" -o "${snapshot_status}" = "PARTIAL" ] ; then
      brlog "ERROR" "Snapshot failed"
      brlog "INFO" "`fetch_cmd_result ${ELASTIC_POD} 'curl -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'" | jq -r ".snapshots[0]"' ${OC_ARGS} -c elasticsearch`"
      break;
    else
      # comment out the progress because it shows always 0 until it complete.
      # brlog "INFO" "Progress: `fetch_cmd_result ${ELASTIC_POD} 'curl -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'" | jq -c ".snapshots[0].shards"' ${OC_ARGS} -c elasticsearch`"
      sleep ${ELASTIC_STATUS_CHECK_INTERVAL}
    fi
  done
  brlog "INFO" "Clean up"
  run_cmd_in_pod ${ELASTIC_POD} 'curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" | grep "acknowledged" || true && \
  while ! curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" | grep "acknowledged" ; do sleep 30; done' ${OC_ARGS} -c elasticsearch
  echo
  start_minio_port_forward
  ${MC} ${MC_OPTS[@]} rm --recursive --force --dangerous wdminio/${ELASTIC_BACKUP_BUCKET}/ > /dev/null
  stop_minio_port_forward
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

  brlog "INFO" "Extracting Archive..."
  mkdir -p ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET}/${ELASTIC_SNAPSHOT_PATH}
  tar xf ${BACKUP_FILE} -C ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET}/${ELASTIC_SNAPSHOT_PATH}
  brlog "INFO" "Transfering data to MinIO..."
  start_minio_port_forward
  ${MC} ${MC_OPTS[@]} config host add wdminio ${MINIO_ENDPOINT_URL} ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} > /dev/null
  if [ -n "`${MC} ${MC_OPTS[@]} ls wdminio/${ELASTIC_BACKUP_BUCKET}/`" ] ; then
    ${MC} ${MC_OPTS[@]} rm --recursive --force --dangerous wdminio/${ELASTIC_BACKUP_BUCKET}/ > /dev/null
  fi
  ${MC} ${MC_OPTS[@]} mirror ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET} wdminio/${ELASTIC_BACKUP_BUCKET} > /dev/null
  stop_minio_port_forward

  brlog "INFO" "Start Restoring snapshot"
  run_cmd_in_pod ${ELASTIC_POD} 'S3_IP=`curl -kv "https://$S3_HOST:$S3_PORT/minio/health/ready" 2>&1 | grep Connected | sed -E "s/.*\(([0-9.]+)\).*/\1/g"` && \
  curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_cluster/settings" -H "Content-Type: application/json" -d"{\"transient\": {\"discovery.zen.commit_timeout\": \"'${ELASTIC_REQUEST_TIMEOUT}'\", \"discovery.zen.publish_timeout\": \"'${ELASTIC_REQUEST_TIMEOUT}'\"}}" && \
  curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_all?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" | grep acknowledged && \
  curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/.*?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" | grep acknowledged && \
  curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" -H "Content-Type: application/json" -d"{\"type\":\"s3\",\"settings\":{\"bucket\":\"${S3_ELASTIC_BACKUP_BUCKET}\",\"region\":\"us-east-1\",\"protocol\":\"https\",\"endpoint\":\"https://${S3_IP}:${S3_PORT}\",\"base_path\":\"es_snapshots\",\"compress\":\"true\",\"server_side_encryption\":\"false\",\"storage_class\":\"reduced_redundancy\"}}" | grep acknowledged && \
  curl -XPOST -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'/_restore?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" -H "Content-Type: application/json" -d"{\"indices\": \"*,-application_logs-*\", \"expand_wildcards\": \"all\", \"allow_no_indices\": \"true\"}" | grep accepted && echo ' ${OC_ARGS} -c elasticsearch
  brlog "INFO" "Sent restore request"
  sleep ${ELASTIC_STATUS_CHECK_INTERVAL}
  total_shards=`fetch_cmd_result ${ELASTIC_POD} 'curl -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_recovery" | jq ".[].shards[]" | jq -s ". | length"' ${OC_ARGS} -c elasticsearch`
  brlog "INFO" "Total shards in snapshot: ${total_shards}"
  while true;
  do
    done_count=`fetch_cmd_result ${ELASTIC_POD} 'curl -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_recovery" | jq '"'"'.[].shards[] | select(.stage == "DONE")'"'"' | jq -s ". | length"' ${OC_ARGS} -c elasticsearch`
    brlog "INFO" "${done_count} shards finished"
    if [ ${done_count} -ge ${total_shards} ] ; then
      break
    fi
    sleep ${ELASTIC_STATUS_CHECK_INTERVAL}
  done
  brlog "INFO" "The all primary shards have been restored. Replication will be performed."
  if [ "${ELASTIC_WAIT_GREEN_STATE}" = "true" ] ; then
    brlog "INFO" "Wait for the ElasticSearch to be Green State"
    while true;
    cluster_status=`fetch_cmd_result ${ELASTIC_POD} 'curl -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_cluster/health" | jq -r ".status"' ${OC_ARGS} -c elasticsearch`
    do
      if [ "${cluster_status}" = "green" ] ; then
        break;
      fi
      sleep ${ELASTIC_STATUS_CHECK_INTERVAL}
    done
  fi
  brlog "INFO" "Delete snapshot"
  run_cmd_in_pod ${ELASTIC_POD} 'curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" | grep "acknowledged" || true && \
  while ! curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" | grep "acknowledged" ; do sleep 30; done && \
  curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_cluster/settings" -H "Content-Type: application/json" -d"{\"transient\": {\"discovery.zen.commit_timeout\": null, \"discovery.zen.publish_timeout\": null}}"' ${OC_ARGS} -c elasticsearch
  echo

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