import os
import boto3
from botocore.exceptions import ClientError
import json
import pandas as pd
import awswrangler as wr

# pip install snowflake-snowpark-python
# pip install awswrangler


def get_account_id():
    client = boto3.client("sts")
    account_id = client.get_caller_identity()["Account"]
    return account_id


def get_env():
    if get_account_id() == '977247693856':
        env = 'dev'
    elif get_account_id() == '204130544204':
        env = 'prd'
    elif get_account_id() == '894285811264':
        env = 'stg'
    else:
        env = None
    return env


def get_secret(secret_name):
    region_name = "us-east-1"
    session = boto3.session.Session()
    client = session.client(
        service_name='secretsmanager', region_name=region_name)
    try:
        get_secret_value_response = client.get_secret_value(
            SecretId=secret_name)
    except ClientError as e:
        raise e
    secret = get_secret_value_response['SecretString']
    return json.loads(secret)


def get_password(private_key):
    from cryptography.hazmat.backends import default_backend
    from cryptography.hazmat.primitives import serialization
    p_key = serialization.load_pem_private_key(private_key.encode(
        'utf-8'), password=None, backend=default_backend())
    return p_key.private_bytes(encoding=serialization.Encoding.DER, format=serialization.PrivateFormat.PKCS8, encryption_algorithm=serialization.NoEncryption())


def get_snowflake_session():
    from snowflake.snowpark.session import Session
    env_name = get_env()
    secret_name = f"/chewy/{env_name}/us-east-1/worker_replen/airflow/connections/replen_snowflake_aws_airflow_svc"
    secret_dict = get_secret(secret_name)
    private_key = secret_dict["extra"]["private_key_content"]
    warehouse = secret_dict["extra"]["warehouse"]
    database = secret_dict["extra"]["database"]
    account = secret_dict["extra"]["account"]
    user_name = secret_dict["login"]
    pkb = get_password(private_key)
    connection_parameters = {
        "account": account,
        "user": user_name,
        "private_key": pkb,
        "database": database,
        "warehouse": warehouse,
        "schema": "SC_FORECAST_SANDBOX"
    }
    session = Session.builder.configs(connection_parameters).create()
    return session



def get_files_list(s3_bucket, prefix, file_extension):
    file_list = []
    session = boto3.Session()
    s3 = session.resource('s3')
    my_bucket = s3.Bucket(s3_bucket)
    for objects in my_bucket.objects.filter(Prefix=prefix):
        if objects.key.endswith(file_extension):
            file_list.append(f"s3://{s3_bucket}/{objects.key}")
    return file_list


def copy_files(source, dest, source_key, dest_key):
    s3 = boto3.resource('s3')
    copy_source = {
        'Bucket': source,
        'Key': source_key
    }
    s3.meta.client.copy(copy_source, dest, dest_key)


def get_default_s3_bucket():
    env_name = get_env()
    s3_bucket = f"{env_name}-use1-worker-replen-data"
    return s3_bucket


def save_df_to_s3(df, s3_bucket, prefix, mode="overwrite"):
    # save df as parquet using awswrangler,default is overwrite
    filepath = f"s3://{s3_bucket}/{prefix}/"
    wr.s3.to_parquet(df=df, path=filepath, dataset=True, mode=mode)


def chunks_to_df(gen):
    chunks = []
    for df in gen:
        chunks.append(df)
    return pd.concat(chunks).reset_index().drop('index', axis=1)


def read_s3_parquet(path):
    df_chunks = wr.s3.read_parquet(
        path=path,
        chunked=1_000_000  # default 1M
    )
    df = chunks_to_df(df_chunks)
    return df


def list_buckets():
    s3 = boto3.resource("s3")
    return s3.buckets.all()


def publish_to_sns_topic(topic_arn: str, message: dict):
    message_str = json.dumps(message)
    sns = boto3.resource('sns')
    topic = sns.Topic(topic_arn)
    response = topic.publish(Message=message_str)
    return response


# test functions locally after intializing aws-sso-util login
if __name__ == "__main__":
    # Step 1. Read data from snowflake table
    session = get_snowflake_session()
    print("Reading table into data frame")
    df_sfl = session.sql("select * from EDLDB.SC_USER_TOOLS_ANALYTICS_SANDBOX.UTA_SEASONALITY_INDX_ORDERED_UNITS limit 10 ").toPandas()

    #######################################
    ## Your agggreation/transformation logic goes here ##
    ########################################

    # Step 2. Write the file from step 1 into s3
    s3_bucket = get_default_s3_bucket()
    file_prefix = "uta_testing/df_test"
    #print("s3_bucket", s3_bucket)
    print("writing df into s3")
    save_df_to_s3(df_sfl, s3_bucket, prefix=file_prefix)
    print("writing complete")

    # Step 3. Read the file from step 2 into a data frame
    file_path = f"s3://{s3_bucket}/{file_prefix}/"
    df = read_s3_parquet(file_path)
    print("printing df shape",df.shape)   

    
