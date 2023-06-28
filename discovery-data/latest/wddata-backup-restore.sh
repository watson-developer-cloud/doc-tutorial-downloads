#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
typeset -r SCRIPT_DIR

# shellcheck source=lib/restore-utilites.bash
source "${SCRIPT_DIR}/lib/restore-updates.bash"
source "${SCRIPT_DIR}/lib/function.bash"

OC_ARGS="${OC_ARGS:-}"
WDDATA_BACKUP="wddata.tar.gz"
TMP_WORK_DIR="tmp/wddata"
CURRENT_COMPONENT="wddata"

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
          BACKUP_ARG="-n $OPTARG";;
  esac
done

brlog "INFO" "WDData: "
brlog "INFO" "Tenant name: $TENANT_NAME"
BACKUP_ARG=${BACKUP_ARG:-""}

WDDATA_ARCHIVE_OPTION="${WDDATA_ARCHIVE_OPTION-$DATASTORE_ARCHIVE_OPTION}"
if [ -n "${WDDATA_ARCHIVE_OPTION}" ] ; then
  read -a WDDATA_TAR_OPTIONS <<< ${WDDATA_ARCHIVE_OPTION}
else
  WDDATA_TAR_OPTIONS=("")
fi
VERIFY_ARCHIVE=${VERIFY_ARCHIVE:-true}
VERIFY_DATASTORE_ARCHIVE=${VERIFY_DATASTORE_ARCHIVE:-$VERIFY_ARCHIVE}

mkdir -p "${BACKUP_RESTORE_LOG_DIR}"

# backup wddata
if [ ${COMMAND} = 'backup' ] ; then
  BACKUP_FILE=${BACKUP_FILE:-"wddata_$(date "+%Y%m%d_%H%M%S").backup"}
  brlog "INFO" "Start backup wddata..."
  CK_SECRET=$(oc get ${OC_ARGS} secret -o jsonpath='{.items[*].metadata.name}' -l tenant=${TENANT_NAME},app=ck-secret)
  OK=$(oc get ${OC_ARGS} secret ${CK_SECRET} --template '{{.data.OK}}' | base64 --decode)
  CK=$(oc get ${OC_ARGS} secret ${CK_SECRET} --template '{{.data.CK}}' | base64 --decode)
  PASSWORD=$(oc get ${OC_ARGS} secret ${CK_SECRET} --template '{{.data.Password}}' | base64 --decode)
  mkdir -p ${TMP_WORK_DIR}/wexdata/config/certs
  cat <<EOF > ${TMP_WORK_DIR}/wexdata/config/certs/crawler.ini
OK=${OK}
CK=${CK}
Password=${PASSWORD}
EOF
  tar "${WDDATA_TAR_OPTIONS[@]}" -cf ${BACKUP_FILE} -C ${TMP_WORK_DIR} wexdata
  rm -rf ${TMP_WORK_DIR}
  if [ -z "$(ls tmp)" ] ; then
    rm -rf tmp
  fi
  if "${VERIFY_DATASTORE_ARCHIVE}" && brlog "INFO" "Verifying backup archive" && ! tar "${WDDATA_TAR_OPTIONS[@]}" -tf ${BACKUP_FILE} &> /dev/null ; then
    brlog "ERROR" "Backup file is broken, or does not exist."
    exit 1
  fi
  brlog "INFO" "Done: ${BACKUP_FILE}"
fi

#restore wddata
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
  brlog "INFO" "Start restore wddata: ${BACKUP_FILE}"
  mkdir -p ${TMP_WORK_DIR}
  tar "${WDDATA_TAR_OPTIONS[@]}" -xf ${BACKUP_FILE} -C ${TMP_WORK_DIR}
  ${SCRIPT_DIR}/src/update-ingestion-conf.sh ${TENANT_NAME} ${TMP_WORK_DIR}/wexdata ${BACKUP_ARG}
  rm -rf ${TMP_WORK_DIR}
  if [ -z "$(ls tmp)" ] ; then
    rm -rf tmp
  fi
  brlog "INFO" "Restore Done"
  brlog "INFO" "Applying updates"
  . ./lib/restore-updates.bash
  wddata_updates
  brlog "INFO" "Completed Updates"
  echo

fi
