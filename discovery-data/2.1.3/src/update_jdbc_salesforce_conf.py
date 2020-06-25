#!/usr/bin/env python3

import requests
import json
import os
import re
import sys
import tempfile
import urllib3
import zipfile
from urllib3.exceptions import InsecureRequestWarning
urllib3.disable_warnings(InsecureRequestWarning)

managementPort = os.environ["MANAGEMENT_PORT"]
zingPort = os.environ["ZING_PORT"]
wexBaseUrl = 'https://localhost:' + managementPort + '/wex/api/v1/'
zingBaseUrl = 'http://localhost:' + zingPort + '/ama-zing/api/v1/'
managementSvc=os.environ.get("MANAGEMENT_SVC")
if managementSvc is not None:
  wexBaseUrl = 'https://' + managementSvc + '/wex/api/v1/'
zingSvc = os.environ.get("ZING_SVC")
if zingSvc is not None:
  zingBaseUrl = 'https://' + zingSvc + '/ama-zing/api/v1/'
pgPathRegex = re.compile("/opt/ibm/.*/postgresql.*jar")

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

def updateResource(data_source, pathParam, resourceParam, crawlUrl):
  if len(sys.argv) != 2:
    print("Path to the parent of /mnt is not specified; Skipping")
    return

  filePath = sys.argv[1] + data_source[pathParam]
  if os.path.isdir(filePath):
    # Create a ZIP file from the JAR files inside
    files = os.listdir(filePath)
    tmpDir = tempfile.TemporaryDirectory()
    zipPath = tmpDir.name + "/salesforce.zip"
    with zipfile.ZipFile(zipPath, "w") as salesforceZip:
      for file in files:
        if (file.lower().endswith(".jar")):
          salesforceZip.write(filePath + "/" + file, arcname=file)
    filePath = zipPath

  fileBinary = open(filePath, "rb").read()
  createResponse = post(wexBaseUrl, "fileResources", {"name": "Crawler-File-Resource", "type": os.path.splitext(filePath)[1][1:]})
  resourceId = createResponse["id"]
  print("    Uploaded file resource ID: " + resourceId)
  postFile(wexBaseUrl, "fileResources/" + resourceId + "/upload", {"file": (os.path.basename(filePath), fileBinary, "application/zip")})

  data_source[pathParam] = ""
  data_source[resourceParam] = resourceId
  put(zingBaseUrl, crawlerUrl, conf)

datasets = get(zingBaseUrl, "datasets")
for dataset in datasets["items"]:
  datasetId = dataset["id"]
  if "tags" in dataset.keys() and "_crawlerconf" in dataset["tags"].keys():
    crawlerIds = dataset["tags"]["_crawlerconf"].keys()
    for crawlerId in crawlerIds:
      print("Migrating crawler " + crawlerId)
      crawlerUrl = "datasets/" + datasetId + "/crawlers/" + crawlerId
      conf = get(zingBaseUrl, crawlerUrl)
      data_source = conf["datasource_settings"]
      if "jdbc_driver_classpath" in data_source.keys() and data_source["jdbc_driver_classpath"] and re.match(pgPathRegex, data_source["jdbc_driver_classpath"]) is None:
        print("    User-created JDBC crawler found")
        updateResource(data_source, "jdbc_driver_classpath", "jdbc_driver_resource_id", crawlerUrl)
      elif "jar_location" in data_source.keys() and data_source["jar_location"]:
        print("    Salesforce crawler found")
        updateResource(data_source, "jar_location", "jar_resource_id", crawlerUrl)
      else:
        print("    No migration necessary")
