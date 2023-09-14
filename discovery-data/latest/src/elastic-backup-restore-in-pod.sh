#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
typeset -r SCRIPT_DIR

source "${SCRIPT_DIR}/lib/restore-updates.bash"
source "${SCRIPT_DIR}/lib/function.bash"

set -euo pipefail

COMMAND=$1
shift

ELASTIC_REPO="my_backup"
ELASTIC_SNAPSHOT="snapshot"
ELASTIC_SNAPSHOT_PATH="es_snapshots"
ELASTIC_BACKUP="elastic_snapshot.tar.gz"
ELASTIC_BACKUP_DIR="elastic_backup"
ELASTIC_BACKUP_BUCKET="elastic-backup"
ELASTIC_ENDPOINT="${ELASTIC_ENDPOINT:-https://localhost:9200}"
ELASTIC_REQUEST_TIMEOUT="30m"
TMP_WORK_DIR="/tmp/backup-restore-workspace"
CURRENT_COMPONENT="elastic"
ELASTIC_LOG="${TMP_WORK_DIR}/elastic.log"

export MINIO_CONFIG_DIR="${TMP_WORK_DIR}/.mc"
MC_OPTS=(--config-dir ${MINIO_CONFIG_DIR} --insecure)
MC_MIRROR_OPTS=()
if "${DISABLE_MC_MULTIPART:-true}" ; then
  MC_MIRROR_OPTS+=( "--disable-multipart" )
fi
MC=mc

if [ -n "${ELASTIC_ARCHIVE_OPTION}" ] ; then
  read -a ELASTIC_TAR_OPTIONS <<< ${ELASTIC_ARCHIVE_OPTION}
else
  ELASTIC_TAR_OPTIONS=("")
fi
VERIFY_DATASTORE_ARCHIVE=${VERIFY_DATASTORE_ARCHIVE:-true}


