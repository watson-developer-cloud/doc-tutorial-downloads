#!/bin/bash

declare -r CUREBT_TIME=`date +%s`
declare -r TIME_OUT=600

print_help() {
  echo "This script is in order to backup/restore all MongoDB/PostgreSQL/S3 data"
  echo "USAGE: $0 [command] [releaseName] [backupDir] [-n namespace]"
  exit 1
}

cmd_check(){
  if [ $? -ne 0 ] ; then
    reactivate
    echo "[FAIL] MongoDB,PostgreSQL,S3 $COMMAND"
    exit 1
  fi
}

reactivate() {
  echo "Reactivate knowledge studio:"
  oc $KUBECTL_ARGS patch --type=merge wks ${RELEASE_NAME} -p "{\"spec\":{\"global\":{\"quiesceMode\":false}}}"
  cmd_check

  oc $KUBECTL_ARGS patch --type=merge wks ${RELEASE_NAME} -p "{\"spec\":{\"mma\":{\"replicas\":\"${MMA_REPLICAS}\"}}}"
  cmd_check

  END_TIME=`date +%s`
  printf "%s %d\n" "Elapsed time: " `expr $END_TIME - $CUREBT_TIME`
}

deactivating() {
  echo "Deactivating knowledge studio:"
  oc $KUBECTL_ARGS patch --type=merge wks ${RELEASE_NAME} -p '{"spec":{"global":{"quiesceMode":true}}}'
  cmd_check

  oc $KUBECTL_ARGS patch --type=merge wks ${RELEASE_NAME} -p '{"spec":{"mma":{"replicas":0}}}'
  cmd_check
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

  DATA_DIR_MONGODB="${DATA_DIR%*/}/mongodb"
  DATA_DIR_POSTRGESQL="${DATA_DIR%*/}/postgresql"
  DATA_DIR_S3="${DATA_DIR%*/}/S3"
else
  DATA_DIR_MONGODB="${DATA_DIR%*/}/mongodb"
  DATA_DIR_POSTRGESQL="${DATA_DIR%*/}/postgresql"
  DATA_DIR_S3=$([ -d ${DATA_DIR%*/}/S3 ] && echo "${DATA_DIR%*/}/S3" || echo "${DATA_DIR%*/}/minio")

  if [[ ! -d ${DATA_DIR_MONGODB} || ! -d ${DATA_DIR_POSTRGESQL} || ! -d ${DATA_DIR_S3} ]]; then
    echo "no backup directory: $DATA_DIR"
    echo "[FAIL] MongoDB,PostgreSQL,S3 $COMMAND"
    exit 1
  fi 
fi

echo "$COMMAND directory:"
echo "  mongodb:'$DATA_DIR_MONGODB'"
echo "  postrgesql:'$DATA_DIR_POSTRGESQL'"
echo "  S3:'$DATA_DIR_S3'"

if [ -v NAMESPACE ]; then
  echo "checking namespace..."
  oc get namespace $NAMESPACE
  if [[ ! $? -eq 0 ]]; then
    echo "namespace:'$NAMESPACE' not exist"  
    echo "[FAIL] MongoDB,PostgreSQL,S3 $COMMAND"
    exit 1
  else 
    echo "namespace:'$NAMESPACE'"
  fi

  KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$NAMESPACE"
  NAMESPACE_OPT="-n $NAMESPACE"
else
  echo "default namespace is used for oc"
fi

################################################################
#Decativate wks deployment
#Make sure no running job
################################################################
jobs=`oc $KUBECTL_ARGS get job --no-headers | grep -e ${RELEASE_NAME}-train -e ${RELEASE_NAME}-batch-apply | awk '{print $2}'`
for job in ${jobs}; do
  if [[ $job == "0/1" ]]; then
    echo "$COMMAND failed because training/evaluation job is running. Please wait for while until the job will complete."
    echo "[FAIL] MongoDB,PostgreSQL,S3 $COMMAND"
    exit 1
  fi
done

echo "Get 'Postgresql IMAGE' for $COMMAND PostgreSql"
POSTGRESQL_POD_NAME=`oc $KUBECTL_ARGS get pods -o=go-template --template='{{range $pod := .items}}{{range .status.containerStatuses}}{{if .ready}}{{$pod.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}' | grep ${RELEASE_NAME}-edb-postgresql | head -n 1`
if [[ ! $POSTGRESQL_POD_NAME ]]; then
  echo "get Postgresql pod failed"
  echo "[FAIL] MongoDB,PostgreSQL,S3 $COMMAND"
  exit 1
else
  echo "Postgresql pod name: '$POSTGRESQL_POD_NAME'"
fi
POSTGRESQL_IMAGE_NAME=`oc $KUBECTL_ARGS get pod $POSTGRESQL_POD_NAME -o jsonpath='{.spec.containers[0].image}'`
if [[ ! $POSTGRESQL_IMAGE_NAME ]]; then
  echo "get Postgresql image failed"
  echo "[FAIL] MongoDB,PostgreSQL,S3 $COMMAND"
  exit 1
else
  echo "Postgresql image name: '$POSTGRESQL_IMAGE_NAME'"
fi

echo ""
echo "Get replicas of MMA"
MMA_REPLICAS=`kubectl $KUBECTL_ARGS get wks ${RELEASE_NAME} -o jsonpath='{.spec.mma.replicas}'`
if [ -z "$MMA_REPLICAS" ]; then
  WKS_SIZE=`kubectl $KUBECTL_ARGS get wks ${RELEASE_NAME} -o jsonpath='{.spec.global.size}'`
  if [[ ${WKS_SIZE} == "medium" ]]; then
    MMA_REPLICAS="2"
  else # small
    MMA_REPLICAS="1"
  fi
fi
echo "replicas of MMA: ${MMA_REPLICAS}"

echo ""
deactivating

echo "Wait until all pods stop except datastore pods, this may take a few minutes..."
sleepTime=0
while :
do
  GET_POD_NUMBER=`kubectl $KUBECTL_ARGS get pod | grep -Ev 'minio|etcd|mongo|postgresql|gw-instance|Completed' | grep "${RELEASE_NAME}-" | wc -l`
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
    echo "[FAIL] MongoDB,PostgreSQL,S3 $COMMAND"
    exit 1
  fi
done

################################################################
#backup/restore all MongoDB PostgreSQL S3 data
################################################################

echo ""
echo "============================== $COMMAND MongoDB start:"
bash mongodb-backup-restore.sh $COMMAND $RELEASE_NAME $DATA_DIR_MONGODB $NAMESPACE_OPT
cmd_check
echo ""
echo "============================== $COMMAND PostgreSQL start:"
bash postgresql-backup-restore.sh $COMMAND $RELEASE_NAME $DATA_DIR_POSTRGESQL $POSTGRESQL_IMAGE_NAME $NAMESPACE_OPT
cmd_check
echo ""
echo "============================== $COMMAND s3 start:"
bash s3-backup-restore.sh $COMMAND $RELEASE_NAME $DATA_DIR_S3 $NAMESPACE_OPT
cmd_check
echo ""

################################################################
#Reactivate wks deployment
################################################################

reactivate

echo "[SUCCESS] MongoDB,PostgreSQL,S3 $COMMAND"
