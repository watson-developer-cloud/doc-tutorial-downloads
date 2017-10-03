#!/usr/bin/env python2
import argparse
import csv
import json
import os
import shlex
import subprocess
import time

#remove the ranker training file (just in case it's left over from a previous run)
TRAINING_DATA_FILENAME='trainingdata.json'
try:
    os.remove(TRAINING_DATA_FILENAME)
except OSError:
    pass

parser = argparse.ArgumentParser(description='Demo script for uploading training data')
parser.add_argument('-u', required=True, help='username:password')
parser.add_argument('-i', '--input-file', required=True, help='Query relevance file')
parser.add_argument('-e', '--environment', required=True, help='Discovery environment id')
parser.add_argument('-c', '--collection', required=True, help='collection id')
parser.add_argument('-d', '--debug', action='store_true', help='Enable debug output for script')
parser.add_argument('-v', action='store_true', help='Enable verbose output for curl')

args = parser.parse_args()

print("Input file is %s" % (args.input_file))
print("Discovery environment is %s" % (args.environment))
print("Collection is %s" % (args.collection))

VERBOSE_CURL = '-v' if args.v else ''

#constants used for URLs
VERSION = '2017-09-01'
BASE_URL = "https://gateway.watsonplatform.net/discovery/api"
TRAINING_URL = BASE_URL + '/v1/environments/%s/collections/%s/training_data?version=%s' % (args.environment, args.collection, VERSION)

with open(args.input_file, 'rb') as csvfile:
    question_relevance = csv.reader(csvfile)
    print 'Uploading training data...'
    for row in question_relevance:
        training_query = {'natural_language_query' : row[0].replace(r"'", r"\'"), 'examples' : []}
        for i in range(1, len(row), 2):
            example = {'document_id' : row[i], 'relevance' : int(row[i+1])}
            training_query['examples'].append(example)

        with open(TRAINING_DATA_FILENAME, "w") as training_file:
            json.dump(training_query, training_file)
        curl_cmd = 'curl -X POST -u "%s" -H "Content-Type: application/json" %s -d@%s "%s"' % (args.u, VERBOSE_CURL, TRAINING_DATA_FILENAME, TRAINING_URL)
        #curl_cmd = ['curl', '-X', 'POST', '-u', args.u, '-H', 'Content-Type: application/json'] + VERBOSE_CURL + ['-d', training_query_json, TRAINING_URL]
        if args.debug:
            print curl_cmd
        process = subprocess.Popen(shlex.split(curl_cmd), stdout=subprocess.PIPE)
        output = process.communicate()[0]
        if args.debug:
           print output
        time.sleep(0.1)
print 'Uploading training data complete.'
