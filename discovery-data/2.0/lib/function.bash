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
  LOCAL_SIZE=`stat --printf="%s" ${LOCAL_BACKUP}`
  if [ ${LOCAL_SIZE} -gt 500000000 ] ; then
    rm -rf ${SPLITE_DIR}
    mkdir -p ${SPLITE_DIR}
    split -d -a 5 -b 500000000 ${LOCAL_BACKUP} ${SPLITE_DIR}/${LOCAL_BASE_NAME}.split.
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
  POD_DIST_DIR=$(dirname "${POD_BACKUP}")
  POD_SIZE=`kubectl $@ exec ${POD} -- bash -c "stat --printf="%s" ${POD_BACKUP}"`
  if [ ${POD_SIZE} -gt 500000000 ] ; then
    rm -rf ${SPLITE_DIR}
    mkdir -p ${SPLITE_DIR}
    kubectl exec $@ ${POD} -- bash -c "split -d -a 5 -b 500000000 ${POD_BACKUP} ${POD_BACKUP}.split."
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
