#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
typeset -r SCRIPT_DIR

# shellcheck source=lib/restore-utilites.bash
source "${SCRIPT_DIR}/lib/restore-updates.bash"
source "${SCRIPT_DIR}/lib/function.bash"

OC_ARGS="${OC_ARGS:-}"
PG_BACKUP="/tmp/pg_backup.tar.gz"
PG_BACKUP_DIR="pg_backup"
PG_BACKUP_PREFIX="/tmp/${PG_BACKUP_DIR}/pg_"
PG_BACKUP_SUFFIX=".dump"
PG_SCRIPT_VERSION="2.1.3"
PG_JOB_FILE="${SCRIPT_DIR}/src/pg-backup-restore-job.yml"
TMP_WORK_DIR="tmp/pg_backup"
CURRENT_COMPONENT="postgresql"
POSTGRES_CONFIG_JOB="wire-postgres"

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
    "n" ) OC_ARGS="${OC_ARGS} --namespace=$OPTARG"
          SCRIPT_ARGS="-n ${OPTARG}";;
  esac
done

SCRIPT_ARGS=${SCRIPT_ARGS:-""}

brlog "INFO" "Postgressql: "
brlog "INFO" "Tenant name: $TENANT_NAME"

WD_VERSION=${WD_VERSION:-$(get_version)}

PG_ARCHIVE_OPTION="${PG_ARCHIVE_OPTION--z}"
if [ $(compare_version "${WD_VERSION}" "4.0.0") -ge 0 ] ; then
  PG_ARCHIVE_OPTION="${PG_ARCHIVE_OPTION} --exclude='${PG_BACKUP_DIR}/pg_dfs_induction.dump'"
fi

if [ -n "${PG_ARCHIVE_OPTION}" ] ; then
  read -a PG_TAR_OPTIONS <<< ${PG_ARCHIVE_OPTION}
else
  PG_TAR_OPTIONS=("")
fi
VERIFY_ARCHIVE=${VERIFY_ARCHIVE:-true}
VERIFY_DATASTORE_ARCHIVE=${VERIFY_DATASTORE_ARCHIVE:-$VERIFY_ARCHIVE}

ARCHIVE_ON_LOCAL=${ARCHIVE_ON_LOCAL:-false}
BACKUP_FILE=${BACKUP_FILE:-"pg_$(date "+%Y%m%d_%H%M%S").backup"}

rm -rf ${TMP_WORK_DIR}
mkdir -p ${TMP_WORK_DIR}
mkdir -p ${BACKUP_RESTORE_LOG_DIR}

PG_POD=""

for POD in $(oc get pods ${OC_ARGS} -o jsonpath='{.items[*].metadata.name}' -l tenant=${TENANT_NAME},component=stolon-keeper) ; do
  if oc logs ${OC_ARGS} --since=30s ${POD} | grep 'our db requested role is master' > /dev/null ; then
    PG_POD=${POD}
  fi
done

