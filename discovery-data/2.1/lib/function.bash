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

get_stat_command(){
  if [ "$(uname)" = "Darwin" ] ; then
    echo 'stat -f="%z"'
  elif [ "$(uname)" = "Linux" ] ; then
    echo 'stat --printf="%s"'
  else
    echo "Unexpected os type. Use: stat --printf='%s'" >&2
    echo 'stat --printf="%s"'
  fi
}

kube_cp_from_local(){
  POD=$1
  shift
  LOCAL_BACKUP=$1
  shift
  POD_BACKUP=$1
  shift
  SPLITE_DIR=./tmp_split_bakcup
  LOCAL_BASE_NAME=$(basename "${LOCAL_BACKUP}")
  POD_DIST_DIR=$(dirname "${POD_BACKUP}")
  STAT_CMD="`get_stat_command` ${LOCAL_BACKUP}"
  LOCAL_SIZE=`eval "${STAT_CMD}"`
  SPLIT_SIZE=${BACKUP_RESTORE_SPLIT_SIZE:-500000000}
  if [ ${SPLIT_SIZE} -ne 0 -a ${LOCAL_SIZE} -gt ${SPLIT_SIZE} ] ; then
    rm -rf ${SPLITE_DIR}
    mkdir -p ${SPLITE_DIR}
    split -d -a 5 -b ${SPLIT_SIZE} ${LOCAL_BACKUP} ${SPLITE_DIR}/${LOCAL_BASE_NAME}.split.
    for file in ${SPLITE_DIR}/*; do
      FILE_BASE_NAME=$(basename "${file}")
      kubectl cp $@ "${file}" "${POD}:${POD_DIST_DIR}/${FILE_BASE_NAME}"
    done
    rm -rf ${SPLITE_DIR}
    kubectl exec $@ ${POD} -- bash -c "cat ${POD_DIST_DIR}/${LOCAL_BASE_NAME}.split.* > ${POD_BACKUP} && rm -rf ${POD_DIST_DIR}/${LOCAL_BASE_NAME}.split.*"
  else
    kubectl cp $@ "${LOCAL_BACKUP}" "${POD}:${POD_BACKUP}"
  fi
}

kube_cp_to_local(){
  POD=$1
  shift
  LOCAL_BACKUP=$1
  shift
  POD_BACKUP=$1
  shift
  SPLITE_DIR=./tmp_split_bakcup
  SPLIT_SIZE=${BACKUP_RESTORE_SPLIT_SIZE:-500000000}
  POD_DIST_DIR=$(dirname "${POD_BACKUP}")
  POD_SIZE=`kubectl $@ exec ${POD} -- bash -c "stat --printf="%s" ${POD_BACKUP}"`
  if [ ${SPLIT_SIZE} -ne 0 -a ${POD_SIZE} -gt ${SPLIT_SIZE} ] ; then
    rm -rf ${SPLITE_DIR}
    mkdir -p ${SPLITE_DIR}
    kubectl exec $@ ${POD} -- bash -c "split -d -a 5 -b ${SPLIT_SIZE} ${POD_BACKUP} ${POD_BACKUP}.split."
    FILE_LIST=`kubectl exec $@ ${POD} -- bash -c "ls ${POD_BACKUP}.split.*"`
    for file in ${FILE_LIST} ; do
      FILE_BASE_NAME=$(basename "${file}")
      kubectl cp $@ "${POD}:${file}" "${SPLITE_DIR}/${FILE_BASE_NAME}"
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
  while true ;
  do
    TAR_STATUS=`kubectl exec $@ ${POD} --  bash -c 'ps auxww'`
    if echo "${TAR_STATUS}" | grep "${GREP_STRING}" > /dev/null ; then
      sleep 5
    else
      break
    fi
  done
}
