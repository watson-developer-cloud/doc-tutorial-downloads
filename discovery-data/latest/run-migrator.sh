#!/bin/bash

set -euo pipefail

printUsage() {
  echo "Usage: $(basename ${0}) <TENANT_NAME>"
  exit 1
}

SCRIPT_DIR=$(dirname $0)
OC_ARGS="${OC_ARGS:-}"

. ${SCRIPT_DIR}/lib/function.bash

TENANT_NAME=$1
shift
while getopts n: OPT
do
  case $OPT in
    "n" ) OC_ARGS="${OC_ARGS} --namespace=$OPTARG"
          NAMESPACE=${OPTARG} ;;
esac
done

export SCRIPT_DIR=${SCRIPT_DIR}
export TENANT_NAME=${TENANT_NAME}
ORG_OC_ARGS=${OC_ARGS}
BACKUP_FILE_NAME="wexdata.tar.gz"
TMP_WORK_DIR="tmp/migration"
MIGRATOR_LOG_FILE="migrator_$(date '+%Y%m%d_%H%M%S').log"

brlog "INFO" "Start migrator"
launch_utils_job "wd-migrator-job"
get_job_pod "app.kubernetes.io/component=wd-backkup-restore"
wait_job_running ${POD}

oc ${OC_ARGS} exec ${POD} -- bash -c 'touch /tmp/wexdata_copied'

FAILED_COUNT="0"
brlog "INFO" "Waiting for migration job to be completed..."
while :
do
  FAILED="$(oc ${OC_ARGS} get job -o jsonpath='{.status.failed}' ${MIGRATOR_JOB_NAME})"
  if [ -n "${FAILED}" -a "${FAILED}" != "${FAILED_COUNT}" ] ; then
    if [ "${FAILED}" = "5" ] ; then
      brlog "ERROR" "Migration job failed ${FAILED} times."
      oc ${OC_ARGS} delete job ${MIGRATOR_JOB_NAME}
      exit 1
    fi
    brlog "WARN" "Migration job failed (${FAILED} times), Retrying..."
    FAILED_COUNT="${FAILED}"
    get_job_pod "app.kubernetes.io/component=wd-backup-restore"
    wait_job_running ${POD}
    oc ${OC_ARGS} exec ${POD} -- bash -c 'touch /tmp/wexdata_copied'
  elif [ "$(oc ${OC_ARGS} get job -o jsonpath='{.status.succeeded}' ${MIGRATOR_JOB_NAME})" = "1" ] ; then
    brlog "INFO" "Completed migration job"
    break;
  else
    sleep 5
  fi
done

oc ${OC_ARGS} logs ${POD} > ${MIGRATOR_LOG_FILE}

oc ${OC_ARGS} delete job ${MIGRATOR_JOB_NAME}
brlog "INFO" "Done migrator"