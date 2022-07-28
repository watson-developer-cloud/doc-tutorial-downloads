#!/bin/bash

print_help() {
  echo "USAGE: $0 [command] [releaseName] [backupDir] [-n namespace]"
  echo "[FAIL] mongodb $COMMAND"
  exit 1
}

cmd_check(){
  if [ $? -ne 0 ] ; then
    echo "[FAIL] mongodb $COMMAND"
    exit 1
  fi
}

get_master_pod() {
  for pod in `kubectl ${KUBECTL_ARGS} get pods -o=go-template --template='{{range $pod := .items}}{{range .status.containerStatuses}}{{if .ready}}{{$pod.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}' | grep ${RELEASE_NAME}-ibm-mongodb`
  do 
    IS_MASTER_FLAG=`kubectl ${KUBECTL_ARGS} exec -it $pod -- mongo --tls --tlsAllowInvalidCertificates  -u $MONGO_USERNAME -p $MONGO_PASSWORD --quiet --eval "db.isMaster().ismaster" | grep "true" | wc -l`
    if [ $IS_MASTER_FLAG -eq 1 ]; then
      MONGODB_POD_NAME="$pod"
    fi
  done
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
  "n" ) KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$OPTARG" ;;
  esac
done


backupMongoDB() {
  for data in $@
  do
    echo "saving $data to $REMOTE_DIR_MONGO under $MONGODB_POD_NAME ..."
    kubectl $KUBECTL_ARGS exec -it $MONGODB_POD_NAME -- mongodump --ssl \
          --sslAllowInvalidCertificates -u $MONGO_USERNAME -p $MONGO_PASSWORD \
          --authenticationDatabase admin \
          --db=$data --quiet -o $REMOTE_DIR_MONGO

    if [[ $? -eq 0 ]]; then
      echo "$data have been saved to '$REMOTE_DIR_MONGO' under pod:'$MONGODB_POD_NAME' temporarily"
    else
      echo "save $data to $REMOTE_DIR_MONGO under $MONGODB_POD_NAME faililed"  
      removeTempFile $REMOTE_DIR_MONGO
      print_help
    fi
  done

  echo "Saving MongoDB data to $DATA_DIR ..."
  if [[ `kubectl $KUBECTL_ARGS cp $MONGODB_POD_NAME:$REMOTE_DIR_MONGO $DATA_DIR` -eq 0 ]]; then
    echo "mongoDB data have been saved to: '$DATA_DIR'"
  else
    echo "save $data to: '$DATA_DIR' failed"
  fi

}

retoreMongoDB() {
  echo "copying MongoDB data from $DATA_DIR to $REMOTE_DIR_MONGO ..."
  for data in $@
  do
    copyBackup=`kubectl $KUBECTL_ARGS cp $DATA_DIR/$data $MONGODB_POD_NAME:$REMOTE_DIR_MONGO`
    if [[ copyBackup -eq 0 ]]; then
      echo "MongoDB backed up data: $data have been saved to: $REMOTE_DIR_MONGO under $MONGODB_POD_NAME temporarily"
    else
      echo "save $data to $REMOTE_DIR_MONGO under $MONGODB_POD_NAME failed"  
      removeTempFile $REMOTE_DIR_MONGO
      print_help
    fi
  done

  echo "restoring MongoDB data to "$MONGODB_POD_NAME" ..."
  kubectl $KUBECTL_ARGS exec -it $MONGODB_POD_NAME -- mongorestore --drop --ssl \
        --sslAllowInvalidCertificates -u $MONGO_USERNAME -p $MONGO_PASSWORD \
        --authenticationDatabase admin \
        --dir $REMOTE_DIR_MONGO
  if [[ $? -eq 0 ]]; then
    echo "MongoDB data have been restored to '$MONGODB_POD_NAME'"
  else
    removeTempFile $REMOTE_DIR_MONGO
    print_help
  fi
}

removeTempFile() {
  echo "Removing temporary remote file: $1 ..."
  kubectl $KUBECTL_ARGS exec -it $MONGODB_POD_NAME -- rm -rf $1
  if [[ ! $? -eq 0 ]]; then
    echo "[WARNING] remove:'$1' temp file failed"
  fi
}

declare -r MONGO_USERNAME=`kubectl $KUBECTL_ARGS get secret ${RELEASE_NAME}-ibm-mongodb-auth-secret --template '{{.data.user}}' | base64 --decode `
declare -r MONGO_PASSWORD=`kubectl $KUBECTL_ARGS get secret ${RELEASE_NAME}-ibm-mongodb-auth-secret --template '{{.data.password}}' | base64 --decode`

declare -r REMOTE_DIR_MONGO="home/mongodb/output"

get_master_pod
cmd_check
echo "mongodb pod name:'$MONGODB_POD_NAME'"

if [[ ! $COMMAND ]]; then
  print_help
fi


################################################################
#MongoDB data
#Create temporary remote file to backup/restore MongoDB data
################################################################

create_output_file_mongo=`kubectl $KUBECTL_ARGS exec -it $MONGODB_POD_NAME -- mkdir $REMOTE_DIR_MONGO`

if [[ $create_output_file_mongo -eq 0 ]]; then
  echo "new directory: '$REMOTE_DIR_MONGO' created under $MONGODB_POD_NAME"
else 
  echo "temp file creation failed"  
  print_help
fi

#backup MongoDB data
if [[ $COMMAND = "backup" ]]; then
  backupMongoDB WKSDATA ENVDATA escloud_sbsep
fi

#retore MongoDB data
if [[ $COMMAND = "restore" ]]; then
  retoreMongoDB WKSDATA ENVDATA escloud_sbsep
fi

################################################################
#remove temporary file
################################################################
removeTempFile $REMOTE_DIR_MONGO

echo "[SUCCESS] mongodb $COMMAND"
