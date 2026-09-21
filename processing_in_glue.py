import sys
from lib import utils
from smart_open import smart_open
import yaml
import logging
import lib.dotdict as dotdict
from prophet import Prophet
from prophet.diagnostics import cross_validation, performance_metrics
import optuna



logging.basicConfig(level=logging.INFO)
logger = logging.getLogger()

#TODO this file is confusing, clean it up

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
        # assume the code is running in AWS here
        from awsglue.utils import getResolvedOptions

        glue_args = [
            "config_file_list",
            "env",
            "config_bucket_name",
            "data_bucket_name",
            "s3_project_root",
        ]

        args = getResolvedOptions(sys.argv, glue_args)
        logger.info(f"this is an AWS environment - {args['env']}")
        script_options['env'] = args['env']
        script_options['project_root'] = args["s3_project_root"]
        script_options['config_bucket_name'] = args["config_bucket_name"]
        script_options['data_bucket_name'] = f"{script_options['env']}-use1-worker-replen-data"
    except ModuleNotFoundError:
        # awsglue isn't here, then we're in local dev
        logger.info("start local dev script, using default script_options")

    return ScriptConfig(
        env=script_options.get('env'),
        config_bucket_name=script_options.get('config_bucket_name'),
        data_bucket_name=script_options.get('data_bucket_name'),
        input_s3_path=script_options.get('input_s3_path'),
        project_root=script_options.get('project_root'),
        config_files=script_options.get('config_files'),
    )


def main():
    # default script option values, this will be used when running locally
    script_options = {
        "env": "local",
        "data_bucket_name": "dev-use1-worker-replen-data",
        "config_bucket_name": "dev-use1-worker-replen-repository",
        "input_s3_path": "uta/test/output_files/",
        "project_root": "./",
        "config_files": [
            f"config/config.yaml",
        ]
    }

    script_config = startup(script_options)

    print(script_config)



if __name__ == "__main__":
    main()
