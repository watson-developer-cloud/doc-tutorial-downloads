#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
typeset -r SCRIPT_DIR

# shellcheck source=lib/restore-utilites.bash
source "${SCRIPT_DIR}/lib/restore-updates.bash"
source "${SCRIPT_DIR}/lib/function.bash"

OC_ARGS="${OC_ARGS:-}"
ELASTIC_REPO=$(get_elastic_repo)
ELASTIC_REPO_LOCATION=$(get_elastic_repo_location)
ELASTIC_SNAPSHOT="snapshot"
ELASTIC_SNAPSHOT_PATH="es_snapshots"
ELASTIC_BACKUP="elastic_snapshot.tar.gz"
ELASTIC_BACKUP_DIR="elastic_backup"
ELASTIC_REQUEST_TIMEOUT="30m"
ELASTIC_STATUS_CHECK_INTERVAL=${ELASTIC_STATUS_CHECK_INTERVAL:-300}
ELASTIC_MAX_WAIT_RECOVERY_SECONDS=${ELASTIC_MAX_WAIT_RECOVERY_SECONDS:-3600}
ELASTIC_WAIT_GREEN_STATE=${ELASTIC_WAIT_GREEN_STATE:-"false"}
ELASTIC_JOB_FILE="${SCRIPT_DIR}/src/elastic-backup-restore-job.yml"
BACKUP_RESTORE_IN_POD=${BACKUP_RESTORE_IN_POD-false}
TMP_WORK_DIR="tmp/elastic_workspace"
CURRENT_COMPONENT="elastic"
S3_FORWARD_PORT=${S3_FORWARD_PORT:-39001}
DISABLE_MC_MULTIPART=${DISABLE_MC_MULTIPART:-true}
KEEP_SNAPSHOT=${KEEP_SNAPSHOT:-false}

printUsage() {
  echo "Usage: $(basename ${0}) [command] [releaseName] [-f backupFile]"
  exit 1
}

get_recovery_status(){
  fetch_cmd_result ${ELASTIC_POD} 'rm -f /tmp/recovery_status.json && export ELASTIC_ENDPOINT=https://localhost:9200 && curl -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_recovery" > /tmp/recovery_status.json && cat /tmp/recovery_status.json' ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}"
}

# Applies to: 4.7.0 <= WD_VERSION < 5.2.0.
mount_pvc_to_elasitc() {
  # Create shared PVC named as ELASTIC_SHARED_PVC if it's not defined or created
  create_elastic_shared_pvc
  # Mount the shared volume
  oc ${OC_ARGS} patch wd "${TENANT_NAME}" --type merge --patch "{\"spec\": {\"elasticsearch\": {\"sharedStoragePvc\": \"${ELASTIC_SHARED_PVC}\"}}}"
  ELASTIC_DATA_STS=$(oc ${OC_ARGS} get sts -l "icpdsupport/addOnId=discovery,icpdsupport/app=elastic,tenant=${TENANT_NAME},ibm-es-data=True" -o jsonpath='{.items[*].metadata.name}')
  while :
  do
    test -n "$(oc ${OC_ARGS} get sts ${ELASTIC_DATA_STS} -o jsonpath="{..volumes[?(@.persistentVolumeClaim.claimName==\"${ELASTIC_SHARED_PVC}\")]}")" && break
    brlog "INFO" "Wait for ElasticSearch to mount shared PVC"
    sleep 30
  done

  # Scaling down elastic search operator to edit configmap of Elastic
  brlog "INFO" "Scale down ElasticSearch operator"
  ELASTIC_VERSION=$(oc ${OC_ARGS} get elasticsearchcluster "${TENANT_NAME}" -o jsonpath='{.status.version}')
  ELASTIC_OPERATOR_DEPLOY=( $(oc get deploy -A -l "olm.owner=ibm-elasticsearch-operator.v${ELASTIC_VERSION}" | tail -n1 | awk '{print $1,$2}') )
  oc ${OC_ARGS} scale deploy -n "${ELASTIC_OPERATOR_DEPLOY[0]}" "${ELASTIC_OPERATOR_DEPLOY[1]}" --replicas=0
  trap_add "oc ${OC_ARGS} scale deploy -n ${ELASTIC_OPERATOR_DEPLOY[0]} ${ELASTIC_OPERATOR_DEPLOY[1]} --replicas=1"
  sleep 30

  # Update configmap
  brlog "INFO" "Update ConfigMap for ElastisSearch configuration"
  oc ${OC_ARGS} rollout status sts "${ELASTIC_DATA_STS}"
  for cm in $(oc ${OC_ARGS} get cm -l "icpdsupport/addOnId=discovery,icpdsupport/app=elastic,tenant=${TENANT_NAME}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -v "cpdbr")
  do
    update_elastic_configmap "${cm}"
  done

  # Restart elasticsearch resources to apply the configuration
  brlog "INFO" "Restart Statefulset"
  for sts in $(oc ${OC_ARGS} get sts -l "icpdsupport/addOnId=discovery,icpdsupport/app=elastic,tenant=${TENANT_NAME}" -o jsonpath='{.items[*].metadata.name}')
  do
    oc ${OC_ARGS} rollout restart sts "${sts}"
  done
  for sts in $(oc ${OC_ARGS} get sts -l "icpdsupport/addOnId=discovery,icpdsupport/app=elastic,tenant=${TENANT_NAME}" -o jsonpath='{.items[*].metadata.name}')
  do
    oc ${OC_ARGS} rollout status sts "${sts}"
  done

  # Wait for elasticsearch to be ready
  while :
  do
    check_elastic_available && break
    brlog "INFO" "Wait for ElasticSearhch to be ready"
    sleep 30
  done
}

delete_snapshot() {
  local snapshot="$1"
  brlog "DEBUG" "Delete snapshot: ${snapshot}"
  cmd='curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${snapshot}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'"'
  run_cmd_in_pod ${ELASTIC_POD} "${cmd}" ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}"
  snapshot_delete_result=$(get_last_cmd_result_in_pod)
  brlog "DEBUG" "snapshot_delete_result: ${snapshot_delete_result}"
  if ! echo "${snapshot_delete_result}" | grep -Eq "acknowledged|snapshot_missing_exception|repository_missing_exception"; then
    brlog "ERROR" "Could not delete the snapshot ${snapshot}"
    exit 1
  fi
}

delete_all_snapshots() {
  brlog "DEBUG" "Delete existing snapshots under ${ELASTIC_REPO} repository"
  cmd='curl -X GET -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_cat/snapshots/'${ELASTIC_REPO}'?h=status,id&s=end_epoch" | awk '\''{ print $2 }'\'''
  run_cmd_in_pod ${ELASTIC_POD} "${cmd}" ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}"
  old_snapshots=$(get_last_cmd_result_in_pod)
  if echo "${old_snapshots}" | grep -q "repository_missing_exception"; then
    brlog "WARN" "Repository ${ELASTIC_REPO} is missing"
    return
  fi 
  for old_snapshot in $old_snapshots
  do
    delete_snapshot "${old_snapshot}"
    sleep 10
  done
  brlog "DEBUG" "Deleted all existing snapshots"
}

reset_repo() {
  # Clean up the shared storage, which stores the snapshot files.
  brlog "DEBUG" "Reset the snapshot repository"
  brlog "DEBUG" "ELASTIC_REPO_LOCATION: $ELASTIC_REPO_LOCATION"

  # Clean up existing snapshots and related files.
  delete_all_snapshots
  run_cmd_in_pod ${ELASTIC_POD} "rm -rf ${ELASTIC_REPO_LOCATION}/*" ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}"
  
  if [ $(compare_version ${WD_VERSION} "5.2.0") -ge 0 ]; then
    # Delete repo.
    cmd='curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} ${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}''
    run_cmd_in_pod ${ELASTIC_POD} "${cmd}" ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}"
    result=$(get_last_cmd_result_in_pod)
    brlog "DEBUG" "Delete repo result: ${result}"
    if ! echo "${result}" | grep -Eq "acknowledged|repository_missing_exception"; then
      brlog "ERROR" "Could not delete the existing repository. Check the cluster status, and if the problem persist please contact support."
      clean_up
      exit 1
    fi
    # Add repo.
    cmd='curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} \
      ${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}' \
      -H "Content-Type: application/json" -d"{\"type\": \"fs\",\"settings\": {\"location\": \"'${ELASTIC_REPO_LOCATION}'\"}}"'
    run_cmd_in_pod ${ELASTIC_POD} "${cmd}" ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}"
    result=$(get_last_cmd_result_in_pod)
    brlog "DEBUG" "Add repo result: ${result}"
    if ! echo "${result}" | grep -q "acknowledged"; then
      brlog "ERROR" "Could not create the repository. Check the cluster status, and if the problem persist please contact support."
      clean_up
      exit 1
    fi
  fi
}

