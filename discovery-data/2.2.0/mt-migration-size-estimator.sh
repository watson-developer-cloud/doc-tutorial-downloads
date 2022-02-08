#!/usr/bin/env bash

set -e
set -o pipefail

echo 'Estimator script version 1.0'

show_help() {
  cat << EOS
Estimate storage usage during migration for each PostgreSQL pod.

usage: $0 [options]

options:
  -h, --help                           Print help info.
  -n, --namespace         ns           [Optional] Namespace where Watson Discovery is installed. If not specified, use the namespace set in current context.
  -i, --instance          name         [Optional] Name of WatsonDiscovery custom resource to run against.
EOS
}

nsopt=
instance_name="wd"

while (( $# > 0 )); do
  case "$1" in
    -h | --help )
      show_help
      exit 0
      ;;
    -n | --namespace )
      shift
      nsopt="-n $1"
      ;;
    -i | --instance )
      shift
      instance_name="$1"
      ;;
    * )
      echo "Invalid argument."
      show_help
      exit 1
      ;;
  esac
  shift
done

declare -r nsopt
declare -r instance_name

PG_CAPACITY_READABLE=$(oc get cluster $nsopt -o jsonpath='{.spec.storage.size}' wd-discovery-cn-postgres)
echo "Current storage capacity for each PostgreSQL pod is $PG_CAPACITY_READABLE"

PG_POD=$(oc get pod $nsopt -l postgresql=${instance_name}-discovery-cn-postgres -o jsonpath='{.items[0].metadata.name}')
PG_USED_MB=$(oc exec $nsopt $PG_POD -- du -sm /var/lib/postgresql/data | cut -f 1)
echo "Current storage usage for each PostgreSQL pod is $(( ($PG_USED_MB+1023)/1024 ))Gi"

SQL=$(cat <<EOS
	with dataset as (
		select pg_total_relation_size(c.oid) as size from pg_class c, pg_namespace n
		where c.relnamespace = n.oid and c.relkind = 'r' and (n.nspname = 'public' and c.relname = 'ds')),
	total as (
		select sum(pg_total_relation_size(c.oid)) as size from pg_class c, pg_namespace n
		where c.relnamespace = n.oid and c.relkind = 'r' and (n.nspname = 'public' or c.relname = 'pg_largeobject'))
	select ceil($PG_USED_MB * (dataset.size + total.size) / (total.size+1) / 1024)+2 from dataset, total
EOS
)
PG_PASSWORD=$(oc get secret wd-discovery-cn-postgres-wd --template '{{.data.pg_su_password}}' | base64 --decode)
CMD="PGUSER=postgres PGPASSWORD=$PG_PASSWORD psql --dbname=dadmin --tuples-only --csv --command=\"$SQL\""
ESTIMATE_GB=$(oc exec $nsopt $PG_POD -- bash -c "$CMD")

echo "Estimated storage usage during migration for each PostgreSQL pod is ${ESTIMATE_GB}Gi"

PG_CAPACITY_GB=$(( $(echo "$PG_CAPACITY_READABLE"|sed 's%Gi%%; s%G%*1000/1024%; s%Mi%/1024%; s%M%*1000/1024/1024%') ))

if [ $ESTIMATE_GB -ge $PG_CAPACITY_GB ]; then
    echo "Please increase the storage capacity for PostgreSQL or remove some collections."
else
    echo "PostgreSQL has enough capacity for migration."
fi
