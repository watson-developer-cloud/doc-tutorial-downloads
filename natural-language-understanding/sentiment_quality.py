'''Report sentiment model quality using a test dataset
'''
import datetime
import json
import argparse
from collections import defaultdict
import csv
import requests
from tqdm import tqdm
from requests.adapters import HTTPAdapter
from requests.packages.urllib3.util.retry import Retry
from requests.packages.urllib3.exceptions import InsecureRequestWarning, MaxRetryError

requests.packages.urllib3.disable_warnings(InsecureRequestWarning)


class QualityEvaluation:
    '''Evaluate model quality using a test dataset.
    '''

    def __init__(self, username, password, url, language, model_id, test_dataset, print_results):
        '''Initialize QualityEvaluation object.

        Args:
            username:  str
                The username to authenticate with service.
            password:  str
                The password to authenticate with service.
            url:  str
                The url provided in the service credential. For example:
                'https://api.us-south.natural-language-understanding.watson.cloud.ibm.com'.
            language:  str
                Language code
            model_id:  str
                This is the model_id associated the custom model.
            test_dataset:  CSV
                The path to a test dataset.
                Note test dataset must have 2 columns with the following headers:
                    doc: column containing sample text phrases.
                    label: column containing one of the following sentiment
                    labels for each sample: 'negative', 'neutral', 'positive'.
            print_results:  boolean
                To indicate if detailed results should be printed
        '''
        self.test_dataset = test_dataset
        self.username = username
        self.password = password
        self.url = url
        self.analyze_request = {'features': {'sentiment': {'model': model_id}}, 'language': language}
        self.headers = {'Content-Type' : 'application/json'}
        self.print_results = print_results
        # Setup retry strategy for post
        retry_strategy = Retry(total=3,
                               status_forcelist=[429, 500, 502, 503, 504],
                               method_whitelist=["HEAD", "GET", "OPTIONS", "POST"],
                               backoff_factor=1)
        adapter = HTTPAdapter(max_retries=retry_strategy)
        self.http = requests.Session()
        self.http.mount("https://", adapter)

    def run(self):
        '''Evaluates model quality for sentiment.

        Returns:
            report
                A sentiment model quality report.
        '''
        report = self.sentiment_eval()
        print(json.dumps(report.get_summary(), indent=4))
        if self.print_results:
            print(json.dumps(report.results, indent=4))
        return report

    def analyze(self, text):
        '''Send the request to NLU service to analyze the sentiment on the text

        Args:
            text: str
                The text to be analyzed for sentiment score, label
        Returns:
            json
                A json response object
        '''
        data = self.analyze_request
        data.update({'text': text})
        data = json.dumps(data).encode('utf8')
        response = ''
        try:
            response = self.http.post(self.url, auth=(self.username, self.password),
                                      verify=False, headers=self.headers, data=data, timeout=10)
        except MaxRetryError as error:
            raise RuntimeError('{}'.format(error.reason))
        if response.status_code != 200:
            json_res = response.json()
            raise RuntimeError('{}, when posting Text: {}'.format(json_res, text))

        return response.json()

    def sentiment_eval(self):
        '''Evaluates the sentiment model quality using a test dataset.

        Returns:
            SentimentReport
                A sentiment model quality report.
        '''
        average_confusion_matrix = {'negative':{'negative':0, 'neutral':0, 'positive':0},
                                    'neutral':{'negative':0, 'neutral':0, 'positive':0},
                                    'positive':{'negative':0, 'neutral':0, 'positive':0}}
        results = {'output': []}
        with open(self.test_dataset, newline='', encoding='utf-8') as csvfile:
            reader = csv.DictReader(csvfile)
            rows = list(reader)
            progress_bar = tqdm(total=len(rows))
            for sample in rows:
                try:
                    text = sample['doc']
                except AttributeError as error:
                    raise AttributeError("Failed to read doc. {}".format(error))

                if not text:
                    raise ValueError('doc is empty in row: {}'.format(sample[0]))
                try:
                    average_label = sample['label']
                except AttributeError as error:
                    raise AttributeError("Failed to read label. {}".format(error))

                if average_label.lower() not in ('positive', 'neutral', 'negative'):
                    raise ValueError('Unknown label "{}" was detected associated with text: {}'
                                     .format(average_label, text))

                # Evaluate each sentence and collect predicted label, score
                response = QualityEvaluation.analyze(self, text)
                predicted_label = response['sentiment']['document']['label']
                predicted_score = response['sentiment']['document']['score']

                # Increment the average confusion_matrix
                average_confusion_matrix[average_label.lower()][predicted_label] += 1

                current_result = {
                    'reference': average_label,
                    'predict': predicted_label,
                    'sentence': text,
                    'score': predicted_score
                }
                # Append current result to final results
                results['output'].append(current_result)
                progress_bar.update(1)
        progress_bar.close()
        return SentimentReport(self.test_dataset, average_confusion_matrix, results)

class Report:
    '''Generic report
    '''
    def __init__(self, test_dataset, confusion_matrix=None, results=None):
        '''Initialize Report object.

        Args:
            test_dataset:  CSV
                A collection of sentences and attributes used for testing a model
            confusion_matrix:  dictionary
                Holds the values for the confusion matrix
            results:  list
                Holds the dictionaries that have test sentence, the gold label, predicted label,
                and predicted score for that sentence
            summary:  dictionary
                Report the precision, recall, f1, macro prcision, macro recall, macro f1,
                and accuracy for the test dataset
        '''
        self.test_dataset = test_dataset
        self.confusion_matrix = confusion_matrix
        self.results = results
        self.summary = {}

    def get_summary(self):
        '''Generic method to print summary results.

        Returns:
            dictionary
                Empty dictionary.
        '''
        return self.summary