function clean_up(){
  if ! "${KEEP_SNAPSHOT:-false}" ; then
    brlog "INFO" "Start clean up"
    brlog "INFO" "Delete snapshot"
    curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/${ELASTIC_REPO}/${ELASTIC_SNAPSHOT}?master_timeout=${ELASTIC_REQUEST_TIMEOUT}" | grep "acknowledged" || true >> ${ELASTIC_LOG}
    retry_count=0
    while true;
      do
      if ! curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/${ELASTIC_REPO}?master_timeout=${ELASTIC_REQUEST_TIMEOUT}" | grep "acknowledged" >> ${ELASTIC_LOG} && [ $retry_count -lt 10 ]; then
        sleep 60
        retry_count=$((retry_count += 1))
      else
        break
      fi
    done
    curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_cluster/settings" -H "Content-Type: application/json" -d"{\"transient\": {\"discovery.zen.commit_timeout\": null, \"discovery.zen.publish_timeout\": null}}" >> ${ELASTIC_LOG}
    echo >> ${ELASTIC_LOG}

    brlog "INFO" "Clean up"
    ${MC} ${MC_OPTS[@]} rm --recursive --force --dangerous wdminio/${ELASTIC_BACKUP_BUCKET}/ > /dev/null
    echo
  fi
}

if [ "${COMMAND}" = "backup" ] ; then
  ${MC} ${MC_OPTS[@]} config host add wdminio ${S3_ENDPOINT_URL} ${S3_ACCESS_KEY} ${S3_SECRET_KEY} > /dev/null
  if [ -n "$(${MC} ${MC_OPTS[@]} ls wdminio/${ELASTIC_BACKUP_BUCKET}/)" ] ; then
    ${MC} ${MC_OPTS[@]} rm --recursive --force --dangerous wdminio/${ELASTIC_BACKUP_BUCKET}/ > /dev/null
  fi
  S3_IP=$(curl -kv "https://$S3_HOST:$S3_PORT/minio/health/ready" 2>&1 | grep Connected | sed -E "s/.*\(([0-9.]+)\).*/\1/g")
  curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/${ELASTIC_REPO}?master_timeout=${ELASTIC_REQUEST_TIMEOUT}" -H "Content-Type: application/json" -d"{\"type\":\"s3\",\"settings\":{\"bucket\":\"${S3_ELASTIC_BACKUP_BUCKET}\",\"region\":\"us-east-1\",\"protocol\":\"https\",\"endpoint\":\"https://${S3_IP}:${S3_PORT}\",\"base_path\":\"es_snapshots\",\"compress\":\"true\",\"server_side_encryption\":\"false\",\"storage_class\":\"reduced_redundancy\"}}" | grep acknowledged >> "${ELASTIC_LOG}"
  curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/${ELASTIC_REPO}/${ELASTIC_SNAPSHOT}?master_timeout=${ELASTIC_REQUEST_TIMEOUT}" -H "Content-Type: application/json" -d'{"indices": "*","ignore_unavailable": true,"include_global_state": false}' | grep accepted >> "${ELASTIC_LOG}"
  brlog "INFO" "Requested snapshot"
  while true;
  do
    snapshot_status=$(curl -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/${ELASTIC_REPO}/${ELASTIC_SNAPSHOT}" | jq -r ".snapshots[0].state")
    if [ "${snapshot_status}" = "SUCCESS" ] ; then
      brlog "INFO" "Snapshot successfully finished."
      curl -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/${ELASTIC_REPO}/${ELASTIC_SNAPSHOT}" | jq -r ".snapshots[0]"
      brlog "INFO" "Transferring snapshot from MinIO"
      while true;
      do
        cat << EOF >> "${ELASTIC_LOG}"
===================================================
${MC} ${MC_OPTS[@]} mirror wdminio/${ELASTIC_BACKUP_BUCKET} ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET}"
===================================================
EOF
        ${MC} "${MC_OPTS[@]}" mirror "${MC_MIRROR_OPTS[@]}" wdminio/${ELASTIC_BACKUP_BUCKET} ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET} &>> "${ELASTIC_LOG}"
        RC=$?
        echo "RC=${RC}" >> "${ELASTIC_LOG}"
        if [ $RC -eq 0 ] ; then
          break
        fi
        brlog "WARN" "Some file could not be transfered. Retrying..."
      done
      brlog "INFO" "Archiving sanpshot..."
      tar "${ELASTIC_TAR_OPTIONS[@]}" -cf ${ELASTIC_BACKUP} -C ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET}/${ELASTIC_SNAPSHOT_PATH} .
      rm -rf ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}
      break;
    elif [ "${snapshot_status}" = "FAILED" -o "${snapshot_status}" = "PARTIAL" ] ; then
      brlog "ERROR" "Snapshot failed"
      brlog "INFO" "$(curl -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/${ELASTIC_REPO}/${ELASTIC_SNAPSHOT}" | jq -r '.snapshots[0]')"
      break;
    else
      # comment out the progress because it shows always 0 until it complete.
      # brlog "INFO" "Progress: $(fetch_cmd_result ${ELASTIC_POD} 'curl -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'" | jq -c ".snapshots[0].shards"' ${OC_ARGS} -c elasticsearch)"
      sleep ${ELASTIC_STATUS_CHECK_INTERVAL}
    fi
  done
  brlog "INFO" "Clean up"
  curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/${ELASTIC_REPO}/${ELASTIC_SNAPSHOT}?master_timeout=${ELASTIC_REQUEST_TIMEOUT}" | grep "acknowledged" >> "${ELASTIC_LOG}" || true
  while ! curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/${ELASTIC_REPO}?master_timeout=${ELASTIC_REQUEST_TIMEOUT}" | grep "acknowledged" >> "${ELASTIC_LOG}" ; do sleep 30; done
  echo
  ${MC} "${MC_OPTS[@]}" rm --recursive --force --dangerous wdminio/${ELASTIC_BACKUP_BUCKET}/ > /dev/null

elif [ "${COMMAND}" = "restore" ] ; then
  if [ ! -e "${ELASTIC_BACKUP}" ] ; then
    brlog "WARN" "no such file: ${ELASTIC_BACKUP}"
    brlog "WARN" "Nothing to Restore"
    echo
    exit 1
  fi

  brlog "INFO" "Extracting Archive..."
  mkdir -p ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET}/${ELASTIC_SNAPSHOT_PATH}
  tar "${ELASTIC_TAR_OPTIONS[@]}" -xf ${ELASTIC_BACKUP} -C ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET}/${ELASTIC_SNAPSHOT_PATH}
  rm -f ${ELASTIC_BACKUP}
  brlog "INFO" "Transferring data to MinIO..."
  ${MC} "${MC_OPTS[@]}" config host add wdminio ${S3_ENDPOINT_URL} ${S3_ACCESS_KEY} ${S3_SECRET_KEY} > /dev/null
  if [ -n "$(${MC} "${MC_OPTS[@]}" ls wdminio/${ELASTIC_BACKUP_BUCKET}/)" ] ; then
    ${MC} "${MC_OPTS[@]}" rm --recursive --force --dangerous wdminio/${ELASTIC_BACKUP_BUCKET}/ > /dev/null
  fi
  while true;
  do
    cat << EOF >> "${ELASTIC_LOG}"
