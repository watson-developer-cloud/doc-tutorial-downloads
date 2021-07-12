export BACKUP_RESTORE_LOG_LEVEL="${BACKUP_RESTORE_LOG_LEVEL:-INFO}"
export WD_CMD_COMPLETION_TOKEN="completed_wd_command"
export DATASTORE_ARCHIVE_OPTION="${DATASTORE_ARCHIVE_OPTION--z}"
export BACKUP_RESTORE_LOG_DIR="${BACKUP_RESTORE_LOG_DIR:-wd-backup-restore-logs-`date "+%Y%m%d_%H%M%S"`}"
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
  if [ -n "`oc get wd ${OC_ARGS} ${TENANT_NAME}`" ] ; then
    local version=`oc get wd ${OC_ARGS} ${TENANT_NAME} -o jsonpath='{.spec.version}'`
    if [ "${version}" = "main" ] ; then #TODO remove this section after dev
      version="4.0.0"
    fi
    echo "${version%%-*}"
  elif [ -n "`oc get pod ${OC_ARGS} -l "app.kubernetes.io/name=discovery,run=management"`" ] ; then
    if [ "`oc ${OC_ARGS} get is wd-migrator -o jsonpath="{.status.tags[*].tag}" | tr -s '[[:space:]]' '\n' | tail -n1`" = "12.0.4-1048" ] ; then
      echo "2.1.3"
    else
      echo "2.1.4"
    fi
  elif [ -n "`oc get sts ${OC_ARGS} -l "app.kubernetes.io/name=discovery,run=gateway" -o jsonpath="{..image}" | grep "wd-management"`" ] ; then
    echo "2.1.2"
  else
    echo "2.1"
  fi
}

