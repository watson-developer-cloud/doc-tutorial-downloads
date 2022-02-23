export BACKUP_RESTORE_LOG_LEVEL="${BACKUP_RESTORE_LOG_LEVEL:-INFO}"
export WD_CMD_COMPLETION_TOKEN="completed_wd_command"
export BACKUP_VERSION_FILE="tmp/version.txt"
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
  if [ -n "${WD_VERSION:+UNDEF}" ] ; then
    echo "${WD_VERSION}"
  else
    if [ -n "`oc get wd ${OC_ARGS} ${TENANT_NAME}`" ] ; then
      local version=`oc get wd ${OC_ARGS} ${TENANT_NAME} -o jsonpath='{.spec.version}'`
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
  if [ -n "${BACKUP_FILE_VERSION:+UNDEF}" ] ; then
    echo "${BACKUP_FILE_VERSION}"
  else
    if [ -e "${BACKUP_VERSION_FILE}" ] ; then
      cat "${BACKUP_VERSION_FILE}"
    else
      echo "2.1" # 2.1.2 or earlier
    fi
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
    for splitfile in ${SPLITE_DIR}/*; do
      FILE_BASE_NAME=$(basename "${splitfile}")
      oc cp $@ "${splitfile}" "${POD}:${POD_DIST_DIR}/${FILE_BASE_NAME}"
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
    for splitfile in ${FILE_LIST} ; do
      FILE_BASE_NAME=$(basename "${splitfile}")
      oc cp $@ "${POD}:${splitfile}" "${SPLITE_DIR}/${FILE_BASE_NAME}"
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
        brlog "ERROR" "Can not get command result over ${MAX_CMD_FAILURE_COUNT} times." >&2
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

show_quiesce_error_message(){
  local message=$( cat << EOS
Backup/Restore failed.
You can restart ${COMMAND} with "--continue-form" option like:
  ./all-backup-restore.sh ${COMMAND} -f ${BACKUP_FILE} --continue-from ${CURRENT_COMPONENT} ${RETRY_ADDITIONAL_OPTION:-}
You can unquiesce WatsonDiscovery by this command:
  oc patch wd wd --type merge --patch '{"spec": {"shared": {"quiesce": {"enabled": true}}}}'
EOS
)
  brlog "ERROR" "${message}"
}

quiesce(){
  echo
  brlog "INFO" "Quiescing"
  echo

  local quiesce_on_error=false

  if [ "$COMMAND" = "backup" ] ; then
    quiesce_on_error=${QUIESCE_ON_ERROR:-false}
  else
    quiesce_on_error=${QUIESCE_ON_ERROR:-true}
  fi

  if "${quiesce_on_error}" ; then
    trap "show_quiesce_error_message" 0 1 2 3 15
  else
    if [ "$COMMAND" = "restore" ] ; then
      trap "brlog 'ERROR' 'Error occur while running scripts.' ; unquiesce; ./post-restore.sh ${TENANT_NAME}; brlog 'ERROR' 'Backup/Restore failed.'" 0 1 2 3 15
    else
      trap "unquiesce; brlog 'ERROR' 'Backup/Restore failed.'" 0 1 2 3 15
    fi
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
  local utils_image="`oc get ${OC_ARGS} deploy -l tenant=${TENANT_NAME} -o jsonpath='{..image}' | tr -s '[[:space:]]' '\n' | sort | uniq | grep wd-utils | tail -n1`"
  echo "${utils_image%/*}"
}

get_migrator_repo(){
  local repo="`get_image_repo`"
  echo "${repo%/}/wd-migrator"
}

declare -A MIGRATOR_TAGS
MIGRATOR_TAGS=(
  ["2.2.0"]="12.0.6-2031"
  ["2.2.1"]="12.0.7-3010"
  ["4.0.0"]="12.0.8-5028@sha256:a74a705b072a25f01c98a4ef5b4e7733ceb7715c042cc5f7876585b5359f1f65"
  ["4.0.2"]="12.0.9-7007@sha256:f604cbed6f6517c6bd8c11dc6dd13da9299c73c36d00c36d60129a798e52dcbb"
  ["4.0.3"]="12.0.10-7006@sha256:b4fd94eee9dade78a32dce828f0b640ae382cc300f746ad5af3c49cea276e43a"
  ["4.0.4"]="12.0.11-7050@sha256:de8f09a0396301b02fde2e15973dbfc7d923af5946ea1592a6c4fd6c859b8524"
  ["4.0.5"]="12.0.12-8043@sha256:ce430b4d5dc9487586f3d539e68de6378982862a6ecb26e319b74bb68f4a2785"
  ["4.0.6"]="12.0.13-8054@sha256:d1fe1f70c88baedaaccba1974d8a5517073d83e0b5085c9b8dae1218bfc3b19f"
)

get_migrator_tag(){
  local wd_version=${WD_VERSION:-`get_version`}
  if [ -n "${MIGRATOR_TAGS["${wd_version}"]+UNDEFINE}" ] ; then
    echo "${MIGRATOR_TAGS["${wd_version}"]}"
  else
    brlog "ERROR" "Can not find migrator image tag for ${wd_version}" >&2
    exit 1
  fi
}

get_migrator_image(){
  echo "`get_migrator_repo`:${MIGRATOR_TAG:-`get_migrator_tag`}"
}

# Get postgres configure image tag in 4.0.0 or later.

declare -A PG_CONFIG_TAGS
PG_CONFIG_TAGS=(
  ["4.0.0"]="20210604-150426-1103-5d09428b@sha256:52d3dd27728388458aaaca2bc86d06f9ad61b7ffcb6abbbb1a87d11e6635ebbf"
  ["4.0.2"]="20210901-003512-1193-d0afc1d9@sha256:1db665ab92d4a8e6ef6d46921cec8c0883562e6330aa37f12fe005d3129aa3b5"
  ["4.0.3"]="20211022-003507-1246-a9166aca@sha256:c177dc8aa05e0e072e8f786a7ebd144f84643c395952757d3af08636626914c2"
  ["4.0.4"]="20211212-155002-4-f1f28c77@sha256:bd53e3c80b2a572bf007eae1c144951c1dcda6315e972ffe2491f98994e919a4"
  ["4.0.5"]="20211221-172037-14-e854223f@sha256:de27642e2e8dc56073ebde40ba2277416ce345f3f132c8f6146329459d1a8732"
  ["4.0.6"]="20220203-003508-1355-e9424fab@sha256:372df30becb14678016a6efc9c339084986e388dbba84316f2ea7fb60b916c4c"
)

get_pg_config_tag(){
  local wd_version=${WD_VERSION:-`get_version`}
  if [ -n "${PG_CONFIG_TAGS["${wd_version}"]+UNDEFINE}" ] ; then
    echo "${PG_CONFIG_TAGS["${wd_version}"]}"
  else
    brlog "ERROR" "Can not find configure-postgres image tag for ${wd_version}" >&2
    exit 1
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
  MAX_WAIT_COUNT=${MAX_MIGRATOR_JOB_WAIT_COUNT:-400}
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
  MAX_WAIT_COUNT=${MAX_MIGRATOR_JOB_WAIT_COUNT:-400}
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
  oc delete pod -l "${label}"
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

run_script_in_pod(){
  local pod="$1"
  shift
  local script="$1"
  shift
  local options=( "$1" )
  shift
  local filename="$(basename "${script}")"
  oc cp $@ "${script}" "${pod}:/tmp/${filename}"
  run_cmd_in_pod ${pod} "/tmp/${filename} ${options[@]}" $@
  oc exec $@ ${pod} -- bash -c "rm -f /tmp/${filename}}"
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
  local wd_version=${WD_VERSION:-`get_version`}
  if [ `compare_version "${wd_version}" "2.2.1"` -le 0 ] ; then
    echo `oc ${OC_ARGS} get serviceaccount -l cpd_module=watson-discovery-adm-setup -o jsonpath="{.items[0].metadata.name}"`
  else
    echo `oc ${OC_ARGS} get serviceaccount -l app.kubernetes.io/component=admin,tenant=${TENANT_NAME} -o jsonpath="{.items[0].metadata.name}"`
  fi
}

get_pg_configmap(){
  local wd_version=${WD_VERSION:-`get_version`}
  if [ `compare_version "${wd_version}" "2.2.1"` -le 0 ] ; then
    echo `oc get ${OC_ARGS} configmap -l tenant=${TENANT_NAME},app.kubernetes.io/component=postgres-cxn -o jsonpath="{.items[0].metadata.name}"`
  else
    echo `oc get ${OC_ARGS} configmap -l tenant=${TENANT_NAME},app=cn-postgres -o jsonpath="{.items[0].metadata.name}"`
  fi
}

get_pg_secret(){
  local wd_version=${WD_VERSION:-`get_version`}
  if [ `compare_version "${wd_version}" "2.2.1"` -le 0 ] ; then
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
  REQUIRE_TENANT_BACKUP="false"
  if [ "${COMMAND}" = "restore" ] && require_tenant_backup ; then
    REQUIRE_TENANT_BACKUP="true"
  fi
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
  add_env_to_job_yaml "REQUIRE_TENANT_BACKUP" "${REQUIRE_TENANT_BACKUP}" "${PG_JOB_FILE}"
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

get_quiesce_status(){
  local tenant=$1
  shift
  quiesce_status=$(oc get $@ wd ${tenant} -o jsonpath='{.status.customResourceQuiesce}')
  echo "${quiesce_status}"
}

require_st_mt_migration(){
  local wd_version=${WD_VERSION:-$(get_version)}
  local backup_version=${BACKUP_FILE_VERSION:-$(get_backup_version)}
  local mt_version="4.0.6"
  if [ $(compare_version "${backup_version}" "${mt_version}") -lt 0 ] && [ $(compare_version "${wd_version}" "${mt_version}") -ge 0 ] ; then
    return 0
  else
    return 1
  fi
}

require_mt_mt_migration(){
  local wd_version=${WD_VERSION:-$(get_version)}
  local backup_version=${BACKUP_FILE_VERSION:-$(get_backup_version)}
  local mt_version="4.0.6"
  if [ $(compare_version "${backup_version}" "${mt_version}") -ge 0 ] && [ $(compare_version "${wd_version}" "${mt_version}") -ge 0 ] ; then
    return 0
  else
    return 1
  fi
}

get_primary_pg_pod(){
  local wd_version=${WD_VERSION:-$(get_version)}
  if [ `compare_version "${wd_version}" "4.0.0"` -ge 0 ] ; then
    echo "$(oc get pod ${OC_ARGS} -l "postgresql=${TENANT_NAME}-discovery-cn-postgres,role=primary" -o jsonpath='{.items[0].metadata.name}')"
  else
    for POD in $(oc get pods ${OC_ARS} -o jsonpath='{.items[*].metadata.name}' -l tenant=${TENANT_NAME},component=stolon-keeper) ; do
      if oc logs ${OC_ARGS} --since=30s ${POD} | grep 'our db requested role is master' > /dev/null ; then
        echo "${POD}"
        break
      fi
    done
  fi
}

launch_minio_pod(){
  MINIO_BACKUP_RESTORE_SCRIPTS="run.sh"
  MINIO_BACKUP_RESTORE_JOB="wd-discovery-minio-backup-restore"
  MINIO_JOB_TEMPLATE="${SCRIPT_DIR}/src/backup-restore-job-template.yml"
  JOB_CPU_LIMITS="${MC_CPU_LIMITS:-800m}" # backward compatibility
  JOB_CPU_LIMITS="${JOB_CPU_LIMITS:-800m}"
  JOB_MEMORY_LIMITS="${MC_MEMORY_LIMITS:-2Gi}" # backward compatibility
  JOB_MEMORY_LIMITS="${JOB_MEMORY_LIMITS:-2Gi}"
  NAMESPACE=${NAMESPACE:-`oc config view --minify --output 'jsonpath={..namespace}'`}
  WD_MIGRATOR_IMAGE="`get_migrator_image`"
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
  add_config_env_to_job_yaml "MINIO_ENDPOINT_URL" "${MINIO_CONFIGMAP}" "endpoint" "${MINIO_JOB_FILE}"
  add_config_env_to_job_yaml "S3_HOST" "${MINIO_CONFIGMAP}" "host" "${MINIO_JOB_FILE}"
  add_config_env_to_job_yaml "S3_PORT" "${MINIO_CONFIGMAP}" "port" "${MINIO_JOB_FILE}"
  add_config_env_to_job_yaml "S3_ELASTIC_BACKUP_BUCKET" "${MINIO_CONFIGMAP}" "bucketElasticBackup" "${MINIO_JOB_FILE}"
  add_secret_env_to_job_yaml "MINIO_ACCESS_KEY" "${MINIO_SECRET}" "accesskey" "${MINIO_JOB_FILE}"
  add_secret_env_to_job_yaml "MINIO_SECRET_KEY" "${MINIO_SECRET}" "secretkey" "${MINIO_JOB_FILE}"
  if [ -n "${MINIO_ARCHIVE_OPTION:+UNDEF}" ] ; then add_env_to_job_yaml "MINIO_ARCHIVE_OPTION" "${MINIO_ARCHIVE_OPTION}" "${MINIO_JOB_FILE}"; fi
  if [ -n "${DISABLE_MC_MULTIPART:+UNDEF}" ] ; then add_env_to_job_yaml "DISABLE_MC_MULTIPART" "${DISABLE_MC_MULTIPART}" "${MINIO_JOB_FILE}"; fi
  add_env_to_job_yaml "TZ" "${TZ_OFFSET}" "${MINIO_JOB_FILE}"
  add_volume_to_job_yaml "${JOB_PVC_NAME:-emptyDir}" "${MINIO_JOB_FILE}"

  oc ${OC_ARGS} delete -f "${MINIO_JOB_FILE}" &> /dev/null || true
  oc ${OC_ARGS} apply -f "${MINIO_JOB_FILE}"
  get_job_pod "app.kubernetes.io/component=${MINIO_BACKUP_RESTORE_JOB},tenant=${TENANT_NAME}"
  wait_job_running ${POD}
}

setup_minio_env(){
  MINIO_SVC=`oc ${OC_ARGS} get svc -l release=${TENANT_NAME}-minio,helm.sh/chart=ibm-minio -o jsonpath="{.items[*].metadata.name}" | tr '[[:space:]]' '\n' | grep headless`
  MINIO_PORT=`oc ${OC_ARGS} get svc ${MINIO_SVC} -o jsonpath="{.spec.ports[0].port}"`
  MINIO_SECRET=`oc ${OC_ARGS} get secret -l tenant=${TENANT_NAME},run=minio-auth -o jsonpath="{.items[*].metadata.name}" | tr -s '[[:space:]]' '\n' | grep minio`
  MINIO_ACCESS_KEY=`oc get ${OC_ARGS} secret ${MINIO_SECRET} --template '{{.data.accesskey}}' | base64 --decode`
  MINIO_SECRET_KEY=`oc get ${OC_ARGS} secret ${MINIO_SECRET} --template '{{.data.secretkey}}' | base64 --decode`
  MINIO_FORWARD_PORT=${MINIO_FORWARD_PORT:-39001}
  MINIO_ENDPOINT_URL=${MINIO_ENDPOINT_URL:-https://localhost:$MINIO_FORWARD_PORT}
}

check_datastore_available(){
  brlog "INFO" "Checking status of data store"
  check_etcd_available || { brlog "ERROR" "Etcd is unavailable"; return 1; }
  check_postgres_available || { brlog "ERROR" "Postgresql is unavailable"; return 1; }
  check_elastic_available || { brlog "ERROR" "ElasticSearch is unavailable"; return 1; }
  check_minio_avairable || { brlog "ERROR" "MinIO is unavailable"; return 1; }
  brlog "INFO" "All data store service are available"
}

check_etcd_available(){
  setup_etcd_env
  ETCD_POD=$(oc get pods ${OC_ARGS} -o jsonpath="{.items[0].metadata.name}" -l etcd_cluster=${TENANT_NAME}-discovery-etcd)
  oc exec ${OC_ARGS} "${ETCD_POD}" -- bash -c "export ETCDCTL_USER='${ETCD_USER}:${ETCD_PASSWORD}' && \
  export ETCDCTL_CERT='/etc/etcdtls/operator/etcd-tls/etcd-client.crt' && \
  export ETCDCTL_CACERT='/etc/etcdtls/operator/etcd-tls/etcd-client-ca.crt' && \
  export ETCDCTL_KEY='/etc/etcdtls/operator/etcd-tls/etcd-client.key' && \
  export ETCDCTL_ENDPOINTS='https://${ETCD_SERVICE}:2379' && \
  etcdctl endpoint health > /dev/null" || return 1
  return 0
}

setup_etcd_env(){
  ETCD_SERVICE=$(oc get svc ${OC_ARGS} -o jsonpath="{.items[*].metadata.name}" -l "app=etcd,tenant=${TENANT_NAME}" | tr '[[:space:]]' '\n' | grep etcd-client || echo "")
  if [ -z "${ETCD_SERVICE}" ] ; then
    # Etcd label changed on 4.0.4
    ETCD_SERVICE=$(oc get svc ${OC_ARGS} -o jsonpath="{.items[*].metadata.name}" -l "app=etcd,etcd_cluster=${TENANT_NAME}-discovery-etcd" | tr '[[:space:]]' '\n' | grep etcd-client)
  fi
  ETCD_SECRET=$(oc get secret ${OC_ARGS} -o jsonpath="{.items[0].metadata.name}" -l tenant=${TENANT_NAME},app=etcd-root)
  ETCD_USER=$(oc get secret ${OC_ARGS} ${ETCD_SECRET} --template '{{.data.username}}' | base64 --decode)
  ETCD_PASSWORD=$(oc get secret ${OC_ARGS} ${ETCD_SECRET} --template '{{.data.password}}' | base64 --decode)
}

setup_pg_env(){
  local wd_version=${WD_VERSION:-$(get_version)}
  if [ `compare_version "${wd_version}" "4.0.0"` -ge 0 ] ; then
    PGUSER="postgres"
    PG_SECRET="$(get_pg_secret)"
    PGPASSWORD="$(oc get secret ${PG_SECRET} --template '{{.data.pg_su_password}}' | base64 --decode)"
  else
    PGUSER='${STKEEPER_PG_SU_USERNAME}'
    PGPASSWORD='${STKEEPER_PG_SU_PASSWORD}'
  fi
}

check_postgres_available(){
  local wd_version=${WD_VERSION:-$(get_version)}
  PG_POD=$(get_primary_pg_pod)
  setup_pg_env
  oc exec ${OC_ARGS} ${PG_POD} -- bash -c 'PGUSER='"${PGUSER}"' \
  PGPASSWORD='"${PGPASSWORD}"' \
  PGHOST=${HOSTNAME} \
  psql -q "dbname=postgres connect_timeout=10" -c "SET lock_timeout = 10000; SET statement_timeout = 10000; SELECT version()" > /dev/null' || return 1
  return 0
}

get_elastic_pod(){
  echo "$(oc get pods ${OC_ARGS} -o jsonpath="{.items[0].metadata.name}" -l tenant=${TENANT_NAME},app=elastic,ibm-es-data=True)"
}

check_elastic_available(){
  ELASTIC_POD=$(get_elastic_pod)
  oc exec ${OC_ARGS} "${ELASTIC_POD}" -c elasticsearch -- bash -c 'export ELASTIC_ENDPOINT=https://localhost:9200 && \
  curl -s -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_cluster/health" | grep "\"status\":\"yellow\"\\|\"status\":\"green\"" > /dev/null' || return 1
  return 0
}

check_minio_avairable(){
  setup_minio_env
  ELASTIC_POD=`oc get pods ${OC_ARGS} -o jsonpath="{.items[0].metadata.name}" -l tenant=${TENANT_NAME},app=elastic,ibm-es-data=True`
  oc exec ${OC_ARGS} "${ELASTIC_POD}" -c elasticsearch -- bash -c "curl -ks 'https://${MINIO_SVC}:${MINIO_PORT}/minio/health/ready' -w '%{http_code}' -o /dev/null | grep 200 > /dev/null" || return 1
  return 0
}

setup_zen_core_service_connection(){
  ZEN_CORE_SERVICE=$(oc get ${OC_ARGS} svc -l component=zen-core-api -o jsonpath='{.items[0].metadata.name}')
  ZEN_CORE_PORT=$(oc get ${OC_ARGS} svc -l component=zen-core-api -o jsonpath='{.items[0].spec.ports[?(@.name=="zencoreapi-tls")].port}')
  ZEN_CORE_API_ENDPOINT="https://${ZEN_CORE_SERVICE}:${ZEN_CORE_PORT}"
  ZEN_CORE_UID="$(oc get ${OC_ARGS} watsondiscoveryapi ${TENANT_NAME} -o jsonpath='{.appConfigOverrides.cp4d.api.admin_uid}')"
  ZEN_CORE_TOKEN="$(oc get ${OC_ARGS} secret zen-service-broker-secret --template '{{.data.token}}' | base64 --decode)"
  ZEN_INSTANCE_TYPE="discovery"
  ZEN_PROVISION_STATUS="PROVISIONED"
}

create_backup_instance_mappings(){
  brlog "INFO" "Creating instance mapping file"
  local mapping_file="${MAPPING_FILE:-${BACKUP_DIR}/instance_mapping.json}"
  setup_zen_core_service_connection
  ELASTIC_POD=$(get_elastic_pod)
  token=$(fetch_cmd_result ${ELASTIC_POD} "curl -ks ${ZEN_CORE_API_ENDPOINT}/internal/v1/service_token?uid=${ZEN_CORE_UID} -H 'secret: ${ZEN_CORE_TOKEN}' -H 'cache-control: no-cache' | jq -r .token" -c elasticsearch)
  mappings=$(fetch_cmd_result ${ELASTIC_POD} "curl -ks '${ZEN_CORE_API_ENDPOINT}/v2/serviceInstance' -H 'Authorization: Bearer ${token}' | jq -r '.requestObj[] | select(.ServiceInstanceType == \"discovery\" and .ProvisionStatus == \"PROVISIONED\") | { \"display_name\": .ServiceInstanceDisplayName, \"source_instance_id\": .CreateArguments.metadata.instanceId, \"dest_instance_id\": \"<new_instance_id>\"}' | jq -s '{\"instance_mappings\": .}'" -c elasticsearch)
  echo "${mappings}" > ${mapping_file}
  brlog "INFO" "Instance mapping file: ${mapping_file}"
}

create_restore_instance_mappings(){
  local rc=0
  local mapping='{ "instance_mappings" : []}'
  setup_zen_core_service_connection
  ELASTIC_POD=$(get_elastic_pod)
  oc cp -c elasticsearch "${MAPPING_FILE}" "${ELASTIC_POD}:/tmp/mapping.json"
  local token=$(fetch_cmd_result ${ELASTIC_POD} "curl -ks '${ZEN_CORE_API_ENDPOINT}/internal/v1/service_token?uid=${ZEN_CORE_UID}&username=admin&display_name=admin' -H 'secret: ${ZEN_CORE_TOKEN}' -H 'cache-control: no-cache' | jq -r .token" -c elasticsearch)
  local service_instances=$(oc exec ${OC_ARGS} -c elasticsearch ${ELASTIC_POD} -- bash -c "curl -ks '${ZEN_CORE_API_ENDPOINT}/v3/service_instances' -H 'Authorization: Bearer ${token}' | jq -r '.service_instances[] | select(.addon_type == \"discovery\" and .provision_status == \"PROVISIONED\") | .id'")
  if [ -n "${service_instances}" ] && [ "${service_instances}" != "null" ] ; then
    brlog "INFO" "Discovery instances exist. Check if they are same instance."
    local src_instances=$(fetch_cmd_result ${ELASTIC_POD} "jq -r '.instance_mappings[].source_instance_id' /tmp/mapping.json" -c elasticsearch)
    len1=( ${service_instances} )
    len2=( ${src_instances} )
    if [ ${#len1[@]} -ne ${#len2[@]} ] ; then
      brlog "ERROR" "Different number of instances. Please create instance mapping, and specify it '--mapping' option"
      return 1
    fi
    for instance in ${src_instances}
    do
      if echo "${service_instances}" | grep "${instance}" > /dev/null ; then
        mapping=$(fetch_cmd_result ${ELASTIC_POD} "echo '${mapping}' | jq -r '.instance_mappings |= . + [{\"source_instance_id\": \"${instance}\", \"dest_instance_id\": \"${instance}\"}]'")
      else
        brlog "ERROR" "Instance ${instance} does not exist. Please create instance mapping, and specify it with '--mapping' option."
        return 1
      fi
    done
  else
    brlog "INFO" "No Discovery instance exist. Create new one."
    local namespace=${NAMESPACE:-`oc config view --minify --output 'jsonpath={..namespace}'`}
    local request_file="${SCRIPT_DIR}/src/create_service_instance.json"
    local template="${SCRIPT_DIR}/src/create_service_instance_template.json"
    local src_instances=( $(fetch_cmd_result ${ELASTIC_POD} "jq -r '.instance_mappings[].source_instance_id' /tmp/mapping.json" -c elasticsearch) )
    local display_names=( $(fetch_cmd_result ${ELASTIC_POD} "jq -r '.instance_mappings[].display_name' /tmp/mapping.json" -c elasticsearch) )
    for i in "${!src_instances[@]}"
    do
        rm -f "${request_file}"
        sed -e "s/#namespace#/${namespace}/g" \
          -e "s/#version#/$(get_version)/g" \
          -e "s/#instance#/${TENANT_NAME}/g" \
          -e "s/#display_name#/${display_names[$i]}/g" \
          "${template}" > "${request_file}"
        oc cp -c elasticsearch "${request_file}" "${ELASTIC_POD}:/tmp/request.json"
        instance_id=$(fetch_cmd_result ${ELASTIC_POD} "curl -ks -X POST '${ZEN_CORE_API_ENDPOINT}/v3/service_instances' -H 'Authorization: Bearer ${token}' -H 'Content-Type: application/json' -d@/tmp/request.json | jq -r '.id'" -c elasticsearch)
        if [ -z "${instance_id}" ] || [ "${instance_id}" = "null" ] ; then
          brlog "ERROR" "Failed to create Discovery service instance for ${src_instances[$i]}"
          return 1
        else
          brlog "INFO" "Created Disocvery service instance: ${instance_id}"
          mapping=$(fetch_cmd_result ${ELASTIC_POD} "echo '${mapping}' | jq -r '.instance_mappings |= . + [{\"source_instance_id\": \"${src_instances[$i]}\", \"dest_instance_id\": \"${instance_id}\"}]'" -c elasticsearch)
        fi
    done
  fi
  export MAPPING_FILE="./instance_mapping-$(date "+%Y%m%d%H%M").json"
  echo "${mapping}" > "${MAPPING_FILE}"
  brlog "INFO" "Created instance mapping: ${MAPPING_FILE}"
  brlog "INFO" "Please specify it with '--mapping' option when you retry restore like: ./all-backup-restore.sh restore -f ${BACKUP_FILE} --mapping ${MAPPING_FILE}"
  export RETRY_ADDITIONAL_OPTION="--mapping ${MAPPING_FILE} ${RETRY_ADDITIONAL_OPTION:-}"
  return 0
}

check_instance_mappings(){
  brlog "INFO" "Check instance mapping"
  if [ -z "${MAPPING_FILE:+UNDEF}" ] ; then
    brlog "INFO" "Mapping file is not specified"
    export MAPPING_FILE="${BACKUP_DIR}/instance_mapping.json"
    create_restore_instance_mappings || return 1
  fi
  if [ ! -e "${MAPPING_FILE}" ] ; then
    brlog "ERROR" "Instance mapping file not found."
    return 1
  fi
  setup_zen_core_service_connection
  ELASTIC_POD=$(get_elastic_pod)
  file_name="$(basename "${MAPPING_FILE}")"
  oc cp -c elasticsearch "${MAPPING_FILE}" "${ELASTIC_POD}:/tmp/mapping.json"
  token=$(fetch_cmd_result ${ELASTIC_POD} "curl -ks '${ZEN_CORE_API_ENDPOINT}/internal/v1/service_token?uid=${ZEN_CORE_UID}&username=admin&display_name=admin' -H 'secret: ${ZEN_CORE_TOKEN}' -H 'cache-control: no-cache' | jq -r .token" -c elasticsearch)
  service_instances=$(fetch_cmd_result ${ELASTIC_POD} "curl -ks '${ZEN_CORE_API_ENDPOINT}/v3/service_instances' -H 'Authorization: Bearer ${token}' | jq -r '.service_instances[] | select(.addon_type == \"discovery\" and .provision_status == \"PROVISIONED\") | .id'" -c elasticsearch)
  dest_instances=$(fetch_cmd_result ${ELASTIC_POD} "jq -r '.instance_mappings[].dest_instance_id' /tmp/mapping.json" -c elasticsearch)
  for instance in ${dest_instances}
  do
    if ! echo "${service_instances}" | grep "${instance}" > /dev/null ; then
      brlog "ERROR" "Instance not found. Instance ID: ${instance}"
      return 1
    fi
  done
  return 0
}

get_instance_tuples(){
  ELASTIC_POD=$(get_elastic_pod)
  file_name="$(basename "${MAPPING_FILE}")"
  oc cp -c elasticsearch "${MAPPING_FILE}" "${ELASTIC_POD}:/tmp/mapping.json"
  mappings=( $(fetch_cmd_result ${ELASTIC_POD} "jq -r '.instance_mappings[] | \"\(.source_instance_id),\(.dest_instance_id)\"' /tmp/mapping.json" -c elasticsearch) )
  oc exec -c elasticsearch ${ELASTIC_POD} -- bash -c "rm -f /tmp/mapping.json"
  for map in "${mappings[@]}"
  do
    ORG_IFS=${IFS}
    IFS=","
    set -- ${map}
    IFS=${ORG_IFS}
    src=( $(printf "%032d" "${1}" | fold -w4) )
    dest=( $(printf "%032d" "${2}" | fold -w4) )
    echo "${src[0]}${src[1]}-${src[2]}-${src[3]}-${src[4]}-${src[5]}${src[6]}${src[7]},${dest[0]}${dest[1]}-${dest[2]}-${dest[3]}-${dest[4]}-${dest[5]}${dest[6]}${dest[7]}"
  done
}

require_tenant_backup(){
  local wd_version=${WD_VERSION:-$(get_backup_version)}
  local backup_file_version=${BACKUP_FILE_VERSION:-$(get_backup_version)}
  if [ $(compare_version ${backup_file_version} "2.1.3") -le 0 ] && [ $(compare_version "${wd_version}" "4.0.5") -le 0 ] ; then
    return 0
  fi
  return 1
}

check_instance_exists(){
  local wd_version=${WD_VERSION:-$(get_version)}
  setup_pg_env
  PG_POD=$(get_primary_pg_pod)
  oc exec ${OC_ARGS} ${PG_POD} -- bash -c 'PGUSER='"${PGUSER}"' \
  PGPASSWORD='"${PGPASSWORD}"' \
  PGHOST=${HOSTNAME} \
  psql -d dadmin -t -c "SELECT * from tenants;" | grep "default" > /dev/null' || return 1
  return 0
}