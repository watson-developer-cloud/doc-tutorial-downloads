export BACKUP_RESTORE_LOG_LEVEL="${BACKUP_RESTORE_LOG_LEVEL:-INFO}"
case "${BACKUP_RESTORE_LOG_LEVEL}" in
  "ERROR") export LOG_LEVEL_NUM=0;;
  "WARN")  export LOG_LEVEL_NUM=1;;
  "INFO")  export LOG_LEVEL_NUM=2;;
  "DEBUG") export LOG_LEVEL_NUM=3;;
esac

brlog(){
  LOG_LEVEL=$1
  shift
  LOG_MESSAGE=$1
  shift
  LOG_DATE=`date "+%Y/%m/%d %H:%M:%S"`
  case ${LOG_LEVEL} in
    ERROR) LEVEL_NUM=0;;
    WARN)  LEVEL_NUM=1;;
    INFO)  LEVEL_NUM=2;;
    DEBUG) LEVEL_NUM=3;;
    *)     return;;
  esac
  if [ ${LEVEL_NUM} -le ${LOG_LEVEL_NUM} ] ; then
    echo "${LOG_DATE}: [${LOG_LEVEL}] ${LOG_MESSAGE}"
  fi
}

set_scripts_version(){
  if [ -n "${SCRIPT_VERSION+UNDEF}" ] ; then
    return
  fi
  SCRIPT_VERSION_FILE="${SCRIPT_DIR}/version.txt"
  if [ ! -e "${SCRIPT_VERSION_FILE}" ] ; then
    brlog "INFO" "No version file."
    export SCRIPT_VERSION="0.0.0"
  fi

  ORG_IFS=${IFS}
  IFS=$'\n'
  for line in `cat "${SCRIPT_VERSION_FILE}"`
  do
    brlog "INFO" "${line}"
    if [[ ${line} == "Scripts Version:"* ]] ; then
      export SCRIPT_VERSION="${line#*: }"
    fi
  done
  IFS=${ORG_IFS}
}

validate_version(){
  VERSIONS=(${SCRIPT_VERSION//./ })
  VERSION="${VERSIONS[0]}.${VERSIONS[1]}.${VERSIONS[2]}"
  if [ `compare_version "${VERSION}" "${WD_VERSION}"` -lt 0 ] ; then
    brlog "ERROR" "Invalid script version. The version of scripts '${SCRIPT_VERSION}' is not valid for the version of Watson Doscovery '${WD_VERSION}' "
    exit 1
  fi
}

get_version(){
  if [ -n "`kubectl get pod ${KUBECTL_ARGS} -l "app.kubernetes.io/name=discovery,run=management"`" ] ; then
    if kubectl get pod ${KUBECTL_ARGS} -l "app.kubernetes.io/name=discovery,run=management" -o jsonpath="{..image}" | tr -s '[[:space:]]' '\n' | grep "wd-management:12.0.4-1049" > /dev/null ; then
      echo "2.1.3"
    else
      echo "2.1.4"
    fi
  elif [ -n "`kubectl get sts ${KUBECTL_ARGS} -l "app.kubernetes.io/name=discovery,run=gateway" -o jsonpath="{..image}" | grep "wd-management"`" ] ; then
    echo "2.1.2"
  else
    echo "2.1"
  fi
}

get_version_num(){
  case "$1" in
    "2.1") echo 1;;
    "2.1.2") echo 2;;
    "2.1.3") echo 3;;
    "2.1.4") echo 4;;
    *)     echo 0;;
  esac
}

compare_version(){
  VER_1=`get_version_num "$1"`
  VER_2=`get_version_num "$2"`
  if [ ${VER_1} -lt ${VER_2} ] ; then
    echo "-1"
  elif [ ${VER_1} -eq ${VER_2} ] ; then
    echo 0
  else
    echo 1
  fi
}

get_backup_version(){
  if [ -e "${BACKUP_VERSION_FILE}" ] ; then
    cat "${BACKUP_VERSION_FILE}"
  else
    echo "2.1" # 2.1.2 or earlier
  fi
}

get_stat_command(){
  if [ "$(uname)" = "Darwin" ] ; then
    echo 'stat -f "%z"'
  elif [ "$(uname)" = "Linux" ] ; then
    echo 'stat --printf="%s"'
  else
    echo "Unexpected os type. Use: stat --printf='%s'" >&2
    echo 'stat --printf="%s"'
  fi
}

