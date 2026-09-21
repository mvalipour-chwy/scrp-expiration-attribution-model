FROM 278833423079.dkr.ecr.us-east-1.amazonaws.com/ecr-public/docker/library/python:3.10.8-slim-buster

ARG PYTHON=python3
ARG PIP=pip3

ENV PYTHONUNBUFFERED=1

RUN apt-get update && \
    apt-get -y upgrade && \
    apt-get install -y --no-install-recommends \
    build-essential \
    libncursesw5-dev \
    libreadline-gplv2-dev \
    libssl-dev \
    libgdbm-dev \
    libc6-dev \
    libsqlite3-dev \
    libbz2-dev \
    libffi-dev \
    zlib1g-dev

RUN which ${PYTHON}

COPY requirements.docker.txt requirements.docker.txt

RUN ${PIP} install -r requirements.docker.txt

COPY . .


ENTRYPOINT ["python3"]