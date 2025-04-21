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

def ensure_sftp_path(sftp, path):
    """Create directories on SFTP server if they don't exist."""
    logger.info(f"Ensuring SFTP path: {path}")
    try:
        sftp.stat(path)
        logger.info(f"Path exists: {path}")
    except IOError:
        parent = os.path.dirname(path)
        if parent and parent != '/':
            ensure_sftp_path(sftp, parent)
        sftp.mkdir(path)
        logger.info(f"Created SFTP directory: {path}")

def lambda_handler(event, context):
    logger.info("Lambda s3_to_sftp started")
    logger.info(f"Event: {json.dumps(event)}")
    try:
        key = get_sftp_key()
        sftp = connect_sftp(key)
    except Exception as e:
        logger.error(f"Failed to initialize SFTP: {str(e)}")
        return

    for record in event.get("Records", []):
        s3_info = record.get("s3", {})
        obj_key = s3_info.get("object", {}).get("key")
        if not obj_key:
            logger.warning("No object key in record")
            continue

        try:
            logger.info(f"Processing S3 object: {obj_key}")
            response = table.get_item(Key={'filename': obj_key})
            if 'Item' in response:
                logger.info(f"Skipping already processed file: {obj_key}")
                continue

            logger.info(f"Fetching S3 object: {BUCKET_NAME}/{obj_key}")
            s3_obj = s3_client.get_object(Bucket=BUCKET_NAME, Key=obj_key)
            body = s3_obj["Body"]
            data = body.read()
            logger.info(f"Read S3 object: {obj_key}")

            sftp_path = f"{SFTP_DIR}/{obj_key}"
            logger.info(f"Ensuring SFTP path for: {sftp_path}")
            ensure_sftp_path(sftp, os.path.dirname(sftp_path))

            logger.info(f"Uploading to SFTP: {sftp_path}")
            with io.BytesIO(data) as memfile:
                memfile.seek(0)
                sftp.putfo(memfile, sftp_path)
            logger.info(f"Transferred s3://{BUCKET_NAME}/{obj_key} → SFTP:{sftp_path}")

            logger.info(f"Marking file as processed: {obj_key}")
            table.put_item(Item={'filename': obj_key})
        except Exception as e:
            logger.error(f"Error during S3→SFTP for {obj_key}: {str(e)}")

    sftp.close()
    logger.info("Lambda s3_to_sftp completed")