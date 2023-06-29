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

worrying() {
  echo "[WORRING] $1"
  exit 0
}

error() {
  echo "[FAIL] $1"
  exit 0
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
DBNAME=S3

echo "COMMAND:$COMMAND"
echo "RELEASE_NAME:$RELEASE_NAME"
echo "S3_BACKUP_DIR:$BACKUP_DIR"

S3_ALIAS=wks

MCG_ENDPOINT="$(oc --namespace openshift-storage get route s3 --namespace openshift-storage --output jsonpath='https://{.spec.host}')"
cmd_check
MCG_ACCESS_KEY="$(oc ${KUBECTL_ARGS} extract secret/noobaa-account-watson-ks --keys=AWS_ACCESS_KEY_ID --to=-)"
cmd_check
MCG_SECRET_KEY="$(oc ${KUBECTL_ARGS} extract secret/noobaa-account-watson-ks --keys=AWS_SECRET_ACCESS_KEY --to=-)"
cmd_check



SCRIPT_DIR=$(dirname $0)
LIB_DIR=${SCRIPT_DIR}/lib
. ${LIB_DIR}/utils.sh

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

$MC alias set ${S3_ALIAS} "${MCG_ENDPOINT}" "${MCG_ACCESS_KEY}" "${MCG_SECRET_KEY}" --insecure
cmd_check

if [ ${COMMAND} = 'backup' ] ; then
  echo "backup start"
  mkdir -p ${BACKUP_DIR}
  
  $MC --insecure cp -r ${S3_ALIAS}/wks-icp ${BACKUP_DIR}
  cmd_check
  
  echo "[SUCCESS] $DBNAME $COMMAND"
elif [ ${COMMAND} = 'restore' ] ; then

  echo "restore start"

  if [ ! -d "${BACKUP_DIR}" ] ; then
    echo "no backup directory: ${BACKUP_DIR}" >&2
    echo "failed to restore" >&2
    exit 1
  fi

  if [[ ! -d ${BACKUP_DIR}/wks-icp ]]; then
    worrying "no data to restore"
  fi

  $MC --insecure cp -r ${BACKUP_DIR}/wks-icp ${S3_ALIAS}/
  cmd_check
  
  echo "[SUCCESS] $DBNAME $COMMAND"
else
  printUsage
fi
