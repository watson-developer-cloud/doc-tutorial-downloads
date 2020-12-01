#!/bin/bash

declare -r CUREBT_TIME=`date +%s`
declare -r TIME_OUT=600

print_help() {
  echo "This script is in order to backup/restore all MongoDB/PostgreSQL/Minio data"
  echo "USAGE: $0 [command] [releaseName] [backupDir] [-n namespace]"
  exit 1
}

cmd_check(){
  if [ $? -ne 0 ] ; then
    reactivate
    echo "[FAIL] MongoDB,PostgreSQL,Minio,PVC $COMMAND"
    exit 1
  fi
}

# command line arguments
if [ $# -lt 3 ] ; then
  print_help
fi

COMMAND=$1
shift
RELEASE_NAME=$1
shift
DATA_DIR=$1
shift
while getopts "n:" opt; do
  case $opt in
    "n" ) NAMESPACE=$OPTARG ;;
  esac
done

echo "release name:'$RELEASE_NAME'"

echo "checking command..."
if [[ ! $COMMAND = "backup" && ! $COMMAND = "restore" ]]; then
  echo "command: '$COMMAND' not supported. backup and restore are supported."
  print_help
else
  echo "command: '$COMMAND'"
fi

echo "checking $COMMAND directory..."
if [[ $COMMAND = "backup" ]]; then
  DATA_DIR=${DATA_DIR%*/}"/wks-${COMMAND}-`date '+%Y%m%d_%H%M%S'`"
fi
DATA_DIR_MONGODB="${DATA_DIR%*/}/mongodb"
DATA_DIR_POSTRGESQL="${DATA_DIR%*/}/postgresql"
DATA_DIR_MINIO="${DATA_DIR%*/}/minio"
DATA_DIR_PVC="${DATA_DIR%*/}/pvc/sandbox"
if [[ $COMMAND = "restore" ]]; then
  if [[ ! -d ${DATA_DIR_MONGODB} || ! -d ${DATA_DIR_POSTRGESQL} || ! -d ${DATA_DIR_MINIO} || ! -d ${DATA_DIR_PVC} ]]; then
    echo "no backup directory: $DATA_DIR"
    echo "[FAIL] MongoDB,PostgreSQL,Minio,PVC $COMMAND"
    exit 1
  fi 
fi
echo "$COMMAND directory:"
echo "  mongodb:'$DATA_DIR_MONGODB'"
echo "  postrgesql:'$DATA_DIR_POSTRGESQL'"
echo "  minio:'$DATA_DIR_MINIO'"
echo "  pvc:'$DATA_DIR_MINIO'"

if [ -v NAMESPACE ]; then
  echo "checking namespace..."
  kubectl get namespace $NAMESPACE
  if [[ ! $? -eq 0 ]]; then
    echo "namespace:'$NAMESPACE' not exist"  
    echo "[FAIL] MongoDB,PostgreSQL,Minio,PVC $COMMAND"
    exit 1
  else 
    echo "namespace:'$NAMESPACE'"
  fi

  KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$NAMESPACE"
  NAMESPACE_OPT="-n $NAMESPACE"
else
  echo "default namespace is used for kubectl"
fi

reactivate() {
  echo "Reactivate knowledge studio:"
  kubectl $KUBECTL_ARGS patch --type=merge wks wks -p '{"spec":{"global":{"quiesceMode":false}}}'
  cmd_check
  kubectl $KUBECTL_ARGS patch --type=merge wks wks -p '{"spec":{"mma":{"replicas":2}}}'
  cmd_check

  END_TIME=`date +%s`
  printf "%s %d\n" "Elapsed time: " `expr $END_TIME - $CUREBT_TIME`
}

if [[ ! $COMMAND ]]; then
  print_help
fi

################################################################
#Decativate wks deployment
#Make sure no running job
################################################################
jobs=`kubectl $KUBECTL_ARGS get job --no-headers | grep -e wks-train -e wks-batch-apply | awk '{print $2}'`
for job in ${jobs}; do
  if [[ $job == "0/1" ]]; then
    echo "$COMMAND failed because training/evaluation job is running. Please wait for while until the job will complete."
    echo "[FAIL] MongoDB,PostgreSQL,Minio,PVC $COMMAND"
    exit 1
  fi