if [ $(compare_version "${WD_VERSION}" 4.0.0) -ge 0 ] || "${BACKUP_RESTORE_IN_POD:-false}" ; then
  brlog "INFO" "Start ${COMMAND} postgres..."
  BACKUP_RESTORE_DIR_IN_POD="/tmp/backup-restore-workspace"
  PG_BACKUP="pg_backup.tar.gz"
  PG_JOB_TEMPLATE="${SCRIPT_DIR}/src/backup-restore-job-template.yml"
  PG_JOB_FILE="${SCRIPT_DIR}/src/pg-backup-restore-job.yml"
  PG_BACKUP_RESTORE_JOB="wd-discovery-postgres-backup-restore"

  run_pg_job

  _oc_cp "${SCRIPT_DIR}/src" ${POD}:${BACKUP_RESTORE_DIR_IN_POD}/
  _oc_cp "${SCRIPT_DIR}/lib" ${POD}:${BACKUP_RESTORE_DIR_IN_POD}/
  _oc_cp "${SCRIPT_DIR}/src/${PG_BACKUP_RESTORE_SCRIPTS}" ${POD}:${BACKUP_RESTORE_DIR_IN_POD}/

  if [ "${COMMAND}" = "restore" ] ; then
    kube_cp_from_local ${POD} "${BACKUP_FILE}" "${BACKUP_RESTORE_DIR_IN_POD}/${PG_BACKUP}" ${OC_ARGS}
  fi
  oc exec ${POD} -- touch /tmp/wexdata_copied
  brlog "INFO" "Waiting for ${COMMAND} job to be completed..."
  if [ "${COMMAND}" = "restore" ] && require_tenant_backup ; then
    brlog "INFO" "Get tenant information."
    while :
    do
      tmp_files=$(fetch_cmd_result ${POD} "ls ${BACKUP_RESTORE_DIR_IN_POD}")
      if echo "${tmp_files}" | grep "tenants" > /dev/null ; then
        TENANT_FILE="tmp_wd_tenants_$(date "+%Y%m%d_%H%M%S").txt"
        kube_cp_to_local ${POD} "${TENANT_FILE}" "${BACKUP_RESTORE_DIR_IN_POD}/tenants" ${OC_ARGS}
        run_cmd_in_pod ${POD} "rm -f ${BACKUP_RESTORE_DIR_IN_POD}/tenants" ${OC_ARGS}
        break
      else
        sleep 10
      fi
    done
  fi
  while :
  do
    ls_tmp=$(fetch_cmd_result ${POD} 'ls /tmp') 
    if echo "${ls_tmp}" | grep "backup-restore-complete" > /dev/null ; then
      brlog "INFO" "Completed ${COMMAND} job"
      break;
    else
      sleep 10
      oc logs ${POD} --since=12s 2>&1 | tee -a "${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log" | grep -v "^error: unexpected EOF$" | grep "^[0-9]\{4\}/[0-9]\{2\}/[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}" || true
    fi
  done
  if [ "${COMMAND}" = "backup" ] ; then
    brlog "INFO" "Transferring backup data"
    kube_cp_to_local ${POD} "${BACKUP_FILE}" "${BACKUP_RESTORE_DIR_IN_POD}/${PG_BACKUP}" ${OC_ARGS}
    if "${VERIFY_DATASTORE_ARCHIVE}" && brlog "INFO" "Verifying backup archive" && ! tar "${PG_TAR_OPTIONS[@]}" -tf ${BACKUP_FILE} &> /dev/null ; then
      brlog "ERROR" "Backup file is broken, or does not exist."
      oc ${OC_ARGS} exec ${POD} -- bash -c "cd ${BACKUP_RESTORE_DIR_IN_POD}; ls | xargs rm -rf"
      exit 1
    fi
  fi
  oc ${OC_ARGS} delete -f "${PG_JOB_FILE}"

  if [ "${COMMAND}" = "restore" ] ; then
    brlog "INFO" "Run training db config job"
    ./run-postgres-config-job.sh ${TENANT_NAME} ${SCRIPT_ARGS}
    brlog "INFO" "Run core db config job"
    run_core_init_db_job
  fi

  rm -rf ${TMP_WORK_DIR}
  if [ -z "$(ls tmp)" ] ; then
    rm -rf tmp
  fi
  exit 0
fi

