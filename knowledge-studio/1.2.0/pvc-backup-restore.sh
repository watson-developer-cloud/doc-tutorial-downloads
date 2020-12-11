#!/bin/bash

print_help() {
  echo "USAGE: $0 [command] [releaseName] [backupDir] [dockerRegistry] [userId] [-n namespace]"
  echo "[FAIL] PVC $COMMAND"
  exit 1
}

cmd_check(){
  if [ $? -ne 0 ] ; then
    removeTempItem
    echo "[FAIL] PVC $COMMAND"
    exit 1
  fi
}

rm_check(){
  if [ $? -ne 0 ] ; then
    [WARNING] remove $1 failed
  fi
}

backupPVC(){
  echo "backup PVC data to $DATA_DIR ..."
  kubectl $KUBECTL_ARGS exec -it $PVC_TEMP_POD_NAME -- bash -c "cd $REMOTE_DIR_PVC; tar cfvz /tmp/sandbox.tgz *"
  cmd_check
  kubectl $KUBECTL_ARGS cp $PVC_TEMP_POD_NAME:/tmp/sandbox.tgz $DATA_DIR/sandbox.tgz
  cmd_check
  echo "PVC data have been saved to: '$DATA_DIR'"
}

restorePVC(){
  echo "restore PVC data from $DATA_DIR ..."
  kubectl $KUBECTL_ARGS cp $DATA_DIR/sandbox.tgz $PVC_TEMP_POD_NAME:/tmp/sandbox.tgz
  cmd_check
  kubectl $KUBECTL_ARGS exec $PVC_TEMP_POD_NAME -- bash -c "cd $REMOTE_DIR_PVC; rm -Rf *; tar xfvz /tmp/sandbox.tgz; rm /tmp/sandbox.tgz"
  cmd_check
  echo "PVC data have been saved to: '$DATA_DIR'"
}

removeTempItem(){
  echo "delete temporary pod: '$PVC_TEMP_POD_NAME'"
  kubectl $KUBECTL_ARGS delete pod $PVC_TEMP_POD_NAME
  rm_check "pod '$PVC_TEMP_POD_NAME'"
  echo "delete temporary yaml file: '$PVC_TEMP_POD_NAME.yaml'"
  rm $PVC_TEMP_POD_NAME.yaml
  rm_check "yaml file: '$PVC_TEMP_POD_NAME.yaml'"
}

# command line arguments
if [ $# -lt 5 ] ; then
  print_help
fi

COMMAND=$1
shift
RELEASE_NAME=$1
shift
DATA_DIR=$1
shift
DOCKER_REGISTRY=$1
shift
USER_ID=$1
shift
while getopts "n:" opt; do
  case $opt in
  "n" ) KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$OPTARG" ;;
  esac
done

declare -r TIME_OUT=120
declare -r REMOTE_DIR_PVC="/opt/ibm/watson/aql-web-tooling/target/sandbox"
declare -r PVC_TEMP_POD_NAME="$RELEASE_NAME-ibm-watson-ks-aql-web-tooling-backup"

# create temporary pod for backup
cat << EOF > $PVC_TEMP_POD_NAME.yaml
apiVersion: v1
kind: Pod
metadata:
  name: ${PVC_TEMP_POD_NAME}
spec:
  containers:
  - name: backup
    image: ${DOCKER_REGISTRY}/wks-nosql-bats:1.3.1
    command:
    - "/bin/bash"
    - "-c"
    - "tail -f /dev/null"
    volumeMounts:
    - mountPath: /opt/ibm/watson/aql-web-tooling/target/sandbox
      name: sandbox
    securityContext:
      runAsNonRoot: true
      runAsUser: ${USER_ID}
  serviceAccount: ${RELEASE_NAME}-ibm-watson-ks
  serviceAccountName: ${RELEASE_NAME}-ibm-watson-ks
  volumes:
  - name: sandbox
    persistentVolumeClaim:
      claimName: ${RELEASE_NAME}-ibm-watson-ks-awt-file-pvc
EOF

echo ""
echo "create temporary pod:'$PVC_TEMP_POD_NAME' for backup ..."
kubectl $KUBECTL_ARGS apply -f $PVC_TEMP_POD_NAME.yaml
cmd_check

echo "wait for pod:'$PVC_TEMP_POD_NAME' to be ready ..."
sleepTime=0
while [ `kubectl $KUBECTL_ARGS get pod wks-ibm-watson-ks-aql-web-tooling-backup -o go-template --template {{.status.phase}}` != "Running" ]; do
  sleep 1s
  sleepTime=$[$sleepTime+1]
  if [[ $sleepTime -ge $TIME_OUT ]]; then
    echo "Time out when waiting temporary pod:'$PVC_TEMP_POD_NAME' to be ready"
    removeTempItem
    echo "[FAIL] PVC $COMMAND"
    exit 1
  fi
done

echo ""
echo "$COMMAND PVC data"
#backup PVC data
if [[ $COMMAND = "backup" ]]; then
  backupPVC
fi

#retore PVC data
if [[ $COMMAND = "restore" ]]; then
  restorePVC
fi

removeTempItem

echo "[SUCCESS] PVC $COMMAND"
