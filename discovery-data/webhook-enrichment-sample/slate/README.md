# Entity Extraction with [watsonx.ai slate model](https://www.ibm.com/blog/introducing-the-technology-behind-watsonx-ai/) fine-tuned with labeled data exported from Watson Discovery's entity extractor workspace

Slate models have the best cost performance trade-off for non-generative use cases, and it requires task-specific labeled data for fine tuning. You can prepare labeled data in Watson Discovery, fine-tune slate model in Watson Studio, and deploy the model in Watson Machine Learning. Once you deploy a fine-tuned model, you can create a webhook enrichment that enriches documents with that model in Watson Discovery efficiently.

## Requirements

- Instance of Watson Discovery Plus/Enterprise plan on IBM Cloud.
- Instance of Cloud Pak for Data (>=4.7.x) on on-premise.
  - Install Watson Studio.
  - Install Watson Machine Learning.
- An API key of IBM Cloud. You can see how to manage API keys [here](https://cloud.ibm.com/docs/account?topic=account-manapikey).
- An API key of Cloud Pak for Data. You can see how to manage API keys [here](https://www.ibm.com/docs/en/cloud-paks/1.0?topic=users-generating-api-keys-authentication).

## Setup Instruction

### Prepare labeled data in Watson Discovery

1. [Create entity extractor workspace and label data](https://cloud.ibm.com/docs/discovery-data?topic=discovery-data-entity-extractor#entity-extractor-export-label) in Watson Discovery
2. [Download labeled data](https://cloud.ibm.com/docs/discovery-data?topic=discovery-data-entity-extractor#entity-extractor-export-label) from entity extractor workspace

In this tutorial, you can use [sample labled data](data/Financial+demo+extractor-labeled_data.zip) in subsequent steps.

### Fine tune slate model in Watson Studio and deploy the model to Watson Machine Learning

1. [Create a project](https://www.ibm.com/docs/en/cloud-paks/cp-data/4.7.x?topic=projects-creating-project) in Watson Studio.
2. [Create a deployment space](https://www.ibm.com/docs/en/cloud-paks/cp-data/4.7.x?topic=spaces-creating-deployment) in Watson Machine Learning.
2. [Create an environment template](https://www.ibm.com/docs/en/cloud-paks/cp-data/4.7.x?topic=environments-creating) in the project. You can create with following options:
   - `Type`: `Default`
   - `Hardware configuration`
       - `Reserve vCPU`: `2`
       - `Reserve RAM (GB)`: `8`
   - `Software version`: `Runtime 23.1 on Python 3.10`
3. [Create notebook](https://www.ibm.com/docs/en/cloud-paks/cp-data/4.7.x?topic=editor-creating-notebooks) in the project using the environment template as runtime from [the notebook file](app/notebook/Financial%20Demo.ipynb).
4. [Upload labeled data](https://www.ibm.com/docs/en/cloud-paks/cp-data/4.7.x?topic=scripts-loading-accessing-data-in-notebook#load-data-from-local-files) in the notebook.
5. Fine tune and deploy slate model by running a notebook step by step with replacing some variables.


### Deploy the webhook enrichment app to Code Engine

In this tutorial, we will use [IBM Cloud Code Engine](https://www.ibm.com/cloud/code-engine) as the infrastructure for the application of webhook enrichment. Of course, you can deploy the application in any environment you like.

1. [Create a project](https://cloud.ibm.com/docs/codeengine?topic=codeengine-manage-project#create-a-project) of Code Engine.
2. [Create a secret](https://cloud.ibm.com/docs/codeengine?topic=codeengine-secret#secret-create) in the project. This secret contains the following key-value pairs:
   - `WD_API_URL`: The API endpoint URL of your Discovery instance
   - `WD_API_KEY`: The API key of your Discovery instance
   - `WEBHOOK_SECRET`: A key to pass with the request that can be used to authenticate with the application. e.g. `purple unicorn`
   - `SCORING_API_HOSTNAME`: The API hostname of your Watson Machine Learning scoring deployment that serve your fine-tuned slate model.
   - `SCORING_DEPLOYMENT_ID`: The ID of your Watson Machine Learning scoring deployment that serve your fine-tuned slate model.
   - `SCORING_API_TOKEN`: The API token to be used in bearer authorization to use your Watson Machine Learning scoring deployment that serve your fine-tuned slate model. You can get a token by following command:
```shell
SCORING_API_TOKEN=$(
  curl -k -X POST 'https://{hostname of your cp4d instance}/icp4d-api/v1/authorize' \
                  --header "Content-Type: application/json" \
                  -d "{\"username\":\"admin\",\"api_key\":\"{api key of your cp4d instance}\"}" \
  | jq .token
)
```
3. [Deploy the application](https://cloud.ibm.com/docs/codeengine?topic=codeengine-app-source-code) from this repository source code.
   - In **Create application**, click **Specify build details** and enter the following:
      - Source
         - Code repo URL: `https://github.com/watson-developer-cloud/doc-tutorial-downloads`
         - Code repo access: `None`
         - Branch name: `master`
         - Context directory: `discovery-data/webhook-enrichment-sample/slate/app`
      - Strategy
         - Strategy: `Dockerfile`
      - Output
         - Enter your container image registry information.
   - Open **Environment variables (optional)**, and add environment variables.
      - Define as: `Reference to full secret`
      - Secret: The name of the secret you created in Step 2.
   - We recommend setting **Min number of instances** to `1`.
4. Confirm that the application status changes to **Ready**.

### Configure Discovery webhook enrichment
1. Create a project.
2. Create a webhook enrichment using Discovery API.
   ```bash
   curl -X POST {auth} \
   --header 'Content-Type: multipart/form-data' \
   --form 'enrichment={"name":"my-first-webhook-enrichment", \
     "type":"webhook", \
     "options":{"url":"{your_code_engine_app_domain}/webhook", \
       "secret":"{your_webhook_secret}", \
       "location_encoding":"utf-16"}}' \
   '{url}/v2/projects/{project_id}/enrichments?version=2023-03-31'
   ```
3. Create a collection in the project and apply the webhook enrichment to the collection.
   ```bash
   curl -X POST {auth} \
   --header 'Content-Type: application/json' \
   --data '{"name":"my-collection", \
     "enrichments":[{"enrichment_id":"{enrichment_id}", \
       "fields":["text"]}]}' \
   '{url}/v2/projects/{project_id}/collections?version=2023-03-31'
   ```

### Ingest documents to Discovery
1. Upload [one of the page of Annual report](data/IBM_Annual_Report_2019-page12.pdf) to the collection.
2. You can find the enrichment results by webhook by previewing your query results after the document processing is complete.

## Reference
CPD 4.7:
   - NLP in Notebooks: https://www.ibm.com/docs/en/cloud-paks/cp-data/4.7.x?topic=scripts-watson-natural-language-processing
   - Deploying NLP Models: https://www.ibm.com/docs/en/cloud-paks/cp-data/4.7.x?topic=deployments-deploying-nlp-models
   - Sample project: https://github.com/IBMDataScience/sample-notebooks/tree/master/CloudPakForData/notebooks/4.7/Projects
   - Sample notebooks: https://github.com/IBMDataScience/sample-notebooks/tree/master/CloudPakForData/notebooks/4.7

## For your interest

We have implemented the way to use Watson Machine Learning deployment as almost complete webhook application.
If you are interested in how to do it, you can check [here](wml-as-webhook/README.md)

## Note
Currently deploying fine-tuned slate model is not supported in Watson Machine Learning on IBM cloud. Once it gets available, these steps can be completed on IBM Cloud.
