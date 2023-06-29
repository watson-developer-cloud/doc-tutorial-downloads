# minio

get_mc(){
  DIST_DIR=$1
  if [ ! -d "${DIST_DIR}" ] ; then
    echo "no such directory: ${DIST_DIR}" >&2
    echo "failed to download mc" >&2
    exit 1
  fi
  
  MC_URL=""
  ARC="amd64"
  if [ "$(uname)" = "Darwin" ] ; then
    MC_URL="https://dl.min.io/client/mc/release/darwin-${ARC}/archive/mc.RELEASE.2022-07-15T09-20-55Z"
  elif [ "$(uname)" = "Linux" ] ; then
    MC_URL="https://dl.min.io/client/mc/release/linux-${ARC}/archive/mc.RELEASE.2022-07-15T09-20-55Z"
  else
    echo "Unexpected os type. Can not get mc." >&2
    exit 1
  fi
  echo "Getting minio client: ${MC_URL}" 
  curl -skL "${MC_URL}" -o ${DIST_DIR}/mc
  chmod +x ${DIST_DIR}/mc
}
