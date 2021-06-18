#!/bin/bash

set -euo pipefail

ROOT_DIR_PG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
typeset -r ROOT_DIR_PG

# shellcheck source=lib/restore-utilites.bash
source "${ROOT_DIR_PG}/lib/restore-updates.bash"
source "${ROOT_DIR_PG}/lib/function.bash"

KUBECTL_ARGS=""
PG_BACKUP="/tmp/pg_backup.tar.gz"
PG_BACKUP_DIR="pg_backup"
PG_BACKUP_PREFIX="/tmp/${PG_BACKUP_DIR}/pg_"
PG_BACKUP_SUFFIX=".dump"
PG_SCRIPT_VERSION="2.1.3"
TMP_WORK_DIR="tmp/pg_backup"
POSTGRES_CONFIG_JOB="wire-postgres"

DATASTORE_ARCHIVE_OPTION="${DATASTORE_ARCHIVE_OPTION--z}"
PG_ARCHIVE_OPTION="${PG_ARCHIVE_OPTION-$DATASTORE_ARCHIVE_OPTION}"
if [ -n "${PG_ARCHIVE_OPTION}" ] ; then
  read -a PG_TAR_OPTIONS <<< ${PG_ARCHIVE_OPTION}
else
  PG_TAR_OPTIONS=("")
fi
VERIFY_ARCHIVE=${VERIFY_ARCHIVE:-true}
VERIFY_DATASTORE_ARCHIVE=${VERIFY_DATASTORE_ARCHIVE:-$VERIFY_ARCHIVE}

ARCHIVE_ON_LOCAL=${ARCHIVE_ON_LOCAL:-false}

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
    "n" ) KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$OPTARG"
          SCRIPT_ARGS="-n ${OPTARG}";;
  esac
done

SCRIPT_ARGS=${SCRIPT_ARGS:-""}

brlog "INFO" "Postgressql: "
brlog "INFO" "Release name: $RELEASE_NAME"

WD_VERSION=`get_version`

mkdir -p ${TMP_WORK_DIR}

PG_POD=""

for POD in `kubectl get pods ${KUBECTL_ARGS} -o jsonpath='{.items[*].metadata.name}' -l release=${RELEASE_NAME},helm.sh/chart=postgresql,component=stolon-keeper` ; do
  if kubectl logs ${KUBECTL_ARGS} --since=30s ${POD} | grep 'our db requested role is master' > /dev/null ; then
    PG_POD=${POD}
  fi
done

