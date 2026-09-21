
-- create or replace local temporary table herald_bi_metrics_template_temp
-- (
--     mc1 varchar(64),
--     date varchar(64),
--     value varchar(64)
-- );


-- INGEST DATE FROM S3
-- COPY INTO herald_bi_metrics_template_temp
-- FROM
-- 's3://{{params.output_bucket_name}}/uta/path/to/file.snappy.parquet' --<put_s3_path_here>
-- MATCH_BY_COLUMN_NAME='CASE_INSENSITIVE'
-- storage_integration = {{params.s3_integration}}
-- FILE_FORMAT = (TYPE = 'PARQUET');
-- ;


-- then you can insert from temp table into your final load table
--
-- insert into {{params.edldb_db_name}}.schema_name.table_name
-- (
--     mc1,
--     date,
--     value
-- )
-- select mc1, date, value
-- from herald_bi_metrics_template_temp
-- ;