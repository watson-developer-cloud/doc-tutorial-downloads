#!/usr/bin/env bash
#
#################################################################
# Licensed Materials - Property of IBM
# (C) Copyright IBM Corp. 2019.  All Rights Reserved.
#
# US Government Users Restricted Rights - Use, duplication or
# disclosure restricted by GSA ADP Schedule Contract with
# IBM Corp.
#################################################################
#
# Script to dump OpenShift configuration information

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
typeset -r ROOT

if [ "$DEBUG" ] ; then
    set -x
fi

openshift_collector_version="4.0.0_20230519_0"

usage() {
  cat <<EOF
Usage:
${BASH_SOURCE[0]}[--cluster <openshift-cluster>] [--namespace <openshift-project>] [--username <openshift-admin-user>] [--password <openshift-admin-password>] [--skip-auth] [--tls] 1>&2

  This command will attempt to authenticate with the specified OpenShift
  cluster and retrieve diagnostic information. The information will be
  compressed into a .tgz file.

  If you need to debug this script, set DEBUG=true and run the script:
    DEBUG=true ${BASH_SOURCE[0]}


Flags:
  -c, --cluster                   The OpenShift cluster to connect to (without
                                  protocol)
  -n, --namespace                 The OpenShift project (a.k.a. namespace) to run
                                  diagnostics against
  -u, --username                  The OpenShift username to log in with
                                  (defaults to "ocadmin")
  -p, --password                  The OpenShift password to log in with
                                  (defaults to "ocadmin")
      --roks                      Login to a ROKS cluster if this option was supplied
      --token                     The Bearer token that requried for logging into ROKS cluster
      --skip-auth                 The namespace, username and password flags aren't
                                  required and will be ignored if they are supplied
                                  and this flag is set
      --check-collection-status   Check the specified collection's status.
                                  Require Watson Discovery instance id and collection id.
  -s, --service                   [Optional] The service name that is used to specify
                                  cluster resources of Watson Discovery.
                                  (defaults to "discovery")
  -t, --tenant                    [Optional] The tenant name that is used to specify
                                  cluster resources of Watson Discovery.
                                  (defaults to "wd")
  -i, --instance                  [Required if --check-collection-status is specified]
                                  The instance id of Watson Discovery.
  -C, --collection                [Required if --check-collection-status is specified]
                                  The collection id that want to check with status.

OPTIONS:
  -v, --v, --version        Print Openshift Collector version.
  -h, --h, --help           Show help
EOF
  exit 2
}

getVersion() {
  echo "Openshift Collector Version: ${openshift_collector_version}"
  exit 0
}

runCommand() {
  local command
  local title
  command=$1
  title=$2
  echo "**********************************************************"
  echo "$title"
  echo "**********************************************************"
  eval $command || { echo "ERROR: $title" >&2; RC=2; }
  echo
}

collectFileLogs() {
  local pod_name=$1
  local local_log_folder=$2
  local remote_log_folder=$3
  local temp_log_dir="/tmp/logs"

  echo "Creating local folder ${local_log_folder}"
  mkdir -p "${local_log_folder}" || exit 1

  echo "**********************************************************"
  echo "$pod_name file logs"
  echo "**********************************************************"
  echo

  runCommand "${OC} exec ${pod_name} -- bash -c 'mkdir -p ${temp_log_dir} && cp -R ${remote_log_folder} ${temp_log_dir}'" "Copying file logs from $remote_log_folder to $temp_log_dir"
  runCommand "${OC} rsync --progress ${pod_name}:${temp_log_dir} ${local_log_folder}" "Copying file logs in $pod_name to from $temp_log_dir to local machine $local_log_dir"
  runCommand "${OC} exec ${pod_name} -- rm -rf ${temp_log_dir}" "Cleaning up file logs on $pod_name at $temp_log_dir"
}