# backup
if [ ${COMMAND} = 'backup' ] ; then
  BACKUP_FILE=${BACKUP_FILE:-"pg_`date "+%Y%m%d_%H%M%S"`.backup"}
  brlog "INFO" "Start backup postgresql..."
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c 'export PGUSER=${PGUSER:-${STKEEPER_PG_SU_USERNAME}} && \
  export PGPASSWORD=${PGPASSWORD:-`cat ${STKEEPER_PG_SU_PASSWORDFILE}`} && \
  export PGHOST=${PGHOST:-localhost} && \
  rm -rf /tmp/'${PG_BACKUP_DIR}' '${PG_BACKUP}' && \
  mkdir -p /tmp/'${PG_BACKUP_DIR}' && \
  for DATABASE in $( psql -l | grep ${PGUSER} | cut -d "|" -f 1 | grep -v -e template -e postgres -e "^\s*$"); do pg_dump ${DATABASE} > '${PG_BACKUP_PREFIX}'${DATABASE}'${PG_BACKUP_SUFFIX}'; done && \
  touch /tmp/'${PG_BACKUP_DIR}'/version_'${PG_SCRIPT_VERSION}
  wait_cmd ${PG_POD} "pg_dump" ${KUBECTL_ARGS}
  if "${ARCHIVE_ON_LOCAL}" ; then 
    brlog "INFO" "Transferring backup files"
    kube_cp_to_local -r ${PG_POD} "${TMP_WORK_DIR}/${PG_BACKUP_DIR}" "/tmp/${PG_BACKUP_DIR}" ${KUBECTL_ARGS}
    kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "rm -rf /tmp/${PG_BACKUP_DIR}"
    brlog "INFO" "Archiving data"
    tar ${PG_TAR_OPTIONS[@]} -cf ${BACKUP_FILE} -C ${TMP_WORK_DIR} ${PG_BACKUP_DIR}
  else
    brlog "INFO" "Archiving data..."
    kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "tar ${PG_ARCHIVE_OPTION} -cf ${PG_BACKUP} -C /tmp ${PG_BACKUP_DIR} && rm -rf /tmp/${PG_BACKUP_DIR}"
    wait_cmd ${PG_POD} "tar ${PG_ARCHIVE_OPTION} -cf" ${KUBECTL_ARGS}
    brlog "INFO" "Trasnfering archive..."
    kube_cp_to_local ${PG_POD} "${BACKUP_FILE}" "${PG_BACKUP}" ${KUBECTL_ARGS}
    kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "rm -rf /tmp/${PG_BACKUP_DIR} ${PG_BACKUP}"
  fi
  if "${VERIFY_DATASTORE_ARCHIVE}" && brlog "INFO" "Verifying backup archive" && ! tar ${PG_TAR_OPTIONS[@]} -tf ${BACKUP_FILE} &> /dev/null ; then
    brlog "ERROR" "Backup file is broken, or does not exist."
    exit 1
  fi
  brlog "INFO" "Done: ${BACKUP_FILE}"
fi