take_snapshot() {
  elastic_env_variables=""
  if [ $(compare_version ${WD_VERSION} "5.2.0") -lt 0 ]; then
    elastic_env_variables+='export S3_HOST='${S3_SVC}' && \
      export S3_PORT='${S3_PORT}' && \
      export S3_ELASTIC_BACKUP_BUCKET='${ELASTIC_BACKUP_BUCKET}' && \
      export ELASTIC_ENDPOINT=https://localhost:9200 && \
      S3_IP=$(curl -kv "https://$S3_HOST:$S3_PORT/minio/health/ready" 2>&1 | grep Connected | sed -E "s/.*\(([0-9.]+)\).*/\1/g") '
  fi

  brlog "INFO" "Adding repository to store the snapshot"
  add_repo_cmd="${elastic_env_variables:-true}"
  add_repo_cmd+='&& curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} \
    "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" \
    -H "Content-Type: application/json" '${REPO_CONFIGURATION}''
  run_cmd_in_pod ${ELASTIC_POD} "${add_repo_cmd}" ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}"
  result=$(get_last_cmd_result_in_pod)
  brlog "DEBUG" "Create repo request result: ${result}"
  if ! echo "${result}" | grep -q "acknowledged"; then
    brlog "ERROR" "Could not create the repository. Check the cluster status, and if the problem persist please contact support."
    clean_up
    exit 1
  fi

  brlog "INFO" "Taking snapshot"
  request_snapshot_cmd="${elastic_env_variables:-true}"
  request_snapshot_cmd+='&& curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} \
    "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" \
    -H "Content-Type: application/json" -d'"'"'{"indices": "*","ignore_unavailable": true,"include_global_state": false}'"'"' '
  run_cmd_in_pod ${ELASTIC_POD} "${request_snapshot_cmd}" ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}"
  result=$(get_last_cmd_result_in_pod)
  brlog "DEBUG" "Snapshot request result: ${result}"
  if ! echo "${result}" | grep -q "accepted"; then
    brlog "ERROR" "Cluster did not accept the snapshot request. Check the cluster status, and if the problem persist please contact support."
    clean_up
    exit 1
  fi
  brlog "INFO" "Requested snapshot"
}

