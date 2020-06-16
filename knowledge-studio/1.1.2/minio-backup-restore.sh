#!/bin/bash

printUsage() {
  echo "Usage: $(basename ${0}) [command] [releaseName] [backupDir] [-n namespace]"
  exit 1
}

cmd_check(){
  if [ $? -ne 0 ] ; then
    echo "[FAIL] $DBNAME $COMMAND"
    exit 1
  fi
}

# command line arguments
if [ $# -lt 3 ] ; then
  printUsage
fi

COMMAND=$1
shift
RELEASE_NAME=$1
shift
BACKUP_DIR=$1
shift
while getopts f:n: OPT
do
  case $OPT in
    "n" ) KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$OPTARG" ;;
  esac
done

# parameters
DBNAME=minio
echo "COMMAND:$COMMAND"
echo "RELEASE_NAME:$RELEASE_NAME"
echo "BACKUP_DIR:$BACKUP_DIR"

# get one health pod with STATUS "Running" (not "Terminating", e.g.)
#MINIO_POD=${RELEASE_NAME}-ibm-minio-1
MINIO_POD=`kubectl ${KUBECTL_ARGS} get pods -o=go-template --template='{{range $pod := .items}}{{range .status.containerStatuses}}{{if .ready}}{{$pod.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}' | grep ${RELEASE_NAME}-ibm-minio | head -n 1`
echo "MINIO_POD:$MINIO_POD"

MINIO_LPORT=9001
MINIO_PORT=9000
MC_ALIAS=wks-minio

SCRIPT_DIR=$(dirname $0)
LIB_DIR=${SCRIPT_DIR}/lib
. ${LIB_DIR}/utils.sh

# keys
MINIO_ACCESS_KEY=`kubectl ${KUBECTL_ARGS} get secret minio-access-secret-$RELEASE_NAME --template '{{.data.accesskey}}' | base64 --decode`
MINIO_SECRET_KEY=`kubectl ${KUBECTL_ARGS} get secret minio-access-secret-$RELEASE_NAME --template '{{.data.secretkey}}' | base64 --decode`
#echo "MINIO_ACCESS_KEY:$MINIO_ACCESS_KEY"
#echo "MINIO_SECRET_KEY:$MINIO_SECRET_KEY"

mkdir -p ${BACKUP_DIR}

# check mc
if type "mc" > /dev/null 2>&1; then
  MC=mc
elif type "${LIB_DIR}/mc" > /dev/null 2>&1; then
  MC=${LIB_DIR}/mc
else
  echo "downloading mc..."
  get_mc ${LIB_DIR}
  MC=${LIB_DIR}/mc
fi

if [ ${COMMAND} = 'backup' ] ; then
  echo "backup start"
  start_minio_port_forward $MINIO_POD $MINIO_LPORT $MINIO_PORT
  
  $MC --insecure config host add ${MC_ALIAS} https://localhost:$MINIO_LPORT ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY}
  cmd_check
  
  $MC --insecure cp -r ${MC_ALIAS}/wks-icp ${BACKUP_DIR}
  cmd_check
  
  stop_minio_port_forward
  echo "[SUCCESS] $DBNAME $COMMAND"
elif [ ${COMMAND} = 'restore' ] ; then
  echo "restore start"
  if [ ! -d "${BACKUP_DIR}" ] ; then
    echo "no backup directory: ${BACKUP_DIR}" >&2
    echo "failed to restore" >&2
    exit 1
  fi
  
  start_minio_port_forward $MINIO_POD $MINIO_LPORT $MINIO_PORT
  
  $MC --insecure config host add ${MC_ALIAS} https://localhost:$MINIO_LPORT ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY}
  cmd_check
  
  $MC --insecure cp -r ${BACKUP_DIR}/wks-icp ${MC_ALIAS}/wks-icp
  cmd_check
  
  stop_minio_port_forward
  echo "[SUCCESS] $DBNAME $COMMAND"
else
  printUsage
fi