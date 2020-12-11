#!/bin/bash
set -euo pipefail

ROOT_DIR_MINIO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

source "${ROOT_DIR_MINIO}/lib/restore-updates.bash"
source "${ROOT_DIR_MINIO}/lib/function.bash"

# Setup the minio directories needed to create the backup file
KUBECTL_ARGS="" 
MINIO_BACKUP="/tmp/minio_backup.tar.gz"
MINIO_BACKUP_DIR="${MINIO_BACKUP_DIR:-minio_backup}"
MINIO_FORWARD_PORT=${MINIO_FORWARD_PORT:-39001}
TMP_WORK_DIR="tmp/minio_workspace"
MINIO_ELASTIC_BACKUP=${MINIO_ELASTIC_BACKUP:-false}
ELASTIC_BACKUP_BUCKET="elastic-backup"
SED_REG_OPT="`get_sed_reg_opt`"
SCRIPT_DIR=${ROOT_DIR_MINIO}

DATASTORE_ARCHIVE_OPTION="${DATASTORE_ARCHIVE_OPTION--z}"
MINIO_ARCHIVE_OPTION="${MINIO_ARCHIVE_OPTION-$DATASTORE_ARCHIVE_OPTION}"
if [ -n "${MINIO_ARCHIVE_OPTION}" ] ; then
  read -a MINIO_TAR_OPTIONS <<< ${MINIO_ARCHIVE_OPTION}
else
  MINIO_TAR_OPTIONS=("")
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
    "n" ) KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$OPTARG" ;;
  esac
done

brlog "INFO" "MinIO:"
brlog "INFO" "Release name: $RELEASE_NAME"

MINIO_SVC=`kubectl ${KUBECTL_ARGS} get svc -l release=${RELEASE_NAME},helm.sh/chart=minio -o jsonpath="{.items[*].metadata.name}" | tr '[[:space:]]' '\n' | grep headless`
MINIO_PORT=`kubectl ${KUBECTL_ARGS} get svc ${MINIO_SVC} -o jsonpath="{.spec.ports[0].port}"`
MINIO_SECRET=`kubectl ${KUBECTL_ARGS} get secret -l release=${RELEASE_NAME} -o jsonpath="{.items[*].metadata.name}" | tr -s '[[:space:]]' '\n' | grep minio`
MINIO_ACCESS_KEY=`kubectl get ${KUBECTL_ARGS} secret ${MINIO_SECRET} --template '{{.data.accesskey}}' | base64 --decode`
MINIO_SECRET_KEY=`kubectl get ${KUBECTL_ARGS} secret ${MINIO_SECRET} --template '{{.data.secretkey}}' | base64 --decode`
MINIO_ENDPOINT_URL=${MINIO_ENDPOINT_URL:-https://localhost:$MINIO_FORWARD_PORT}

rm -rf ${TMP_WORK_DIR}
mkdir -p ${TMP_WORK_DIR}/.mc
mkdir -p ${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}
if [ -n "${MC_COMMAND+UNDEF}" ] ; then
  MC=${MC_COMMAND}
else
  get_mc ${TMP_WORK_DIR}
  MC=${PWD}/${TMP_WORK_DIR}/mc
fi
export MINIO_CONFIG_DIR="${PWD}/${TMP_WORK_DIR}/.mc"
MC_OPTS=(--config-dir ${MINIO_CONFIG_DIR} --insecure)

# backup
if [ "${COMMAND}" = "backup" ] ; then
  BACKUP_FILE=${BACKUP_FILE:-"minio_`date "+%Y%m%d_%H%M%S"`.tar.gz"}
  brlog "INFO" "Start backup minio"
  brlog "INFO" "Backup data..."
  start_minio_port_forward
  ${MC} ${MC_OPTS[@]} --quiet config host add wdminio ${MINIO_ENDPOINT_URL} ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} > /dev/null
  EXCLUDE_OBJECTS=`cat "${ROOT_DIR_MINIO}/src/minio_exclude_paths"`
  for bucket in `${MC} ${MC_OPTS[@]} ls wdminio | sed ${SED_REG_OPT} "s|.*[0-9]+B\ (.*)/.*|\1|g" | grep -v ${ELASTIC_BACKUP_BUCKET}`
  do
    EXTRA_MC_MIRROR_COMMAND=""
    ORG_IFS=${IFS}
    IFS=$'\n'
    for line in ${EXCLUDE_OBJECTS}
    do
      if [[ ${line} == ${bucket}* ]] ; then
        EXTRA_MC_MIRROR_COMMAND="--exclude ${line#$bucket } ${EXTRA_MC_MIRROR_COMMAND}"
      fi
    done
    IFS=${ORG_IFS}
    cd ${TMP_WORK_DIR}
    ${MC} ${MC_OPTS[@]} --quiet mirror ${EXTRA_MC_MIRROR_COMMAND} wdminio/${bucket} ${MINIO_BACKUP_DIR}/${bucket} > /dev/null
    cd - > /dev/null
  done
  stop_minio_port_forward
  brlog "INFO" "Archiving data..."
  tar ${MINIO_TAR_OPTIONS[@]} -cf ${BACKUP_FILE} -C ${TMP_WORK_DIR}/${MINIO_BACKUP_DIR} .
  if "${VERIFY_DATASTORE_ARCHIVE}" && brlog "INFO" "Verifying backup archive" && ! tar ${MINIO_TAR_OPTIONS[@]} -tf ${BACKUP_FILE} &> /dev/null ; then
    brlog "ERROR" "Backup file is broken, or does not exist."
    exit 1
  fi
  brlog "INFO" "Done: ${BACKUP_FILE}"
fi

# restore
if [ "${COMMAND}" = "restore" ] ; then
  if [ -z ${BACKUP_FILE} ] ; then
    printUsage
  fi
  if [ ! -e "${BACKUP_FILE}" ] ; then
    brlog "WARN" "no such file: ${BACKUP_FILE}"
    brlog "WARN" "Nothing to Restore"
    echo
    exit 1
  fi
  brlog "INFO" "Start restore minio: ${BACKUP_FILE}"
  brlog "INFO" "Extracting archive..."
  tar ${MINIO_TAR_OPTIONS[@]} -xf ${BACKUP_FILE} -C ${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}
  brlog "INFO" "Restoring data..."
  start_minio_port_forward
  ${MC} ${MC_OPTS[@]} --quiet config host add wdminio ${MINIO_ENDPOINT_URL} ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} > /dev/null
  for bucket in `ls ${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}`
  do
    if ${MC} ${MC_OPTS[@]} ls wdminio | grep ${bucket} > /dev/null ; then
      ${MC} ${MC_OPTS[@]} --quiet rm --recursive --force --dangerous "wdminio/${bucket}/" > /dev/null
      ${MC} ${MC_OPTS[@]} --quiet mirror ${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}/${bucket} wdminio/${bucket} > /dev/null
    fi
  done
  stop_minio_port_forward
  brlog "INFO" "Done"
  brlog "INFO" "Applying updates"
  . ./lib/restore-updates.bash
  minio_updates
  brlog "INFO" "Completed Updates"
  echo
fi

rm -rf ${TMP_WORK_DIR}
if [ -z "$(ls tmp)" ] ; then
  rm -rf tmp
fi