#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

source "${SCRIPT_DIR}/lib/restore-updates.bash"
source "${SCRIPT_DIR}/lib/function.bash"

# Setup the minio directories needed to create the backup file
OC_ARGS="${OC_ARGS:-}" 
MINIO_BACKUP="minio_backup.tar.gz"
MINIO_BACKUP_DIR="${MINIO_BACKUP_DIR:-minio_backup}"
MINIO_FORWARD_PORT=${MINIO_FORWARD_PORT:-39001}
TMP_WORK_DIR="tmp/minio_workspace"
MINIO_JOB_FILE="${SCRIPT_DIR}/src/minio-backup-restore-job.yml"
BACKUP_RESTORE_IN_POD=${BACKUP_RESTORE_IN_POD-false}
CURRENT_COMPONENT="minio"
MINIO_ELASTIC_BACKUP=${MINIO_ELASTIC_BACKUP:-false}
DISABLE_MC_MULTIPART=${DISABLE_MC_MULTIPART:-true}
ELASTIC_BACKUP_BUCKET="elastic-backup"
SED_REG_OPT="`get_sed_reg_opt`"
SCRIPT_DIR=${SCRIPT_DIR}

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
    "n" ) OC_ARGS="${OC_ARGS} --namespace=$OPTARG" ;;
  esac
done

brlog "INFO" "MinIO:"
brlog "INFO" "Tenant name: $TENANT_NAME"

BACKUP_FILE=${BACKUP_FILE:-"minio_`date "+%Y%m%d_%H%M%S"`.tar.gz"}

MINIO_ARCHIVE_OPTION="${MINIO_ARCHIVE_OPTION-$DATASTORE_ARCHIVE_OPTION}"
if [ -n "${MINIO_ARCHIVE_OPTION}" ] ; then
  read -a MINIO_TAR_OPTIONS <<< ${MINIO_ARCHIVE_OPTION}
else
  MINIO_TAR_OPTIONS=("")
fi
VERIFY_ARCHIVE=${VERIFY_ARCHIVE:-true}
VERIFY_DATASTORE_ARCHIVE=${VERIFY_DATASTORE_ARCHIVE:-$VERIFY_ARCHIVE}