function clean_up(){
  # Snapshot inside of the cluster is no longer needed as they are copied to the local file system.
  if ! "${KEEP_SNAPSHOT:-false}" ; then
    brlog "INFO" "Clean up"
    brlog "INFO" "Delete snapshot"

    if [ $(compare_version ${WD_VERSION} "5.2.0") -lt 0 ]; then
      run_cmd_in_pod ${ELASTIC_POD} 'export ELASTIC_ENDPOINT=https://localhost:9200 && curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" | grep "acknowledged" || true && \
      retry_count=0 && \
      while true; \
      do\
        if ! curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" | grep "acknowledged" && [ $retry_count -le 10 ]; then\
          sleep 60;\
          retry_count=$((retry_count += 1));\
        else\
          break;\
        fi;\
      done ' ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}"
      echo
    else
      reset_repo
    fi 

    if [ $(compare_version ${WD_VERSION} "4.8.6") -lt 0 ]; then
      run_cmd_in_pod ${ELASTIC_POD} 'export ELASTIC_ENDPOINT=https://localhost:9200 && \
      curl -XPUT -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_cluster/settings" -H "Content-Type: application/json" -d"{\"transient\": {\"discovery.zen.commit_timeout\": null, \"discovery.zen.publish_timeout\": null}}"' ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}"
    fi

    if [ $(compare_version ${WD_VERSION} "4.7.0") -lt 0 ] ; then
      start_minio_port_forward
      "${MC}" "${MC_OPTS[@]}" rm --recursive --force --dangerous wdminio/${ELASTIC_BACKUP_BUCKET}/ > /dev/null
      stop_minio_port_forward
      echo
    elif [ $(compare_version ${WD_VERSION} "5.2.0") -lt 0 ] ; then
      run_cmd_in_pod ${ELASTIC_POD} "rm -rf ${ELASTIC_REPO_LOCATION}/*" -c "${ELASTIC_POD_CONTAINER}"
      oc ${OC_ARGS} patch wd "${TENANT_NAME}" --type json --patch "[{ \"op\": \"remove\", \"path\": \"/spec/elasticsearch/sharedStoragePvc\" }]"
      while :
      do
        test -z "$(oc ${OC_ARGS} get elasticsearchcluster "${TENANT_NAME}" -o jsonpath='{.spec.sharedStoragePVC}')" && break
        brlog "INFO" "Wait for sharedStoragePVC is set to None"
        sleep 30
      done
      brlog "INFO" "Delete statefulset and job of ElasticSearch to rebuld them"
      oc ${OC_ARGS} delete sts,job -l "icpdsupport/addOnId=discovery,icpdsupport/app=elastic,tenant=${TENANT_NAME}"
      if [ "${ELASTIC_SHARED_PVC}" = "${ELASTIC_SHARED_PVC_DEFAULT_NAME:-}" ] ; then
        brlog "INFO" "Delete PVC created for ElasticSearch: ${ELASTIC_SHARED_PVC_DEFAULT_NAME}"
        oc ${OC_ARGS} delete pvc "${ELASTIC_SHARED_PVC_DEFAULT_NAME}"
      fi
      oc ${OC_ARGS} scale deploy -n ${ELASTIC_OPERATOR_DEPLOY[0]} ${ELASTIC_OPERATOR_DEPLOY[1]} --replicas=1
      trap_remove "oc ${OC_ARGS} scale deploy -n ${ELASTIC_OPERATOR_DEPLOY[0]} ${ELASTIC_OPERATOR_DEPLOY[1]} --replicas=1"
      brlog "INFO" "Waiting for ElasticSearch pod start up"
      while :
      do
        oc ${OC_ARGS} get sts "${ELASTIC_DATA_STS}" &> /dev/null && break
        brlog "INFO" "Wait for ElasticSearch statefulset"
        sleep 30
      done
      oc ${OC_ARGS} rollout status sts "${ELASTIC_DATA_STS}"
    fi
  fi
}

