# Watson Machine Learning deployment as webhook application

This project provides the way to deploy webhook application as Watson Machine Learning deployment, which means that you can do receive webhook notification, pull batches from Watson Discovery, enrich documents with model, and push enriched batches to Watson Discovery.
Note that we need to run proxy to update request payload since request to Watson Machine Learning deployment must meet the requirements that are listed in [Scoring input requirements](https://www.ibm.com/docs/en/cloud-paks/cp-data/4.7.x?topic=functions-writing-deployable-python#scoinreq)

## Requirements

- Instance of Watson Discovery Plus/Enterprise plan on IBM Cloud.
- Instance of Cloud Pak for Data (>=4.7.x) on on-premise.
  - Install Watson Studio.
  - Install Watson Machine Learning.
- An API key of IBM Cloud. You can see how to manage API keys [here](https://cloud.ibm.com/docs/account?topic=account-manapikey).
- An API key of Cloud Pak for Data. You can see how to manage API keys [here](https://www.ibm.com/docs/en/cloud-paks/1.0?topic=users-generating-api-keys-authentication).

## Setup Instruction

### Prepare labeled data in Watson Discovery

The same as [original one](../README.md)

### Fine tune slate model in Watson Studio and deploy the model to Watson Machine Learning

Most is the same as [original one](../README.md), except `Create notebook`

[Create notebook](https://www.ibm.com/docs/en/cloud-paks/cp-data/4.7.x?topic=editor-creating-notebooks) in the project using the environment template as runtime from [the notebook file](notebook/Deploy%20Webhook%20Application.ipynb).

### Deploy the proxy to webhook enrichment app to Code Engine

In this tutorial, we will use [IBM Cloud Code Engine](https://www.ibm.com/cloud/code-engine) as the infrastructure for the proxy to webhook enrichment application. Of course, you can deploy the proxy in any environment you like.

1. [Create a project](https://cloud.ibm.com/docs/codeengine?topic=codeengine-manage-project#create-a-project) of Code Engine.
2. [Create a secret](https://cloud.ibm.com/docs/codeengine?topic=codeengine-secret#secret-create) in the project. This secret contains the following key-value pairs:
   - `SCORING_API_HOSTNAME`: The API hostname of your Watson Machine Learning scoring deployment that serve your fine-tuned slate model.
   - `SCORING_DEPLOYMENT_ID`: The ID of your Watson Machine Learning scoring deployment that serve your fine-tuned slate model.
3. [Deploy the application](https://cloud.ibm.com/docs/codeengine?topic=codeengine-app-source-code) from this repository source code.
   - In **Create application**, click **Specify build details** and enter the following:
      - Source
         - Code repo URL: `https://github.com/watson-developer-cloud/doc-tutorial-downloads`
         - Code repo access: `None`
         - Branch name: `master`
         - Context directory: `discovery-data/webhook-enrichment-sample/slate/wml-as-webhook/proxy`
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
2. Get a token of scoring API
```shell
SCORING_API_TOKEN=$(
  curl -k -X POST 'https://{hostname of your cp4d instance}/icp4d-api/v1/authorize' \
                  --header "Content-Type: application/json" \
                  -d "{\"username\":\"admin\",\"api_key\":\"{api key of your cp4d instance}\"}" \
  | jq .token
)
```
3. Create a webhook enrichment using Discovery API.
   ```bash
   curl -X POST {auth} \
   --header 'Content-Type: multipart/form-data' \
   --form 'enrichment={"name":"my-first-webhook-enrichment",
   "type":"webhook",
   "options":{"url":"{your_code_engine_app_domain}/webhook",
      "headers":[
         {
            "name": "Authorization",
            "value": "Bearer {SCORING_API_TOKEN}"
         }
      ],
      "location_encoding":"utf-32"}}' \
   '{url}/v2/projects/{project_id}/enrichments?version=2023-03-31'
   ```
4. Create a collection in the project and apply the webhook enrichment to the collection.
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
