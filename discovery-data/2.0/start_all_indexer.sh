#!/bin/bash

if [[  -z $1 ]] ; then
    echo 'set the name of gateway pod'
    echo 'e.g.'
    echo '     ./start_all_indexer.sh wd-watson-discovery-gateway-0'
    exit 1
fi

kubectl exec $1 -- python -c'
import json
import ast
import urllib.request
cols = "http://localhost:9080/wex/api/v1/collections"

req = urllib.request.Request(cols)
with urllib.request.urlopen(req) as res:
  body = res.read()
collections = json.loads(body)
cids = []
for c in collections["items"]:
  cids.append(c["id"])

data = {
    "enabled": True
}
headers = {
    "Content-Type": "application/json"
}

for cid in cids:
  url = cols+"/"+cid+"/indexing"
  req = urllib.request.Request(url, json.dumps(data).encode(), headers, method="PUT")
  with urllib.request.urlopen(req) as res:
    body = res.read()
    ret = body.decode("utf-8")
    print(cid," -> ",ret)
'


