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
zingBaseUrl = 'http://localhost:' + zingPort + '/ama-zing/api/v1/'
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

if len(sys.argv) != 2:
  print("Output intermediate JSON file is not specified")
  exit(1)

intermediateJson = dict()
intermediateJson["clientId_to_clientSecret"] = dict()
intermediateJson["keyId_to_passphrase"] = dict()

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
        intermediateJson["clientId_to_clientSecret"][data_source["client_id"]] = ""
        intermediateJson["keyId_to_passphrase"][data_source["kid"]] = ""
      else:
        print("Not a Box crawler, or already migrated: " + crawlerId)

with open(sys.argv[1], mode="w") as file:
  file.write(json.dumps(intermediateJson, indent=2))