collectDiagnosticsData() {
  echo "********** OpenShift diagnostics data collected on ${openshift_diagnostic_collection_date} **********"
  echo "********** OpenShift collector version: ${openshift_collector_version} **********"
  echo
  echo "**********************************************************"
  echo "Collecting diagnostic data from Clustername $cluster"
  echo "**********************************************************"
  echo

  runCommand "${OC} version" "Get oc version"

  runCommand "${OC} get namespaces" "Get Kubernetes namespaces"

  runCommand "${OC} get nodes --show-labels" "Get nodes"

  runCommand "${OC} get nodes -o=jsonpath=\"{range .items[*]}{.metadata.name}{'\t'}{.status.allocatable.memory}{'\t'}{.status.allocatable.cpu}{'\n'}{end}\"" "Memory and CPU"

  runCommand "${OC} get images --all-namespaces" "Get list of images from kubernetes"

  runCommand "${OC} get securitycontextconstraints" "Get SecurityContextConstraints"

  runCommand "${OC} get serviceaccounts --all-namespaces" "Get ServiceAccounts"

  runCommand "${OC} get roles --all-namespaces" "Get Roles"

  runCommand "${OC} get rolebinding --all-namespaces" "Get RoleBindings"

  echo "**********************************************************"
  echo "Checking SCC configuration - see https://github.com/IBM/cloud-pak/tree/master/samples/utilities"
  echo "**********************************************************"
  echo
  # Stolen from https://github.com/IBM/cloud-pak/blob/master/samples/utilities/getSCCs.sh

  TMP_IFS=$IFS
  IFS='
  '

  echo "Checking SCC configuration for namespace: $namespace"
  ${OC} get namespace $namespace &> /dev/null
  if [ $? -ne 0 ]; then
    echo "Namespace $namespace does not exist."
    exit 1
  fi


  ${OC} get scc -o name | while read SCC;do
    SCCNAME="$(echo $SCC | cut -d'/' -f2)"
    USERSFILE=$(mktemp)
    trap "rm -f $USERSFILE" EXIT


      # Find all groups from the current SCC
      ${OC} get $SCC -o jsonpath='{range .groups[*]}{@}{"\n"}{end}' | while read line;do
        # Check to see if the service account namespace is in the name
        GROUPNS="$line"
        if [ "$GROUPNS" = "system:serviceaccounts:$namespace" ]; then
          if [ -s "$USERSFILE" ]; then
            echo -n ", " >> $USERSFILE
          fi
          echo -n "*sys:sa:ns" > $USERSFILE
        elif [ "$GROUPNS" = "system:authenticated" ]; then
          if [ -s "$USERSFILE" ]; then
            echo -n ", " >> $USERSFILE
          fi
          echo -n "*sys:auth" > $USERSFILE
        elif [ "$GROUPNS" = "system:serviceaccounts" ]; then
          if [ -s "$USERSFILE" ]; then
            echo -n ", " >> $USERSFILE
          fi
          echo -n "*sys:sa" > $USERSFILE
        fi
      done

      # Find all users from the current SCC
      ${OC} get $SCC -o jsonpath='{range .users[*]}{@}{"\n"}{end}' | while read line;do
        # Check to see if the service account namespace is in the name
        USERNS="$(echo $line | cut -d':' -f1,2,3)"
        if [ "$USERNS" = "system:serviceaccount:$namespace" ]; then
          SA="$(echo $line | cut -d':' -f4)"
          if [ -s "$USERSFILE" ]; then
            echo -n ", " >> $USERSFILE
          fi
          echo -n "$SA" >> $USERSFILE
        fi
      done

      if [ -s "$USERSFILE" ]; then
        echo "$SCCNAME ($(cat $USERSFILE))"
      fi
  done

  IFS=$TMP_IFS
  echo

  collect_etcd=false
  etcd_label="etcd_cluster=${tenant}-discovery-etcd"
  if ! ${OC} get pod -l icpdsupport/addOnId=$service,app=etcd -o 'jsonpath={.items[0].metadata.name}' >/dev/null 2>&1; then
    collect_etcd=true
  fi

  runCommand "${OC} get storageclass" "Get Storage Classes"

  runCommand "${OC} describe storageclass" "Describe Storage Classes"

  runCommand "${OC} get persistentvolume | awk '{if(\$5==\"Bound\"){print}}' | grep $tenant-" "Get Persistent Volumes in $tenant tenant on Bound status"

  runCommand "${OC} describe persistentvolume -l icpdsupport/addOnId=$service" "Describe Persistent Volumes in $service service"

  runCommand "${OC} get persistentvolumeclaims -l icpdsupport/addOnId=$service" "Get Persistent Volume Claims in $service service"
  if [ "$collect_etcd" = true ]; then
    runCommand "${OC} get persistentvolumeclaims -l ${etcd_label}" "Get Persistent Volume Claims of Etcd in $service service"
  fi

  runCommand "${OC} describe persistentvolumeclaims -l icpdsupport/addOnId=$service" "Describe Persistent Volume Claims in $service service"
  if [ "$collect_etcd" = true ]; then
    runCommand "${OC} describe persistentvolumeclaims -l ${etcd_label}" "Describe Etcd Persistent Volume Claims in $service service"
  fi

  runCommand "${OC} get configmaps -l icpdsupport/addOnId=$service" "Get ConfigMaps in $service service"

  runCommand "${OC} get services -l icpdsupport/addOnId=$service" "Get Services in $service service"
  if [ "$collect_etcd" = true ]; then
    runCommand "${OC} get services -l ${etcd_label}" "Get Services of Etcd in $service service"
  fi

  runCommand "${OC} get secrets -l icpdsupport/addOnId=$service" "Get Secrets in $service service"

  runCommand "${OC} get statefulsets -l icpdsupport/addOnId=$service" "Get Stateful Sets in $service service"
  if [ "$collect_etcd" = true ]; then
    runCommand "${OC} get statefulsets -l ${etcd_label}" "Get Etcd Stateful Sets in $service service"
  fi

  runCommand "${OC} get replicasets -l icpdsupport/addOnId=$service" "Get Replica Sets in $service service"

  runCommand "${OC} get jobs -l icpdsupport/addOnId=$service" "Get Jobs in $service service"

  runCommand "${OC} get pods -l icpdsupport/addOnId=$service -o wide" "Get Kubernetes Pods in $service service"
  if [ "$collect_etcd" = true ]; then
    runCommand "${OC} get pods -l ${etcd_label} -o wide" "Get Kubernetes Pods of Etcd in $service service"
  fi

  if [ "$checkCollectionStatus" = true ]; then
  echo "**********************************************************"
  echo "Checking status of collection"
  echo "**********************************************************"
  echo
    if [[ $collectionId == -* ]] || [[ $collectionId == "" ]] || [[ $instanceId == -* ]] || [[ $instanceId == "" ]]; then
      echo "WARNING: Skip checking collection status because either instance id or collection id or both of them have not been specified."
    else
      MANAGEMENT_POD="$(${OC} get pods -l icpdsupport/addOnId=$service,run=management -o=jsonpath='{.items[0].metadata.name}')"
      command="bash -c 'curl -ks http://localhost:9080/wex/api/v1/collections/${collectionId}/status -H \"X-Watson-Userinfo: bluemix-instance-id=${instanceId}\" | jq'"
      echo "Command: $command"
      runCommand "${OC} exec ${MANAGEMENT_POD} -c management -- ${command}" "Checking collection status"
      echo
    fi
  fi

  HADOOP_POD="$(${OC} get pods -l icpdsupport/addOnId=$service,run=hdp-rm -o=jsonpath='{.items[0].metadata.name}')"
  runCommand "${OC} exec ${HADOOP_POD} -- yarn application -list" "Listing yarn applications"
  echo

  if $collectHDFS; then
    echo "**********************************************************"
    echo "$HADOOP_POD hadoop filesystem logs - this could take a while"
    echo "**********************************************************"
    echo

    runCommand "${OC} exec ${HADOOP_POD} -- hdfs dfs -copyToLocal /tmp/logs /tmp/logs" "Collecting Hadoop filesystem log data - this could take a while..."
    runCommand "${OC} rsync --progress ${HADOOP_POD}:/tmp/logs ${openshift_diagnostic_hadoop_folder}" "Copying Hadoop filesystem logs to local machine"
    runCommand "${OC} exec ${HADOOP_POD} -- rm -rf /tmp/logs" "Cleaning up temporary logs dir of Hadoop filesystem data"
  fi

  sc="$(${OC} get wd $tenant -o jsonpath='{.spec.shared.storageClassName}')"
  if [ -z "$sc" ]; then
    sc="$(${OC} get wd $tenant -o jsonpath='{.spec.blockStorageClass}')"
  fi
  if [[ $sc =~ "portworx" ]]; then
    runCommand "${OC} get pods -n kube-system | grep portworx" "Fetching Portworx Status"
    PX_POD=$(${OC} get pods -l name=portworx -n kube-system -o jsonpath='{.items[0].metadata.name}')
    ${OC} exec $PX_POD -n kube-system -- /opt/pwx/bin/pxctl status
    echo
  else
    echo "INFO: Skip collecting logs for storage class of $sc. Only support portworx for now." >&2
  fi

  echo "**********************************************************"
  echo "Fetching Minio Storage Usage"
  echo "**********************************************************"
  echo

  minio_data_dir="/workdir/data"
  for POD in $(${OC} get pods -n $namespace -l icpdsupport/addOnId=$service,release=$tenant-minio -o name | awk -F '/' '{print $2 }')
  do
    echo "$POD:df"
    ${OC} rsh $POD df -h $minio_data_dir
    echo

    echo "$POD:du"
    ${OC} exec $POD -- bash -c "du -sh $minio_data_dir > /tmp/du_res & timeout 10m bash -c 'while sleep 20; do if [ -s "/tmp/du_res" ]; then cat /tmp/du_res && rm /tmp/du_res && break; else date; fi ; done'"
    echo
  done

  echo "**********************************************************"
  echo "Fetching Postgres Storage Usage"
  echo "**********************************************************"
  echo

  postgres_data_dir="/var/lib/edb/data"
  for POD in $(${OC} get pods -n $namespace -l icpdsupport/addOnId=$service,run=postgres,component=stolon-keeper -o name | awk -F '/' '{print $2 }')
  do
    runCommand "${OC} rsh $POD df -h $postgres_data_dir" "$POD:df"
    runCommand "${OC} rsh $POD du -sh $postgres_data_dir" "$POD:du"
  done

  echo "**********************************************************"
  echo "Fetching Etcd logs for Converter"
  echo "**********************************************************"
  echo

  if [ "$collect_etcd" = true ]; then
    ETCD_POD=$(${OC} get pod -l ${etcd_label} -o 'jsonpath={.items[0].metadata.name}')
  else
    ETCD_POD=$(${OC} get pod -l icpdsupport/addOnId=$service,app=etcd -o 'jsonpath={.items[0].metadata.name}')
  fi

  echo "Verifying ETCDCTL_USER variable is set to access ETCD pod"
  if ${OC} exec -t $ETCD_POD -- sh -c 'test -n "${ETCDCTL_USER}"'; then
    ${OC} exec -i $ETCD_POD -- bash -c "etcdctl --insecure-skip-tls-verify=true --cert=/etc/etcdtls/operator/etcd-tls/etcd-client.crt --key=/etc/etcdtls/operator/etcd-tls/etcd-client.key --cacert=/etc/etcdtls/operator/etcd-tls/etcd-client-ca.crt get /wex/global --prefix"
  else
    echo "Fetching ETCD access information from the secret"
    ETCD_USER=$(${OC} get secret $(${OC} get secret -l icpdsupport/addOnId=$service,app=etcd --no-headers -o custom-columns=:.metadata.name) --template='{{.data.username }}' | base64 --decode)
    ETCD_PSW=$(${OC} get secret $(${OC} get secret -l icpdsupport/addOnId=$service,app=etcd --no-headers -o custom-columns=:.metadata.name) --template='{{.data.password }}' | base64 --decode)
    ${OC} exec -i $ETCD_POD -- bash -c "etcdctl --insecure-skip-tls-verify=true --cert=/etc/etcdtls/operator/etcd-tls/etcd-client.crt --key=/etc/etcdtls/operator/etcd-tls/etcd-client.key --cacert=/etc/etcdtls/operator/etcd-tls/etcd-client-ca.crt --user=$ETCD_USER:$ETCD_PSW get /wex/global --prefix"
  fi

  echo

  echo "**********************************************************"
  echo "Describe Kubernetes Pods in $service service"
  echo "**********************************************************"
  echo

  getOpenShiftPodsResult=$(${OC} get pods -l icpdsupport/addOnId=$service -o custom-columns=NAME:.metadata.name --no-headers) || { echo "ERROR: Failed to get list of pods." >&2; exit 2; }
  if [ -z "$getOpenShiftPodsResult" ]; then
    echo "No pods found in service $service"
    echo
  else
    if [ "$collect_etcd" = true ]; then
      getEtcdPodsResult=$(${OC} get pods -l ${etcd_label} -o custom-columns=NAME:.metadata.name --no-headers) || { echo "ERROR: Failed to get list of etcd pods." >&2; exit 2; }
      enter=$'\n'
      getOpenShiftPodsResult="${getOpenShiftPodsResult}$enter${getEtcdPodsResult}"
    fi

    echo "Running Describe for the following pods"
    echo "---------------------------------------"
    echo "${getOpenShiftPodsResult}"
    echo

    echo "$getOpenShiftPodsResult" |
    while read openshiftPodName; do
      echo -e "--------- $openshiftPodName ----------\n"
      ${OC} describe pods $openshiftPodName || { echo "ERROR: Failed to describe pod $openshiftPodName." >&2; exit 2; }
      echo -e "----------------------------------------------------------------\n"
    done
    echo

    echo "**********************************************************"
    echo "Downloading logs from service $service pods"
    echo "**********************************************************"
    echo

    echo "$getOpenShiftPodsResult" |
    while read openshiftPodName; do
      echo "**********************************************************"
      echo "$opeshiftPodName log(s)"
      echo "**********************************************************"
      echo
      while read openshiftContainerName; do
        echo "**********************************************************"
        echo "$openshiftPodName ($openshiftContainerName) log"
        echo "**********************************************************"
        echo "Writing log to ${openshift_diagnostic_data_folder}/$openshiftPodName-$openshiftContainerName.log"
        echo
        ${OC} logs $openshiftPodName -c $openshiftContainerName > ${openshift_diagnostic_logs_folder}/$openshiftPodName-$openshiftContainerName.log || { echo "ERROR: Failed to get logs for pod $openshiftPodName($openshiftContainerName)." >&2; }
      done <<<"$(echo "$(${OC} get pods $openshiftPodName -o jsonpath='{.spec.initContainers[*].name}') $(${OC} get pods $openshiftPodName -o jsonpath='{.spec.containers[*].name}')" | xargs | tr " " "\n")"
    done
    echo
  fi
}