MINIO_SVC=`oc ${OC_ARGS} get svc -l release=${TENANT_NAME}-minio,helm.sh/chart=ibm-minio -o jsonpath="{.items[*].metadata.name}" | tr '[[:space:]]' '\n' | grep headless`
MINIO_PORT=`oc ${OC_ARGS} get svc ${MINIO_SVC} -o jsonpath="{.spec.ports[0].port}"`
MINIO_SECRET=`oc ${OC_ARGS} get secret -l tenant=${TENANT_NAME},run=minio-auth -o jsonpath="{.items[*].metadata.name}" | tr -s '[[:space:]]' '\n' | grep minio`
MINIO_ACCESS_KEY=`oc get ${OC_ARGS} secret ${MINIO_SECRET} --template '{{.data.accesskey}}' | base64 --decode`
MINIO_SECRET_KEY=`oc get ${OC_ARGS} secret ${MINIO_SECRET} --template '{{.data.secretkey}}' | base64 --decode`
MINIO_ENDPOINT_URL=${MINIO_ENDPOINT_URL:-https://localhost:$MINIO_FORWARD_PORT}

rm -rf ${TMP_WORK_DIR}

mkdir -p "${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}"
mkdir -p "${BACKUP_RESTORE_LOG_DIR}"

if "${BACKUP_RESTORE_IN_POD}" ; then
  BACKUP_RESTORE_DIR_IN_POD="/tmp/backup-restore-workspace"
  MINIO_BACKUP_RESTORE_SCRIPTS="minio-backup-restore-in-pod.sh"
  MINIO_BACKUP_RESTORE_JOB="wd-discovery-minio-backup-restore"
  MINIO_JOB_TEMPLATE="${SCRIPT_DIR}/src/backup-restore-job-template.yml"
  JOB_CPU_LIMITS="${MC_CPU_LIMITS:-800m}" # backward compatibility
  JOB_CPU_LIMITS="${JOB_CPU_LIMITS:-800m}"
  JOB_MEMORY_LIMITS="${MC_MEMORY_LIMITS:-2Gi}" # backward compatibility
  JOB_MEMORY_LIMITS="${JOB_MEMORY_LIMITS:-2Gi}"
  NAMESPACE=${NAMESPACE:-`oc config view --minify --output 'jsonpath={..namespace}'`}
  WD_MIGRATOR_IMAGE="`get_migrator_image`"
  ELASTIC_CONFIGMAP=`oc get ${OC_ARGS} configmap -l tenant=${TENANT_NAME},app=elastic-cxn -o jsonpath="{.items[0].metadata.name}"`
  ELASTIC_SECRET=`oc ${OC_ARGS} get secret -l tenant=${TENANT_NAME},run=elastic-secret -o jsonpath="{.items[*].metadata.name}"`
  MINIO_CONFIGMAP=`oc get ${OC_ARGS} configmap -l tenant=${TENANT_NAME},app=minio -o jsonpath="{.items[0].metadata.name}"`
  DISCO_SVC_ACCOUNT=`get_service_account`
  NAMESPACE=${NAMESPACE:-`oc config view --minify --output 'jsonpath={..namespace}'`}
  CURRENT_TZ=`date "+%z" | tr -d '0'`
  if echo "${CURRENT_TZ}" | grep "+" > /dev/null; then
    TZ_OFFSET="UTC-`echo ${CURRENT_TZ} | tr -d '+'`"
  else
    TZ_OFFSET="UTC+`echo ${CURRENT_TZ} | tr -d '-'`"
  fi

  sed -e "s/#namespace#/${NAMESPACE}/g" \
    -e "s/#svc-account#/${DISCO_SVC_ACCOUNT}/g" \
    -e "s|#image#|${WD_MIGRATOR_IMAGE}|g" \
    -e "s/#cpu-limit#/${JOB_CPU_LIMITS}/g" \
    -e "s/#memory-limit#/${JOB_MEMORY_LIMITS}/g" \
    -e "s|#command#|./${MINIO_BACKUP_RESTORE_SCRIPTS} ${COMMAND}|g" \
    -e "s/#job-name#/${MINIO_BACKUP_RESTORE_JOB}/g" \
    -e "s/#tenant#/${TENANT_NAME}/g" \
    "${MINIO_JOB_TEMPLATE}" > "${MINIO_JOB_FILE}"
  add_config_env_to_job_yaml "ELASTIC_ENDPOINT" "${ELASTIC_CONFIGMAP}" "endpoint" "${MINIO_JOB_FILE}"
  add_secret_env_to_job_yaml "ELASTIC_USER" "${ELASTIC_SECRET}" "username" "${MINIO_JOB_FILE}"
  add_secret_env_to_job_yaml "ELASTIC_PASSWORD" "${ELASTIC_SECRET}" "password" "${MINIO_JOB_FILE}"
  add_config_env_to_job_yaml "MINIO_ENDPOINT_URL" "${MINIO_CONFIGMAP}" "endpoint" "${MINIO_JOB_FILE}"
  add_config_env_to_job_yaml "S3_HOST" "${MINIO_CONFIGMAP}" "host" "${MINIO_JOB_FILE}"
  add_config_env_to_job_yaml "S3_PORT" "${MINIO_CONFIGMAP}" "port" "${MINIO_JOB_FILE}"
  add_config_env_to_job_yaml "S3_ELASTIC_BACKUP_BUCKET" "${MINIO_CONFIGMAP}" "bucketElasticBackup" "${MINIO_JOB_FILE}"
  add_secret_env_to_job_yaml "MINIO_ACCESS_KEY" "${MINIO_SECRET}" "accesskey" "${MINIO_JOB_FILE}"
  add_secret_env_to_job_yaml "MINIO_SECRET_KEY" "${MINIO_SECRET}" "secretkey" "${MINIO_JOB_FILE}"
  add_env_to_job_yaml "MINIO_ARCHIVE_OPTION" "${MINIO_ARCHIVE_OPTION}" "${MINIO_JOB_FILE}"
  add_env_to_job_yaml "DISABLE_MC_MULTIPART" "${DISABLE_MC_MULTIPART}" "${MINIO_JOB_FILE}"
  add_env_to_job_yaml "TZ" "${TZ_OFFSET}" "${MINIO_JOB_FILE}"
  add_volume_to_job_yaml "${JOB_PVC_NAME:-emptyDir}" "${MINIO_JOB_FILE}"

  oc ${OC_ARGS} delete -f "${MINIO_JOB_FILE}" &> /dev/null || true
  oc ${OC_ARGS} apply -f "${MINIO_JOB_FILE}"
  get_job_pod "app.kubernetes.io/component=${MINIO_BACKUP_RESTORE_JOB},tenant=${TENANT_NAME}"
  wait_job_running ${POD}
  oc ${OC_ARGS} cp "${SCRIPT_DIR}/src" ${POD}:${BACKUP_RESTORE_DIR_IN_POD}/
  oc ${OC_ARGS} cp "${SCRIPT_DIR}/lib" ${POD}:${BACKUP_RESTORE_DIR_IN_POD}/
  oc ${OC_ARGS} cp "${SCRIPT_DIR}/src/${MINIO_BACKUP_RESTORE_SCRIPTS}" ${POD}:${BACKUP_RESTORE_DIR_IN_POD}/

  if [ ${COMMAND} == "restore" ] ; then
    brlog "INFO" "Transferring backup data"
    kube_cp_from_local ${POD} "${BACKUP_FILE}" "${BACKUP_RESTORE_DIR_IN_POD}/${MINIO_BACKUP}" ${OC_ARGS}
  fi
  oc ${OC_ARGS} exec ${POD} -- touch /tmp/wexdata_copied
  brlog "INFO" "Waiting for ${COMMAND} job to be completed..."
  while :
  do
    if fetch_cmd_result ${POD} 'ls /tmp' | grep "backup-restore-complete" > /dev/null ; then
      brlog "INFO" "Completed ${COMMAND} job"
      break;
    else
      sleep 10
      oc ${OC_ARGS} logs ${POD} --since=12s 2>&1 | tee -a "${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log" | grep -v "^error: unexpected EOF$" | grep "^[0-9]\{4\}/[0-9]\{2\}/[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}" || true
    fi
  done
  if [ "${COMMAND}" = "backup" ] ; then
    brlog "INFO" "Transferring backup data"
    kube_cp_to_local ${POD} "${BACKUP_FILE}" "${BACKUP_RESTORE_DIR_IN_POD}/${MINIO_BACKUP}" ${OC_ARGS}
    if "${VERIFY_DATASTORE_ARCHIVE}" && brlog "INFO" "Verifying backup archive" && ! tar ${ELASTIC_TAR_OPTIONS[@]} -tf ${BACKUP_FILE} &> /dev/null ; then
      brlog "ERROR" "Backup file is broken, or does not exist."
      oc ${OC_ARGS} exec ${POD} -- bash -c "cd ${BACKUP_RESTORE_DIR_IN_POD}; ls | xargs rm -rf"
      exit 1
    fi
  fi
  oc ${OC_ARGS} exec ${POD} -- bash -c "cd ${BACKUP_RESTORE_DIR_IN_POD}; ls | xargs rm -rf"
  oc ${OC_ARGS} delete -f "${MINIO_JOB_FILE}"
  rm -rf ${TMP_WORK_DIR}
  if [ -z "$(ls tmp)" ] ; then
    rm -rf tmp
  fi
  exit 0
fi

mkdir -p ${TMP_WORK_DIR}/.mc
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
  brlog "INFO" "Start backup minio"
  brlog "INFO" "Backup data..."
  start_minio_port_forward
  ${MC} ${MC_OPTS[@]} --quiet config host add wdminio ${MINIO_ENDPOINT_URL} ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} > /dev/null
  EXCLUDE_OBJECTS=`cat "${SCRIPT_DIR}/src/minio_exclude_paths"`
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
    set +e
    ${MC} ${MC_OPTS[@]} --quiet mirror ${EXTRA_MC_MIRROR_COMMAND} wdminio/${bucket} ${MINIO_BACKUP_DIR}/${bucket} &>> "${SCRIPT_DIR}/${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log"
    RC=$?
    echo "RC=${RC}" >> "${SCRIPT_DIR}/${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log"
    if [ $RC -ne 0 ] ; then
      brlog "ERROR" "Some file could not be transfered. Consider to use '--use-job' and '--pvc' option. Please see help (--help) for details."
      exit 1
    fi
    set -e
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
      if [ -n "`${MC} ${MC_OPTS[@]} ls wdminio/${bucket}/`" ] ; then
        ${MC} ${MC_OPTS[@]} --quiet rm --recursive --force --dangerous "wdminio/${bucket}/" > /dev/null
      fi
      if [ "${bucket}" = "discovery-dfs" ] ; then
        continue
      fi
      set +e
      ${MC} ${MC_OPTS[@]} --quiet mirror ${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}/${bucket} wdminio/${bucket} &>> "${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log"
      RC=$?
      echo "RC=${RC}" >> "${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log"
      if [ $RC -ne 0 ] ; then
        brlog "ERROR" "Some files could not be transfered. Please consider to use '--use-job' and '--pvc' option. See help (--help) for details."
        exit 1
      fi
      set -e
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