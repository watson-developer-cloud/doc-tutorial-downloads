#!/bin/bash

set -euo pipefail

ROOT_DIR_WDDATA="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
typeset -r ROOT_DIR_WDDATA

# shellcheck source=lib/restore-utilites.bash
source "${ROOT_DIR_WDDATA}/lib/restore-updates.bash"
source "${ROOT_DIR_WDDATA}/lib/function.bash"

KUBECTL_ARGS=""
WDDATA_BACKUP="wddata.tar.gz"
TMP_WORK_DIR="tmp/wddata"

DATASTORE_ARCHIVE_OPTION="${DATASTORE_ARCHIVE_OPTION--z}"
WDDATA_ARCHIVE_OPTION="${WDDATA_ARCHIVE_OPTION-$DATASTORE_ARCHIVE_OPTION}"
if [ -n "${WDDATA_ARCHIVE_OPTION}" ] ; then
  read -a WDDATA_TAR_OPTIONS <<< ${WDDATA_ARCHIVE_OPTION}
else
  WDDATA_TAR_OPTIONS=("")
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
    "n" ) KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$OPTARG"
          BACKUP_ARG="-n $OPTARG";;
  esac
done

brlog "INFO" "WDData: "
brlog "INFO" "Release name: $RELEASE_NAME"
INGESTION_API_POD=`kubectl get pods ${KUBECTL_ARGS} -o jsonpath="{.items[0].metadata.name}" -l release=${RELEASE_NAME},run=ingestion-api`
ORG_KUBECTL_ARGS=${KUBECTL_ARGS}
BACKUP_ARG=${BACKUP_ARG:-""}

export KUBECTL_ARGS="${KUBECTL_ARGS} -c ingestion-api"

# backup wddata
if [ ${COMMAND} = 'backup' ] ; then
  BACKUP_FILE=${BACKUP_FILE:-"wddata_`date "+%Y%m%d_%H%M%S"`.backup"}
  brlog "INFO" "Start backup wddata..."
  mkdir -p ${TMP_WORK_DIR}/wexdata/config/certs
  kubectl cp ${KUBECTL_ARGS} ${INGESTION_API_POD}:/tmp/config/certs/crawler.ini ${TMP_WORK_DIR}/wexdata/config/certs/crawler.ini
  tar ${WDDATA_TAR_OPTIONS[@]} -cf ${BACKUP_FILE} -C ${TMP_WORK_DIR} wexdata
  rm -rf ${TMP_WORK_DIR}
  if [ -z "$(ls tmp)" ] ; then
    rm -rf tmp
  fi
  if "${VERIFY_DATASTORE_ARCHIVE}" && brlog "INFO" "Verifying backup archive" && ! tar ${WDDATA_TAR_OPTIONS[@]} -tf ${BACKUP_FILE} &> /dev/null ; then
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
  tar ${WDDATA_TAR_OPTIONS[@]} -xf ${BACKUP_FILE} -C ${TMP_WORK_DIR}
  ${ROOT_DIR_WDDATA}/src/update-ingestion-conf.sh ${RELEASE_NAME} ${TMP_WORK_DIR}/wexdata ${BACKUP_ARG}
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

export KUBECTL_ARGS=${ORG_KUBECTL_ARGS}
