# minio
start_minio_port_forward(){
  MINIO_POD=$1
  MINIO_LPORT=$2
  MINIO_PORT=$3
  kubectl ${KUBECTL_ARGS} port-forward ${MINIO_POD} ${MINIO_LPORT}:${MINIO_PORT} > /dev/null &
  PORT_FORWARD_PID=$!
  trap "kill ${PORT_FORWARD_PID}" 0 1 2 3 15
  sleep 5
}

stop_minio_port_forward(){
  kill ${PORT_FORWARD_PID}
  trap 0 1 2 3 15
}

get_mc(){
  DIST_DIR=$1
  if [ ! -d "${DIST_DIR}" ] ; then
    echo "no such directory: ${DIST_DIR}" >&2
    echo "failed to download mc" >&2
    exit 1
  fi
  
  MC_URL=""
  if [ "$(uname)" = "Darwin" ] ; then
    MC_URL="https://dl.min.io/client/mc/release/darwin-amd64/archive/mc.RELEASE.2020-05-06T18-00-07Z"
  elif [ "$(uname)" = "Linux" ] ; then
    ARC="amd64"
    MC_URL="https://dl.min.io/client/mc/release/linux-${ARC}/archive/mc.RELEASE.2020-05-06T18-00-07Z"
  else
    echo "Unexpected os type. Can not get mc." >&2
    exit 1
  fi
  echo "Getting minio client: ${MC_URL}" 
  curl -skL "${MC_URL}" -o ${DIST_DIR}/mc
  chmod +x ${DIST_DIR}/mc
}