from typing import Any


class DotDict(dict):
    """dot.notation access to dictionary attributes"""

    def __getattr__(self, attr: str) -> Any:
        try:
            return self[attr]
        except KeyError:
            raise AttributeError(attr)

    def __setattr__(self, attr: str, value: Any) -> None:
        self[attr] = value

    def __setitem__(self, key: str, value: Any) -> None:
        super().__setitem__(key, value)

    def __getitem__(self, key: str) -> Any:
        return super().__getitem__(key)


def make_dotdict_recursive(elem):
    if isinstance(elem, (list, tuple)):
        return type(elem)(make_dotdict_recursive(item) for item in elem)
    if isinstance(elem, dict):
        return DotDict({k: make_dotdict_recursive(v) for k, v in elem.items()})

    return elem