if [ $# -lt 2 ] ; then
  printUsage
fi

###############
# Parse args
###############
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


###############
# Prepare environment
###############
brlog "INFO" "Elastic: "
brlog "INFO" "Tenant name: $TENANT_NAME"

# Set variables.
WD_VERSION=${WD_VERSION:-$(get_version)}
BACKUP_FILE=${BACKUP_FILE:-"elastic_$(date "+%Y%m%d_%H%M%S").snapshot"}
ELASTIC_ARCHIVE_OPTION="${ELASTIC_ARCHIVE_OPTION-$DATASTORE_ARCHIVE_OPTION}"
if [ -n "${ELASTIC_ARCHIVE_OPTION}" ] ; then
  read -a ELASTIC_TAR_OPTIONS <<< ${ELASTIC_ARCHIVE_OPTION}
else
  ELASTIC_TAR_OPTIONS=("")
fi
# Remove -z (gzip) option because it is not installed in the opensearch container.
if [ $(compare_version ${WD_VERSION} "5.2.0") -ge 0 ]; then
  ELASTIC_TAR_OPTIONS=($(printf "%s\n" "${ELASTIC_TAR_OPTIONS[@]}" | grep -vxF -- "-z" || true))
fi 
VERIFY_ARCHIVE=${VERIFY_ARCHIVE:-true}
VERIFY_DATASTORE_ARCHIVE=${VERIFY_DATASTORE_ARCHIVE:-$VERIFY_ARCHIVE}
ELASTIC_POD=$(get_elastic_pod)
ELASTIC_POD_CONTAINER=$(get_elastic_pod_container)
setup_s3_env
ELASTIC_BACKUP_BUCKET="$(oc ${OC_ARGS} extract configmap/${S3_CONFIGMAP} --to=- --keys=bucketElasticBackup 2> /dev/null)"

rm -rf ${TMP_WORK_DIR}
mkdir -p ${TMP_WORK_DIR}
mkdir -p "${BACKUP_RESTORE_LOG_DIR}"

if [ $(compare_version ${WD_VERSION} "4.7.0") -ge 0 ] && [ $(compare_version ${WD_VERSION} "5.2.0") -lt 0 ]; then
  mount_pvc_to_elasitc
fi

if [ $(compare_version ${WD_VERSION} "5.2.0") -ge 0 ]; then
  brlog "INFO" "Scale down opensearch operator"
  OPENSEARCH_CLUSTER=$(get_opensearch_cluster)
  OPENSEARCH_VERSION=$(oc ${OC_ARGS} get cluster.opensearch ${OPENSEARCH_CLUSTER} -o jsonpath='{.status.release}{"\n"}')
  OPENSEARCH_OPERATOR_DEPLOY=( $(oc get deploy -A -l "olm.owner=ibm-opensearch-operator.v${OPENSEARCH_VERSION}" | tail -n1 | awk '{print $1,$2}') )
  oc ${OC_ARGS} scale deploy -n "${OPENSEARCH_OPERATOR_DEPLOY[0]}" "${OPENSEARCH_OPERATOR_DEPLOY[1]}" --replicas=0
  trap_add "oc ${OC_ARGS} scale deploy -n ${OPENSEARCH_OPERATOR_DEPLOY[0]} ${OPENSEARCH_OPERATOR_DEPLOY[1]} --replicas=1"
fi

if "${BACKUP_RESTORE_IN_POD}" && [ $(compare_version ${WD_VERSION} "4.7.0") -lt 0 ] ; then
  brlog "INFO" "Start ${COMMAND} elasticsearch..."
  BACKUP_RESTORE_DIR_IN_POD="/tmp/backup-restore-workspace"
  ELASTIC_BACKUP_RESTORE_SCRIPTS="elastic-backup-restore-in-pod.sh"
  ELASTIC_BACKUP_RESTORE_JOB="wd-discovery-elastic-backup-restore"
  ELASTIC_JOB_TEMPLATE="${SCRIPT_DIR}/src/backup-restore-job-template.yml"
  JOB_CPU_LIMITS="${MC_CPU_LIMITS:-800m}" # backward compatibility
  JOB_CPU_LIMITS="${JOB_CPU_LIMITS:-800m}"
  JOB_MEMORY_LIMITS="${MC_MEMORY_LIMITS:-2Gi}" # backward compatibility
  JOB_MEMORY_LIMITS="${JOB_MEMORY_LIMITS:-2Gi}"
  NAMESPACE=${NAMESPACE:-$(oc config view --minify --output 'jsonpath={..namespace}')}
  WD_MIGRATOR_IMAGE="$(get_migrator_image)"
  ELASTIC_CONFIGMAP=$(oc get ${OC_ARGS} configmap -l tenant=${TENANT_NAME},app=elastic-cxn -o jsonpath="{.items[0].metadata.name}")
  ELASTIC_SECRET=$(oc ${OC_ARGS} get secret -l tenant=${TENANT_NAME},run=elastic-secret -o jsonpath="{.items[*].metadata.name}")
  setup_s3_env
  DISCO_SVC_ACCOUNT=$(get_service_account)
  CURRENT_TZ=$(date "+%z" | tr -d '0')
  if echo "${CURRENT_TZ}" | grep "+" > /dev/null; then
    TZ_OFFSET="UTC-$(echo ${CURRENT_TZ} | tr -d '+')"
  else
    TZ_OFFSET="UTC+$(echo ${CURRENT_TZ} | tr -d '-')"
  fi

  sed -e "s/#namespace#/${NAMESPACE}/g" \
    -e "s/#svc-account#/${DISCO_SVC_ACCOUNT}/g" \
    -e "s|#image#|${WD_MIGRATOR_IMAGE}|g" \
    -e "s/#cpu-limit#/${JOB_CPU_LIMITS}/g" \
    -e "s/#memory-limit#/${JOB_MEMORY_LIMITS}/g" \
    -e "s|#command#|./${ELASTIC_BACKUP_RESTORE_SCRIPTS} ${COMMAND}|g" \
    -e "s/#job-name#/${ELASTIC_BACKUP_RESTORE_JOB}/g" \
    -e "s/#tenant#/${TENANT_NAME}/g" \
    "${ELASTIC_JOB_TEMPLATE}" > "${ELASTIC_JOB_FILE}"
  add_config_env_to_job_yaml "ELASTIC_ENDPOINT" "${ELASTIC_CONFIGMAP}" "endpoint" "${ELASTIC_JOB_FILE}"
  add_secret_env_to_job_yaml "ELASTIC_USER" "${ELASTIC_SECRET}" "username" "${ELASTIC_JOB_FILE}"
  add_secret_env_to_job_yaml "ELASTIC_PASSWORD" "${ELASTIC_SECRET}" "password" "${ELASTIC_JOB_FILE}"
  add_config_env_to_job_yaml "S3_ENDPOINT_URL" "${S3_CONFIGMAP}" "endpoint" "${ELASTIC_JOB_FILE}"
  add_config_env_to_job_yaml "S3_HOST" "${S3_CONFIGMAP}" "host" "${ELASTIC_JOB_FILE}"
  add_config_env_to_job_yaml "S3_PORT" "${S3_CONFIGMAP}" "port" "${ELASTIC_JOB_FILE}"
  add_config_env_to_job_yaml "S3_ELASTIC_BACKUP_BUCKET" "${S3_CONFIGMAP}" "bucketElasticBackup" "${ELASTIC_JOB_FILE}"
  add_secret_env_to_job_yaml "S3_ACCESS_KEY" "${S3_SECRET}" "accesskey" "${ELASTIC_JOB_FILE}"
  add_secret_env_to_job_yaml "S3_SECRET_KEY" "${S3_SECRET}" "secretkey" "${ELASTIC_JOB_FILE}"
  add_env_to_job_yaml "ELASTIC_ARCHIVE_OPTION" "${ELASTIC_ARCHIVE_OPTION}" "${ELASTIC_JOB_FILE}"
  add_env_to_job_yaml "ELASTIC_STATUS_CHECK_INTERVAL" "${ELASTIC_STATUS_CHECK_INTERVAL}" "${ELASTIC_JOB_FILE}"
  add_env_to_job_yaml "ELASTIC_WAIT_GREEN_STATE" "${ELASTIC_WAIT_GREEN_STATE}" "${ELASTIC_JOB_FILE}"
  add_env_to_job_yaml "DISABLE_MC_MULTIPART" "${DISABLE_MC_MULTIPART}" "${ELASTIC_JOB_FILE}"
  add_env_to_job_yaml "TZ" "${TZ_OFFSET}" "${ELASTIC_JOB_FILE}"
  add_env_to_job_yaml "KEEP_SNAPSHOT" "${KEEP_SNAPSHOT}" "${ELASTIC_JOB_FILE}"
  add_env_to_job_yaml "ELASTIC_MAX_WAIT_RECOVERY_SECONDS" "${ELASTIC_MAX_WAIT_RECOVERY_SECONDS}" "${ELASTIC_JOB_FILE}"
  add_volume_to_job_yaml "backup-restore-workspace" "${TMP_PVC_NAME:-emptyDir}" "${ELASTIC_JOB_FILE}"

  oc ${OC_ARGS} delete -f "${ELASTIC_JOB_FILE}" &> /dev/null || true
  oc ${OC_ARGS} apply -f "${ELASTIC_JOB_FILE}"
  get_job_pod "app.kubernetes.io/component=${ELASTIC_BACKUP_RESTORE_JOB},tenant=${TENANT_NAME}"
  wait_job_running ${POD}
  _oc_cp "${SCRIPT_DIR}/src" ${POD}:${BACKUP_RESTORE_DIR_IN_POD}/ ${OC_ARGS}
  _oc_cp "${SCRIPT_DIR}/lib" ${POD}:${BACKUP_RESTORE_DIR_IN_POD}/ ${OC_ARGS}
  _oc_cp "${SCRIPT_DIR}/src/${ELASTIC_BACKUP_RESTORE_SCRIPTS}" ${POD}:${BACKUP_RESTORE_DIR_IN_POD}/ ${OC_ARGS}

  if [ "${COMMAND}" = "restore" ] ; then
    brlog "INFO" "Transferring backup data"
    kube_cp_from_local ${POD} "${BACKUP_FILE}" "${BACKUP_RESTORE_DIR_IN_POD}/${ELASTIC_BACKUP}" ${OC_ARGS}
  fi
  oc ${OC_ARGS} exec ${POD} -- touch /tmp/wexdata_copied
  brlog "INFO" "Waiting for ${COMMAND} job to be completed"
  while :
  do
    ls_tmp="$(fetch_cmd_result ${POD} 'ls /tmp')"
    if echo "${ls_tmp}" | grep "backup-restore-complete" > /dev/null ; then
      brlog "INFO" "Completed ${COMMAND} job"
      break;
    else
      sleep 10
      oc ${OC_ARGS} logs ${POD} --since=12s 2>&1 | tee -a "${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log" | grep -v "^error: unexpected EOF$" | grep "^[0-9]\{4\}/[0-9]\{2\}/[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}" || true
    fi
  done
  if [ "${COMMAND}" = "backup" ] ; then
    brlog "INFO" "Transferring backup data"
    kube_cp_to_local ${POD} "${BACKUP_FILE}" "${BACKUP_RESTORE_DIR_IN_POD}/${ELASTIC_BACKUP}" ${OC_ARGS}
    if "${VERIFY_DATASTORE_ARCHIVE}" && brlog "INFO" "Verifying backup archive" && ! tar "${ELASTIC_TAR_OPTIONS[@]}" -tf ${BACKUP_FILE} &> /dev/null ; then
      brlog "ERROR" "Backup file is broken, or does not exist."
      oc ${OC_ARGS} exec ${POD} -- bash -c "cd ${BACKUP_RESTORE_DIR_IN_POD}; ls | xargs rm -rf"
      exit 1
    fi
  fi
  oc ${OC_ARGS} exec ${POD} -- bash -c "cd ${BACKUP_RESTORE_DIR_IN_POD}; ls | xargs rm -rf"
  oc ${OC_ARGS} delete -f "${ELASTIC_JOB_FILE}"
  rm -rf ${TMP_WORK_DIR}
  if [ -z "$(ls tmp)" ] ; then
    rm -rf tmp
  fi
  brlog "INFO" "Done"
  exit 0
fi

if [ $(compare_version ${WD_VERSION} "4.7.0") -lt 0 ] ; then
  setup_mc
fi

# Setup repository configuration which defines its snapshot file location.
if [ $(compare_version ${WD_VERSION} "4.7.0") -lt 0 ] ; then
  REPO_CONFIGURATION='-d"{\"type\":\"s3\",\"settings\":{\"bucket\":\"${S3_ELASTIC_BACKUP_BUCKET}\",\"region\":\"us-east-1\",\"protocol\":\"https\",\"endpoint\":\"https://${S3_IP}:${S3_PORT}\",\"base_path\":\"es_snapshots\",\"compress\":\"true\",\"server_side_encryption\":\"false\",\"storage_class\":\"reduced_redundancy\"}}"'
else
  REPO_CONFIGURATION='-d"{\"type\": \"fs\",\"settings\": {\"location\": \"'${ELASTIC_REPO_LOCATION}'\"}}"'
fi

brlog "DEBUG" "BACKUP_FILE: $BACKUP_FILE"
brlog "DEBUG" "VERIFY_ARCHIVE: $VERIFY_ARCHIVE"
brlog "DEBUG" "VERIFY_DATASTORE_ARCHIVE: $VERIFY_DATASTORE_ARCHIVE"
brlog "DEBUG" "REPO_CONFIGURATION: $REPO_CONFIGURATION"

###############
# Main (Backup)
###############
if [ ${COMMAND} = 'backup' ] ; then
  brlog "INFO" "Start backup elasticsearch..."
  mkdir -p ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}
  if [ $(compare_version ${WD_VERSION} "4.7.0") -lt 0 ] ; then
    # Clean up MinIO
    start_minio_port_forward
    "${MC}" "${MC_OPTS[@]}" config host add wdminio ${S3_ENDPOINT_URL} ${S3_ACCESS_KEY} ${S3_SECRET_KEY} > /dev/null
    if [ -n "$("${MC}" "${MC_OPTS[@]}" ls wdminio/${ELASTIC_BACKUP_BUCKET}/)" ] ; then
      "${MC}" "${MC_OPTS[@]}" rm --recursive --force --dangerous wdminio/${ELASTIC_BACKUP_BUCKET}/ > /dev/null
    fi
    stop_minio_port_forward
  else
    reset_repo
  fi
  take_snapshot

  brlog "DEBUG" "Waiting for snapshot to be created"
  while true;
  do
    snapshot_status=$(fetch_cmd_result ${ELASTIC_POD} 'export ELASTIC_ENDPOINT=https://localhost:9200 && curl -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'" | jq -r ".snapshots[0].state"' ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}")
    
    # Snapshot is successfuly created, so validate it and save into local file system.
    if [ "${snapshot_status}" = "SUCCESS" ] ; then
      brlog "INFO" "Snapshot successfully finished."
      run_cmd_in_pod ${ELASTIC_POD} 'export ELASTIC_ENDPOINT=https://localhost:9200 && curl -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'" | jq -r ".snapshots[0]"' ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}"
      
      if [ $(compare_version ${WD_VERSION} "4.7.0") -lt 0 ] ; then
        brlog "INFO" "Transfering snapshot from MinIO"
        cat << EOF >> "${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log"
