#!/usr/bin/env python3

import requests
import json
import os
import urllib.parse
import time
import urllib3
from urllib3.exceptions import InsecureRequestWarning
urllib3.disable_warnings(InsecureRequestWarning)

managementPort = os.environ["MANAGEMENT_PORT"]
wexBaseUrl = 'https://localhost:' + managementPort + '/wex/api/v1/'
managementSvc=os.environ.get("MANAGEMENT_SVC")
if managementSvc is not None:
  wexBaseUrl='https://' + managementSvc + '/wex/api/v1/'
wdApiBaseUrl = 'https://localhost:10443/wd-api/api/v2/'
sampleCollectionName = "Sample Collection"
commonParam = "?version=1111-11-11"
waitWdApiTimeoutMinutes = 10

def err():
  print("Error on running post restore scripts")
  exit(1)

def get(baseUrl, endpoint):
  r = requests.get(baseUrl + endpoint,verify=False)
  if r.status_code != requests.codes.ok :
    print(r.text)
    print("can not get " + endpoint)
    err()
  return r.json()

def waitForWdApiToBeReady():
  start = time.time()
  while True :
    if(start - time.time() > waitWdApiTimeoutMinutes * 60):
      print("WD api has not been ready after " + str(waitForWdApiToBeReady) + " minutes")
      err()
    r = requests.get(wdApiBaseUrl + "projects" + commonParam,verify=False)
    if r.status_code == requests.codes.ok:
      break
    time.sleep(1)

waitForWdApiToBeReady()
projects = get(wdApiBaseUrl, "projects" + commonParam)
cm_collections = set()
for project in projects["projects"]:
  if(project["type"] == "content_mining") and (project["collection_count"] > 0):
    cols_in_proj = get(wdApiBaseUrl, "projects/" + project["project_id"] + "/collections" + commonParam)
    for col in cols_in_proj["collections"]:
      cm_collections.add(col["collection_id"]) 

cm_datasets = set()
for colid in cm_collections:
  collection = get(wexBaseUrl, "collections/" + colid)
  if "datasets" in collection.keys():
    for dataset in collection["datasets"]:
      cm_datasets.add(dataset)

for dataset in cm_datasets:
  endpoint = wdApiBaseUrl +  "datasets/" + dataset + "/rebuild" + commonParam
  data = { "rebuild_collections" : "true" }
  headers = { "content-type": "application/json" }
  r = requests.post(endpoint, verify=False, headers=headers,data=json.dumps(data))
  if r.status_code != requests.codes.no_content:
    print(r.text)
    print("rebuild " + dataset + " returns " + str(r.status_code))
