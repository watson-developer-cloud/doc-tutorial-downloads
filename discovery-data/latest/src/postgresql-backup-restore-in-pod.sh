#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
typeset -r SCRIPT_DIR

# shellcheck source=lib/restore-utilites.bash
source "${SCRIPT_DIR}/lib/restore-updates.bash"
source "${SCRIPT_DIR}/lib/function.bash"

OC_ARGS="${OC_ARGS:-}"
PG_BACKUP="pg_backup.tar.gz"
PG_BACKUP_DIR="pg_backup"
PG_BACKUP_SUFFIX=".dump"
PG_SCRIPT_VERSION="2.1.3"
TMP_WORK_DIR="/tmp/backup-restore-workspace"
PG_BACKUP_PREFIX="${TMP_WORK_DIR}/${PG_BACKUP_DIR}/pg_"
CURRENT_COMPONENT="postgresql"
POSTGRES_CONFIG_JOB="wire-postgres"

printUsage() {
  echo "Usage: $(basename ${0}) [command] [releaseName] [-f backupFile]"
  exit 1
}

COMMAND=$1
shift

SCRIPT_ARGS=${SCRIPT_ARGS:-""}

PG_ARCHIVE_OPTION="${PG_ARCHIVE_OPTION--z}"
if [ -n "${PG_ARCHIVE_OPTION}" ] ; then
  read -a PG_TAR_OPTIONS <<< ${PG_ARCHIVE_OPTION}
else
  PG_TAR_OPTIONS=("")
fi

ARCHIVE_ON_LOCAL=${ARCHIVE_ON_LOCAL:-false}

mkdir -p ${BACKUP_RESTORE_LOG_DIR}

# backup
if [ ${COMMAND} = 'backup' ] ; then
  BACKUP_FILE=${BACKUP_FILE:-"pg_$(date "+%Y%m%d_%H%M%S").backup"}
  brlog "INFO" "Start backup postgresql..."
  mkdir -p ${TMP_WORK_DIR}/${PG_BACKUP_DIR}
  for DATABASE in $( psql -l | grep ${PGUSER} | cut -d "|" -f 1 | grep -v -e template -e postgres -e "^\s*$")
  do
    pg_dump ${DATABASE} > "${PG_BACKUP_PREFIX}${DATABASE}${PG_BACKUP_SUFFIX}"
  done
  touch ${TMP_WORK_DIR}/${PG_BACKUP_DIR}/version_${PG_SCRIPT_VERSION}
  brlog "INFO" "Archiving data..."
  tar "${PG_TAR_OPTIONS[@]}" -cf "${TMP_WORK_DIR}/${PG_BACKUP}" -C "${TMP_WORK_DIR}" "${PG_BACKUP_DIR}" && rm -rf "${TMP_WORK_DIR}/${PG_BACKUP_DIR}"
fi

# restore
if [ ${COMMAND} = 'restore' ] ; then

  mkdir -p ${TMP_WORK_DIR}
  cd ${TMP_WORK_DIR}

  if "${REQUIRE_TENANT_BACKUP}" ; then 
    if ! psql -d dadmin -c "SELECT id FROM tenants" | grep "default" > /dev/null ; then
      psql -d dadmin -c "UPDATE tenants SET id = 'default'"
    fi

    psql -d dadmin -c "\COPY tenants TO '${TMP_WORK_DIR}/tenants'"
    if ! cat "${TMP_WORK_DIR}/tenants" | grep "default" > /dev/null ; then
      brlog "ERROR" "Can not get tenant information"
      exit 1
    fi

    while ls ${TMP_WORK_DIR}/tenants | grep "tenants" > /dev/null
    do
      sleep 10
    done
  fi

  brlog "INFO" "Extracting archive..."
  tar ${PG_ARCHIVE_OPTION} -xf ${PG_BACKUP}

  brlog "INFO" "Restoreing data..."
  for DATABASE in $(ls ${PG_BACKUP_DIR}/*.dump | cut -d "/" -f 2 | grep -v dfs | sed -e "s/^pg_//g" -e "s/.dump$//g")
  do
    if psql -lqt | cut -d \| -f 1 | grep -qw "${DATABASE}" ; then
      psql -d ${DATABASE} -c "REVOKE CONNECT ON DATABASE ${DATABASE} FROM public;"
      psql -d ${DATABASE} -c "SELECT pid, pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid();"
      dropdb --if-exists ${DATABASE}
    fi
    createdb ${DATABASE}
    psql -d ${DATABASE} -c "GRANT CONNECT ON DATABASE ${DATABASE} TO public;"
    cat ${PG_BACKUP_PREFIX}${DATABASE}${PG_BACKUP_SUFFIX} | grep -v "OWNER TO dadmin" | grep -v "OWNER TO enterprisedb" | psql ${DATABASE}
  done
  rm -rf ${PG_BACKUP_DIR} ${PG_BACKUP}
  brlog "INFO" "Done"

  brlog "INFO" "Applying updates"
  for pgupdate in $(ls ${TMP_WORK_DIR}/src/*.pgupdate | grep -v dfs)
  do
    eval "$(cat ${pgupdate})"
  done
  brlog "INFO" "Completed Updates"
fi