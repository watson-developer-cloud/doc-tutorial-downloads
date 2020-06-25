#!/bin/bash

set -euo pipefail

printUsage() {
  echo "Usage: $(basename ${0}) <wd_data_backup_file>"
  exit 1
}

SCRIPT_DIR=$(dirname $0)
KUBECTL_ARGS=""

. ${SCRIPT_DIR}/lib/function.bash

BACKUP_FILE=$1
shift
while getopts n: OPT
do
  case $OPT in
    "n" ) KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$OPTARG"
          NAMESPACE=${OPTARG} ;;
esac
done

export SCRIPT_DIR=${SCRIPT_DIR}
ORG_KUBECTL_ARGS=${KUBECTL_ARGS}
BACKUP_FILE_NAME="wexdata.tar.gz"
TMP_WORK_DIR="tmp/migration"
MIGRATOR_LOG_FILE="migrator_`date '+%Y%m%d_%H%M%S'`.log"

brlog "INFO" "Start migrator"
launch_migrator_job
get_job_pod
wait_job_running ${POD}

kubectl ${KUBECTL_ARGS} cp ${BACKUP_FILE} ${POD}:/tmp/${BACKUP_FILE_NAME}
kubectl ${KUBECTL_ARGS} exec ${POD} -- bash -c 'touch /tmp/wexdata_copied'

FAILED_COUNT="0"
brlog "INFO" "Waiting for migration job to be completed..."
while :
do
  FAILED="`kubectl ${KUBECTL_ARGS} get job -o jsonpath='{.status.failed}' ${MIGRATOR_JOB_NAME}`"
  if [ -n "${FAILED}" -a "${FAILED}" != "${FAILED_COUNT}" ] ; then
    if [ "${FAILED}" = "5" ] ; then
      brlog "ERROR" "Migration job failed ${FAILED} times."
      kubectl ${KUBECTL_ARGS} delete job ${MIGRATOR_JOB_NAME}
      exit 1
    fi
    brlog "WARN" "Migration job failed (${FAILED} times), Retrying..."
    FAILED_COUNT="${FAILED}"
    get_job_pod
    wait_job_running ${POD}
    kubectl ${KUBECTL_ARGS} cp ${BACKUP_FILE} ${POD}:/tmp/${BACKUP_FILE_NAME}
    kubectl ${KUBECTL_ARGS} exec ${POD} -- bash -c 'touch /tmp/wexdata_copied'
  elif [ "`kubectl ${KUBECTL_ARGS} get job -o jsonpath='{.status.succeeded}' ${MIGRATOR_JOB_NAME}`" = "1" ] ; then
    brlog "INFO" "Completed migration job"
    break;
  else
    sleep 5
  fi
done

kubectl ${KUBECTL_ARGS} logs ${POD} > ${MIGRATOR_LOG_FILE}

kubectl ${KUBECTL_ARGS} delete job ${MIGRATOR_JOB_NAME}
brlog "INFO" "Done migrator"