get_sed_reg_opt(){
  if [ -n "${SED_REG_OPT+UNDEF}" ] ; then
    echo " ${SED_REG_OPT}"
  elif [ "$(uname)" = "Darwin" ] ; then
    echo ' -E'
  elif [ "$(uname)" = "Linux" ] ; then
    echo ' -r'
  else
    echo "Unexpected os type. Use '-r' as a regex option for sed." >&2
    echo ' -r'
  fi
}

get_base64_opt(){
  if [ -n "${BASE64_OPT+UNDEF}" ] ; then
    echo " ${BASE64_OPT}"
  elif [ "$(uname)" = "Darwin" ] ; then
    echo '-b 0'
  elif [ "$(uname)" = "Linux" ] ; then
    echo '-w 0'
  else
    echo "Unexpected os type. Use base64 option '-w 0'." >&2
    echo '-w 0'
  fi
}

TRANSFER_COMPRESS_OPTION="${TRANSFER_COMPRESS_OPTION--z}"
if [ -n "${TRANSFER_COMPRESS_OPTION}" ] ; then
  read -a TRANSFER_TAR_OPTIONS <<< ${TRANSFER_COMPRESS_OPTION}
else
  TRANSFER_TAR_OPTIONS=("")
fi

kube_cp_from_local(){
  IS_RECURSIVE=false
  if [ "$1" = "-r" ] ; then
    IS_RECURSIVE=true
    shift
  fi
  POD=$1
  shift
  LOCAL_BACKUP=$1
  shift
  POD_BACKUP=$1
  shift
  SPLITE_DIR=./tmp_split_bakcup
  SPLITE_SIZE=${BACKUP_RESTORE_SPLIT_SIZE:-500000000}
  
  LOCAL_BASE_NAME=$(basename "${LOCAL_BACKUP}")
  POD_DIST_DIR=$(dirname "${POD_BACKUP}")

  if "${IS_RECURSIVE}" ; then
    ORG_POD_BACKUP=${POD_BACKUP}
    ORG_LOCAL_BACKUP=${LOCAL_BACKUP}
    kubectl exec $@ ${POD} -- bash -c "mkdir -p ${ORG_POD_BACKUP}"
    for file in `find "${ORG_LOCAL_BACKUP}" -type f` ; do
      relative_path=${file#$ORG_LOCAL_BACKUP/}
      FILE_DIR_NAME=$(dirname "${relative_path}")
      if [ "${FILE_DIR_NAME}" != "." ] ; then
        kubectl exec $@ ${POD} -- bash "mkdir -p ${ORG_POD_BACKUP}/${FILE_DIR_NAME}"
      fi
      if [ ${TRANSFER_WITH_COMPRESSION-true} ] ; then
        tar -C ${ORG_LOCAL_BACKUP} ${TRANSFER_TAR_OPTIONS[@]} -cf ${file}.tgz ${relative_path}
        kube_cp_from_local ${POD} ${file}.tgz ${ORG_POD_BACKUP}/${relative_path}.tgz $@
        rm -f ${ORG_LOCAL_BACKUP}/${relative_path}.tgz
        oc exec $@ ${POD} -- bash -c "tar -C ${ORG_POD_BACKUP} ${TRANSFER_COMPRESS_OPTION} -xf -m ${ORG_POD_BACKUP}/${relative_path}.tgz && rm -f ${ORG_POD_BACKUP}/${relative_path}.tgz"
        wait_cmd ${POD} "tar -C ${ORG_POD_BACKUP} ${TRANSFER_COMPRESS_OPTION} -xf ${ORG_POD_BACKUP}/${relative_path}.tgz" $@
      else
        kube_cp_from_local ${POD} ${file} ${ORG_POD_BACKUP}/${relative_path} $@
      fi
    done
    return
  fi

  STAT_CMD="`get_stat_command` ${LOCAL_BACKUP}"
  LOCAL_SIZE=`eval "${STAT_CMD}"`
  if [ ${SPLITE_SIZE} -ne 0 -a ${LOCAL_SIZE} -gt ${SPLITE_SIZE} ] ; then
    rm -rf ${SPLITE_DIR}
    mkdir -p ${SPLITE_DIR}
    split -a 5 -b ${SPLITE_SIZE} ${LOCAL_BACKUP} ${SPLITE_DIR}/${LOCAL_BASE_NAME}.split.
    for splitfile in ${SPLITE_DIR}/*; do
      FILE_BASE_NAME=$(basename "${splitfile}")
      kubectl cp $@ "${splitfile}" "${POD}:${POD_DIST_DIR}/${FILE_BASE_NAME}"
    done
    rm -rf ${SPLITE_DIR}
    kubectl exec $@ ${POD} -- bash -c "cat ${POD_DIST_DIR}/${LOCAL_BASE_NAME}.split.* > ${POD_BACKUP} && rm -rf ${POD_DIST_DIR}/${LOCAL_BASE_NAME}.split.*"
  else
    kubectl cp $@ "${LOCAL_BACKUP}" "${POD}:${POD_BACKUP}"
  fi
}

kube_cp_to_local(){
  IS_RECURSIVE=false
  if [ "$1" = "-r" ] ; then
    IS_RECURSIVE=true
    shift
  fi
  POD=$1
  shift
  LOCAL_BACKUP=$1
  shift
  POD_BACKUP=$1
  shift
  SPLITE_DIR=./tmp_split_bakcup
  SPLITE_SIZE=${BACKUP_RESTORE_SPLIT_SIZE:-500000000}
  POD_DIST_DIR=$(dirname "${POD_BACKUP}")

  if "${IS_RECURSIVE}" ; then
    ORG_POD_BACKUP=${POD_BACKUP}
    ORG_LOCAL_BACKUP=${LOCAL_BACKUP}
    mkdir -p ${ORG_LOCAL_BACKUP}
    for file in `kubectl exec $@ ${POD} -- bash -c "cd ${ORG_POD_BACKUP} && find . -type f"` ; do
      file=${file#./}
      FILE_DIR_NAME=$(dirname "${file}")
      if [ "${FILE_DIR_NAME}" != "." ] ; then
        mkdir -p ${ORG_LOCAL_BACKUP}/${FILE_DIR_NAME}
      fi
      if [ ${TRANSFER_WITH_COMPRESSION-true} ] ; then
        oc exec $@ ${POD} -- bash -c "tar -C ${ORG_POD_BACKUP} ${TRANSFER_COMPRESS_OPTION} -cf ${ORG_POD_BACKUP}/${file}.tgz ${file}  && rm -f ${ORG_POD_BACKUP}/${file}"
        wait_cmd ${POD} "tar -C ${ORG_POD_BACKUP} ${TRANSFER_COMPRESS_OPTION} -cf ${ORG_POD_BACKUP}/${file}.tgz" $@
        kube_cp_to_local ${POD} ${ORG_LOCAL_BACKUP}/${file}.tgz ${ORG_POD_BACKUP}/${file}.tgz $@
        oc exec $@ ${POD} -- bash -c "rm -f ${ORG_POD_BACKUP}/${file}.tgz"
        tar -C ${ORG_LOCAL_BACKUP} ${TRANSFER_TAR_OPTIONS[@]} -xf ${ORG_LOCAL_BACKUP}/${file}.tgz
        rm -f ${ORG_LOCAL_BACKUP}/${file}.tgz
      else
        kube_cp_to_local ${POD} ${ORG_LOCAL_BACKUP}/${file} ${ORG_POD_BACKUP}/${file} $@
        oc exec $@ ${POD} -- bash -c "rm -f ${ORG_POD_BACKUP}/${file}"
      fi
    done
    return
  fi

  POD_SIZE=`kubectl $@ exec ${POD} -- bash -c "stat --printf="%s" ${POD_BACKUP}"`
  if [ ${SPLITE_SIZE} -ne 0 -a ${POD_SIZE} -gt ${SPLITE_SIZE} ] ; then
    rm -rf ${SPLITE_DIR}
    mkdir -p ${SPLITE_DIR}
    kubectl exec $@ ${POD} -- bash -c "split -d -a 5 -b ${SPLITE_SIZE} ${POD_BACKUP} ${POD_BACKUP}.split."
    FILE_LIST=`kubectl exec $@ ${POD} -- bash -c "ls ${POD_BACKUP}.split.*"`
    for splitfile in ${FILE_LIST} ; do
      FILE_BASE_NAME=$(basename "${splitfile}")
      kubectl cp $@ "${POD}:${splitfile}" "${SPLIT_DIR}/${FILE_BASE_NAME}"
    done
    cat ${SPLITE_DIR}/* > ${LOCAL_BACKUP}
    rm -rf ${SPLITE_DIR}
    kubectl exec $@ ${POD} -- bash -c "rm -rf ${POD_BACKUP}.split.*"
  else
    kubectl cp $@ "${POD}:${POD_BACKUP}" "${LOCAL_BACKUP}"
  fi
}

wait_cmd(){
  POD=$1
  shift
  CMD=$1
  shift
  FIRST=${CMD:0:1}
  GREP_STRING="[${FIRST}]${CMD:1}"
  MAX_CMD_FAILURE_COUNT=${MAX_CMD_FAILURE_COUNT:-10}
  MONITOR_CMD_INTERVAL=${MONITOR_CMD_INTERVAL:-5}
  local fail_count=0
  set +e
  while true ;
  do
    PROCESSES=`kubectl exec $@ ${POD} --  bash -c 'ps auxww'`
    if [ -z "${PROCESSES}" ] ; then
      fail_count=$((fail_count += 1))
      brlog "WARN" "Failed to get process status. Failure count: ${fail_count}"
      if [ ${fail_count} -gt ${MAX_CMD_FAILURE_COUNT} ] ; then
        brlog "ERROR" "Can not get process status over ${MAX_CMD_FAILURE_COUNT} times."
        exit 1
      fi
      sleep ${MONITOR_CMD_INTERVAL}
    elif echo "${PROCESSES}" | grep "${GREP_STRING}" > /dev/null ; then
      sleep ${MONITOR_CMD_INTERVAL}
      fail_count=0
    else
      break
    fi
  done
  set -e
}

get_mc(){
  DIST_DIR=$1
  if [ "$(uname)" = "Linux" ] ; then
    brlog "INFO" "Getting mc command for linux-amd64."
    launch_migrator_job
    get_job_pod
    wait_job_running ${POD}
    kubectl cp ${KUBECTL_ARGS} ${POD}:/usr/local/bin/mc ${DIST_DIR}/mc
    kubectl ${KUBECTL_ARGS} delete job ${MIGRATOR_JOB_NAME}
    chmod +x ${DIST_DIR}/mc
    brlog "INFO" "Got mc command: ${DIST_DIR}/mc"
  else
    brlog "ERROR" "Not linux os. Can not get mc. Please set your minio client path to environment variable 'MC_COMMAND'"
    exit 1
  fi
}

start_minio_port_forward(){
  touch ${TMP_WORK_DIR}/keep_minio_port_forward
  trap "rm -f ${TMP_WORK_DIR}/keep_minio_port_forward" 0 1 2 3 15
  keep_minio_port_forward &
  sleep 5
}

keep_minio_port_forward(){
  while [ -e ${TMP_WORK_DIR}/keep_minio_port_forward ]
  do
    kubectl ${KUBECTL_ARGS} port-forward svc/${MINIO_SVC} ${MINIO_FORWARD_PORT}:${MINIO_PORT} > /dev/null &
    PORT_FORWARD_PID=$!
    while [ -e ${TMP_WORK_DIR}/keep_minio_port_forward ] && kill -0 ${PORT_FORWARD_PID} &> /dev/null
    do
      sleep 1
    done
  done
  if kill -0 ${PORT_FORWARD_PID} &> /dev/null ; then
    kill ${PORT_FORWARD_PID}
  fi
}

stop_minio_port_forward(){
  rm -f ${TMP_WORK_DIR}/keep_minio_port_forward
  trap 0 1 2 3 15
  sleep 5
}

scale_resource(){
  SCALE_RESOURCE_TYPE=$1
  SCALE_RESOURCE_NAME=$2
  SCALE_NUM=$3
  WAIT_SCALE=$4
  brlog "INFO" "Change replicas of ${SCALE_RESOURCE_NAME} to ${SCALE_NUM}".
  kubectl ${KUBECTL_ARGS} scale ${SCALE_RESOURCE_TYPE} ${SCALE_RESOURCE_NAME} --replicas=${SCALE_NUM}
  if "${WAIT_SCALE}" ; then
    brlog "INFO" "Waiting for ${SCALE_RESOURCE_NAME} to be scaled..."
    while :
    do
      if [ "`kubectl ${KUBECTL_ARGS} get ${SCALE_RESOURCE_TYPE} ${SCALE_RESOURCE_NAME} -o jsonpath='{.status.replicas}'`" = "0" ] ; then
        break
      else
        sleep 1
      fi
    done
    brlog "INFO" "Complete scale."
  fi
}

set_release_names_for_ingestion(){
  INGESTION_RELEASE_NAME="core"
  ORCHESTRATOR_RELEASE_NAME="core"
  HDP_RELEASE_NAME="mantle"
}

start_ingestion(){
  echo
  brlog "INFO" "Restore core pods"
  echo
  scale_resource sts ${CRAWLER_RESOURCE_NAME} ${ORG_CRAWLER_POD_NUM} false
  scale_resource sts ${CONVERTER_RESOURCE_NAME} ${ORG_CONVERTER_POD_NUM} false
  scale_resource sts ${INLET_RESOURCE_NAME} ${ORG_INLET_POD_NUM} false
  scale_resource sts ${OUTLET_RESOURCE_NAME} ${ORG_OUTLET_POD_NUM} false
  scale_resource deployment ${ORCHESTRATOR_RESOURCE_NAME} ${ORG_ORCHESTRATOR_POD_NUM} false
  trap 0 1 2 3 15
  echo
  brlog "INFO" "Core pods will be restored soon."
  echo
}

stop_ingestion(){
  echo
  brlog "INFO" "Scale core pods to stop ingestion..."
  echo
  set_release_names_for_ingestion
  # Scale ingestion and orchestrator pods to ensure that there are no ingestion process.
  CRAWLER_RESOURCE_NAME=`kubectl get sts ${KUBECTL_ARGS} -o jsonpath='{.items[0].metadata.name}' -l release=${INGESTION_RELEASE_NAME},run=crawler`
  ORG_CRAWLER_POD_NUM=`kubectl get sts ${KUBECTL_ARGS} -o jsonpath='{.items[0].spec.replicas}' -l release=${INGESTION_RELEASE_NAME},run=crawler`
  if [ ${ORG_CRAWLER_POD_NUM} -eq 0 ] ; then
    ORG_CRAWLER_POD_NUM=1
  fi
  CONVERTER_RESOURCE_NAME=`kubectl get sts ${KUBECTL_ARGS} -o jsonpath='{.items[0].metadata.name}' -l release=${INGESTION_RELEASE_NAME},run=converter`
  ORG_CONVERTER_POD_NUM=`kubectl get sts ${KUBECTL_ARGS} -o jsonpath='{.items[0].spec.replicas}' -l release=${INGESTION_RELEASE_NAME},run=converter`
  if [ ${ORG_CONVERTER_POD_NUM} -eq 0 ] ; then
    ORG_CONVERTER_POD_NUM=1
  fi
  INLET_RESOURCE_NAME=`kubectl get sts ${KUBECTL_ARGS} -o jsonpath='{.items[0].metadata.name}' -l release=${INGESTION_RELEASE_NAME},run=inlet`
  ORG_INLET_POD_NUM=`kubectl get sts ${KUBECTL_ARGS} -o jsonpath='{.items[0].spec.replicas}' -l release=${INGESTION_RELEASE_NAME},run=inlet`
  if [ ${ORG_INLET_POD_NUM} -eq 0 ] ; then
    ORG_INLET_POD_NUM=1
  fi
  OUTLET_RESOURCE_NAME=`kubectl get sts ${KUBECTL_ARGS} -o jsonpath='{.items[0].metadata.name}' -l release=${INGESTION_RELEASE_NAME},run=outlet`
  ORG_OUTLET_POD_NUM=`kubectl get sts ${KUBECTL_ARGS} -o jsonpath='{.items[0].spec.replicas}' -l release=${INGESTION_RELEASE_NAME},run=outlet`
  if [ ${ORG_OUTLET_POD_NUM} -eq 0 ] ; then
    ORG_OUTLET_POD_NUM=1
  fi
  ORCHESTRATOR_RESOURCE_NAME=`kubectl get deployment ${KUBECTL_ARGS} -o jsonpath='{.items[0].metadata.name}' -l release=${ORCHESTRATOR_RELEASE_NAME},run=orchestrator`
  ORG_ORCHESTRATOR_POD_NUM=`kubectl get deployment ${KUBECTL_ARGS} -o jsonpath='{.items[0].spec.replicas}' -l release=${ORCHESTRATOR_RELEASE_NAME},run=orchestrator`
  if [ ${ORG_ORCHESTRATOR_POD_NUM} -eq 0 ] ; then
    ORG_ORCHESTRATOR_POD_NUM=1
  fi
  trap "start_ingestion" 0 1 2 3 15
  scale_resource sts ${CRAWLER_RESOURCE_NAME} 0 true
  scale_resource sts ${CONVERTER_RESOURCE_NAME} 0 true
  scale_resource sts ${INLET_RESOURCE_NAME} 0 true
  scale_resource sts ${OUTLET_RESOURCE_NAME} 0 true
  scale_resource deployment ${ORCHESTRATOR_RESOURCE_NAME} 0 false

  sleep 30

  HDP_RM_POD=`kubectl get pod ${KUBECTL_ARGS} -o jsonpath='{.items[0].metadata.name}' -l release=${HDP_RELEASE_NAME},run=hdp-rm`

  # Check there are no DOCPROC application in yarn cue.
  brlog "INFO" "Stop all ingestion process..."
  check_count=0
  while :
  do
    DOCPROC_APP=`kubectl ${KUBECTL_ARGS} exec ${HDP_RM_POD} -- bash -c 'yarn application -list 2> /dev/null | grep "DOCPROC" | cut -f1'`
    if [ -n "${DOCPROC_APP}" ] ; then
      check_count=0
      for APP in ${DOCPROC_APP}
      do
        kubectl ${KUBECTL_ARGS} exec ${HDP_RM_POD} -- yarn application -kill ${APP} || true
      done
    else
      check_count=$((check_count += 1))
      if [ ${check_count} -gt 5 ] ; then
        break
      fi
    fi
  done

  echo
  brlog "INFO" "Stopped ingestion."
  echo
}

get_migrator_tag(){
  local wd_version=`get_version`
  if [ "${wd_version}" = "2.1.3" ] ; then
    echo "12.0.4-1048"
  elif [ "${wd_version}" = "2.1.4" ] ; then
    echo "12.0.5-2016"
  fi
}

launch_migrator_job(){
  MIGRATOR_TAG=`get_migrator_tag`
  MIGRATOR_JOB_NAME="wd-migrator-job"
  MIGRATOR_JOB_TEMPLATE="${SCRIPT_DIR}/src/migrator-job-template.yml"
  MIGRATOR_JOB_FILE="${SCRIPT_DIR}/src/migrator-job.yml"
  ADMIN_RELEASE_NAME="admin"
  DATA_SOURCE_RELEASE_NAME="crust"
  CORE_RELEASE_NAME="core"
  MIGRATOR_CPU_LIMITS="${MIGRATOR_CPU_LIMITS:-800m}"
  MIGRATOR_MEMORY_LIMITS="${MIGRATOR_MEMORY_LIMITS:-4Gi}"
  MIGRATOR_MAX_HEAP="${MIGRATOR_MAX_HEAP:-3g}"

  WD_UTIL_IMAGE=`kubectl ${KUBECTL_ARGS} get pods -o jsonpath="{..image}" |tr -s '[[:space:]]' '\n' | sort | uniq | grep wd-utils`
  WD_MIGRATOR_IMAGE="${WD_UTIL_IMAGE%wd-utils*}wd-migrator:${MIGRATOR_TAG}"
  PG_CONFIGMAP=`kubectl get ${KUBECTL_ARGS} configmap -l release=${DATA_SOURCE_RELEASE_NAME},app.kubernetes.io/component=postgresql -o jsonpath="{.items[0].metadata.name}"`
  PG_SECRET=`kubectl ${KUBECTL_ARGS} get secret -l release=${DATA_SOURCE_RELEASE_NAME},helm.sh/chart=postgresql -o jsonpath="{.items[*].metadata.name}"`
  ETCD_CONFIGMAP=`kubectl get ${KUBECTL_ARGS} configmap -l release=${DATA_SOURCE_RELEASE_NAME},app.kubernetes.io/component=etcd -o jsonpath="{.items[0].metadata.name}"`
  ETCD_SECRET=`kubectl ${KUBECTL_ARGS} get secret -l release=${DATA_SOURCE_RELEASE_NAME},helm.sh/chart=etcd -o jsonpath="{.items[*].metadata.name}"`
  CK_SECRET=`kubectl ${KUBECTL_ARGS} get secret -l release=${CORE_RELEASE_NAME},app.kubernetes.io/component=core-discovery-wex-core-ck-secret -o jsonpath="{.items[*].metadata.name}"`
  MINIO_CONFIGMAP=`kubectl get ${KUBECTL_ARGS} configmap -l release=${DATA_SOURCE_RELEASE_NAME},app.kubernetes.io/component=minio -o jsonpath="{.items[0].metadata.name}"`
  MINIO_SECRET=`kubectl ${KUBECTL_ARGS} get secret -l release=${DATA_SOURCE_RELEASE_NAME} -o jsonpath="{.items[*].metadata.name}" | tr -s '[[:space:]]' '\n' | grep minio`
  DISCO_SVC_ACCOUNT=`kubectl ${KUBECTL_ARGS} get serviceaccount -l release=${ADMIN_RELEASE_NAME} -o jsonpath="{.items[*].metadata.name}"`
  SDU_SVC=`kubectl get ${KUBECTL_ARGS} configmap core-discovery-gateway -o jsonpath='{.data.SDU_SVC}'`
  NAMESPACE=${NAMESPACE:-`kubectl config view --minify --output 'jsonpath={..namespace}'`}

  sed -e "s/@namespace@/${NAMESPACE}/g" \
    -e "s/@svc-account@/${DISCO_SVC_ACCOUNT}/g" \
    -e "s|@image@|${WD_MIGRATOR_IMAGE}|g" \
    -e "s/@max-heap@/${MIGRATOR_MAX_HEAP}/g" \
    -e "s/@pg-configmap@/${PG_CONFIGMAP}/g" \
    -e "s/@pg-secret@/${PG_SECRET}/g" \
    -e "s/@etcd-configmap@/${ETCD_CONFIGMAP}/g" \
    -e "s/@etcd-secret@/${ETCD_SECRET}/g" \
    -e "s/@minio-secret@/${MINIO_SECRET}/g" \
    -e "s/@minio-configmap@/${MINIO_CONFIGMAP}/g" \
    -e "s/@ck-secret@/${CK_SECRET}/g" \
    -e "s/@cpu-limit@/${MIGRATOR_CPU_LIMITS}/g" \
    -e "s/@memory-limit@/${MIGRATOR_MEMORY_LIMITS}/g" \
    -e "s/@sdu-svc@/${SDU_SVC}/g" \
    "${MIGRATOR_JOB_TEMPLATE}" > "${MIGRATOR_JOB_FILE}"

  kubectl ${KUBECTL_ARGS} apply -f "${MIGRATOR_JOB_FILE}"
}

get_job_pod(){
  brlog "INFO" "Waiting for migrator pod"
  POD=""
  MAX_WAIT_COUNT=${MAX_MIGRATOR_JOB_WAIT_COUNT:-20}
  WAIT_COUNT=0
  while :
  do
    PODS=`kubectl get ${KUBECTL_ARGS} pod -l release=core,app.kubernetes.io/component=wd-migrator -o jsonpath="{.items[*].metadata.name}"`
    if [ -n "${PODS}" ] ; then
      for P in $PODS ;
      do
        if [ "`kubectl get ${KUBECTL_ARGS} pod ${P} -o jsonpath='{.status.phase}'`" != "Failed" ] ; then
          POD=${P}
        fi
      done
    fi
    if [ -n "${POD}" ] ; then
      break
    fi
    if [ ${WAIT_COUNT} -eq ${MAX_WAIT_COUNT} ] ; then
      brlog "ERROR" "Migrator pod have not been created after 100s"
      exit 1
    fi
    WAIT_COUNT=$((WAIT_COUNT += 1))
    sleep 5
  done
}

wait_job_running() {
  POD=$1
  MAX_WAIT_COUNT=${MAX_MIGRATOR_JOB_WAIT_COUNT:-20}
  WAIT_COUNT=0
  while :
  do
    STATUS=`kubectl get ${KUBECTL_ARGS} pod ${POD} -o jsonpath="{.status.phase}"`
    if [ "${STATUS}" = "Running" ] ; then
      break
    fi
    if [ ${WAIT_COUNT} -eq ${MAX_WAIT_COUNT} ] ; then
      brlog "ERROR" "Migrator pod have not run after 100s"
      exit 1
    fi
    WAIT_COUNT=$((WAIT_COUNT += 1))
    sleep 5
  done
}