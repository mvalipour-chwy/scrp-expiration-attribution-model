from typing import Any, Dict
from lib.config import get_config
import pandas as pd


def do_some_processing(df: pd.DataFrame):
    print(f"doing some processing on df with length: {len(df)}")
    return df


def deep_get(
    dictionary: Dict[Any, Any],
    *key_path: str,
    default: Any,
) -> Any:
    """step through a dictionary to find a value. if at any point the path you're
    searching no longer exists, return the default. the key_path is a parameter group,
    so you call this like val=deep_get(my_dict, 'path1', 'path2', 'key', default=0),
    with the last argument (default) being optional."""
    value = dictionary
    for key in key_path:
        if isinstance(value, dict) and key in value:
            value = value[key]
        else:
            return default
    return value

def plural(word: str, count: int, suffix: str = "s") -> str:
    return word if count == 1 else (word + suffix)


def func_that_uses_config(key: str):
    return get_config()[key]