# backup
if [ ${COMMAND} = 'backup' ] ; then
  brlog "INFO" "Start backup postgresql..."
  run_cmd_in_pod ${PG_POD} 'export PGUSER=${STKEEPER_PG_SU_USERNAME} && \
  export PGPASSWORD=${STKEEPER_PG_SU_PASSWORD} && \
  export PGHOST=${HOSTNAME} && \
  rm -rf /tmp/'${PG_BACKUP_DIR}' '${PG_BACKUP}' && \
  mkdir -p /tmp/'${PG_BACKUP_DIR}' && \
  for DATABASE in $( psql -l | grep ${PGUSER} | cut -d "|" -f 1 | grep -v -e template -e postgres -e "^\s*$"); do pg_dump ${DATABASE} > '${PG_BACKUP_PREFIX}'${DATABASE}'${PG_BACKUP_SUFFIX}'; done && \
  touch /tmp/'${PG_BACKUP_DIR}'/version_'${PG_SCRIPT_VERSION} ${OC_ARGS}
  if "${ARCHIVE_ON_LOCAL}" ; then 
    brlog "INFO" "Transferring backup files"
    kube_cp_to_local -r ${PG_POD} "${TMP_WORK_DIR}/${PG_BACKUP_DIR}" "/tmp/${PG_BACKUP_DIR}" ${OC_ARGS}
    oc ${OC_ARGS} exec ${PG_POD} -- bash -c "rm -rf /tmp/${PG_BACKUP_DIR}"
    brlog "INFO" "Archiving data"
    tar "${PG_TAR_OPTIONS[@]}" -cf ${BACKUP_FILE} -C ${TMP_WORK_DIR} ${PG_BACKUP_DIR}
  else
    brlog "INFO" "Archiving data..."
    run_cmd_in_pod ${PG_POD} "tar ${PG_ARCHIVE_OPTION} -cf ${PG_BACKUP} -C /tmp ${PG_BACKUP_DIR} && rm -rf /tmp/${PG_BACKUP_DIR}" ${OC_ARGS}
    brlog "INFO" "Trasnfering archive..."
    kube_cp_to_local ${PG_POD} "${BACKUP_FILE}" "${PG_BACKUP}" ${OC_ARGS}
    oc ${OC_ARGS} exec ${PG_POD} -- bash -c "rm -rf /tmp/${PG_BACKUP_DIR} ${PG_BACKUP}"
  fi
  if "${VERIFY_DATASTORE_ARCHIVE}" && brlog "INFO" "Verifying backup archive" && ! tar "${PG_TAR_OPTIONS[@]}" -tf ${BACKUP_FILE} &> /dev/null ; then
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

  brlog "INFO" "Start restore postgresql: ${BACKUP_FILE}"

  if [ ! -e "${BACKUP_FILE}" ] ; then
    brlog "WARN" "no such file: ${BACKUP_FILE}"
    brlog "WARN" "Nothing to Restore"
    echo
    exit 1
  fi

  if require_tenant_backup ; then
    brlog "INFO" "Get tenant information."
    run_cmd_in_pod ${PG_POD} 'export PGUSER=${STKEEPER_PG_SU_USERNAME} && \
    export PGPASSWORD=${STKEEPER_PG_SU_PASSWORD} && \
    export PGHOST=${HOSTNAME} && \
    psql -d dadmin -c "COPY tenants TO '"'"'/tmp/tenants'"'"'"' ${OC_ARGS}
    TENANT_FILE="tmp_wd_tenants_$(date "+%Y%m%d_%H%M%S").txt"
    kube_cp_to_local ${PG_POD} "${TENANT_FILE}" "/tmp/tenants" ${OC_ARGS}
    if ! cat "${TENANT_FILE}" | grep "default" > /dev/null ; then
      brlog "ERROR" "Can not get tenant information"
      exit 1
    fi
    run_cmd_in_pod ${PG_POD} 'rm -f /tmp/tenants' ${OC_ARGS}
  fi

  if "${ARCHIVE_ON_LOCAL}" ; then
    brlog "INFO" "Extracting archive"
    tar "${PG_TAR_OPTIONS[@]}" -xf ${BACKUP_FILE} -C ${TMP_WORK_DIR}
    brlog "INFO" "Transferring backup files"
    kube_cp_from_local -r ${PG_POD} "${TMP_WORK_DIR}/${PG_BACKUP_DIR}" "/tmp/${PG_BACKUP_DIR}" ${OC_ARGS}
  else
    brlog "INFO" "Transferting archive..."
    kube_cp_from_local ${PG_POD} "${BACKUP_FILE}" "${PG_BACKUP}" ${OC_ARGS}
    brlog "INFO" "Extracting archive..."
    run_cmd_in_pod ${PG_POD} "cd tmp && rm -rf ${PG_BACKUP_DIR} && tar ${PG_ARCHIVE_OPTION} -xf ${PG_BACKUP}" ${OC_ARGS}
  fi
  brlog "INFO" "Restoreing data..."
  run_cmd_in_pod ${PG_POD} 'export PGUSER=${STKEEPER_PG_SU_USERNAME} && \
  export PGPASSWORD=${STKEEPER_PG_SU_PASSWORD} && \
  export PGHOST=${HOSTNAME} && \
  cd tmp && \
  for DATABASE in $(ls '${PG_BACKUP_DIR}'/*.dump | cut -d "/" -f 2 | sed -e "s/^pg_//g" -e "s/.dump$//g"); do
  psql -d ${DATABASE} -c "REVOKE CONNECT ON DATABASE ${DATABASE} FROM public;" || true && \
  psql -d ${DATABASE} -c "SELECT pid, pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid();" || true && \
  dropdb --if-exists ${DATABASE} && \
  createdb ${DATABASE} && \
  psql -d ${DATABASE} -c "GRANT CONNECT ON DATABASE ${DATABASE} TO public;" && \
  cat '${PG_BACKUP_PREFIX}'${DATABASE}'${PG_BACKUP_SUFFIX}' | grep -v "OWNER TO dadmin" | psql ${DATABASE} ; done && \
  rm -rf '${PG_BACKUP_DIR}' '${PG_BACKUP} ${OC_ARGS}
  brlog "INFO" "Done"

  brlog "INFO" "Run training db config job"
  ./run-postgres-config-job.sh ${TENANT_NAME} ${SCRIPT_ARGS}
  brlog "INFO" "Run core db config job"
  run_core_init_db_job

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