# restore
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

  SDU_RELEASE_NAME="core"
  SDU_RESOURCE_TYPE="sts"
  DFS_RELEASE_NAME="core"

  brlog "INFO" "SDU Resource Type: ${SDU_RESOURCE_TYPE}"

  SDU_API_RESOURCE=`kubectl get ${SDU_RESOURCE_TYPE} ${KUBECTL_ARGS} -o jsonpath='{.items[0].metadata.name}' -l release=${SDU_RELEASE_NAME},run=sdu`
  SDU_API_REPLICAS=`kubectl get ${SDU_RESOURCE_TYPE} ${KUBECTL_ARGS} -o jsonpath='{.items[0].spec.replicas}' -l release=${SDU_RELEASE_NAME},run=sdu`
  DFS_INDUCTION_RESOURCE=`kubectl get deployment ${KUBECTL_ARGS} -o jsonpath='{.items[0].metadata.name}' -l release=${DFS_RELEASE_NAME},run=dfs-induction`
  DFS_INDUCTION_REPLICAS=`kubectl get deployment ${KUBECTL_ARGS} -o jsonpath='{.items[0].spec.replicas}' -l release=${DFS_RELEASE_NAME},run=dfs-induction`
  if [ ${SDU_API_REPLICAS} -eq 0 ] ; then
    SDU_API_REPLICAS=1
  fi
  if [ ${DFS_INDUCTION_REPLICAS} -eq 0 ] ; then
    DFS_INDUCTION_REPLICAS=1
  fi
  trap "scale_resource sts ${SDU_API_RESOURCE} ${SDU_API_REPLICAS} false; scale_resource deployment ${DFS_INDUCTION_RESOURCE} ${DFS_INDUCTION_REPLICAS} false" 0 1 2 3 15
  scale_resource deployment ${DFS_INDUCTION_RESOURCE} 0 false
  scale_resource sts ${SDU_API_RESOURCE} 0 true

  brlog "INFO" "Start restore postgresql: ${BACKUP_FILE}"

  echo 'export PGUSER=${PGUSER:-${STKEEPER_PG_SU_USERNAME}} && \
  export PGPASSWORD=${PGPASSWORD:-`cat ${STKEEPER_PG_SU_PASSWORDFILE}`} && \
  export PGHOST=${PGHOST:-localhost} && \
  cd tmp && \
  for DATABASE in $(ls '${PG_BACKUP_DIR}'/*.dump | cut -d "/" -f 2 | sed -e "s/^pg_//g" -e "s/.dump$//g"); do
  pgrep -f "postgres: ${PGUSER} ${PGPASSWORD} ${DATABASE}" | xargs --no-run-if-empty kill && \
  PGPASSWORD=${PGPASSWORD} psql -U ${PGUSER} -d ${DATABASE} -c "REVOKE CONNECT ON DATABASE ${DATABASE} FROM public;" && \
  PGPASSWORD=${PGPASSWORD} psql -U ${PGUSER} -d ${DATABASE} -c "SELECT pid, pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid();" && \
  dropdb --if-exists ${DATABASE} && \
  createdb ${DATABASE} && \
  PGPASSWORD=${PGPASSWORD} psql -U ${PGUSER} -d ${DATABASE} -c "GRANT CONNECT ON DATABASE ${DATABASE} TO public;" && \
  psql ${DATABASE} < '${PG_BACKUP_PREFIX}'${DATABASE}'${PG_BACKUP_SUFFIX}'; done && \
  rm -rf '${PG_BACKUP_DIR}' '${PG_BACKUP} > ${TMP_WORK_DIR}/pg_restore.sh
  kubectl cp ${KUBECTL_ARGS} ${TMP_WORK_DIR}/pg_restore.sh ${PG_POD}:/tmp/pg_restore.sh
  if "${ARCHIVE_ON_LOCAL}" ; then
    brlog "INFO" "Extracting archive"
    tar ${PG_TAR_OPTIONS[@]} -xf ${BACKUP_FILE} -C ${TMP_WORK_DIR}
    brlog "INFO" "Transferring backup files"
    kube_cp_from_local -r ${PG_POD} "${TMP_WORK_DIR}/${PG_BACKUP_DIR}" "/tmp/${PG_BACKUP_DIR}" ${KUBECTL_ARGS}
  else
    brlog "INFO" "Transferting archive..."
    kube_cp_from_local ${PG_POD} "${BACKUP_FILE}" "${PG_BACKUP}" ${KUBECTL_ARGS}
    brlog "INFO" "Extracting archive..."
    kubectl exec ${KUBECTL_ARGS} ${PG_POD} -- bash -c  "cd tmp && rm -rf ${PG_BACKUP_DIR} && tar ${PG_ARCHIVE_OPTION} -xf ${PG_BACKUP}"
    wait_cmd ${PG_POD} "tar ${PG_ARCHIVE_OPTION} -xf ${PG_BACKUP}" ${KUBECTL_ARGS}
  fi
  brlog "INFO" "Restorering data..."
  kubectl exec ${KUBECTL_ARGS} ${PG_POD} -- bash -c 'chmod +x /tmp/pg_restore.sh && /tmp/pg_restore.sh &> /tmp/pg_restore.log &'
  wait_cmd ${PG_POD} "/tmp/pg_restore.sh" ${KUBECTL_ARGS}
  kubectl exec ${KUBECTL_ARGS} ${PG_POD} -- bash -c 'cat /tmp/pg_restore.log; rm -rf /tmp/pg_restore.sh /tmp/pg_restore.log'
  brlog "INFO" "Done"

  brlog "INFO" "Run postgres-config job"
  ./run-postgres-config-job.sh ${SCRIPT_ARGS}

  brlog "INFO" "Restore replicas of ${SDU_API_RESOURCE}"
  scale_resource sts ${SDU_API_RESOURCE} ${SDU_API_REPLICAS} false
  scale_resource deployment ${DFS_INDUCTION_RESOURCE} ${DFS_INDUCTION_REPLICAS} false
  trap 0 1 2 3 15

  brlog "INFO" "Applying updates"
  . ./lib/restore-updates.bash
  postgresql_updates
  brlog "INFO" "Completed Updates"
  echo
fi

rm -rf ${TMP_WORK_DIR}
if [ -z "$(ls tmp)" ] ; then
  rm -rf tmp
fi