# Unstructured Data Search with Elastic + Jina
## Contents
1.  [Summary](#summary)
2.  [Architecture](#architecture)
3.  [Features](#features)
4.  [Prerequisites](#prerequisites)
5.  [Installation](#installation)
6.  [Usage](#usage)

## Summary <a name="summary"></a>
This is a demonstration of various search scenarios against technical product manuals using Elasticsearch and Jina models.

## Architecture <a name="architecture"></a>
![architecture](assets/arch.png) 


## Features <a name="features"></a>
- Jupyter notebook
- Builds an Elastic Serverless deployment via Terraform
- Creates a data set from iFixit technical manuals.
- Utilizes the Jina Reader to parse the tech manual contents.
- Utilizes the Jina embeddings v5 model to embed the manual content.
- Performs four different search scenarios that demonstrate the enhanced search capabilities 
- Deletes the entire deployment via Terraform

## Prerequisites <a name="prerequisites"></a>
- terraform
- Elastic Cloud account and API key
- Jina API key
- Python

## Installation <a name="installation"></a>
- Edit the terraform.tfvars.sample and rename to terraform.tfvars
- Create a Python virtual environment

## Usage <a name="usage"></a>
- Execute notebook