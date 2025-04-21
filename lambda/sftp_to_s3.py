import os
import json
import io
import logging
import boto3
import paramiko

# Configuration from Lambda environment
SFTP_HOST = os.environ["SFTP_HOST"]
SFTP_PORT = int(os.environ.get("SFTP_PORT", 22))
SFTP_USER = os.environ.get("SFTP_USER", "ec2-user")
SECRET_NAME = os.environ["SFTP_SECRET_NAME"]
BUCKET_NAME = os.environ["FILE_SYNC_BUCKET"]
SFTP_DIR = "/home/ec2-user/sftp"

# Clients & Logger
secrets_client = boto3.client("secretsmanager")
s3_client = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ.get("PROCESSED_FILES_TABLE", "student-query-sync-processed-files"))
logger = logging.getLogger()
logger.setLevel(logging.INFO)

def get_sftp_key():
    """Fetch the private key PEM from Secrets Manager."""
    logger.info(f"Fetching secret: {SECRET_NAME}")
    try:
        resp = secrets_client.get_secret_value(SecretId=SECRET_NAME)
        logger.info("Secret response received")
        secret = json.loads(resp["SecretString"])
        if "private_key" not in secret:
            logger.error("Secret missing 'private_key' field")
            raise ValueError("Secret missing 'private_key' field")
        key_pem = secret["private_key"]
        logger.info("Parsing RSA key")
        key = paramiko.RSAKey.from_private_key(io.StringIO(key_pem))
        logger.info("SFTP key retrieved successfully")
        return key
    except Exception as e:
        logger.error(f"Failed to fetch SFTP key: {str(e)}")
        raise

def connect_sftp(key):
    """Establish and return an SFTP client."""
    logger.info(f"Connecting to SFTP: {SFTP_USER}@{SFTP_HOST}:{SFTP_PORT}")
    try:
        transport = paramiko.Transport((SFTP_HOST, SFTP_PORT))
        transport.connect(username=SFTP_USER, pkey=key)
        sftp = paramiko.SFTPClient.from_transport(transport)
        logger.info("SFTP connected successfully")
        return sftp
    except Exception as e:
        logger.error(f"Failed to connect to SFTP: {str(e)}")
        raise

def lambda_handler(event, context):
    logger.info("Lambda sftp_to_s3 started")
    logger.info(f"Event: {json.dumps(event)}")
    try:
        key = get_sftp_key()
        sftp = connect_sftp(key)
    except Exception as e:
        logger.error(f"Failed to initialize SFTP: {str(e)}")
        return

    try:
        logger.info(f"Listing SFTP directory: {SFTP_DIR}")
        files = sftp.listdir(SFTP_DIR)
        logger.info(f"Found files: {files}")
    except Exception as e:
        logger.error(f"Failed to list SFTP directory {SFTP_DIR}: {str(e)}")
        sftp.close()
        return

    for filename in files:
        try:
            logger.info(f"Processing file: {filename}")
            response = table.get_item(Key={'filename': filename})
            if 'Item' in response:
                logger.info(f"Skipping already processed file: {filename}")
                continue

            logger.info(f"Reading SFTP file: {SFTP_DIR}/{filename}")
            with sftp.open(f"{SFTP_DIR}/{filename}", 'rb') as remote_f:
                data_stream = io.BytesIO(remote_f.read())
                logger.info(f"Uploading to S3: {filename}")
                s3_client.upload_fileobj(data_stream, BUCKET_NAME, filename)
                logger.info(f"Transferred {filename} → s3://{BUCKET_NAME}/{filename}")

            logger.info(f"Marking file as processed: {filename}")
            table.put_item(Item={'filename': filename})
        except Exception as e:
            logger.error(f"Error transferring {filename}: {str(e)}")

    sftp.close()
    logger.info("Lambda sftp_to_s3 completed")