compare_version(){
  VER_1=(${1//./ })
  VER_2=(${2//./ })
  for ((i = 0; i <= ${#VER_1[@]} || i <= ${#VER_2[@]}; i++))
  do
      if [ -z "${VER_1[$i]+UNDEFINE}" ] && [ -z "${VER_2[$i]+UNDEFINE}" ] ; then
        echo 0
        break;
      elif [ -z "${VER_1[$i]+UNDEFINE}" ] ; then
        echo  "-1"
        break;
      elif [ -z "${VER_2[$i]+UNDEFINE}" ] ; then
        echo "1"
        break;
      elif [ ${VER_1[$i]} -lt ${VER_2[$i]} ] ; then
        echo "-1"
        break;
      elif [ ${VER_1[$i]} -gt ${VER_2[$i]} ] ; then
        echo 1
        break;
      fi
  done
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
    oc exec $@ ${POD} -- bash -c "mkdir -p ${ORG_POD_BACKUP}"
    for file in `find "${ORG_LOCAL_BACKUP}" -type f` ; do
      relative_path=${file#$ORG_LOCAL_BACKUP/}
      FILE_DIR_NAME=$(dirname "${relative_path}")
      if [ "${FILE_DIR_NAME}" != "." ] ; then
        oc exec $@ ${POD} -- bash "mkdir -p ${ORG_POD_BACKUP}/${FILE_DIR_NAME}"
      fi
      if [ ${TRANSFER_WITH_COMPRESSION-true} ] ; then
        tar -C ${ORG_LOCAL_BACKUP} ${TRANSFER_TAR_OPTIONS[@]} -cf ${file}.tgz ${relative_path}
        kube_cp_from_local ${POD} ${file}.tgz ${ORG_POD_BACKUP}/${relative_path}.tgz $@
        rm -f ${file}.tgz
        run_cmd_in_pod ${POD} "tar -C ${ORG_POD_BACKUP} ${TRANSFER_COMPRESS_OPTION} -xf -m ${ORG_POD_BACKUP}/${relative_path}.tgz && rm -f ${ORG_POD_BACKUP}/${relative_path}.tgz" $@
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
    for file in ${SPLITE_DIR}/*; do
      FILE_BASE_NAME=$(basename "${file}")
      oc cp $@ "${file}" "${POD}:${POD_DIST_DIR}/${FILE_BASE_NAME}"
    done
    rm -rf ${SPLITE_DIR}
    run_cmd_in_pod ${POD} "cat ${POD_DIST_DIR}/${LOCAL_BASE_NAME}.split.* > ${POD_BACKUP} && rm -rf ${POD_DIST_DIR}/${LOCAL_BASE_NAME}.split.*" $@
  else
    oc cp $@ "${LOCAL_BACKUP}" "${POD}:${POD_BACKUP}"
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
    for file in `oc exec $@ ${POD} -- sh -c 'cd '"${ORG_POD_BACKUP}"' && ls -Rp . | awk '"'"'/:$/&&f{s=$0;f=0};/:$/&&!f{sub(/:$/,"");s=$0;f=1;next};NF&&f{ print s"/"$0 }'"'"' | grep -v '"'"'.*/$'"'"` ; do
      file=${file#./}
      FILE_DIR_NAME=$(dirname "${file}")
      if [ "${FILE_DIR_NAME}" != "." ] ; then
        mkdir -p ${ORG_LOCAL_BACKUP}/${FILE_DIR_NAME}
      fi
      if [ ${TRANSFER_WITH_COMPRESSION-true} ] ; then
        run_cmd_in_pod ${POD} "tar -C ${ORG_POD_BACKUP} ${TRANSFER_COMPRESS_OPTION} -cf ${ORG_POD_BACKUP}/${file}.tgz ${file}  && rm -f ${ORG_POD_BACKUP}/${file}" $@
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

  POD_SIZE=`oc $@ exec ${POD} -- sh -c "stat -c "%s" ${POD_BACKUP}"`
  if [ ${SPLITE_SIZE} -ne 0 -a ${POD_SIZE} -gt ${SPLITE_SIZE} ] ; then
    rm -rf ${SPLITE_DIR}
    mkdir -p ${SPLITE_DIR}
    run_cmd_in_pod ${POD} "split -d -a 5 -b ${SPLITE_SIZE} ${POD_BACKUP} ${POD_BACKUP}.split." $@
    FILE_LIST=`oc exec $@ ${POD} -- sh -c "ls ${POD_BACKUP}.split.*"`
    for file in ${FILE_LIST} ; do
      FILE_BASE_NAME=$(basename "${file}")
      oc cp $@ "${POD}:${file}" "${SPLITE_DIR}/${FILE_BASE_NAME}"
    done
    cat ${SPLITE_DIR}/* > ${LOCAL_BACKUP}
    rm -rf ${SPLITE_DIR}
    oc exec $@ ${POD} -- bash -c "rm -rf ${POD_BACKUP}.split.*"
  else
    oc cp $@ "${POD}:${POD_BACKUP}" "${LOCAL_BACKUP}"
  fi
}

wait_cmd(){
  local pod=$1
  shift
  MONITOR_CMD_INTERVAL=${MONITOR_CMD_INTERVAL:-5}
  while true ;
  do
    files=`fetch_cmd_result ${pod} "ls /tmp" $@`
    if echo "${files}" | grep "${WD_CMD_COMPLETION_TOKEN}" > /dev/null ; then
      break
    else
      sleep ${MONITOR_CMD_INTERVAL}
    fi
  done
}

fetch_cmd_result(){
  set +e
  local pod=$1
  shift
  local cmd=$1
  shift
  MAX_CMD_FAILURE_COUNT=${MAX_CMD_FAILURE_COUNT:-10}
  MONITOR_CMD_INTERVAL=${MONITOR_CMD_INTERVAL:-5}
  local fail_count=0
  while true ;
  do
    local cmd_result=`oc exec $@ ${pod} --  sh -c "${cmd}"`
    if [ -z "${cmd_result}" ] ; then
      brlog "WARN" "Failed to get command result. Failure count: ${fail_count}" >&2
      fail_count=$((fail_count += 1))
      if [ ${fail_count} -gt ${MAX_CMD_FAILURE_COUNT} ] ; then
        brlog "ERROR" "Can not get command result over ${MAX_CMD_FAILURE_COUNT} times."
        exit 1
      fi
      sleep ${MONITOR_CMD_INTERVAL}
      continue
    fi
    echo "${cmd_result}"
    break
  done
  set -e
}

get_mc(){
  DIST_DIR=$1
  if [ "$(uname)" = "Linux" ] ; then
    brlog "INFO" "Getting mc command for linux-amd64."
    launch_migrator_job
    get_job_pod "app.kubernetes.io/component=wd-migrator"
    wait_job_running ${POD}
    oc cp ${OC_ARGS} ${POD}:/usr/local/bin/mc ${DIST_DIR}/mc
    oc ${OC_ARGS} delete job ${MIGRATOR_JOB_NAME}
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
    oc ${OC_ARGS} port-forward svc/${MINIO_SVC} ${MINIO_FORWARD_PORT}:${MINIO_PORT} &>> "${BACKUP_RESTORE_LOG_DIR}/port-foward.log" &
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
  oc ${OC_ARGS} scale ${SCALE_RESOURCE_TYPE} ${SCALE_RESOURCE_NAME} --replicas=${SCALE_NUM}
  if "${WAIT_SCALE}" ; then
    brlog "INFO" "Waiting for ${SCALE_RESOURCE_NAME} to be scaled..."
    while :
    do
      if [ "`oc ${OC_ARGS} get ${SCALE_RESOURCE_TYPE} ${SCALE_RESOURCE_NAME} -o jsonpath='{.status.replicas}'`" = "0" ] ; then
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

unquiesce(){
  echo
  brlog "INFO" "Activating"
  oc patch wd ${TENANT_NAME} --type merge --patch '{"spec": {"shared": {"quiesce": {"enabled": false}}}}'
  trap 0 1 2 3 15

  if [ "${WAIT_ACTIVATION_COMPLETE:-false}" != "false" ] ; then
    brlog "INFO" "Wait for the pods to be ready"
    wait_pod_ready "tenant=${TENANT_NAME},run=minerapp"
  fi
  echo
  brlog "INFO" "Pods will be restored soon."
  echo
}

wait_pod_ready(){
  local label="$1"
  while :
  do
    if oc describe pod ${OC_ARGS} -l "${label}" | grep -e "ContainersReady.*False" -e "PodScheduled.*False" > /dev/null ; then
      sleep 5;
    else
      brlog "INFO" "Pods are ready";
      break;
    fi
  done
}

quiesce(){
  echo
  brlog "INFO" "Quiescing"
  echo

  if [ "$COMMAND" = "restore" ] ; then
    trap "brlog 'ERROR' 'Error occur while running scripts.' ; unquiesce; ./post-restore.sh ${TENANT_NAME}; brlog 'ERROR' 'Backup/Restore failed.'" 0 1 2 3 15
  else
    trap "unquiesce; brlog 'ERROR' 'Backup/Restore failed.'" 0 1 2 3 15
  fi
  oc patch wd ${TENANT_NAME} --type merge --patch '{"spec": {"shared": {"quiesce": {"enabled": true}}}}'

  while :
  do
    oc ${OC_ARGS} get wd ${TENANT_NAME} -o jsonpath='{.status.customResourceQuiesce}' | grep -e "^QUIESCED" > /dev/null && break
    sleep 10
  done

  echo
  brlog "INFO" "Quiesced"
  echo
}

get_image_repo(){
  local utils_image="`oc get ${OC_ARGS} pod -l tenant=${TENANT_NAME} -o jsonpath='{..image}' | tr -s '[[:space:]]' '\n' | sort | uniq | grep wd-utils | tail -n1`"
  echo "${utils_image%/*}"
}

get_migrator_repo(){
  local repo="`get_image_repo`"
  echo "${repo%/}/wd-migrator"
}

get_migrator_tag(){
  local wd_version=${WD_VERSION:-`get_version`}
  if [ "${wd_version}" = "2.2.0" ] ; then
    echo "12.0.6-2031"
  elif [ "${wd_version}" = "2.2.1" ] ; then
    echo "12.0.7-3010"
  else
    echo "12.0.8-5028@sha256:a74a705b072a25f01c98a4ef5b4e7733ceb7715c042cc5f7876585b5359f1f65"
  fi
}

get_migrator_image(){
  echo "`get_migrator_repo`:${MIGRATOR_TAG:-`get_migrator_tag`}"
}

get_pg_config_tag(){
  local wd_version=${WD_VERSION:-`get_version`}
  if [ "${wd_version}" = "4.0.0" ] ; then
    echo "20210604-150426-1103-5d09428b@sha256:52d3dd27728388458aaaca2bc86d06f9ad61b7ffcb6abbbb1a87d11e6635ebbf"
  fi
}

launch_migrator_job(){
  MIGRATOR_TAG="${MIGRATOR_TAG:-`get_migrator_tag`}"
  MIGRATOR_JOB_NAME="wd-migrator-job"
  MIGRATOR_JOB_TEMPLATE="${SCRIPT_DIR}/src/migrator-job-template.yml"
  MIGRATOR_JOB_FILE="${SCRIPT_DIR}/src/migrator-job.yml"
  ADMIN_RELEASE_NAME="admin"
  MIGRATOR_CPU_LIMITS="${MIGRATOR_CPU_LIMITS:-800m}"
  MIGRATOR_MEMORY_LIMITS="${MIGRATOR_MEMORY_LIMITS:-4Gi}"
  MIGRATOR_MAX_HEAP="${MIGRATOR_MAX_HEAP:-3g}"

  WD_MIGRATOR_IMAGE="`get_migrator_image`"
  PG_CONFIGMAP=`get_pg_configmap`
  PG_SECRET=`get_pg_secret`
  ETCD_CONFIGMAP=`oc get ${OC_ARGS} configmap -l tenant=${TENANT_NAME},app=etcd-cxn -o jsonpath="{.items[0].metadata.name}"`
  ETCD_SECRET=`oc ${OC_ARGS} get secret -l tenant=${TENANT_NAME},app=etcd-root -o jsonpath="{.items[*].metadata.name}"`
  CK_SECRET=`oc ${OC_ARGS} get secret -l tenant=${TENANT_NAME},app=ck-secret -o jsonpath="{.items[*].metadata.name}"`
  MINIO_CONFIGMAP=`oc get ${OC_ARGS} configmap -l tenant=${TENANT_NAME},app=minio -o jsonpath="{.items[0].metadata.name}"`
  MINIO_SECRET=`oc ${OC_ARGS} get secret -l tenant=${TENANT_NAME},app=minio-auth -o jsonpath="{.items[*].metadata.name}"`
  DISCO_SVC_ACCOUNT=`get_service_account`
  NAMESPACE=${NAMESPACE:-`oc config view --minify --output 'jsonpath={..namespace}'`}
  WD_VERSION=${WD_VERSION:-`get_version`}
  if [ `compare_version "${WD_VERSION}" "2.2.1"` -le 0 ] ; then
    PG_SECRET_PASS_KEY="STKEEPER_PG_SU_PASSWORD"
  else
    PG_SECRET_PASS_KEY="pg_su_password"
  fi

  sed -e "s/#namespace#/${NAMESPACE}/g" \
    -e "s/#svc-account#/${DISCO_SVC_ACCOUNT}/g" \
    -e "s|#image#|${WD_MIGRATOR_IMAGE}|g" \
    -e "s/#max-heap#/${MIGRATOR_MAX_HEAP}/g" \
    -e "s/#pg-configmap#/${PG_CONFIGMAP}/g" \
    -e "s/#pg-secret#/${PG_SECRET}/g" \
    -e "s/#etcd-configmap#/${ETCD_CONFIGMAP}/g" \
    -e "s/#etcd-secret#/${ETCD_SECRET}/g" \
    -e "s/#minio-secret#/${MINIO_SECRET}/g" \
    -e "s/#minio-configmap#/${MINIO_CONFIGMAP}/g" \
    -e "s/#ck-secret#/${CK_SECRET}/g" \
    -e "s/#cpu-limit#/${MIGRATOR_CPU_LIMITS}/g" \
    -e "s/#memory-limit#/${MIGRATOR_MEMORY_LIMITS}/g" \
    -e "s/#pg-pass-key#/${PG_SECRET_PASS_KEY}/g" \
    "${MIGRATOR_JOB_TEMPLATE}" > "${MIGRATOR_JOB_FILE}"

  oc ${OC_ARGS} apply -f "${MIGRATOR_JOB_FILE}"
}

get_job_pod(){
  local label=$1
  brlog "INFO" "Waiting for job pod"
  POD=""
  MAX_WAIT_COUNT=${MAX_MIGRATOR_JOB_WAIT_COUNT:-200}
  WAIT_COUNT=0
  while :
  do
    PODS=`oc get ${OC_ARGS} pod -l "${label}" -o jsonpath="{.items[*].metadata.name}"`
    if [ -n "${PODS}" ] ; then
      for P in $PODS ;
      do
        if [ "`oc get ${OC_ARGS} pod ${P} -o jsonpath='{.status.phase}'`" != "Failed" ] ; then
          POD=${P}
        fi
      done
    fi
    if [ -n "${POD}" ] ; then
      break
    fi
    if [ ${WAIT_COUNT} -eq ${MAX_WAIT_COUNT} ] ; then
      brlog "ERROR" "Pod have not been created after 100s"
      exit 1
    fi
    WAIT_COUNT=$((WAIT_COUNT += 1))
    sleep 5
  done
}

wait_job_running() {
  POD=$1
  MAX_WAIT_COUNT=${MAX_MIGRATOR_JOB_WAIT_COUNT:-200}
  WAIT_COUNT=0
  while :
  do
    STATUS=`oc get ${OC_ARGS} pod ${POD} -o jsonpath="{.status.phase}"`
    if [ "${STATUS}" = "Running" ] ; then
      break
    fi
    if [ ${WAIT_COUNT} -eq ${MAX_WAIT_COUNT} ] ; then
      brlog "ERROR" "Pod have not run after 100s"
      exit 1
    fi
    WAIT_COUNT=$((WAIT_COUNT += 1))
    sleep 5
  done
}

run_core_init_db_job(){
  local label="tenant=${TENANT_NAME},run=core-database-init"
  JOB_NAME=`oc get ${OC_ARGS} job -o jsonpath="{.items[0].metadata.name}" -l "${label}"`
  oc delete ${OC_ARGS} job -l "${label}"
  oc delete pod -l "release=${TENANT_NAME},app=operator"
  get_job_pod "${label}"
  wait_job_running ${POD}
  brlog "INFO" "Waiting for core db config job to be completed..."
  while :
  do
    if [ "`oc ${OC_ARGS} get job -o jsonpath='{.status.succeeded}' ${JOB_NAME}`" = "1" ] ; then
      brlog "INFO" "Completed postgres config job"
      break;
    else
      sleep 5
    fi
  done
}

run_cmd_in_pod(){
  local pod="$1"
  shift
  local cmd="$1"
  shift
  WD_CMD_FILE="wd-br-cmd.sh"
  WD_CMD_LOG="wd-br-cmd.log"
  cat <<EOF >> "${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log"
==========================
${cmd}
--------------------------
EOF

  cat <<EOF >| ${TMP_WORK_DIR}/${WD_CMD_FILE}
trap "touch /tmp/${WD_CMD_COMPLETION_TOKEN}" 0 1 2 3 15
{ ${cmd} ; } &> /tmp/${WD_CMD_LOG}
touch /tmp/${WD_CMD_COMPLETION_TOKEN}
trap 0 1 2 3 15
EOF

  chmod +x ${TMP_WORK_DIR}/${WD_CMD_FILE}
  oc cp $@ ${TMP_WORK_DIR}/${WD_CMD_FILE} ${pod}:/tmp/${WD_CMD_FILE}
  oc exec $@ ${pod} -- bash -c "rm -rf /tmp/${WD_CMD_COMPLETION_TOKEN} && /tmp/${WD_CMD_FILE} &"
  wait_cmd ${pod} $@
  oc exec $@ ${pod} -- bash -c "cat /tmp/${WD_CMD_LOG}; rm -rf /tmp/${WD_CMD_FILE} /tmp/${WD_CMD_LOG} /tmp/${WD_CMD_COMPLETION_TOKEN}" >> "${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log"
}

add_env_to_job_yaml(){
  local env_name=$1
  shift
  local env_value=$1
  shift
  local yaml_file=$1
  shift
  sed -i -e "s|          env:|          env:\n            - name: ${env_name}\n              value: \"${env_value}\"|" "${yaml_file}"
}

add_config_env_to_job_yaml(){
  local env_name=$1
  shift
  local config_map=$1
  shift
  local config_key=$1
  shift
  local yaml_file=$1
  shift
  sed -i -e "s/          env:/          env:\n            - name: ${env_name}\n              valueFrom:\n                configMapKeyRef:\n                  name: ${config_map}\n                  key: ${config_key}/" "${yaml_file}"
}

add_secret_env_to_job_yaml(){
  local env_name=$1
  shift
  local secret_name=$1
  shift
  local secret_key=$1
  shift
  local yaml_file=$1
  shift
  sed -i -e "s/          env:/          env:\n            - name: ${env_name}\n              valueFrom:\n                secretKeyRef:\n                  name: ${secret_name}\n                  key: ${secret_key}/" "${yaml_file}"
}

get_service_account(){
  local version=`get_version`
  if [ `compare_version "${version}" "2.2.1"` -le 0 ] ; then
    echo `oc ${OC_ARGS} get serviceaccount -l app.kubernetes.io/component=admin-sa -o jsonpath="{.items[*].metadata.name}"`
  else
    echo `oc ${OC_ARGS} get serviceaccount -l app.kubernetes.io/component=admin,tenant=${TENANT_NAME} -o jsonpath="{.items[*].metadata.name}"`
  fi
}

get_pg_configmap(){
  local version=`get_version`
  if [ `compare_version "${version}" "2.2.1"` -le 0 ] ; then
    echo `oc get ${OC_ARGS} configmap -l tenant=${TENANT_NAME},app.kubernetes.io/component=postgres-cxn -o jsonpath="{.items[0].metadata.name}"`
  else
    echo `oc get ${OC_ARGS} configmap -l tenant=${TENANT_NAME},app=cn-postgres -o jsonpath="{.items[0].metadata.name}"`
  fi
}

get_pg_secret(){
  local version=`get_version`
  if [ `compare_version "${version}" "2.2.1"` -le 0 ] ; then
    echo `oc ${OC_ARGS} get secret -l tenant=${TENANT_NAME},cr=${TENANT_NAME}-discovery-postgres -o jsonpath="{.items[*].metadata.name}"`
  else
    echo `oc ${OC_ARGS} get secret -l tenant=${TENANT_NAME},run=cn-postgres -o jsonpath="{.items[*].metadata.name}" | tr '[[:space:]]' '\n' | grep "cn-postgres-wd"`
  fi
}

run_pg_job(){
  local wd_version=${WD_VERSION:-`get_version`}
  PG_BACKUP_RESTORE_SCRIPTS="postgresql-backup-restore-in-pod.sh"
  JOB_CPU_LIMITS="${MC_CPU_LIMITS:-800m}" # backward compatibility
  JOB_CPU_LIMITS="${JOB_CPU_LIMITS:-800m}"
  JOB_MEMORY_LIMITS="${MC_MEMORY_LIMITS:-2Gi}" # backward compatibility
  JOB_MEMORY_LIMITS="${JOB_MEMORY_LIMITS:-2Gi}"
  NAMESPACE=${NAMESPACE:-`oc config view --minify --output 'jsonpath={..namespace}'`}
  PG_IMAGE="`get_migrator_image`"
  if [ `compare_version "${wd_version}" "2.2.0"` -eq 0 ] ; then
    PG_IMAGE="`oc get ${OC_ARGS} pod -l tenant=${TENANT_NAME} -o jsonpath='{..image}' | tr -s '[[:space:]]' '\n' | sort | uniq | grep "edb-postgresql-12:ubi8-amd64" | tail -n1`"
  fi
  PG_CONFIGMAP=`get_pg_configmap`
  PG_SECRET=`get_pg_secret`
  PG_PASSWORD_KEY="pg_su_password"
  if [ `compare_version "${wd_version}" "4.0.0"` -lt 0 ] ; then
    PG_PASSWORD_KEY="STKEEPER_PG_SU_PASSWORD"
  fi
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
    -e "s|#image#|${PG_IMAGE}|g" \
    -e "s/#cpu-limit#/${JOB_CPU_LIMITS}/g" \
    -e "s/#memory-limit#/${JOB_MEMORY_LIMITS}/g" \
    -e "s|#command#|./${PG_BACKUP_RESTORE_SCRIPTS} ${COMMAND}|g" \
    -e "s/#job-name#/${PG_BACKUP_RESTORE_JOB}/g" \
    -e "s/#tenant#/${TENANT_NAME}/g" \
    "${PG_JOB_TEMPLATE}" > "${PG_JOB_FILE}"

  add_config_env_to_job_yaml "PGUSER" "${PG_CONFIGMAP}" "username" "${PG_JOB_FILE}"
  add_config_env_to_job_yaml "PGHOST" "${PG_CONFIGMAP}" "host" "${PG_JOB_FILE}"
  add_config_env_to_job_yaml "PGPORT" "${PG_CONFIGMAP}" "port" "${PG_JOB_FILE}"
  add_secret_env_to_job_yaml "PGPASSWORD" "${PG_SECRET}" "${PG_PASSWORD_KEY}" "${PG_JOB_FILE}"
  add_env_to_job_yaml "PG_ARCHIVE_OPTION" "${PG_ARCHIVE_OPTION}" "${PG_JOB_FILE}"
  add_env_to_job_yaml "TZ" "${TZ_OFFSET}" "${PG_JOB_FILE}"
  add_volume_to_job_yaml "${JOB_PVC_NAME:-emptyDir}" "${PG_JOB_FILE}"

  oc ${OC_ARGS} delete -f "${PG_JOB_FILE}" &> /dev/null || true
  oc ${OC_ARGS} apply -f "${PG_JOB_FILE}"
  get_job_pod "app.kubernetes.io/component=${PG_BACKUP_RESTORE_JOB},tenant=${TENANT_NAME}"
  wait_job_running ${POD}
}

add_volume_to_job_yaml(){
  local volume_name=$1
  shift
  local yaml_file=$1
  shift
  if [ "${volume_name}" = "emptyDir" ] ; then
    sed -i -e "s/      volumes:/      volumes:\n        - name: backup-restore-workspace\n          emptyDir: {}/" "${yaml_file}"
  else
    sed -i -e "s/      volumes:/      volumes:\n        - name: backup-restore-workspace\n          persistentVolumeClaim:\n            claimName: ${volume_name}/" "${yaml_file}"
  fi
}

verify_args(){
  if [ -z "$COMMAND" ] ; then
    brlog "ERROR" "Please specify command, backup or restore"
    exit 1
  fi
  if [ "$COMMAND" = "restore" ] ; then
    if [ -z "${BACKUP_FILE}" ] ; then
      brlog "ERROR" "Please specify backup file."
      exit 1
    fi
    if [ ! -e "${BACKUP_FILE}" ] ; then
      brlog "ERROR" "Backup file not found: ${BACKUP_FILE}"
      exit 1
    fi
  fi
  if [ -n "${TENANT_NAME+UNDEF}" ] && [ -z "`oc get ${OC_ARGS} wd ${TENANT_NAME}`" ] ; then
    brlog "ERROR" "Tenant (release) not found: ${TENANT_NAME}"
    exit 1
  fi
  if [ -n "${JOB_PVC_NAME+UNDEF}" ] && [ -z "`oc get ${OC_ARGS} pvc ${JOB_PVC_NAME}`" ] ; then
    brlog "ERROR" "PVC not found: ${JOB_PVC_NAME}"
    exit 1
  fi
}