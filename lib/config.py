import os
import yaml
import sys
import logging
from lib import dotdict
from smart_open import smart_open

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(name="config.py")



def get_config():
    try:
        # if you can import from `awsglue`, then the code is running in glue
        from awsglue.utils import getResolvedOptions

        glue_args = [
            "config_file_list",
            "env",
            "config_bucket_name",
            "data_bucket_name",
            "s3_project_root",
        ]

        args = getResolvedOptions(sys.argv, glue_args)
        config_file = f"s3://{args['config_bucket_name']}/{args['s3_project_root']}config/config.yaml"

    except ModuleNotFoundError:
        config_file = os.path.join(
            "config",
            "config.yaml",
        )

    logger.info(f"Reading config file {config_file}")

    with smart_open(config_file, "r") as f:
        config_dict = dotdict.make_dotdict_recursive(
            yaml.safe_load(f),
        )
        logger.info(config_dict)
        return config_dict
    
