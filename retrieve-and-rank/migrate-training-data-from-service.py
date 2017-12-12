import argparse
import json
import pip
import datetime

pip.main(["install", "requests"])
import requests

# parse command line arguments
parser = argparse.ArgumentParser(description="Script for uploading exported R&R training data. Requires python3")
parser.add_argument('-u', required=True, help='username:password of Discovery account')
parser.add_argument('-i', '--input-file', required=True, help='Exported R&R training data json file')
parser.add_argument('-e', '--environment', required=True, help='Discovery environment id')
parser.add_argument('-c', '--collection', required=True, help='Discovery collection id')
parser.add_argument('-v', '--version-date', help='version date in format YYYY-MM-DD. Default to 2017-10-16')

args = parser.parse_args()

print("Input file is %s" % (args.input_file))
print("Discovery environment is %s" % (args.environment))
print("Collection is %s" % (args.collection))
print("Version Date is %s" % (args.version_date))

class TrainingData:
    def __init__(self, input_file):
        """
        Initialize the object. Parse the input json file and convert it to Discovery training data format.

        Arguments:
        input_file -- input json file exported from R&R service containing the training data
        """
        self.input_file = input_file
        self.training_data = {}
        self.__parse()

    def __parse(self):
        """
        Parse the input json file and convert it to Discovery training data format.
        """
        with open(self.input_file, 'r') as data_file:
            data = json.load(data_file)
            for query in data:
                examples = []
                answers = query['cluster']['answers']
                for key in answers:
                    for an in answers[key]:
                        score = 0
                        if an['ranking'] > 1:
                            score = 10
                        examples.append({'document_id' : an['id'],
                                         'relevance' : score})
                self.training_data[query['text']] = examples

    def upload(self, environment_id, collection_id, base_url, version, user, pw):
        """
        Upload training data to a collection.

        Arguments:
        environment_id -- intended environment id to upload the training data
        collection_id -- intended collection id to upload the training data
        base_url -- base url for Watson Discovery
        version -- date version
        user -- account username
        pw -- account password
        """
        url = base_url + '/v1/environments/%s/collections/%s/training_data?version=%s' % (environment_id, collection_id, version)
        print('Uploading training data...')
        for query, examples in self.training_data.items():
            query_formated = {'natural_language_query' : query,
                              'examples' : examples}
            print("query: " + str(query_formated))
            r = requests.post(url, headers={'content-type': 'application/json'}, 
                                   auth=(user, pw),
                                   json=query_formated)
            print(r)
            if (r.status_code < 200 or r.status_code >= 300):
                print('failed uploading query: ' + r.text)
            print()

def main():

    VERSION = args.version_date or '2017-10-16'
    print(VERSION)
    BASE_URL = "https://gateway.watsonplatform.net/discovery/api"
    
    # parse training data
    training_data = TrainingData(args.input_file)

    user, pw = args.u.split(':')
    # upload training data to Discovery
    training_data.upload(args.environment, args.collection, BASE_URL, VERSION, user, pw)

if __name__ == "__main__":
    main()