===================================================
"${MC}" ${MC_OPTS[@]} mirror wdminio/${ELASTIC_BACKUP_BUCKET} ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET}"
===================================================
EOF
        set +e
        start_minio_port_forward
        "${MC}" "${MC_OPTS[@]}" mirror wdminio/${ELASTIC_BACKUP_BUCKET} ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET} &>> "${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log"
        RC=$?
        stop_minio_port_forward
        echo "RC=${RC}" >> "${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log"
        if [ $RC -eq 0 ] ; then
          brlog "INFO" "Archiving sanpshot..."
          tar "${ELASTIC_TAR_OPTIONS[@]}" -cf ${BACKUP_FILE} -C ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET}/${ELASTIC_SNAPSHOT_PATH} .
        else
          brlog "ERROR" "Some files could not be transfered. Consider to use '--use-job' and '--pvc' option. Please see help (--help) for details."
        fi
        set -e
      else
        # Compress all snapshot files and save into the local file system.
        brlog "INFO" "Archiveing created snapshot as ${BACKUP_FILE}"
        run_cmd_in_pod "${ELASTIC_POD}" "tar ${ELASTIC_TAR_OPTIONS[*]} --warning=no-file-changed --warning=no-file-removed --exclude ${ELASTIC_BACKUP} -cf ${ELASTIC_REPO_LOCATION}/${ELASTIC_BACKUP} -C ${ELASTIC_REPO_LOCATION} . || [[ \$? == 1 ]]" -c "${ELASTIC_POD_CONTAINER}"
        kube_cp_to_local ${ELASTIC_POD} "${BACKUP_FILE}" "${ELASTIC_REPO_LOCATION}/${ELASTIC_BACKUP}" ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}"
      fi
      break;
    elif [ "${snapshot_status}" = "FAILED" -o "${snapshot_status}" = "PARTIAL" ] ; then
      brlog "ERROR" "Snapshot failed"
      brlog "INFO" "$(fetch_cmd_result ${ELASTIC_POD} 'export ELASTIC_ENDPOINT=https://localhost:9200 && curl -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'" | jq -r ".snapshots[0]"' ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}")"
      break;
    else
      brlog "INFO" "snapshot status: ${snapshot_status}. Retrying in ${ELASTIC_STATUS_CHECK_INTERVAL} seconds."
      sleep ${ELASTIC_STATUS_CHECK_INTERVAL}
    fi
  done
  clean_up
  if [ -e "${BACKUP_FILE}" ] ; then
    if "${VERIFY_DATASTORE_ARCHIVE}" && brlog "INFO" "Verifying backup archive" && ! tar "${ELASTIC_TAR_OPTIONS[@]}" -tf ${BACKUP_FILE} &> /dev/null ; then
      brlog "ERROR" "Backup file is broken, or does not exist."
      exit 1
    fi
  else
    brlog "ERROR" "Error on getting backup ElasticSearch"
    exit 1
  fi
  echo
  brlog "INFO" "Backup file '${BACKUP_FILE}' successfully created."
