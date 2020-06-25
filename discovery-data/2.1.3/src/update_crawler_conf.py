#!/usr/bin/env python3

import requests
import json
import os
import re
import urllib.parse
import urllib3
from urllib3.exceptions import InsecureRequestWarning
urllib3.disable_warnings(InsecureRequestWarning)

managementPort = os.environ["MANAGEMENT_PORT"]
zingPort = os.environ["ZING_PORT"]
wexBaseUrl = 'https://localhost:' + managementPort + '/wex/api/v1/'
zingBaseUrl = 'https://localhost:' + zingPort + '/ama-zing/api/v1/'
managementSvc=os.environ.get("MANAGEMENT_SVC")
if managementSvc is not None:
  wexBaseUrl = 'https://' + managementSvc + '/wex/api/v1/'
zingSvc = os.environ.get("ZING_SVC")
if zingSvc is not None:
  zingBaseUrl = 'https://' + zingSvc + '/ama-zing/api/v1/'
pgHost = os.environ["PGHOST"]
pgPort = os.environ["PGPORT"]
pgUser = os.environ["PGUSER"]
pgPassword = os.environ["PGPASSWORD"]
pgDatabase = pgUser
pgJar = os.environ["PG_JAR"]
validPgUrl = "jdbc:postgresql://" + pgHost + ":" + pgPort + "/" + pgDatabase
protocol = "jdbc://"
quotedValidDocumentId = protocol + urllib.parse.quote(validPgUrl, safe='')
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
def post(baseUrl, endpoint):
  r = requests.post(baseUrl + endpoint, json.dumps({}), headers={'Content-Type': 'application/json'}, verify=False)
  if r.status_code != 204 :
    print(r.text)
    print("can not post " + endpoint)
    # err()
  return r.text
def put(baseUrl, endpoint, jsonData):
  r = requests.put(baseUrl + endpoint, json.dumps(jsonData), headers={'Content-Type': 'application/json'}, verify=False)
  if r.status_code != requests.codes.ok :
    print(r.text)
    print("can not put " + endpoint + ":\n" + json.dumps(jsonData))
    err()
  return r.json()
def delete(baseUrl, endpoint):
  r = requests.delete(baseUrl + endpoint, verify=False)
  if(r.status_code != requests.codes.ok):
    print(r.text)
    print("can not delete " + endpoint)
    err()

def deleteOldDocumentsIfExists(datasetId):
  isDeleting = True
  documentsEndpoint = "datasets/" + datasetId + "/documents"
  while isDeleting:
    isDeleting = False
    documents = get(wexBaseUrl, documentsEndpoint)
    for doc in documents["items"]:
      if not doc["groupId"].startswith(quotedValidDocumentId):
        isDeleting = True
        deletionUrl = documentsEndpoint + "/" + getDeletionPrefixFromId(doc["groupId"]) + "?prefix=true"
        delete(wexBaseUrl, deletionUrl)
        break

def getDeletionPrefixFromId(id):
  url = id.lstrip(protocol)
  return urllib.parse.quote(protocol + url.split("/")[0], safe='')

datasets = get(zingBaseUrl, "datasets")
for dataset in datasets["items"]:
  datasetId = dataset["id"]
  if "tags" in dataset.keys() and "_crawlerconf" in dataset["tags"].keys():
    crawlerIds = dataset["tags"]["_crawlerconf"].keys()
    for crawlerId in crawlerIds:
      crawlerUrl = "datasets/" + datasetId + "/crawlers/" + crawlerId
      conf = get(zingBaseUrl, crawlerUrl)
      if "datasource_settings" in conf.keys():
        data_source = conf["datasource_settings"]
        if "database_url" in data_source.keys():
          if "jdbc_driver_classpath" in data_source.keys() and re.match(pgPathRegex, data_source["jdbc_driver_classpath"]) != None:
            data_source["jdbc_driver_classpath"] = pgJar
            data_source["user"] = pgUser
            data_source["password"] = pgPassword
            deleteOldDocumentsIfExists(datasetId)
            put(zingBaseUrl, crawlerUrl, conf)
            post(zingBaseUrl, crawlerUrl + "/start?crawlMode=FULL")