done

echo "get 'Docker Registry' and 'User ID' for $COMMAND PVC"
PVC_POD_NAME=`kubectl $KUBECTL_ARGS get pods -o=go-template --template='{{range $pod := .items}}{{range .status.containerStatuses}}{{if .ready}}{{$pod.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}' | grep ${RELEASE_NAME}-ibm-watson-ks-aql-web-tooling | head -n 1`
if [[ ! $PVC_POD_NAME ]]; then
  echo "get PVE pod failed"
  echo "[FAIL] MongoDB,PostgreSQL,Minio,PVC $COMMAND"
  exit 1
fi
echo "PVC pod name: '$PVC_POD_NAME'"
PVC_USER_ID=`kubectl $KUBECTL_ARGS get pod $PVC_POD_NAME -o yaml | grep "runAsUser" | head -n 1`
declare -r PVC_USER_ID=${PVC_USER_ID##*runAsUser:}
echo "PVC User ID: '$PVC_USER_ID'"

DOCKER_REGISTRY=`kubectl $KUBECTL_ARGS get pod $PVC_POD_NAME -o yaml | grep " image" | head -n 1`
DOCKER_REGISTRY=${DOCKER_REGISTRY#*image:}
declare -r DOCKER_REGISTRY=${DOCKER_REGISTRY%/*}
echo "PVC Docker Registry: '$DOCKER_REGISTRY'"

echo "deactivating knowledge studio:"
kubectl $KUBECTL_ARGS patch --type=merge wks wks -p '{"spec":{"global":{"quiesceMode":true}}}'
cmd_check
kubectl $KUBECTL_ARGS patch --type=merge wks wks -p '{"spec":{"mma":{"replicas":0}}}'
cmd_check

echo "wait until all pods stop except datastore pods, this may take a few minutes..."
sleepTime=0
while :
do
  GET_POD_NUMBER=`kubectl $KUBECTL_ARGS get pod | grep -Ev 'minio|etcd|mongo|postgresql|gw-instance|Completed' | grep wks | wc -l`
  echo "number of the present pods which need to stop: $GET_POD_NUMBER, please wait..."
  if [ $GET_POD_NUMBER = 0 ] ; then 
    echo "All pods outside the datastore pod scaled down"
    break
  fi

  sleep 10
  sleepTime=$[$sleepTime+10]
  if [[ $sleepTime -ge $TIME_OUT ]]; then
    echo "Time out when waiting knowledge studio to be deactivated"
    reactivate
    echo "[FAIL] MongoDB,PostgreSQL,Minio,PVC $COMMAND"
    exit 1
  fi
done

################################################################
#backup/restore all MongoDB PostgreSQL Minio PVC data
################################################################

echo ""
echo "$COMMAND MongoDB start:"
bash mongodb-backup-restore.sh $COMMAND $RELEASE_NAME $DATA_DIR_MONGODB $NAMESPACE_OPT
cmd_check
echo ""
echo "$COMMAND PostgreSQL start:"
bash postgresql-backup-restore.sh $COMMAND $RELEASE_NAME $DATA_DIR_POSTRGESQL $NAMESPACE_OPT
cmd_check
echo ""
echo "$COMMAND Minio start:"
bash minio-backup-restore.sh $COMMAND $RELEASE_NAME $DATA_DIR_MINIO $NAMESPACE_OPT
cmd_check
echo ""
echo "$COMMAND PVC start:"
bash pvc-backup-restore.sh $COMMAND $RELEASE_NAME $DATA_DIR_PVC $DOCKER_REGISTRY $PVC_USER_ID $NAMESPACE_OPT
cmd_check
echo ""

################################################################
#Reactivate wks deployment
################################################################

reactivate

echo "[SUCCESS] MongoDB,PostgreSQL,Minio,PVC $COMMAND"