fi

###############
# Main (Restore)
###############
if [ "${COMMAND}" = 'restore' ] ; then
  if [ -z "${BACKUP_FILE}" ] ; then
    printUsage
  fi
  if [ ! -e "${BACKUP_FILE}" ] ; then
    brlog "WARN" "no such file: ${BACKUP_FILE}"
    brlog "WARN" "Nothing to Restore"
    echo
    exit 1
  fi

  if [ $(compare_version ${WD_VERSION} "4.7.0") -lt 0 ] ; then
    brlog "INFO" "Extracting Archive..."
    mkdir -p ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET}/${ELASTIC_SNAPSHOT_PATH}
    tar "${ELASTIC_TAR_OPTIONS[@]}" -xf ${BACKUP_FILE} -C ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET}/${ELASTIC_SNAPSHOT_PATH}
    brlog "INFO" "Transferring data to MinIO..."
    start_minio_port_forward
    "${MC}" "${MC_OPTS[@]}" config host add wdminio ${S3_ENDPOINT_URL} ${S3_ACCESS_KEY} ${S3_SECRET_KEY} > /dev/null
    if [ -n "$("${MC}" "${MC_OPTS[@]}" ls wdminio/${ELASTIC_BACKUP_BUCKET}/)" ] ; then
      "${MC}" "${MC_OPTS[@]}" rm --recursive --force --dangerous wdminio/${ELASTIC_BACKUP_BUCKET}/ > /dev/null
    fi
    stop_minio_port_forward
    set +e
    cat << EOF >> "${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log"
