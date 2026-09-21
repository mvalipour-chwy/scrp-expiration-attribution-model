import os
import logging
from prophet import Prophet
import optuna
import pandas as pd
import ray


logging.basicConfig(level=logging.INFO)
logger = logging.getLogger()


class ScriptConfig:
    env: str
    config_bucket_name: str
    input_s3_path: str
    output_s3_key: str
    project_root: str
    config_files: list[str]

    def __init__(self, env, config_bucket_name, data_bucket_name, input_s3_path, project_root, config_files):
        self.env = env
        self.config_bucket_name = config_bucket_name
        self.data_bucket_name = data_bucket_name
        self.input_s3_path = input_s3_path
        self.project_root = project_root
        self.config_files = config_files

    def __str__(self):
        return f"""
            env={self.env}
            config_bucket_name={self.config_bucket_name}
            data_bucket_name={self.data_bucket_name}
            input_s3_path={self.input_s3_path}
            project_root={self.project_root}
            config_files={self.config_files}
        """


def startup(script_options: dict):
    try:
        if os.environ.get('env') is None:
            raise Exception("this is a local env")

        logger.info(f"this is an AWS environment - {os.environ.get('env')}")
        script_options['env'] = os.environ.get('env')
        script_options['project_root'] = os.environ.get("s3_project_root")
        script_options['config_bucket_name'] = os.environ.get("config_bucket_name")
        #script_options['data_bucket_name'] = f"{script_options['env']}-use1-worker-replen-data"
        script_options['data_bucket_name'] = f"{script_options['env']}-use1-worker-replen-mwaa-data"
    except Exception as e:
        logger.info("start local dev script, using default script_options")

    return ScriptConfig(
        env=script_options.get('env'),
        config_bucket_name=script_options.get('config_bucket_name'),
        data_bucket_name=script_options.get('data_bucket_name'),
        input_s3_path=script_options.get('input_s3_path'),
        project_root=script_options.get('project_root'),
        config_files=script_options.get('config_files'),
    )


if __name__ == "__main__":
    #main()
    script_options = {
        "env": "local",
        "data_bucket_name": "dev-use1-worker-replen-mwaa-data",
        "config_bucket_name": "dev-use1-worker-replen-repository",
        "project_root": "./",
        "config_files": [
            f"config/config.yaml",
        ]
    }

    script_config = startup(script_options)

    print(script_config)
    