#########################################################################################
#                                MAIN
#########################################################################################

cluster=
namespace=
username=
password=
service=discovery
tenant=wd
skipAuth=false
roks=false
token=
collectHDFS=false
tls=
checkCollectionStatus=false
instanceId=
collectionId=

# Allow user to specify full path of oc client via OCCLI env var. If OCCLI env var isn't set, use oc found in PATH.
# i.e export OCCLI=/tmp/oc321 will force the script to use the /tmp/oc321 cli.
OC="${OCCLI:-oc}"
export OC
RC=0

while (( $# > 0 )); do
  case "$1" in
    -c | --cluster )
      if [[ $2 == -* ]] || [[ $2 == "" ]]; then
        echo "**********************************************************"
        echo -e "Error: You must specify a cluster."
        echo "**********************************************************"
        usage
      fi
      shift
      cluster="$1"
      ;;
    -n | --namespace )
      if [[ $2 == -* ]] || [[ $2 == "" ]]; then
        echo "**********************************************************"
        echo "Error: You must specify a namespace."
        echo "**********************************************************"
        usage
      fi
      shift
      namespace="$1"
      ;;
    -u | --username )
      shift
      username="$1"
      ;;
    -p | --password )
      shift
      password="$1"
      ;;
    -s | --service )
      if [[ $2 == -* ]] || [[ $2 == "" ]]; then
        echo "**********************************************************"
        echo "Info: Default service name of 'discovery' would be used."
        echo "**********************************************************"
        echo
      fi
      shift
      service="$1"
      ;;
    -t | --tenant )
      if [[ $2 == -* ]] || [[ $2 == "" ]]; then
        echo "**********************************************************"
        echo "Info: Default tenant name of 'wd' would be used."
        echo "**********************************************************"
        echo
      fi
      shift
      tenant="$1"
      ;;
    --roks )
      roks=true
      ;;
    --token )
      shift
      token="$1"
      ;;
    --skip-auth )
      skipAuth=true
      ;;
    --collect-hdfs-logs )
      collectHDFS=true
      ;;
    --check-collection-status )
      checkCollectionStatus=true
      ;;
    -i | --instance )
      shift
      instanceId="$1"
      ;;
    -C | --collection )
      shift
      collectionId="$1"
      ;;
    -t | --tls )
      tls="--tls"
      ;;
    -h | --h | --help )
      usage
      exit 0
      ;;
    -v | --v | --version )
      getVersion
      exit 0
      ;;
    * | -* )
      echo "Unknown option: $1"
      echo
      usage
      ;;
  esac
  shift
