import argparse
import sys
import pandas as pd
from dataclasses import dataclass

from lib import utils


PATHS = {
    "input": {
        "actuals_data": "/opt/ml/processing/input/actuals/",
        "holiday_file": "/opt/ml/processing/input/config/holidays.json",
    },
    "output": {
        "output_dir": "/opt/ml/processing/output",
    }
}


@dataclass
class Args:
    run_date: str
    snapshot_date: str
    horizon: str
    train_start: str
    models: str


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument('--run_date', type=str, required=True)
    parser.add_argument('--snapshot_date', type=str, required=True)
    parser.add_argument('--horizon', type=str, required=True)
    parser.add_argument('--train_start', type=str, required=True)
    parser.add_argument('--models', type=str, required=True)
    parsed_args, _ = parser.parse_known_args()
    return Args(**vars(parsed_args))


if __name__ == '__main__':
    print("hello")
    print("parsing args")
    args = parse_args()
    print(f"Found from args: {args}")

    df = pd.read_parquet(PATHS["input"]["actuals_data"])

    print(len(df))

    holidays = pd.read_json(PATHS["input"]["holiday_file"])

    print(holidays.head())

    # do something with df
    df = utils.do_some_processing(df)

    df.to_parquet(f'{PATHS["output"]["output_dir"]}/output.snappy.parquet')

    print("FINISHED")