class SentimentReport(Report):
    '''Generate a sentiment model quality report.
    '''
    def __init__(self, test_dataset, confusion_matrix, results=None):
        super().__init__(test_dataset, confusion_matrix, results)
        tree = lambda: defaultdict(tree)
        self.summary = tree()

    def get_summary(self):
        '''Reports sentiment model quality measures accuracy, precision, recall and f1 score.

        Returns:
            dictionary
                Summary sentiment report.
        '''
        total_count = 0
        total_correct_count = 0
        total_predicted = {}
        total_label = {}

        self.summary['report'] = 'Custom sentiment model quality report'
        self.summary['dataset'] = self.test_dataset
        self.summary['timestamp'] = datetime.datetime.utcnow().strftime('%B %d %Y - %H:%M:%S')
        self.summary['number_of_samples'] = len(self.results['output'])

        # step 1: Initialize sentiment predicted/totals for
        # each 'negative', 'positive', 'neutral' label
        for label in self.confusion_matrix:
            total_predicted[label] = 0
            total_label[label] = 0

        # step 2: From the confusion matrix calculate total predicted count,
        # total predicted count per label, and total correct predicted count for all labels.
        # Also store confusion matrix in the summary report.
        for label in self.confusion_matrix:
            self.summary['quality_measures']['confusion_matrix'][label] = {}

            for label2 in self.confusion_matrix:
                total_count += self.confusion_matrix[label][label2]
                total_predicted[label2] += self.confusion_matrix[label][label2]
                total_label[label] += self.confusion_matrix[label][label2]
                self.summary['quality_measures']['confusion_matrix'][label][label2] = \
                    self.confusion_matrix[label][label2]
                if label == label2:
                    total_correct_count += self.confusion_matrix[label][label2]

        precision = {}
        macro_precision = 0
        recall = {}
        macro_recall = 0
        f1_class = {}
        macro_f1 = 0

        # step 3: Using previous counts, compute the precision, recall, and f1
        # for each classification label and save to summary report.
        # Also store the precision, recall, and f1 for all labels for later macro computation
        for label in self.confusion_matrix:
            precision[label] = 0.0 if total_predicted[label] == 0 else \
            (self.confusion_matrix[label][label] + 0.0)/total_predicted[label]

            recall[label] = 0.0 if total_label[label] == 0 else \
            (self.confusion_matrix[label][label] + 0.0)/total_label[label]

            f1_class[label] = 0.0 if (precision[label]+recall[label]) == 0 else \
                2*precision[label]*recall[label]/(precision[label]+recall[label])

            macro_precision += precision[label]
            macro_recall += recall[label]
            macro_f1 += f1_class[label]

            self.summary['quality_measures']['classification_report']['precision'][label] = \
                round(precision[label], 4)

            self.summary['quality_measures']['classification_report']['recall'][label] = \
                round(recall[label], 4)

            self.summary['quality_measures']['classification_report']['f1'][label] = \
                round(f1_class[label], 4)

        # step 4: Compute macro precision, recall, f1, and accuracy and save to summary report
        macro_precision /= len(precision)
        macro_recall /= len(recall)
        macro_f1 /= len(f1_class)
        accuracy = 0.0 if total_count == 0 else total_correct_count / total_count

        self.summary['quality_measures']['other_quality_measures']['macro_f1'] = \
            round(macro_f1, 4)
        self.summary['quality_measures']['other_quality_measures']['macro_precision'] = \
            round(macro_precision, 4)
        self.summary['quality_measures']['other_quality_measures']['macro_recall'] = \
            round(macro_recall, 4)
        self.summary['quality_measures']['other_quality_measures']['accuracy'] = \
            round(accuracy, 4)

        return self.summary

def main():
    '''Collect parameters and run model evalution
    '''
    default_url = 'https://api.us-south.natural-language-understanding.watson.cloud.ibm.com'
    parser = argparse.ArgumentParser(description='Evaluate custom sentiment model.')
    parser.add_argument('-u', '--username', dest='username', default='apikey', required=False,
                        help='Username to authenticate with the service instance. \
                        See your `Service credentials` in cloud.ibm.com.')
    parser.add_argument('-p', '--password', dest='password', required=True,
                        help='Password to authenticate with the service instance. \
                        See your `Service credentials` in cloud.ibm.com.')
    parser.add_argument('-url', '--url', dest='url', required=True,
                        default=default_url, help='NLU Analyze Service URL. \
                        See `Getting started` in your NLU service in cloud.ibm.com.')
    parser.add_argument('-l', '--language', dest='language', required=True, \
                         help='Language code. One of ar, de, en, es, fr, it, ja, ko, nl, pt, zh')
    parser.add_argument('-m', '--modelID', dest='modelID', required=True,
                        help='Model ID of the trained custom model to be evaluated.')
    parser.add_argument('-d', '--data', dest='data', required=True, help='Path to test dataset.')
    parser.add_argument('-r', '--results', dest='results', required=False, action='store_true',
                        help='Print detailed results.')
    args = parser.parse_args()
    QualityEvaluation(args.username, args.password, args.url, args.language, args.modelID, args.data, args.results).run()

if __name__ == '__main__':
    main()