done

if [ -z "$cluster" ]; then
  echo "**********************************************************"
  echo "Error: You must specify a cluster."
  echo "**********************************************************"
  echo ""
  usage
  exit 1
fi

if [ -z "$namespace" ] && ! $skipAuth; then
  echo "**********************************************************"
  echo "Error: You must specify a namespace."
  echo "**********************************************************"
  echo ""
  usage
  exit 1
fi

echo
echo "**********************************************************"
echo "Checking for Helm/oc Client"
echo "**********************************************************"
if ! command -v "${OC}" > /dev/null; then
  echo "oc client not found. Ensure that you have oc installed and on your PATH, or set OCCLI to the aboslute path to the binary"
  exit 1
fi

# set_helm

echo

if ! $skipAuth; then
  echo "**********************************************************"
  echo "Logging into OpenShift"
  echo "**********************************************************"
  if $roks; then
    if [[ ${token} == "" ]]; then
      echo "****************************************************************"
      echo "Error: You must specify a token for logging into ROKS cluster."
      echo "****************************************************************"
      echo
      usage
    fi
    ${OC} login --token=${token} --server=https://${cluster} || { echo "ERROR: Logging into OpenShift Failed. [ROKS]" >&2; exit 3; }
  else
    if [[ ${username} == "" ]] || [[ ${password} == "" ]]; then
      echo "**************************************************************************"
      echo "Error: You must specify username and password for logging into OpenShift"
      echo "**************************************************************************"
      echo
      usage
    fi
    ${OC} login https://$cluster -u $username -p $password || { echo "ERROR: Logging into OpenShift Failed." >&2; exit 3; }
  fi

  ${OC} project $namespace || { echo "ERROR: Switching to project $namespace Failed." >&2; exit 3; }
