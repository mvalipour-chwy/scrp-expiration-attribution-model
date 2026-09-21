from lib import boto3_utils


def main():
    print("hello from main!")
    buckets = boto3_utils.list_buckets()
    for bucket in buckets:
        print(bucket)


if __name__ == "__main__":
    main()