===================================================
"${MC}" ${MC_OPTS[@]} mirror --debug ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET} wdminio/${ELASTIC_BACKUP_BUCKET}
===================================================
EOF
    start_minio_port_forward
    "${MC}" "${MC_OPTS[@]}" mirror ${TMP_WORK_DIR}/${ELASTIC_BACKUP_DIR}/${ELASTIC_BACKUP_BUCKET} wdminio/${ELASTIC_BACKUP_BUCKET} &>> "${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log"
    RC=$?
    stop_minio_port_forward
    echo "RC=${RC}" >> "${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log"
    if [ $RC -ne 0 ] ; then
      brlog "ERROR" "Some files could not be transfered. Consider to use '--use-job' and '--pvc' option. Please see help (--help) for details."
      brlog "INFO" "Clean up"
      start_minio_port_forward
      "${MC}" "${MC_OPTS[@]}" rm --recursive --force --dangerous wdminio/${ELASTIC_BACKUP_BUCKET}/ > /dev/null
      stop_minio_port_forward
      exit 1
    fi
    set -e
  else
    # Copy the snapshot file into the elastic pod.
    reset_repo
    if file "$BACKUP_FILE" | grep -q "gzip compressed data" && [ $(compare_version ${WD_VERSION} "5.2.0") -ge 0 ] ; then
      # opensearch client pod does not have gzip, so we need to recompress the backup data without gzip.
      RECOMPRESSED_BACKUP_FILE="$(dirname "${BACKUP_FILE}")/recompressed.backup"
      gzip_to_plain_tar "${BACKUP_FILE}" "${RECOMPRESSED_BACKUP_FILE}"
      kube_cp_from_local ${ELASTIC_POD} "${RECOMPRESSED_BACKUP_FILE}" "${ELASTIC_REPO_LOCATION}/${ELASTIC_BACKUP}" ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}"
    else
      kube_cp_from_local ${ELASTIC_POD} "${BACKUP_FILE}" "${ELASTIC_REPO_LOCATION}/${ELASTIC_BACKUP}" ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}"
    fi
    run_cmd_in_pod ${ELASTIC_POD} "tar ${ELASTIC_TAR_OPTIONS[*]} -xmpf ${ELASTIC_REPO_LOCATION}/${ELASTIC_BACKUP} -C ${ELASTIC_REPO_LOCATION} && rm -f ${ELASTIC_REPO_LOCATION}/${ELASTIC_BACKUP}" ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}"
  fi
  brlog "INFO" "Start Restoring snapshot"

  # Setup the snapshot repository, and send the restore request.
  elastic_env_variables=""
  if [ $(compare_version ${WD_VERSION} "5.2.0") -lt 0 ]; then
    elastic_env_variables+='export S3_HOST='${S3_SVC}' && export S3_PORT='${S3_PORT}' && export S3_ELASTIC_BACKUP_BUCKET='${ELASTIC_BACKUP_BUCKET}' && export ELASTIC_ENDPOINT=https://localhost:9200 && \
      S3_IP=$(curl -kv "https://$S3_HOST:$S3_PORT/minio/health/ready" 2>&1 | grep Connected | sed -E "s/.*\(([0-9.]+)\).*/\1/g") '
  fi 

  if [ $(compare_version ${WD_VERSION} "5.2.0") -lt 0 ]; then
    reset_timeout_cmd="${elastic_env_variables:-true}"
    reset_timeout_cmd+='&& curl -XDELETE --fail -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_all?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" && \
    curl -XDELETE -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/.*?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'"'
    run_cmd_in_pod ${ELASTIC_POD} "${reset_timeout_cmd}" ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}"
  fi

  set_repo_cmd="${elastic_env_variables:-true}"
  set_repo_cmd+='&& curl -XPUT --fail -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" -H "Content-Type: application/json" '${REPO_CONFIGURATION}''
  run_cmd_in_pod ${ELASTIC_POD} "${set_repo_cmd}" ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}"
  
  if [ $(compare_version ${WD_VERSION} "5.2.0") -lt 0 ]; then
    restore_request_cmd="${elastic_env_variables:-true}"
    restore_request_cmd+='&& curl -XPOST --fail -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'/_restore?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" -H "Content-Type: application/json" -d"{\"indices\": \"*,-application_logs-*\", \"expand_wildcards\": \"all\", \"allow_no_indices\": \"true\"}"'
    run_cmd_in_pod ${ELASTIC_POD} "${restore_request_cmd}" ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}"
  else
    # WD_VERSION >= 5.2.0 does not allow restore indices which start with `.` due to security reason, so we will have to manually specify the whitelist.
    # TODO get white list from opensearch cluster CR.
    whitelist_indices=".ltrstore"
    restore_whitelist_indices_cmd='curl -XPOST -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} \
      "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'/_restore?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'&wait_for_completion=true" \
      -H "Content-Type: application/json" \
      -d"{\"indices\": \"'${whitelist_indices}'\", \"expand_wildcards\": \"all\", \"allow_no_indices\": \"true\"}"'
    run_cmd_in_pod ${ELASTIC_POD} "${restore_whitelist_indices_cmd}" ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}"
    result=$(get_last_cmd_result_in_pod)
    brlog "DEBUG" "restore whitelist indices result: ${result}"
    if ! echo "${result}" | grep -Eq '"total":1,"failed":0,"successful":1'; then
      brlog "ERROR" "Could not restore the ${whitelist_indices} index due to the following error: ${result}. Please check the cluster."
      clean_up
      exit 1
    fi 
    # Restore remaining indices.
    restore_request_cmd="${elastic_env_variables:-true}"
    restore_request_cmd+='&& curl -XPOST -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} \
      "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'/_restore?master_timeout='${ELASTIC_REQUEST_TIMEOUT}'" \
      -H "Content-Type: application/json" \
      -d"{\"indices\": \"*,-application_logs-*,-.*\", \"expand_wildcards\": \"all\", \"allow_no_indices\": \"true\"}"'
    run_cmd_in_pod ${ELASTIC_POD} "${restore_request_cmd}" ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}"
  fi 

  # Check if the restore request is successfuly accepted or not.
  brlog "DEBUG" "Checking restore request"
  result=$(get_last_cmd_result_in_pod)
  brlog "DEBUG" "restore snapshot result: ${result}"
  if ! echo "${result}" | grep -Eq "accepted|acknowledged"; then
    brlog "ERROR" "Elasticsearch did not accept the restore request. Check the cluster status, and if the problem persist please contact support."
    clean_up
    exit 1
  fi
  
  if [ $(compare_version ${WD_VERSION} "4.8.6") -lt 0 ]; then
    run_cmd_in_pod ${ELASTIC_POD} 'export ELASTIC_ENDPOINT=https://localhost:9200 && \
    curl -XPUT --fail -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_cluster/settings" -H "Content-Type: application/json" -d"{\"transient\": {\"discovery.zen.commit_timeout\": \"'${ELASTIC_REQUEST_TIMEOUT}'\", \"discovery.zen.publish_timeout\": \"'${ELASTIC_REQUEST_TIMEOUT}'\"}}" '  ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}"
  fi
  
  brlog "INFO" "Sent restore request"
  waited_seconds=0
  total_shards=0
  while true;
  do
    recovery_status=$(get_recovery_status)
    brlog "DEBUG" "Recovery Status: ${recovery_status}"
    if [ "${recovery_status}" != "{}" ] ; then
      tmp_total_shards=$(fetch_cmd_result ${ELASTIC_POD} 'cat /tmp/recovery_status.json | jq ".[].shards[]" | jq -s ". | length"' ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}")
      if [ ${total_shards} -ge ${tmp_total_shards} ] && [ ${tmp_total_shards} -ne 0 ] ; then
        break
      else
        total_shards=${tmp_total_shards}
      fi
    else
      waited_seconds=$((waited_seconds += ELASTIC_STATUS_CHECK_INTERVAL))
      if [ ${waited_seconds} -ge ${ELASTIC_MAX_WAIT_RECOVERY_SECONDS} ] ; then
        brlog "ERROR" "There is no recovery status in ${ELASTIC_MAX_WAIT_RECOVERY_SECONDS} seconds. Please contact support."
        clean_up
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
    recovery_status=$(get_recovery_status)
    total_shards=$(fetch_cmd_result ${ELASTIC_POD} 'cat /tmp/recovery_status.json | jq ".[].shards[]" | jq -s ". | length"' ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}")
    done_count=$(fetch_cmd_result ${ELASTIC_POD} 'cat /tmp/recovery_status.json | jq '"'"'.[].shards[] | select(.stage == "DONE")'"'"' | jq -s ". | length"' ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}")
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
    cluster_status=$(fetch_cmd_result ${ELASTIC_POD} 'export ELASTIC_ENDPOINT=https://localhost:9200 && curl -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_cluster/health" | jq -r ".status"' ${OC_ARGS} -c "${ELASTIC_POD_CONTAINER}")
    do
      if [ "${cluster_status}" = "green" ] ; then
        break;
      fi
      sleep ${ELASTIC_STATUS_CHECK_INTERVAL}
    done
  fi

  clean_up

  brlog "INFO" "Restore Done"
  brlog "INFO" "Applying updates"
  . ./lib/restore-updates.bash
  elastic_updates
  brlog "INFO" "Completed Updates"
  echo
fi

###############
# Cleanup
###############
rm -rf ${TMP_WORK_DIR}
if [ -z "$(ls tmp)" ] ; then
  rm -rf tmp
fi