fi

openshift_diagnostic_collection_date=`date +"%d_%m_%y_%H_%M_%S"`

# if the user skipped auth then we'll fetch the current namespace
if $skipAuth; then
  namespace=$(${OC} get sa default -o jsonpath='{.metadata.namespace}')
fi

echo "********** OpenShift diagnostics: Starting data collection for Cluster=$cluster & Namespace=$namespace at ${openshift_diagnostic_collection_date} **********"
echo

tempFolder="."
temp_folder_name="${cluster}_${openshift_diagnostic_collection_date}"
openshift_diagnostic_data_folder_name=${temp_folder_name//:/_}
openshift_diagnostic_data_folder="${tempFolder}/${openshift_diagnostic_data_folder_name}"
openshift_diagnostic_logs_folder="${openshift_diagnostic_data_folder}/logs"
openshift_diagnostic_hadoop_folder="${openshift_diagnostic_data_folder}/hadoop"
openshift_diagnostic_data_log="${openshift_diagnostic_data_folder}/watson-diagnostics-data.log"
openshift_diagnostic_data_zipped_file="${openshift_diagnostic_data_folder}.tgz"


echo "Creating temporary folder ${openshift_diagnostic_data_folder}"
mkdir -p ${openshift_diagnostic_logs_folder} || exit 1

if $collectHDFS; then
  echo "Creating temporary folder ${openshift_diagnostic_hadoop_folder}"
  mkdir -p ${openshift_diagnostic_hadoop_folder} || exit 1
fi

echo "Collecting Diagnostics data. Please wait...."
echo "View log collection progress by running 'tail -f ${openshift_diagnostic_data_log}' in a separate window"
echo "NB Any errors caught will be printed below and to the log."
echo "-------------------------------------------"
# redirect output so that stdout and stderr are sent to openshift_diagnostic_data_log ... and stderr is also sent to the console
collectDiagnosticsData $@1 >>${openshift_diagnostic_data_log} 2> >(tee -a ${openshift_diagnostic_data_log} >&2)

${OC} describe node >${openshift_diagnostic_data_folder_name}/describe_node.txt

echo

if [ $RC -eq 0 ]; then
  echo "Successfully collected OpenShift diagnostics data"
else
  echo "Error occurred while trying to collect OpenShift diagnostics data. Check ${openshift_diagnostic_data_log} for details"
fi

echo "Zipping up OpenShift Diagnostics data from ${openshift_diagnostic_data_folder}"
tar cfz ${openshift_diagnostic_data_zipped_file} --directory ${tempFolder} ${openshift_diagnostic_data_folder_name}
if [ $? -eq 0 ]; then
  echo "Cleaning up temporary folder ${openshift_diagnostic_data_folder}"
  rm -rf ${openshift_diagnostic_data_folder}
  echo "********** Successfully collected and zipped up OpenShift diagnostics data. The diagnostics data is available at ${openshift_diagnostic_data_zipped_file} **********"
else
  echo "********** Failed to zip up diagnostics data. Diagnostics data folder is available at ${openshift_diagnostic_data_folder} **********"
fi
