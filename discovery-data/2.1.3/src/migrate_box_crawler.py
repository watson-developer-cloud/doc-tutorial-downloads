#!/usr/bin/env python3

import requests
import json
import os
import sys
import urllib3
from urllib3.exceptions import InsecureRequestWarning
urllib3.disable_warnings(InsecureRequestWarning)

managementPort = os.environ["MANAGEMENT_PORT"]
zingPort = os.environ["ZING_PORT"]
#wexBaseUrl = 'https://localhost:' + managementPort + '/wex/api/v1/'
#zingBaseUrl = 'http://localhost:' + zingPort + '/ama-zing/api/v1/'
wexBaseUrl = 'https://localhost:60443/api/v1/'
zingBaseUrl = 'https://localhost:60443/api/v1/'
managementSvc=os.environ.get("MANAGEMENT_SVC")
if managementSvc is not None:
  wexBaseUrl = 'https://' + managementSvc + '/wex/api/v1/'
zingSvc = os.environ.get("ZING_SVC")
if zingSvc is not None:
  zingBaseUrl = 'https://' + zingSvc + '/ama-zing/api/v1/'

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
def post(baseUrl, endpoint, jsonData={}):
  r = requests.post(baseUrl + endpoint, json.dumps(jsonData), headers={'Content-Type': 'application/json'}, verify=False)
  if r.status_code != requests.codes.ok and r.status_code != 204 :
    print(r.text)
    print("can not post " + endpoint)
    # err()
  if r.text:
    return r.json()
def postFile(baseUrl, endpoint, filesDict):
  r = requests.post(baseUrl + endpoint, files=filesDict, headers={'Accept': 'application/json'}, verify=False)
  if r.status_code != requests.codes.ok:
    print(r.text)
    print("can not post " + endpoint)
    # err()
  return r.json()
def put(baseUrl, endpoint, jsonData):
  r = requests.put(baseUrl + endpoint, json.dumps(jsonData), headers={'Content-Type': 'application/json'}, verify=False)
  if r.status_code != requests.codes.ok :
    print(r.text)
    print("can not put " + endpoint + ":\n" + json.dumps(jsonData))
    err()
  return r.json()

if len(sys.argv) != 3:
  print("Usage: " + sys.argv[0] + " /path/to/parent/of/mnt intermediate_JSON_file")
  exit(1)

with open(sys.argv[2]) as file:
  intermediateJson = json.load(file)

datasets = get(zingBaseUrl, "datasets")
for dataset in datasets["items"]:
  datasetId = dataset["id"]
  if "tags" in dataset.keys() and "_crawlerconf" in dataset["tags"].keys():
    crawlerIds = dataset["tags"]["_crawlerconf"].keys()
    for crawlerId in crawlerIds:
      crawlerUrl = "datasets/" + datasetId + "/crawlers/" + crawlerId
      conf = get(zingBaseUrl, crawlerUrl)
      data_source = conf["datasource_settings"]
      if not data_source:
        print("Data source settings not found; Skipping")
        continue
      if "private_key_path" in data_source.keys() and data_source["private_key_path"]:
        print("Box crawler found: " + crawlerId)
        privateKeyPath = sys.argv[1] + data_source["private_key_path"]
        with open(privateKeyPath) as file:
          lines = [s.strip() for s in file.readlines()]
        data_source["private_key"] = "\\n".join(lines)
        clientSecret = intermediateJson["clientId_to_clientSecret"][data_source["client_id"]]
        if not clientSecret:
          print("    Client secret not found for " + data_source["client_id"])
          continue
        data_source["client_secret"] = clientSecret
        data_source["passphrase"] = intermediateJson["keyId_to_passphrase"][data_source["kid"]] # null allowed
        boxJsonTemplate = """{
  "boxAppSettings": {
    "clientID": "%(client_id)s",
    "clientSecret": "%(client_secret)s",
    "appAuth": {
      "publicKeyID": "%(kid)s",
      "privateKey": "%(private_key)s",
      "passphrase": "%(passphrase)s"
    }
  },
  "enterpriseID": "%(enterprise_id)s"
}"""
        boxJson = boxJsonTemplate % data_source
        createResponse = post(wexBaseUrl, "fileResources", {"name": "Crawler-File-Resource", "type": "json", "tags": {"encryption": "true"}})
        resourceId = createResponse["id"]
        print("    Uploaded file resource ID: " + resourceId)
        postFile(wexBaseUrl, "fileResources/" + resourceId + "/upload", {"file": ("box_config.json", bytes(boxJson, "utf-8"), "application/json")})
        del data_source["client_id"], data_source["client_secret"], data_source["kid"], data_source["private_key_path"], data_source["private_key"], data_source["passphrase"], data_source["enterprise_id"]
        data_source["private_key_resource_id"] = resourceId
        put(zingBaseUrl, crawlerUrl, conf)
      else:
        print("Not a Box crawler, or already migrated: " + crawlerId)
