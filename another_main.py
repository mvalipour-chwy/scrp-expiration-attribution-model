import sys
from lib import utils
from smart_open import smart_open
import yaml
import logging
import lib.boto3_utils as bu
import lib.dotdict as dotdict

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
        if args["config_file_list"] == "ALL":
            script_options['config_files'] = bu.get_files_list(
                s3_bucket=script_options['config_bucket_name'],
                prefix=f"{script_options['project_root']}/config/",
                file_extension="yaml",)
        else:
            # config_files = args['config_file_list'].split(",")
            script_options['config_files'] = [
                f"s3://{script_options['config_bucket_name']}/{script_options['project_root']}/config/{x}"
                for x in args["config_file_list"].split(",")
            ]
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
    logger.info(f'This is from another_main.py')
    # import from lib
    logger.info(
        f'Sometimes theres 1 goose, sometimes there\'s a gaggle of {utils.plural("goose", 3)}'
    )

    logger.info(
        f"here is the config_value: {utils.func_that_uses_config('config_value')}"
    )

    logger.info(f"here is another_value from config: {utils.func_that_uses_config('another_value')}")

    # input_data = bu.read_s3_parquet(f"s3://{script_config.data_bucket_name}/{script_config.input_s3_path}")
    # logger.info(f"Length of input_files data {len(input_data)}")

    # # for loop through config files
    # for config_file in script_config.config_files:
    #     logger.info(f"reading {config_file}")
    #     with smart_open(config_file, "r") as f:
    #         CONFIG = dotdict.make_dotdict_recursive(
    #             yaml.safe_load(f),
    #         )
    #         logger.info(CONFIG)



if __name__ == "__main__":
    main()