===================================================
${MC} ${MC_OPTS[@]} mirror --debug ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET} wdminio/${ELASTIC_BACKUP_BUCKET}
===================================================
EOF
    ${MC} "${MC_OPTS[@]}" mirror "${MC_MIRROR_OPTS[@]}" ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET} wdminio/${ELASTIC_BACKUP_BUCKET} &>> "${ELASTIC_LOG}"
    RC=$?
    echo "RC=${RC}" >> "${ELASTIC_LOG}"
    if [ $RC -eq 0 ] ; then
      break
    fi
    brlog "WARN" "Some file could not be transfered. Retrying..."
  done
  brlog "INFO" "Start Restoring snapshot"
  S3_IP=$(curl -kv "https://$S3_HOST:$S3_PORT/minio/health/ready" 2>&1 | grep Connected | sed -E "s/.*\(([0-9.]+)\).*/\1/g")
  curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_cluster/settings" -H "Content-Type: application/json" -d"{\"transient\": {\"discovery.zen.commit_timeout\": \"${ELASTIC_REQUEST_TIMEOUT}\", \"discovery.zen.publish_timeout\": \"${ELASTIC_REQUEST_TIMEOUT}\"}}" >> ${ELASTIC_LOG}
  curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_all?master_timeout=${ELASTIC_REQUEST_TIMEOUT}" | grep acknowledged >> ${ELASTIC_LOG}
  curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/.*?master_timeout=${ELASTIC_REQUEST_TIMEOUT}" | grep acknowledged >> ${ELASTIC_LOG}
  curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/${ELASTIC_REPO}?master_timeout=${ELASTIC_REQUEST_TIMEOUT}" -H "Content-Type: application/json" -d"{\"type\":\"s3\",\"settings\":{\"bucket\":\"${S3_ELASTIC_BACKUP_BUCKET}\",\"region\":\"us-east-1\",\"protocol\":\"https\",\"endpoint\":\"https://${S3_IP}:${S3_PORT}\",\"base_path\":\"es_snapshots\",\"compress\":\"true\",\"server_side_encryption\":\"false\",\"storage_class\":\"reduced_redundancy\"}}" | grep acknowledged >> ${ELASTIC_LOG}
  curl -XPOST -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/${ELASTIC_REPO}/${ELASTIC_SNAPSHOT}/_restore?master_timeout=${ELASTIC_REQUEST_TIMEOUT}" -H "Content-Type: application/json" -d"{\"indices\": \"*,-application_logs-*\", \"expand_wildcards\": \"all\", \"allow_no_indices\": \"true\"}" | grep accepted >> ${ELASTIC_LOG}
  echo >> ${ELASTIC_LOG}
  brlog "INFO" "Sent restore request"
  total_shards=0
  waited_seconds=0
  while true;
  do
    recovery_status=$(curl -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_recovery")
    brlog "DEBUG" "Recovery status: ${recovery_status}"
    if [ "${recovery_status}" != "{}" ] ; then
      tmp_total_shards=$(echo "${recovery_status}" | jq ".[].shards[]" | jq -s ". | length")
      if [ ${total_shards} -ge ${tmp_total_shards} ] && [ ${tmp_total_shards} -ne 0 ]; then
        break
      else
        total_shards=${tmp_total_shards}
      fi
    else
      waited_seconds=$((waited_seconds += ELASTIC_STATUS_CHECK_INTERVAL))
      if [ ${waited_seconds} -ge ${ELASTIC_MAX_WAIT_RECOVERY_SECONDS} ] ; then
        brlog "ERROR" "There is no recovery status in ${ELASTIC_MAX_WAIT_RECOVERY_SECONDS} seconds. Please contact support."
        clean_up
        cat "${ELASTIC_LOG}"
        exit 1
      else
        brlog "WARN" "Empty status. Check status after ${ELASTIC_STATUS_CHECK_INTERVAL} seconds."
      fi
    fi
    sleep ${ELASTIC_STATUS_CHECK_INTERVAL}
  done
  brlog "INFO" "Total shards in snapshot: ${total_shards}"
  while true;
  do
    done_count=$(curl -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_recovery" | jq '.[].shards[] | select(.stage == "DONE")' | jq -s ". | length")
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
    cluster_status=$(fetch_cmd_result ${ELASTIC_POD} 'curl -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_cluster/health" | jq -r ".status"' ${OC_ARGS} -c elasticsearch)
    do
      if [ "${cluster_status}" = "green" ] ; then
        break;
      fi
      sleep ${ELASTIC_STATUS_CHECK_INTERVAL}
    done
  fi

  clean_up

  cat "${ELASTIC_LOG}"
fi