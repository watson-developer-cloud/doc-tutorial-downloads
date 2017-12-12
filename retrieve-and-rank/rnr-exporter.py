#!/usr/bin/python
import argparse
import pysolr
import json
import sys
import os
import StringIO
from threading import Thread
from watson_developer_cloud import DiscoveryV1
from watson_developer_cloud import WatsonApiException


class InvalidPagingConfigError(RuntimeError):
    def __init__(self, message):
        super(RuntimeError, self).__init__(message)

class DiscoveryIndexer(Thread):
    def __init__(self, docs, args):
        super(type(self), self).__init__()
        hostname = args["hostname"]
        disco_username = args["disco_username"]
        disco_password = args["disco_password"]

        self.docs = docs
        self.disco_env_id = args["disco_env_id"]
        self.disco_collection_id = args["disco_collection_id"]
        self.discovery = DiscoveryV1(url=('https://%s/discovery/api' % hostname), username=disco_username, password=disco_password, version="2017-11-07")

    def run(self):
        for doc in self.docs:
            self._index_one_document(doc)

    def _index_one_document(self, doc):
        if "id" not in doc.keys():
            print("ERROR: Document doesn't have ID; skipping, but this is bad")
            return
        doc_id = doc["id"]

        # Remove Solr fields which will be invalid in Discovery
        doc.pop("_version_", None)
        doc.pop("id", None)

        doc_text = json.dumps(doc)
        while True:
            doc_file = StringIO.StringIO(doc_text)
            try:
                add_doc_rsp = self.discovery.update_document(self.disco_env_id, self.disco_collection_id, doc_id, file=doc_file,
                                                             filename="rnr-export-file", file_content_type="application/json")
                print(json.dumps(add_doc_rsp))
                break
            except WatsonApiException as e:
                if e.code == 429:
                    print("Rate limit hit; retrying [%s].  Consider using fewer threads in future." % doc_id)
                else:
                    print("Unexpected error encountered while indexing doc [%s]: %sSkipping document." % (doc_id, str(e)))
                    break
            finally:
                doc_file.close()


class SolrDocs:
    """ Cursor-based iteration, most performant. Requires a sort on id somewhere in required "sort" argument.

        This is recommended approach for iterating docs in a Solr collection
    """

    def __init__(self, solr_conn, sort, **options):
        self.solr_conn = solr_conn
        self.lastCursorMark = ''
        self.cursorMark = '*'
        self.sort = sort

        try:
            self.rows = options['rows']
            del options['rows']
        except KeyError:
            self.rows = 0
        self.options = options

    def next_batch(self):
        try:
            if self.lastCursorMark != self.cursorMark:
                response = self.solr_conn.search("*:*", rows=self.rows, cursorMark=self.cursorMark,
                                                 sort=self.sort, **self.options)
                self.lastCursorMark = self.cursorMark
                self.cursorMark = response.nextCursorMark
                return response.docs
            else:
                raise StopIteration()
        except pysolr.SolrError as e:
            if "Cursor" in e.message:
                raise InvalidPagingConfigError(e.message)
            raise e


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument('--rnr_username', type=str, required=True,
                        help='The username used to access this Retrieve and Rank instance')
    parser.add_argument('--rnr_password', type=str, required=True,
                        help='The password used to access this Retrieve and Rank instance')
    parser.add_argument('--rnr_solr_cluster_id', type=str, required=True,
                        help='The Solr cluster ID to export data from.')
    parser.add_argument('--rnr_collection_name', type=str, required=True,
                        help='The Solr collection to export data from.')
    parser.add_argument('--rows-per-page', type=int, default=500,
                        help='The batch size when fetching documents from Retrieve and Rank')
    parser.add_argument('--hostname', type=str, default="gateway.watsonplatform.net",
                        help='The hostname used to access RnR and Discovery')

    parser.add_argument('--disco_username', type=str, required=True,
                        help='The username used to access this Discovery instance')
    parser.add_argument('--disco_password', type=str, required=True,
                        help='The password used to access this Discovery instance')
    parser.add_argument('--disco_env_id', type=str, required=True,
                        help='The environment-ID to import data into')
    parser.add_argument('--disco_collection_id', type=str, required=True,
                        help='The collection-ID to import data into')

    parser.add_argument('--num_ingest_threads', type=int, default=2,
                        help='The number of threads to use for ingesting data into Discovery.  This number is ' +
                        'configurable, but values much higher than 2 are likely to provide diminishing returns' +
                        'due to server-side rate limiting.')

    return vars(parser.parse_args())


def fetch_doc_batch(solr_itr):
    try:
        return solr_itr.next_batch()
    except StopIteration as e:
        print("Successfully finished exporting documents from Retrieve and Rank")
        return None
    except Exception as e:
        print("Error encountered while fetching documents from Retrieve and Rank: %s" % str(e))
        sys.exit(1)


def main():
    try:
        args = parse_args()
        hostname = args['hostname']
        rnr_username = args['rnr_username']
        rnr_password = args['rnr_password']
        rnr_cluster_id = args['rnr_solr_cluster_id']
        rnr_collection_name = args['rnr_collection_name']

        rnr_batch_size = args['rows_per_page']
        rnr_collection_path = "retrieve-and-rank/api/v1/solr_clusters/%s/solr/%s" % (rnr_cluster_id, rnr_collection_name)
        solr_url = "https://%s:%s@%s/%s" % (rnr_username, rnr_password, hostname, rnr_collection_path)
        solr_conn = pysolr.Solr(solr_url)
        solr_itr = SolrDocs(solr_conn, "id asc", rows=rnr_batch_size)

        num_indexers = args["num_ingest_threads"]
        while True:
            docs = fetch_doc_batch(solr_itr)
            if docs == None:
                break

            indexers = []
            try:
                for indexer_num in range(0, num_indexers):
                    docs_per_indexer = rnr_batch_size / num_indexers
                    start_idx = indexer_num * docs_per_indexer
                    end_idx = start_idx + docs_per_indexer
                    doc_slice = docs[start_idx:] if (indexer_num == num_indexers -1) else docs[start_idx:end_idx]

                    indexer = DiscoveryIndexer(doc_slice, args)
                    indexer.start()
                    indexers.append(indexer)

                for indexer in indexers:
                    indexer.join()
            except Exception as e:
                print("Error encountered importing documents into Discovery: %s" % str(e))
                sys.exit(1)

    except KeyboardInterrupt:
        print('Interrupted')


if __name__ == "__main__":
    main()
