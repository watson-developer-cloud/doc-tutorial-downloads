export BACKUP_RESTORE_LOG_LEVEL="${BACKUP_RESTORE_LOG_LEVEL:-INFO}"
export WD_CMD_COMPLETION_TOKEN="completed_wd_command"
export WD_CMD_FAILED_TOKEN="failed_wd_command"
export BACKUP_VERSION_FILE="tmp/version.txt"
export DATASTORE_ARCHIVE_OPTION="${DATASTORE_ARCHIVE_OPTION--z}"
export BACKUP_RESTORE_LOG_DIR="${BACKUP_RESTORE_LOG_DIR:-wd-backup-restore-logs-$(date "+%Y%m%d_%H%M%S")}"
export BACKUP_RESTORE_SA="${BACKUP_RESTORE_SA:-wd-discovery-backup-restore-sa}"

case "${BACKUP_RESTORE_LOG_LEVEL}" in
  "ERROR") export LOG_LEVEL_NUM=0;;
  "WARN")  export LOG_LEVEL_NUM=1;;
  "INFO")  export LOG_LEVEL_NUM=2;;
  "DEBUG") export LOG_LEVEL_NUM=3;;
esac

declare -a trap_commands

brlog(){
  LOG_LEVEL=$1
  shift
  LOG_MESSAGE=$1
  shift
  LOG_DATE=$(date "+%Y/%m/%d %H:%M:%S")
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

trap_add(){
  trap_commands+=("$1")
  printf -v joined '%s;' "${trap_commands[@]}"
  cmd="$(echo -n "${joined%;}")"
  trap "${cmd}" 0 1 2 3 15
}

trap_remove(){
  trap_commands=( "${trap_commands[@]/$1}" )
  trap "${trap_commands}" 0 1 2 3 15
}

disable_trap(){
  trap 0 1 2 3 15
}

_oc_cp(){
  local src=$1
  local dst=$2
  shift 2
  local max_retry_count=${MAX_CP_RETRY_COUNT:-5}
  local retry_count=1
  local oc_cp_arg=""
  if oc cp -h | grep -e "--retries=" > /dev/null ; then
    oc_cp_arg="--retries=${OC_CP_RETRIES:-50}"
  fi
  while true;
  do
    oc cp ${oc_cp_arg} $@ "$src" "$dst" && break
    if [ ${retry_count} -le ${max_retry_count} ] ; then
      brlog "WARN" "Failed to copy file. Retry count: ${retry_count}" >&2
      retry_count=$((retry_count += 1))
    else
      brlog "ERROR" "Failed to copy ${src} to ${dst}" >&2
      return 1
    fi
    sleep 1
  done
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
  for line in $(cat "${SCRIPT_VERSION_FILE}")
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
  if [ $(compare_version "${VERSION}" "${WD_VERSION}") -lt 0 ] ; then
    brlog "ERROR" "Invalid script version. The version of scripts '${SCRIPT_VERSION}' is not valid for the version of Watson Discovery '${WD_VERSION}' "
    exit 1
  fi
}

get_version(){
  if [ -n "${WD_VERSION:+UNDEF}" ] ; then
    echo "${WD_VERSION}"
  else
    if [ -n "$(oc get wd ${OC_ARGS} ${TENANT_NAME})" ] ; then
      local version=$(oc get wd ${OC_ARGS} ${TENANT_NAME} -o jsonpath='{.spec.version}')
      if [ "${version}" = "main" ] ; then
        # this should be latest version
        set_scripts_version > /dev/null
        echo "${SCRIPT_VERSION}"
      else
        echo "${version%%-*}"
      fi
    elif [ -n "$(oc get pod ${OC_ARGS} -l "app.kubernetes.io/name=discovery,run=management")" ] ; then
      if [ "$(oc ${OC_ARGS} get is wd-migrator -o jsonpath="{.status.tags[*].tag}" | tr -s '[[:space:]]' '\n' | tail -n1)" = "12.0.4-1048" ] ; then
        echo "2.1.3"
      else
        echo "2.1.4"
      fi
    elif [ -n "$(oc get sts ${OC_ARGS} -l "app.kubernetes.io/name=discovery,run=gateway" -o jsonpath="{..image}" | grep "wd-management")" ] ; then
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
  SPLIT_DIR=./tmp_split_backup
  SPLIT_SIZE=${BACKUP_RESTORE_SPLIT_SIZE:-500000000}
  LOCAL_BASE_NAME=$(basename "${LOCAL_BACKUP}")
  POD_DIST_DIR=$(dirname "${POD_BACKUP}")

  if "${IS_RECURSIVE}" ; then
    ORG_POD_BACKUP=${POD_BACKUP}
    ORG_LOCAL_BACKUP=${LOCAL_BACKUP}
    oc exec $@ ${POD} -- bash -c "mkdir -p ${ORG_POD_BACKUP}"
    for file in $(find "${ORG_LOCAL_BACKUP}" -type f) ; do
      relative_path=${file#$ORG_LOCAL_BACKUP/}
      FILE_DIR_NAME=$(dirname "${relative_path}")
      if [ "${FILE_DIR_NAME}" != "." ] ; then
        oc exec $@ ${POD} -- bash "mkdir -p ${ORG_POD_BACKUP}/${FILE_DIR_NAME}"
      fi
      if [ ${TRANSFER_WITH_COMPRESSION-true} ] ; then
        tar -C ${ORG_LOCAL_BACKUP} "${TRANSFER_TAR_OPTIONS[@]}" -cf ${file}.tgz ${relative_path}
        kube_cp_from_local ${POD} ${file}.tgz ${ORG_POD_BACKUP}/${relative_path}.tgz $@
        rm -f ${file}.tgz
        run_cmd_in_pod ${POD} "tar -C ${ORG_POD_BACKUP} ${TRANSFER_COMPRESS_OPTION} -xf -m ${ORG_POD_BACKUP}/${relative_path}.tgz && rm -f ${ORG_POD_BACKUP}/${relative_path}.tgz" $@
      else
        kube_cp_from_local ${POD} ${file} ${ORG_POD_BACKUP}/${relative_path} $@
      fi
    done
    return
  fi

  STAT_CMD="$(get_stat_command) ${LOCAL_BACKUP}"
  LOCAL_SIZE=$(eval "${STAT_CMD}")
  if [ ${SPLIT_SIZE} -ne 0 -a ${LOCAL_SIZE} -gt ${SPLIT_SIZE} ] ; then
    rm -rf ${SPLIT_DIR}
    mkdir -p ${SPLIT_DIR}
    split -a 5 -b ${SPLIT_SIZE} ${LOCAL_BACKUP} ${SPLIT_DIR}/${LOCAL_BASE_NAME}.split.
    for splitfile in ${SPLIT_DIR}/*; do
      FILE_BASE_NAME=$(basename "${splitfile}")
      _oc_cp "${splitfile}" "${POD}:${POD_DIST_DIR}/${FILE_BASE_NAME}" $@
    done
    rm -rf ${SPLIT_DIR}
    run_cmd_in_pod ${POD} "cat ${POD_DIST_DIR}/${LOCAL_BASE_NAME}.split.* > ${POD_BACKUP} && rm -rf ${POD_DIST_DIR}/${LOCAL_BASE_NAME}.split.*" $@
  else
    _oc_cp "${LOCAL_BACKUP}" "${POD}:${POD_BACKUP}" $@
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
  SPLIT_DIR=./tmp_split_backup
  SPLIT_SIZE=${BACKUP_RESTORE_SPLIT_SIZE:-500000000}
  POD_DIST_DIR=$(dirname "${POD_BACKUP}")

  if "${IS_RECURSIVE}" ; then
    ORG_POD_BACKUP=${POD_BACKUP}
    ORG_LOCAL_BACKUP=${LOCAL_BACKUP}
    mkdir -p ${ORG_LOCAL_BACKUP}
    for file in $(oc exec $@ ${POD} -- sh -c 'cd '"${ORG_POD_BACKUP}"' && ls -Rp . | awk '"'"'/:$/&&f{s=$0;f=0};/:$/&&!f{sub(/:$/,"");s=$0;f=1;next};NF&&f{ print s"/"$0 }'"'"' | grep -v '"'"'.*/$'"'") ; do
      file=${file#./}
      FILE_DIR_NAME=$(dirname "${file}")
      if [ "${FILE_DIR_NAME}" != "." ] ; then
        mkdir -p ${ORG_LOCAL_BACKUP}/${FILE_DIR_NAME}
      fi
      if [ ${TRANSFER_WITH_COMPRESSION-true} ] ; then
        run_cmd_in_pod ${POD} "tar -C ${ORG_POD_BACKUP} ${TRANSFER_COMPRESS_OPTION} -cf ${ORG_POD_BACKUP}/${file}.tgz ${file}  && rm -f ${ORG_POD_BACKUP}/${file}" $@
        kube_cp_to_local ${POD} ${ORG_LOCAL_BACKUP}/${file}.tgz ${ORG_POD_BACKUP}/${file}.tgz $@
        oc exec $@ ${POD} -- bash -c "rm -f ${ORG_POD_BACKUP}/${file}.tgz"
        tar -C ${ORG_LOCAL_BACKUP} "${TRANSFER_TAR_OPTIONS[@]}" -xf ${ORG_LOCAL_BACKUP}/${file}.tgz
        rm -f ${ORG_LOCAL_BACKUP}/${file}.tgz
      else
        kube_cp_to_local ${POD} ${ORG_LOCAL_BACKUP}/${file} ${ORG_POD_BACKUP}/${file} $@
        oc exec $@ ${POD} -- bash -c "rm -f ${ORG_POD_BACKUP}/${file}"
      fi
    done
    return
  fi

  POD_SIZE=$(oc $@ exec ${POD} -- sh -c "stat -c "%s" ${POD_BACKUP}")
  if [ ${SPLIT_SIZE} -ne 0 -a ${POD_SIZE} -gt ${SPLIT_SIZE} ] ; then
    rm -rf ${SPLIT_DIR}
    mkdir -p ${SPLIT_DIR}
    run_cmd_in_pod ${POD} "split -d -a 5 -b ${SPLIT_SIZE} ${POD_BACKUP} ${POD_BACKUP}.split." $@
    FILE_LIST=$(oc exec $@ ${POD} -- sh -c "ls ${POD_BACKUP}.split.*")
    for splitfile in ${FILE_LIST} ; do
      FILE_BASE_NAME=$(basename "${splitfile}")
      _oc_cp "${POD}:${splitfile}" "${SPLIT_DIR}/${FILE_BASE_NAME}" $@
    done
    cat ${SPLIT_DIR}/* > ${LOCAL_BACKUP}
    rm -rf ${SPLIT_DIR}
    oc exec $@ ${POD} -- bash -c "rm -rf ${POD_BACKUP}.split.*"
  else
    _oc_cp "${POD}:${POD_BACKUP}" "${LOCAL_BACKUP}" $@
  fi
}

wait_cmd(){
  local pod=$1
  shift
  MONITOR_CMD_INTERVAL=${MONITOR_CMD_INTERVAL:-5}
  while true ;
  do
    files=$(fetch_cmd_result ${pod} "ls /tmp" $@)
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
    local cmd_result=$(oc exec $@ ${pod} --  sh -c "${cmd}")
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
    launch_utils_job "wd-backup-restore-util-job"
    get_job_pod "app.kubernetes.io/component=wd-backup-restore"
    wait_job_running ${POD}
    _oc_cp ${POD}:/usr/local/bin/mc ${DIST_DIR}/mc ${OC_ARGS}
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
    if [ -n "${S3_NAMESPACE+UNDEF}" ] ; then
      oc ${OC_ARGS} -n "${S3_NAMESPACE}" port-forward svc/${S3_PORT_FORWARD_SVC} ${S3_FORWARD_PORT}:${S3_PORT} &>> "${BACKUP_RESTORE_LOG_DIR}/port-forward.log" &
    else
      oc ${OC_ARGS} port-forward svc/${S3_PORT_FORWARD_SVC} ${S3_FORWARD_PORT}:${S3_PORT} &>> "${BACKUP_RESTORE_LOG_DIR}/port-forward.log" &
    fi
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
      if [ "$(oc ${OC_ARGS} get ${SCALE_RESOURCE_TYPE} ${SCALE_RESOURCE_NAME} -o jsonpath='{.status.replicas}')" = "0" ] ; then
        break
      else
        sleep 1
      fi
    done
    brlog "INFO" "Complete scale."
  fi
}

unquiesce(){
  echo
  brlog "INFO" "Activating"
  oc patch wd ${TENANT_NAME} --type merge --patch '{"spec": {"shared": {"quiesce": {"enabled": false}}}}'
  trap_remove "brlog 'ERROR' 'Error occur while running scripts.'"
  trap_remove "unquiesce"
  trap_remove "./post-restore.sh ${TENANT_NAME}"
  trap_remove "brlog 'ERROR' 'Backup/Restore failed.'"
  trap_remove "show_quiesce_error_message"

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
You can restart ${COMMAND} with adding "--continue-from" option:
  ex) ./all-backup-restore.sh ${COMMAND} -f ${BACKUP_FILE} --continue-from ${CURRENT_COMPONENT} ${RETRY_ADDITIONAL_OPTION:-}
You can unquiesce WatsonDiscovery by this command:
  oc patch wd wd --type merge --patch '{"spec": {"shared": {"quiesce": {"enabled": false}}}}'
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
    trap_add "show_quiesce_error_message"
  else
    if [ "$COMMAND" = "restore" ] ; then
      trap_add "brlog 'ERROR' 'Error occur while running scripts.'"
      trap_add "unquiesce"
      trap_add "./post-restore.sh ${TENANT_NAME}"
      trap_add "brlog 'ERROR' 'Backup/Restore failed.'"
    else
      trap_add "unquiesce"
      trap_add "brlog 'ERROR' 'Backup/Restore failed.'"
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
  local utils_image="$(oc get ${OC_ARGS} deploy -l tenant=${TENANT_NAME} -o jsonpath='{..image}' | tr -s '[[:space:]]' '\n' | sort | uniq | grep wd-utils | tail -n1)"
  echo "${utils_image%/*}"
}

get_migrator_repo(){
  local repo="$(get_image_repo)"
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
  ["4.0.7"]="12.0.14-8035@sha256:cb192a11959644e2b127ad41645063db53cdef8cc6e9ffed4b759b975a048008"
  ["4.0.8"]="12.0.15-9069@sha256:82a0f396ca18e217c79dd006e10836bf8092e28f76bb18ba38a2fed83db9f26b"
  ["4.0.9"]="12.0.16-9040@sha256:cdbd9cb5eda984fae392c3decab212facc69675d0246468940440a1305b8aa88"
  ["4.5.0"]="14.5.0-9004@sha256:cdbd9cb5eda984fae392c3decab212facc69675d0246468940440a1305b8aa88"
  ["4.5.1"]="14.5.1-9057@sha256:2851ff3309a3be38d3f4bd455fb0b7ca56fcef8912a314d01b4d52ba47dd083d"
  ["4.5.3"]="14.5.2-10588@sha256:614d7ca6616cd43c9ce813ddd98cd85ba676fee9979b592355c0fe7006bf0173"
  ["4.6.0"]="14.6.0-11063@sha256:54bca39b01993b8453417e6fcdf26d60aa0788db5e5d585a9b11de7b5466f4da"
)

get_migrator_tag(){
  local wd_version=${WD_VERSION:-$(get_version)}
  if [ -n "${MIGRATOR_TAGS["${wd_version}"]+UNDEFINE}" ] ; then
    echo "${MIGRATOR_TAGS["${wd_version}"]}"
  else
    brlog "ERROR" "Can not find migrator image tag for ${wd_version}" >&2
    exit 1
  fi
}

get_migrator_image(){
  local wd_version=${WD_VERSION:-$(get_version)}
  if [ $(compare_version "${wd_version}" "4.6.0") -le 0 ] ; then
    echo "$(get_migrator_repo):${MIGRATOR_TAG:-$(get_migrator_tag)}"
  else
    utils_repo="$(oc get watsondiscoveryapi wd -o jsonpath='{.spec.shared.dockerRegistryPrefix}')"
    utils_image="$(oc get watsondiscoveryapi wd -o jsonpath='{.spec.shared.initContainer.utils.image.name}')"
    utils_tag="$(oc get watsondiscoveryapi wd -o jsonpath='{.spec.shared.initContainer.utils.image.tag}')"
    utils_digest="$(oc get watsondiscoveryapi wd -o jsonpath='{.spec.shared.initContainer.utils.image.digest}')"
    echo "${utils_repo}/${utils_image}:${utils_tag}@${utils_digest}"
  fi
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
  ["4.0.7"]="20220304-150142-11-eb251f4d@sha256:0743350fbdadcaae1c0440f630ed23b1b5fa9d5608782d40da54bfa7ac772f36"
  ["4.0.8"]="20220404-180919-16-03066e2f@sha256:9ebbeedca00aac2aea721d54d078d947f9ac8850aa38208452cf6dc0a2a620df"
  ["4.0.9"]="20220503-234532-11-3223b318@sha256:1edbce69c27fe5b1391cc8925aa3a4775d4f5c4a3abb43a1fcf4fd494fc36860"
  ["4.5.0"]="20220519-010245-5-e4d8540b@sha256:e5a4caa82117fff857b7a0e8c66164ae75702cb1494411c5bbbccadaec259d9f"
  ["4.5.1"]="20220519-010245-5-e4d8540b@sha256:e5a4caa82117fff857b7a0e8c66164ae75702cb1494411c5bbbccadaec259d9f"
  ["4.5.3"]="20220705-150429-1523-990b004f@sha256:c9323c3a468c9097f83c1268541c94885d7a9713d3532e5058612cd1b05515c5"
  ["4.6.0"]="20221030-165859-3-a739344f@sha256:97aa673571fc65e239afb28138760dbc2eadc8c698c76afa757ca9e8e4a93f74"
)

get_pg_config_tag(){
  local wd_version=${WD_VERSION:-$(get_version)}
  if [ -n "${PG_CONFIG_TAGS["${wd_version}"]+UNDEFINE}" ] ; then
    echo "${PG_CONFIG_TAGS["${wd_version}"]}"
  elif [ -n "$(oc get watsondiscoverywire ${TENANT_NAME} -o jsonpath='{.spec.wire.postgresConfigJob.image.tag}')" ] ; then
    pg_config_tag="$(oc get watsondiscoverywire ${TENANT_NAME} -o jsonpath='{.spec.wire.postgresConfigJob.image.tag}')"
    pg_config_digest="$(oc get watsondiscoverywire ${TENANT_NAME} -o jsonpath='{.spec.wire.postgresConfigJob.image.digest}')"
    echo "${pg_config_tag}@${pg_config_digest}"
  else
    brlog "ERROR" "Can not find configure-postgres image tag for ${wd_version}" >&2
    exit 1
  fi
}

launch_utils_job(){
  local job_name="${1}"
  MIGRATOR_JOB_NAME="${job_name}"
  MIGRATOR_JOB_TEMPLATE="${SCRIPT_DIR}/src/migrator-job-template.yml"
  MIGRATOR_JOB_FILE="${SCRIPT_DIR}/src/migrator-job.yml"
  MIGRATOR_CPU_LIMITS="${MIGRATOR_CPU_LIMITS:-800m}"
  MIGRATOR_MEMORY_LIMITS="${MIGRATOR_MEMORY_LIMITS:-4Gi}"
  MIGRATOR_MAX_HEAP="${MIGRATOR_MAX_HEAP:-3g}"

  WD_MIGRATOR_IMAGE="$(get_migrator_image)"
  PG_CONFIGMAP=$(get_pg_configmap)
  PG_SECRET=$(get_pg_secret)
  ETCD_CONFIGMAP=$(oc get ${OC_ARGS} configmap -l tenant=${TENANT_NAME},app=etcd-cxn -o jsonpath="{.items[0].metadata.name}")
  ETCD_SECRET=$(oc ${OC_ARGS} get secret -l "tenant=${TENANT_NAME},app in (etcd,etcd-root)" -o jsonpath="{.items[*].metadata.name}")
  CK_SECRET=$(oc ${OC_ARGS} get secret -l tenant=${TENANT_NAME},app=ck-secret -o jsonpath="{.items[*].metadata.name}")
  DISCO_SVC_ACCOUNT=$(get_service_account)
  NAMESPACE=${NAMESPACE:-$(oc config view --minify --output 'jsonpath={..namespace}')}
  WD_VERSION=${WD_VERSION:-$(get_version)}
  setup_s3_env
  if [ $(compare_version "${WD_VERSION}" "2.2.1") -le 0 ] ; then
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
    -e "s/#minio-secret#/${S3_SECRET}/g" \
    -e "s/#minio-configmap#/${S3_CONFIGMAP}/g" \
    -e "s/#ck-secret#/${CK_SECRET}/g" \
    -e "s/#cpu-limit#/${MIGRATOR_CPU_LIMITS}/g" \
    -e "s/#memory-limit#/${MIGRATOR_MEMORY_LIMITS}/g" \
    -e "s/#pg-pass-key#/${PG_SECRET_PASS_KEY}/g" \
    -e "s/#job-name#/${job_name}/g" \
    "${MIGRATOR_JOB_TEMPLATE}" > "${MIGRATOR_JOB_FILE}"

  oc ${OC_ARGS} delete -f "${MIGRATOR_JOB_FILE}" --ignore-not-found
  wait_job_pod_deleted "app.kubernetes.io/component=wd-backup-restore,app.kubernetes.io/name=discovery" "${job_name}"
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
    PODS=$(oc get ${OC_ARGS} pod -l "${label}" -o jsonpath="{.items[*].metadata.name}")
    if [ -n "${PODS}" ] ; then
      for P in $PODS ;
      do
        if [ "$(oc get ${OC_ARGS} pod ${P} -o jsonpath='{.status.phase}')" != "Failed" ] ; then
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
    STATUS=$(oc get ${OC_ARGS} pod ${POD} -o jsonpath="{.status.phase}")
    if [ "${STATUS}" = "Running" ] || [ "${STATUS}" =  "Succeeded" ] ; then
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

wait_job_pod_deleted(){
  local label=$1
  local job_name=$2
  while true;
  do
    oc get ${OC_ARGS} pod -l "${label}" | grep "${job_name}" &> /dev/null || break
    oc delete ${OC_ARGS} pod -l "${label}" --ignore-not-found
    brlog "INFO" "Wait for old job pod to be deleted"
    sleep 10
  done
}


run_core_init_db_job(){
  local label="tenant=${TENANT_NAME},run=core-database-init"
  JOB_NAME=$(oc get ${OC_ARGS} job -o jsonpath="{.items[0].metadata.name}" -l "${label}")
  oc delete pod -l "${label}"
  oc delete ${OC_ARGS} job -l "${label}"
  oc delete pod -l "release=${TENANT_NAME},app=operator"
  get_job_pod "${label}"
  wait_job_running ${POD}
  brlog "INFO" "Waiting for core db config job to be completed..."
  while :
  do
    if [ "$(oc ${OC_ARGS} get job -o jsonpath='{.status.succeeded}' ${JOB_NAME})" = "1" ] ; then
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
set -eo pipefail
trap "touch /tmp/${WD_CMD_COMPLETION_TOKEN}; touch /tmp/${WD_CMD_FAILED_TOKEN}" 0 1 2 3 15
{ ${cmd} ; } &> /tmp/${WD_CMD_LOG}
touch /tmp/${WD_CMD_COMPLETION_TOKEN}
trap 0 1 2 3 15
EOF

  chmod +x ${TMP_WORK_DIR}/${WD_CMD_FILE}
  _oc_cp ${TMP_WORK_DIR}/${WD_CMD_FILE} ${pod}:/tmp/${WD_CMD_FILE} $@
  oc exec $@ ${pod} -- bash -c "rm -rf /tmp/${WD_CMD_COMPLETION_TOKEN} && /tmp/${WD_CMD_FILE} &"
  wait_cmd ${pod} $@
  oc exec $@ ${pod} -- bash -c "cat /tmp/${WD_CMD_LOG}; rm -rf /tmp/${WD_CMD_FILE} /tmp/${WD_CMD_LOG} /tmp/${WD_CMD_COMPLETION_TOKEN}" >> "${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log"
  files=$(fetch_cmd_result ${pod} "ls /tmp" $@)
  if echo "${files}" | grep "${WD_CMD_FAILED_TOKEN}" > /dev/null ; then
    oc exec $@ ${pod} -- bash -c "rm -f /tmp/${WD_CMD_FAILED_TOKEN}"
    brlog "ERROR" "Something error happened while running command in ${pod}. See ${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log for details."
    exit 1
  fi
}

run_script_in_pod(){
  local pod="$1"
  shift
  local script="$1"
  shift
  local options=( "$1" )
  shift
  local filename="$(basename "${script}")"
  _oc_cp "${script}" "${pod}:/tmp/${filename}" $@
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
  local wd_version=${WD_VERSION:-$(get_version)}
  if [ $(compare_version "${wd_version}" "2.2.1") -le 0 ] ; then
    echo $(oc ${OC_ARGS} get serviceaccount -l cpd_module=watson-discovery-adm-setup -o jsonpath="{.items[0].metadata.name}")
  else
    echo $(oc ${OC_ARGS} get serviceaccount -l app.kubernetes.io/component=admin,tenant=${TENANT_NAME} -o jsonpath="{.items[0].metadata.name}")
  fi
}

get_pg_configmap(){
  local wd_version=${WD_VERSION:-$(get_version)}
  if [ $(compare_version "${wd_version}" "2.2.1") -le 0 ] ; then
    echo $(oc get ${OC_ARGS} configmap -l tenant=${TENANT_NAME},app.kubernetes.io/component=postgres-cxn -o jsonpath="{.items[0].metadata.name}")
  else
    echo $(oc get ${OC_ARGS} configmap -l tenant=${TENANT_NAME},app=cn-postgres -o jsonpath="{.items[0].metadata.name}")
  fi
}

get_pg_secret(){
  local wd_version=${WD_VERSION:-$(get_version)}
  if [ $(compare_version "${wd_version}" "2.2.1") -le 0 ] ; then
    echo $(oc ${OC_ARGS} get secret -l tenant=${TENANT_NAME},cr=${TENANT_NAME}-discovery-postgres -o jsonpath="{.items[*].metadata.name}")
  else
    echo $(oc ${OC_ARGS} get secret -l tenant=${TENANT_NAME},run=cn-postgres -o jsonpath="{.items[*].metadata.name}" | tr '[[:space:]]' '\n' | grep "cn-postgres-wd")
  fi
}

run_pg_job(){
  local wd_version=${WD_VERSION:-$(get_version)}
  PG_BACKUP_RESTORE_SCRIPTS="postgresql-backup-restore-in-pod.sh"
  JOB_CPU_LIMITS="${MC_CPU_LIMITS:-800m}" # backward compatibility
  JOB_CPU_LIMITS="${JOB_CPU_LIMITS:-800m}"
  JOB_MEMORY_LIMITS="${MC_MEMORY_LIMITS:-2Gi}" # backward compatibility
  JOB_MEMORY_LIMITS="${JOB_MEMORY_LIMITS:-2Gi}"
  NAMESPACE=${NAMESPACE:-$(oc config view --minify --output 'jsonpath={..namespace}')}
  PG_IMAGE="$(get_migrator_image)"
  if [ $(compare_version "${wd_version}" "2.2.0") -eq 0 ] ; then
    PG_IMAGE="$(oc get ${OC_ARGS} pod -l tenant=${TENANT_NAME} -o jsonpath='{..image}' | tr -s '[[:space:]]' '\n' | sort | uniq | grep "edb-postgresql-12:ubi8-amd64" | tail -n1)"
  fi
  PG_CONFIGMAP=$(get_pg_configmap)
  PG_SECRET=$(get_pg_secret)
  PG_PASSWORD_KEY="pg_su_password"
  REQUIRE_TENANT_BACKUP="false"
  if [ "${COMMAND}" = "restore" ] && require_tenant_backup ; then
    REQUIRE_TENANT_BACKUP="true"
  fi
  if [ $(compare_version "${wd_version}" "4.0.0") -lt 0 ] ; then
    PG_PASSWORD_KEY="STKEEPER_PG_SU_PASSWORD"
  fi
  DISCO_SVC_ACCOUNT=$(get_service_account)
  NAMESPACE=${NAMESPACE:-$(oc config view --minify --output 'jsonpath={..namespace}')}
  CURRENT_TZ=$(date "+%z" | tr -d '0')
  if echo "${CURRENT_TZ}" | grep "+" > /dev/null; then
    TZ_OFFSET="UTC-$(echo ${CURRENT_TZ} | tr -d '+')"
  else
    TZ_OFFSET="UTC+$(echo ${CURRENT_TZ} | tr -d '-')"
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
  add_volume_to_job_yaml "backup-restore-workspace" "${TMP_PVC_NAME:-emptyDir}" "${PG_JOB_FILE}"

  oc ${OC_ARGS} delete -f "${PG_JOB_FILE}" &> /dev/null || true
  wait_job_pod_deleted "app.kubernetes.io/component=${PG_BACKUP_RESTORE_JOB},tenant=${TENANT_NAME}" "${PG_BACKUP_RESTORE_JOB}"
  oc ${OC_ARGS} apply -f "${PG_JOB_FILE}"
  get_job_pod "app.kubernetes.io/component=${PG_BACKUP_RESTORE_JOB},tenant=${TENANT_NAME}"
  wait_job_running ${POD}
}

add_volume_to_job_yaml(){
  local volume_name=$1
  shift
  local pvc_name=$1
  shift
  local yaml_file=$1
  shift
  local yaml=""
  if [ "${pvc_name}" = "emptyDir" ] ; then
    yaml=$(
      cat <<EOF
      volumes:
        - name: ${volume_name}
          emptyDir: {}
EOF
    )
  else
    yaml=$(
      cat <<EOF
      volumes:
        - name: ${volume_name}
          persistentVolumeClaim:
            claimName: ${pvc_name}
EOF
    )
  fi
  local oneline_yaml="$(convert_yaml_to_oneliner "${yaml}")"
  sed -i -e "s|      volumes:|${oneline_yaml}|" "${yaml_file}"
}

add_secret_volume_to_job_yaml(){
  local volume_name=$1
  shift
  local secret_name=$1
  shift
  local yaml_file=$1
  local yaml=$(
    cat <<EOF
      volumes:
        - name: ${volume_name}
          secret:
            defaultMode: 420
            secretName: ${secret_name}
EOF
  )
  local oneline_yaml="$(convert_yaml_to_oneliner "${yaml}")"
  sed -i -e "s|      volumes:|${oneline_yaml}|" "${yaml_file}"
}

add_volume_mount_to_job_yaml(){
  local volume_name=$1
  shift
  local mount_path=$1
  shift
  local yaml_file=$1
  local yaml=$(
    cat <<EOF
          volumeMounts:
            - mountPath: ${mount_path}
              name: ${volume_name}
EOF
  )
  local oneline_yaml="$(convert_yaml_to_oneliner "${yaml}")"
  sed -i -e "s|          volumeMounts:|${oneline_yaml}|" "${yaml_file}"
}

convert_yaml_to_oneliner(){
  echo "${1//$'\n'/'\n'}"
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
  if [ -n "${TENANT_NAME+UNDEF}" ] && [ -z "$(oc get ${OC_ARGS} wd ${TENANT_NAME})" ] ; then
    brlog "ERROR" "Tenant (release) not found: ${TENANT_NAME}"
    exit 1
  fi
  if [ -n "${TMP_PVC_NAME+UNDEF}" ] && [ -z "$(oc get ${OC_ARGS} pvc ${TMP_PVC_NAME})" ] ; then
    brlog "ERROR" "PVC not found: ${TMP_PVC_NAME}"
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
  if [ $(compare_version "${wd_version}" "4.0.0") -ge 0 ] ; then
    echo "$(oc get pod ${OC_ARGS} -l "postgresql=${TENANT_NAME}-discovery-cn-postgres,role=primary" -o jsonpath='{.items[0].metadata.name}')"
  else
    for POD in $(oc get pods ${OC_ARGS} -o jsonpath='{.items[*].metadata.name}' -l tenant=${TENANT_NAME},component=stolon-keeper) ; do
      if oc logs ${OC_ARGS} --since=30s ${POD} | grep 'our db requested role is master' > /dev/null ; then
        echo "${POD}"
        break
      fi
    done
  fi
}

launch_s3_pod(){
  local wd_version="${WD_VERSION:-$(get_version)}"
  S3_BACKUP_RESTORE_SCRIPTS="run.sh"
  S3_BACKUP_RESTORE_JOB="wd-discovery-s3-backup-restore"
  S3_JOB_TEMPLATE="${SCRIPT_DIR}/src/backup-restore-job-template.yml"
  S3_CONFIG_DIR="/tmp/backup-restore-workspace/.aws"
  S3_CERT_MOUNT_PATH="/opt/tls"
  JOB_CPU_LIMITS="${MC_CPU_LIMITS:-800m}" # backward compatibility
  JOB_CPU_LIMITS="${JOB_CPU_LIMITS:-800m}"
  JOB_MEMORY_LIMITS="${MC_MEMORY_LIMITS:-2Gi}" # backward compatibility
  JOB_MEMORY_LIMITS="${JOB_MEMORY_LIMITS:-2Gi}"
  NAMESPACE=${NAMESPACE:-$(oc config view --minify --output 'jsonpath={..namespace}')}
  WD_MIGRATOR_IMAGE="$(get_migrator_image)"
  setup_s3_env
  DISCO_SVC_ACCOUNT=$(get_service_account)
  NAMESPACE=${NAMESPACE:-$(oc config view --minify --output 'jsonpath={..namespace}')}
  CURRENT_TZ=$(date "+%z" | tr -d '0')
  if echo "${CURRENT_TZ}" | grep "+" > /dev/null; then
    TZ_OFFSET="UTC-$(echo ${CURRENT_TZ} | tr -d '+')"
  else
    TZ_OFFSET="UTC+$(echo ${CURRENT_TZ} | tr -d '-')"
  fi

  sed -e "s/#namespace#/${NAMESPACE}/g" \
    -e "s/#svc-account#/${DISCO_SVC_ACCOUNT}/g" \
    -e "s|#image#|${WD_MIGRATOR_IMAGE}|g" \
    -e "s/#cpu-limit#/${JOB_CPU_LIMITS}/g" \
    -e "s/#memory-limit#/${JOB_MEMORY_LIMITS}/g" \
    -e "s|#command#|./${S3_BACKUP_RESTORE_SCRIPTS} ${COMMAND}|g" \
    -e "s/#job-name#/${S3_BACKUP_RESTORE_JOB}/g" \
    -e "s/#tenant#/${TENANT_NAME}/g" \
    "${S3_JOB_TEMPLATE}" > "${S3_JOB_FILE}"
  add_config_env_to_job_yaml "S3_ENDPOINT_URL" "${S3_CONFIGMAP}" "endpoint" "${S3_JOB_FILE}"
  add_config_env_to_job_yaml "S3_HOST" "${S3_CONFIGMAP}" "host" "${S3_JOB_FILE}"
  add_config_env_to_job_yaml "S3_PORT" "${S3_CONFIGMAP}" "port" "${S3_JOB_FILE}"
  add_config_env_to_job_yaml "S3_ELASTIC_BACKUP_BUCKET" "${S3_CONFIGMAP}" "bucketElasticBackup" "${S3_JOB_FILE}"
  add_config_env_to_job_yaml "S3_COMMON_BUCKET" "${S3_CONFIGMAP}" "bucketCommon" "${S3_JOB_FILE}"
  add_secret_env_to_job_yaml "S3_ACCESS_KEY" "${S3_SECRET}" "accesskey" "${S3_JOB_FILE}"
  add_secret_env_to_job_yaml "S3_SECRET_KEY" "${S3_SECRET}" "secretkey" "${S3_JOB_FILE}"
  if [ -n "${MINIO_ARCHIVE_OPTION:+UNDEF}" ] ; then add_env_to_job_yaml "MINIO_ARCHIVE_OPTION" "${MINIO_ARCHIVE_OPTION}" "${S3_JOB_FILE}"; fi
  if [ -n "${DISABLE_MC_MULTIPART:+UNDEF}" ] ; then add_env_to_job_yaml "DISABLE_MC_MULTIPART" "${DISABLE_MC_MULTIPART}" "${S3_JOB_FILE}"; fi
  add_env_to_job_yaml "TZ" "${TZ_OFFSET}" "${S3_JOB_FILE}"
  add_env_to_job_yaml "WD_VERSION" "${wd_version}" "${S3_JOB_FILE}"
  add_volume_to_job_yaml "backup-restore-workspace" "${TMP_PVC_NAME:-emptyDir}" "${S3_JOB_FILE}"
  if [ $(compare_version ${wd_version} "4.7.0") -ge 0 ] ; then
    BUCKET_SUFFIX="$(get_bucket_suffix)"
    S3_CERT_SECRET=$(oc get secret -l "icpdsupport/addOnId=discovery,icpdsupport/app=s3-cert-secret,tenant=${TENANT_NAME}" -o jsonpath="{.items[0].metadata.name}")
    add_secret_volume_to_job_yaml "tls-secret" "${S3_CERT_SECRET}" "${S3_JOB_FILE}"
    add_volume_mount_to_job_yaml "tls-secret" "${S3_CERT_MOUNT_PATH}" "${S3_JOB_FILE}"
    add_env_to_job_yaml "S3_CERT_PATH" "${S3_CERT_MOUNT_PATH}/tls.crt" "${S3_JOB_FILE}"
    add_env_to_job_yaml "S3_CONFIG_DIR" "${S3_CONFIG_DIR}" "${S3_JOB_FILE}"
    add_env_to_job_yaml "BUCKET_SUFFIX" "${BUCKET_SUFFIX}" "${S3_JOB_FILE}"
  fi

  oc ${OC_ARGS} delete -f "${S3_JOB_FILE}" &> /dev/null || true
  wait_job_pod_deleted "app.kubernetes.io/component=${S3_BACKUP_RESTORE_JOB},tenant=${TENANT_NAME}" "${S3_BACKUP_RESTORE_JOB}"
  oc ${OC_ARGS} apply -f "${S3_JOB_FILE}"
  get_job_pod "app.kubernetes.io/component=${S3_BACKUP_RESTORE_JOB},tenant=${TENANT_NAME}"
  wait_job_running ${POD}
}

setup_s3_env(){
  local wd_version="${WD_VERSION:-$(get_version)}"
  if [ $(compare_version "${wd_version}" "4.7.0") -lt 0 ] ; then
    S3_CONFIGMAP=${S3_CONFIGMAP:-$(oc get ${OC_ARGS} cm -l "app.kubernetes.io/component=minio,tenant=${TENANT_NAME}" -o jsonpath="{.items[*].metadata.name}")}
    S3_SECRET=${S3_SECRET:-$(oc ${OC_ARGS} get secret -l "tenant=${TENANT_NAME},run=minio-auth" -o jsonpath="{.items[*].metadata.name}" | tr -s '[[:space:]]' '\n' | grep minio)}
  else
    S3_CONFIGMAP=${S3_CONFIGMAP:-$(oc get ${OC_ARGS} cm -l "app.kubernetes.io/component=s3,tenant=${TENANT_NAME}" -o jsonpath="{.items[*].metadata.name}")}
    S3_SECRET=${S3_SECRET:-$(oc ${OC_ARGS} get secret -l "tenant=${TENANT_NAME},run=s3-auth" -o jsonpath="{.items[*].metadata.name}" | tr -s '[[:space:]]' '\n' | grep s3)}
  fi
  S3_SVC=${S3_SVC:-$(oc extract ${OC_ARGS} configmap/${S3_CONFIGMAP} --keys=host --to=- 2> /dev/null)}
  if [[ "${S3_SVC}" == *"."* ]] ; then
    array=(${S3_SVC//./ })
    S3_PORT_FORWARD_SVC="${array[0]}"
    S3_NAMESPACE="${array[1]}"
  else
    S3_PORT_FORWARD_SVC=${S3_SVC}
  fi
  S3_PORT=${S3_PORT:-$(oc extract ${OC_ARGS} configmap/${S3_CONFIGMAP} --keys=port --to=- 2> /dev/null)}
  S3_ACCESS_KEY=${S3_ACCESS_KEY:-$(oc get ${OC_ARGS} secret ${S3_SECRET} --template '{{.data.accesskey}}' | base64 --decode)}
  S3_SECRET_KEY=${S3_SECRET_KEY:-$(oc get ${OC_ARGS} secret ${S3_SECRET} --template '{{.data.secretkey}}' | base64 --decode)}
  S3_FORWARD_PORT=${S3_FORWARD_PORT:-39001}
  S3_ENDPOINT_URL=${S3_ENDPOINT_URL:-https://localhost:$S3_FORWARD_PORT}
  S3_JOB_FILE="${SCRIPT_DIR}/src/s3-backup-restore-job.yml"
}

check_datastore_available(){
  brlog "INFO" "Checking status of data store"
  check_etcd_available || { brlog "ERROR" "Etcd is unavailable"; return 1; }
  check_postgres_available || { brlog "ERROR" "Postgresql is unavailable"; return 1; }
  check_elastic_available || { brlog "ERROR" "ElasticSearch is unavailable"; return 1; }
  check_s3_available || { brlog "ERROR" "S3 is unavailable"; return 1; }
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
  ETCD_SERVICE="localhost"
  ETCD_ENDPOINT="https://${ETCD_SERVICE}:2379"
  ETCD_SECRET=$(oc get secret ${OC_ARGS} -o jsonpath="{.items[0].metadata.name}" -l "tenant=${TENANT_NAME},app in (etcd,etcd-root)")
  ETCD_USER=$(oc get secret ${OC_ARGS} ${ETCD_SECRET} --template '{{.data.username}}' | base64 --decode)
  ETCD_PASSWORD=$(oc get secret ${OC_ARGS} ${ETCD_SECRET} --template '{{.data.password}}' | base64 --decode)
  ETCD_POD=$(oc get pods ${OC_ARGS} -o jsonpath="{.items[0].metadata.name}" -l etcd_cluster=${TENANT_NAME}-discovery-etcd)
}

setup_pg_env(){
  local wd_version=${WD_VERSION:-$(get_version)}
  if [ $(compare_version "${wd_version}" "4.0.0") -ge 0 ] ; then
    PGUSER="postgres"
    PG_SECRET="$(get_pg_secret)"
    PGPASSWORD="$(oc get secret ${PG_SECRET} --template '{{.data.pg_su_password}}' | base64 --decode)"
  else
    PGUSER='${STKEEPER_PG_SU_USERNAME}'
    PGPASSWORD='${STKEEPER_PG_SU_PASSWORD}'
  fi
  PG_POD=$(get_primary_pg_pod)
}

check_postgres_available(){
  local wd_version=${WD_VERSION:-$(get_version)}
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

check_s3_available(){
  setup_s3_env
  local wd_version="${WD_VERSION:-$(get_version)}"
  if [ $(compare_version ${wd_version} "4.7.0") -lt 0 ] ; then
    ELASTIC_POD=$(oc get pods ${OC_ARGS} -o jsonpath="{.items[0].metadata.name}" -l tenant=${TENANT_NAME},app=elastic,ibm-es-data=True)
    oc exec ${OC_ARGS} "${ELASTIC_POD}" -c elasticsearch -- bash -c "curl -ks 'https://${S3_SVC}:${S3_PORT}/minio/health/ready' -w '%{http_code}' -o /dev/null | grep 200 > /dev/null" || return 1
    return 0
  else
    launch_s3_pod
    run_script_in_pod "${POD}" "${SCRIPT_DIR}/src/check_s3_status.sh"
    oc ${OC_ARGS} delete -f ${S3_JOB_FILE}
  fi
}

setup_zen_core_service_connection(){
  ZEN_CORE_SERVICE=${ZEN_CORE_SERVICE:-$(oc get ${OC_ARGS} svc -l component=zen-core-api -o jsonpath='{.items[0].metadata.name}')}
  ZEN_CORE_PORT=${ZEN_CORE_PORT:-$(oc get ${OC_ARGS} svc -l component=zen-core-api -o jsonpath='{.items[0].spec.ports[?(@.name=="zencoreapi-tls")].port}')}
  ZEN_CORE_API_ENDPOINT="https://${ZEN_CORE_SERVICE}:${ZEN_CORE_PORT}"
  ZEN_CORE_TOKEN="${ZEN_CORE_TOKEN:-"$(oc get ${OC_ARGS} secret zen-service-broker-secret --template '{{.data.token}}' | base64 --decode)"}"
  ZEN_INSTANCE_TYPE="discovery"
  ZEN_PROVISION_STATUS="PROVISIONED"
  WATSON_GATEWAY_SERVICE="${WATSON_GATEWAY_SERVICE:-"$(oc get ${OC_ARGS} svc -l release=${TENANT_NAME}-discovery-watson-gateway -o jsonpath='{.items[0].metadata.name}')"}"
  WATSON_GATEWAY_PORT="${WATSON_GATEWAY_PORT:-"$(oc get ${OC_ARGS} svc -l release=${TENANT_NAME}-discovery-watson-gateway -o jsonpath='{.items[0].spec.ports[?(@.name=="https")].port}')"}"
  WATSON_GATEWAY_ENDPOINT="https://${WATSON_GATEWAY_SERVICE}:${WATSON_GATEWAY_PORT}"
}

get_zen_access_pod() {
  echo "$(oc get pods ${OC_ARGS} -o jsonpath="{.items[0].metadata.name}" -l app.kubernetes.io/component=wd-backup-restore)"
}

create_backup_instance_mappings(){
  brlog "INFO" "Creating instance mapping file"
  launch_utils_job "wd-backup-restore-util-job"
  get_job_pod "app.kubernetes.io/component=wd-backup-restore"
  wait_job_running ${POD}
  local mapping_file="${MAPPING_FILE:-${BACKUP_DIR}/instance_mapping.json}"
  local wd_version="${WD_VERSION:-$(get_version)}"
  setup_zen_core_service_connection
  ZEN_ACCESS_POD=$(get_zen_access_pod)
  token=$(fetch_cmd_result ${ZEN_ACCESS_POD} "curl -ks '${ZEN_CORE_API_ENDPOINT}/internal/v1/service_token?expiration_time=1000' -H 'secret: ${ZEN_CORE_TOKEN}' -H 'cache-control: no-cache' | jq -r .token")
  if [ $(compare_version ${wd_version} "4.0.9") -le 0 ] ; then
    mappings=$(fetch_cmd_result ${ZEN_ACCESS_POD} "curl -ks '${ZEN_CORE_API_ENDPOINT}/v2/serviceInstance' -H 'Authorization: Bearer ${token}' | jq -r '.requestObj[] | select(.ServiceInstanceType == \"discovery\" and .ProvisionStatus == \"PROVISIONED\") | { \"display_name\": .ServiceInstanceDisplayName, \"source_instance_id\": .CreateArguments.metadata.instanceId, \"dest_instance_id\": \"<new_instance_id>\"}' | jq -s '{\"instance_mappings\": .}'")
  else
    mappings=$(fetch_cmd_result ${ZEN_ACCESS_POD} "curl -ks '${ZEN_CORE_API_ENDPOINT}/v3/service_instances?fetch_all_instances=true&addon_type=discovery' -H 'Authorization: Bearer ${token}' | jq -r '.service_instances | if (. | length != 0) and (map(.addon_type == \"discovery\" and .provision_status == \"PROVISIONED\") | any) then .[] | select(.addon_type == \"discovery\" and .provision_status == \"PROVISIONED\") | { \"display_name\": .display_name, \"source_instance_id\": .id, \"dest_instance_id\": \"<new_instance_id>\"} else \"null\" end' | jq -s '{\"instance_mappings\": .}'")
  fi
  if [ -z "${mappings}" ] || echo "${mappings}" | grep " null" > /dev/null || echo "${mappings}" | grep " \[\]" > /dev/null ; then
    brlog "ERROR" "Failed to get instances with CP4D API"
    exit 1
  fi
  echo "${mappings}" > ${mapping_file}
  oc ${OC_ARGS} delete job wd-backup-restore-util-job
  brlog "INFO" "Instance mapping file: ${mapping_file}"
}

service_instance_query='.service_instances | if (. | length != 0) and (map(.addon_type == "discovery" and .provision_status == "PROVISIONED") | any) then .[] | select(.addon_type == "discovery" and .provision_status == "PROVISIONED") | .id else "null" end'

create_restore_instance_mappings(){
  local rc=0
  local mapping='{ "instance_mappings" : []}'
  setup_zen_core_service_connection
  ZEN_ACCESS_POD=$(get_zen_access_pod)
  _oc_cp "${MAPPING_FILE}" "${ZEN_ACCESS_POD}:/tmp/mapping.json"
  local token=$(fetch_cmd_result ${ZEN_ACCESS_POD} "curl -ks '${ZEN_CORE_API_ENDPOINT}/internal/v1/service_token?expiration_time=1000' -H 'secret: ${ZEN_CORE_TOKEN}' -H 'cache-control: no-cache' | jq -r .token")
  local service_instances=$(fetch_cmd_result ${ZEN_ACCESS_POD} "curl -ks '${ZEN_CORE_API_ENDPOINT}/v3/service_instances?fetch_all_instances=true&addon_type=discovery' -H 'Authorization: Bearer ${token}' | jq -r '${service_instance_query}'")
  if [ -n "${service_instances}" ] && [ "${service_instances}" != "null" ] ; then
    brlog "INFO" "Discovery instances exist. Check if they are same instance."
    local src_instances=$(fetch_cmd_result ${ZEN_ACCESS_POD} "jq -r '.instance_mappings[].source_instance_id' /tmp/mapping.json")
    len1=( ${service_instances} )
    len2=( ${src_instances} )
    if [ ${#len1[@]} -ne ${#len2[@]} ] ; then
      brlog "ERROR" "Different number of instances. Please create instance mapping, and specify it '--mapping' option"
      return 1
    fi
    for instance in ${src_instances}
    do
      if echo "${service_instances}" | grep "${instance}" > /dev/null ; then
        mapping=$(fetch_cmd_result ${ZEN_ACCESS_POD} "echo '${mapping}' | jq -r '.instance_mappings |= . + [{\"source_instance_id\": \"${instance}\", \"dest_instance_id\": \"${instance}\"}]'")
      else
        brlog "ERROR" "Instance ${instance} does not exist. Please create instance mapping, and specify it with '--mapping' option."
        return 1
      fi
    done
  else
    brlog "INFO" "No Discovery instance exist. Create new one."
    local src_instances=( $(fetch_cmd_result ${ZEN_ACCESS_POD} "jq -r '.instance_mappings[].source_instance_id' /tmp/mapping.json") )
    local display_names=( $(fetch_cmd_result ${ZEN_ACCESS_POD} "jq -r '.instance_mappings[].display_name' /tmp/mapping.json") )
    for i in "${!src_instances[@]}"
    do
        instance_id=$(create_service_instance "${display_names[$i]}")
        if [ -z "${instance_id}" ] ; then
          brlog "ERROR" "Failed to create Discovery service instance for ${src_instances[$i]}"
          return 1
        else
          brlog "INFO" "Created Discovery service instance: ${instance_id}"
          mapping=$(fetch_cmd_result ${ZEN_ACCESS_POD} "echo '${mapping}' | jq -r '.instance_mappings |= . + [{\"source_instance_id\": \"${src_instances[$i]}\", \"dest_instance_id\": \"${instance_id}\"}]'")
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
  ZEN_ACCESS_POD=$(get_zen_access_pod)
  local file_name="$(basename "${MAPPING_FILE}")"
  _oc_cp "${MAPPING_FILE}" "${ZEN_ACCESS_POD}:/tmp/mapping.json"
  local token=$(fetch_cmd_result ${ZEN_ACCESS_POD} "curl -ks '${ZEN_CORE_API_ENDPOINT}/internal/v1/service_token?expiration_time=1000' -H 'secret: ${ZEN_CORE_TOKEN}' -H 'cache-control: no-cache' | jq -r .token")
  local service_instances=$(fetch_cmd_result ${ZEN_ACCESS_POD} "curl -ks '${ZEN_CORE_API_ENDPOINT}/v3/service_instances?fetch_all_instances=true&addon_type=discovery' -H 'Authorization: Bearer ${token}' | jq -r '${service_instance_query}'")
  local dest_instances=$(fetch_cmd_result ${ZEN_ACCESS_POD} "jq -r '.instance_mappings[].dest_instance_id' /tmp/mapping.json")
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
  local file_name="$(basename "${MAPPING_FILE}")"
  _oc_cp "${MAPPING_FILE}" "${ELASTIC_POD}:/tmp/mapping.json" -c elasticsearch
  local mappings=( $(fetch_cmd_result ${ELASTIC_POD} "jq -r '.instance_mappings[] | \"\(.source_instance_id),\(.dest_instance_id)\"' /tmp/mapping.json" -c elasticsearch) )
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
  local wd_version=${WD_VERSION:-$(get_version)}
  local backup_file_version=${BACKUP_FILE_VERSION:-$(get_backup_version)}
  if [ $(compare_version ${backup_file_version} "2.1.3") -le 0 ] && [ $(compare_version "${wd_version}" "4.0.5") -le 0 ] ; then
    return 0
  fi
  return 1
}

check_instance_exists(){
  setup_zen_core_service_connection
  ZEN_ACCESS_POD=$(get_zen_access_pod)
  local token="$(fetch_cmd_result ${ZEN_ACCESS_POD} "curl -ks '${ZEN_CORE_API_ENDPOINT}/internal/v1/service_token?expiration_time=1000' -H 'secret: ${ZEN_CORE_TOKEN}' -H 'cache-control: no-cache' | jq -r .token")"
  local service_instances=$(fetch_cmd_result ${ZEN_ACCESS_POD} "curl -ks '${ZEN_CORE_API_ENDPOINT}/v3/service_instances?fetch_all_instances=true&addon_type=discovery' -H 'Authorization: Bearer ${token}' | jq -r '${service_instance_query}'")
  if [ -n "${service_instances}" ] && [ "${service_instances}" != "null" ] ; then
    return 0
  else
    return 1
  fi
}

create_service_instance(){
  setup_zen_core_service_connection
  ZEN_ACCESS_POD=$(get_zen_access_pod)
  local display_name=$1
  local namespace=${NAMESPACE:-$(oc config view --minify --output 'jsonpath={..namespace}')}
  local request_file="${SCRIPT_DIR}/src/create_service_instance.json"
  local template="${SCRIPT_DIR}/src/create_service_instance_template.json"
  rm -f "${request_file}"
  sed -e "s/#namespace#/${namespace}/g" \
    -e "s/#version#/$(get_version)/g" \
    -e "s/#instance#/${TENANT_NAME}/g" \
    -e "s/#display_name#/${display_name}/g" \
    "${template}" > "${request_file}"
  _oc_cp "${request_file}" "${ZEN_ACCESS_POD}:/tmp/request.json"
  if [ -z "${ZEN_USER_NAME+UNDEF}" ] ; then
    brlog "WARN" "'--cp4d-user-name' option is not provided. Use default admin user to create Discovery instance" >&2
    iam_secret="$(oc get ${OC_ARGS} secret/ibm-iam-bindinfo-platform-auth-idp-credentials --ignore-not-found -o jsonpath='{.metadata.name}')"
    if [ -n "${iam_secret}" ] ; then
      ZEN_USER_NAME="$(oc extract secret/ibm-iam-bindinfo-platform-auth-idp-credentials --to=- --keys=admin_username 2> /dev/null)"
    else
      ZEN_USER_NAME="admin"
      ZEN_UID="1000330999"
    fi
  fi
  if [ -z "${ZEN_UID+UNDEF}" ] ; then
    brlog "INFO" "Get CP4D user ID for ${ZEN_USER_NAME}" >&2
    token="$(fetch_cmd_result ${ZEN_ACCESS_POD} "curl -ks '${ZEN_CORE_API_ENDPOINT}/internal/v1/service_token?expiration_time=1000' -H 'secret: ${ZEN_CORE_TOKEN}' -H 'cache-control: no-cache' | jq -r .token")"
    ZEN_UID="$(fetch_cmd_result ${ZEN_ACCESS_POD} "curl -ks '${ZEN_CORE_API_ENDPOINT}/openapi/v1/users/${ZEN_USER_NAME}' -H 'Authorization: Bearer ${token}' | jq -r '.UserInfo.uid'")"
  fi
  brlog "INFO" "Create Discovery instance as ${ZEN_USER_NAME}:${ZEN_UID}" >&2
  local token=$(fetch_cmd_result ${ZEN_ACCESS_POD} "curl -ks '${ZEN_CORE_API_ENDPOINT}/internal/v1/service_token?uid=${ZEN_UID}&username=${ZEN_USER_NAME}&display_name=${ZEN_USER_NAME}' -H 'secret: ${ZEN_CORE_TOKEN}' -H 'cache-control: no-cache' | jq -r .token")
  local instance_id=$(fetch_cmd_result ${ZEN_ACCESS_POD} "curl -ks -X POST '${WATSON_GATEWAY_ENDPOINT}/api/ibmcloud/resource-controller/resource_instances' -H 'Authorization: Bearer ${token}' -H 'Content-Type: application/json' -d@/tmp/request.json | jq -r 'if .zen_id == null or .zen_id == \"\" then \"null\" else .zen_id end'")
  if [ "${instance_id}" != "null" ] ; then
    echo "${instance_id}"
  fi
}

create_service_account(){
  local service_account="$1"
  if [ -n "$(oc get sa ${service_account})" ] ; then
    brlog "INFO" "Service Account ${service_account} already exists"
  else
    brlog "INFO" "Create Service Account for scripts: ${service_account}"
    local namespace="${NAMESPACE:-$(oc config view --minify --output 'jsonpath={..namespace}')}"
    oc ${OC_ARGS} create sa ${service_account}
    oc ${OC_ARGS} policy add-role-to-user admin system:serviceaccount:${namespace}:${service_account}
    oc delete clusterrolebinding "${service_account}-cluster-rb" --ignore-not-found
    oc ${OC_ARGS} create clusterrolebinding "${service_account}-cluster-rb" --clusterrole cluster-admin --serviceaccount ${namespace}:${service_account} 2>&1
    if [ -n "$(oc ${OC_ARGS} get role discovery-operator-role --ignore-not-found)" ] ; then
      # This is 2.2.1 install. Link operator role to this service account to get permission of discovery resources
      cat <<EOF | oc ${OC_ARGS} apply -f -
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${service_account}-rb
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: discovery-operator-role
subjects:
- namespace: ${namespace}
  kind: ServiceAccount
  name: ${service_account}
EOF
      trap_add "brlog 'INFO' 'Please delete rolebinding ${service_account}-rb when you delete ServiceAccount'"
    fi
  fi
}

get_oc_token(){
  local service_account="$1"
  if [ $(compare_version "$(get_version)" "4.8.0") -ge 0 ] ; then
    oc ${OC_ARGS} create token ${service_account} --duration "${SA_TOKEN_DURATION:-168h}"
  else
    # OCP 4.12 doesn't automatically link token to ServiceAccount so instead use secret annotations
    local token_secret=$(oc ${OC_ARGS} get secrets -o jsonpath='{range .items[?(@.metadata.annotations.kubernetes\.io\/service\-account\.name=="'"${service_account}"'")]}{.metadata.name}{"\n"}{end}' | grep -m1 'token')
    if [ -z "${token_secret}" ]; then
      brlog "ERROR" "Failed to find token in Service Account ${service_account}" >&2
      return 1
    fi
    oc ${OC_ARGS} extract secret/${token_secret} --keys=token --to=-
  fi
}

delete_service_account(){
  local service_account="$1"
  oc ${OC_ARGS} delete rolebinding ${service_account}-rb --ignore-not-found
  oc ${OC_ARGS} delete sa ${service_account} --ignore-not-found
  oc ${OC_ARGS} delete clusterrolebinding ${service_account}-cluster-rb --ignore-not-found
  trap_remove "brlog 'INFO' 'You currently oc login as a scripts ServiceAccount. You can rerun scripts with this. Please delete ServiceAccount ${service_account} and clusterrolebinding ${service_account}-cluster-rb when you complete backup or restore'"
  trap_remove "brlog 'INFO' 'brlog 'INFO' 'Please delete rolebinding ${service_account}-rb when you delete ServiceAccount'"
  brlog "INFO" "Deleted scripts service account: ${service_account}"
  brlog "INFO" "Please acknowledge that you have to oc login to the cluster to continue to work"
}

oc_login_as_scripts_user(){
  create_service_account "${BACKUP_RESTORE_SA}"
  local oc_token=$(get_oc_token "${BACKUP_RESTORE_SA}")
  local cluster=$(oc config view --minify -o jsonpath='{..server}')
  local namespace=$(oc config view --minify -o jsonpath='{..namespace}')
  export KUBECONFIG="${KUBECONFIG_FILE:-${PWD}/.kubeconfig}"
  oc login "${cluster}" --token="${oc_token}" -n "${namespace}" --insecure-skip-tls-verify
  trap_add "brlog 'INFO' 'You currently oc login as a scripts ServiceAccount. You can rerun scripts with this. Please delete ServiceAccount ${BACKUP_RESTORE_SA} and clusterrolebinding ${BACKUP_RESTORE_SA}-cluster-rb when you complete backup or restore'"

}

get_bucket_suffix(){
  common_bucket=$(oc extract ${OC_ARGS} configmap/${S3_CONFIGMAP} --to=- --keys=bucketCommon 2> /dev/null)
  local suffix=""
  if [ "${common_bucket}" != "common" ] ; then
    suffix="${common_bucket:6}"
  fi
  echo "${suffix}"
}

create_elastic_shared_pvc(){
  local wd_version=${WD_VERSION:-$(get_version)}
  if [ $(compare_version "${wd_version}" "4.7.0") -ge 0 ] ; then
    # shared volume should be RWX
    if [ -n "${TMP_PVC_NAME:+UNDEF}" ] ; then
      if oc ${OC_ARGS} get pvc "${TMP_PVC_NAME}" -o jsonpath='{.spec.}' | grep "ReadWriteMany" > /dev/null ; then
        ELASTIC_SHARED_PVC=${TMP_PVC_NAME}
      else
        brlog "INFO" "${TMP_PVC_NAME} is not RWX storage class. Don't use it for backup of ElasticSearch"
      fi
    fi
    if [ -n "${ELASTIC_SHARED_PVC:+UNDEF}" ] ; then
      if ! oc ${OC_ARGS} get pvc "${ELASTIC_SHARED_PVC}" -o jsonpath='{.spec.}' | grep "ReadWriteMany" > /dev/null ; then
        brlog "ERROR" "PVC for backup/restore for ElasticSearch should be RWX: ${ELASTIC_SHARED_PVC}"
        exit 1
      fi
    else
      if [ -z "${FILE_STORAGE_CLASS+UNDEF}" ] ; then
        FILE_STORAGE_CLASS="$(oc ${OC_ARGS} get wd ${TENANT_NAME} -o jsonpath='{.spec.fileStorageClass}')"
      fi
      brlog "INFO" "Create RWX PVC for backup and restore"
      if ! numfmt --help > /dev/null ; then
        brlog "ERROR" "numfmt command is not available. Please install numfmt."
        exit 1
      fi
      local snapshot_repo_size="$(oc ${OC_ARGS} get elasticsearchcluster ${TENANT_NAME} -o jsonpath='{.spec.snapshotRepo.size}')"
      local size_array=( $(echo "${snapshot_repo_size}" | awk 'match($0, /([[:digit:]]+)([[:alpha:]]+)/, array) {print array[1], array[2]}') )
      ELASTIC_SHARED_PVC_SIZE="$((size_array[0]*2))${size_array[1]}"
      ELASTIC_SHARED_PVC_DEFAULT_NAME="${TENANT_NAME}-discovery-backup-restore-pvc"
      cat <<EOF | oc ${OC_ARGS} apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${ELASTIC_SHARED_PVC_DEFAULT_NAME}
spec:
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: ${ELASTIC_SHARED_PVC_SIZE}
  storageClassName: ${FILE_STORAGE_CLASS}
EOF
      ELASTIC_SHARED_PVC="${ELASTIC_SHARED_PVC_DEFAULT_NAME}"
    fi
  fi
}

update_elastic_configmap(){
  rm -f "${TMP_WORK_DIR}/es_configmap.json" "${TMP_WORK_DIR}/es_updated.json"
  oc ${OC_ARGS} get cm $1 -o json > "${TMP_WORK_DIR}/es_configmap.json"
  if cat "${TMP_WORK_DIR}/es_configmap.json" | grep "/workdir/shared_storage" > /dev/null ; then
    return
  fi
  _oc_cp "${TMP_WORK_DIR}/es_configmap.json" "${ELASTIC_POD}:/tmp/es_configmap.json" ${OC_ARGS} -c elasticsearch
  fetch_cmd_result ${ELASTIC_POD} "jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.selfLink,.metadata.creationTimestamp,.metadata.annotations,.metadata.generation,.metadata.ownerReferences,.status)' /tmp/es_configmap.json > /tmp/es_updated.json &&\
  sed -i 's|      - /workdir/snapshot_storage\\\\n|      - /workdir/snapshot_storage\\\\n      - /workdir/shared_storage\\\\n|' /tmp/es_updated.json && echo ok" -c elasticsearch > /dev/null 
  _oc_cp "${ELASTIC_POD}:/tmp/es_updated.json" "${TMP_WORK_DIR}/es_updated.json" ${OC_ARGS} -c elasticsearch
  oc ${OC_ARGS} replace -f "${TMP_WORK_DIR}/es_updated.json"
  rm -f "${TMP_WORK_DIR}/es_configmap.json" "${TMP_WORK_DIR}/es_updated.json"
}

restart_job(){
  read -a comps <<< "$1"
  for comp in "${comps[@]}"
  do
    label="tenant=${TENANT_NAME},run=${comp}"
    oc delete ${OC_ARGS} pod -l "${label}" --ignore-not-found
    oc delete ${OC_ARGS} job -l "${label}" --ignore-not-found
  done
  for comp in "${comps[@]}"
  do
    label="tenant=${TENANT_NAME},run=${comp}"
    get_job_pod "${label}"
    wait_job_running ${POD}
    JOB_NAME="$(oc get ${OC_ARGS} job -o jsonpath="{.items[0].metadata.name}" -l "${label}")"
    brlog "INFO" "Waiting for ${comp} job to complete..."
    while :
    do
      if [ "$(oc ${OC_ARGS} get job -o jsonpath='{.status.succeeded}' ${JOB_NAME})" = "1" ] ; then
        brlog "INFO" "Completed ${comp} job"
        break;
      else
        sleep 5
      fi
    done
  done
}