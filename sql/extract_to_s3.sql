copy into 's3://{{params.output_bucket_name}}/uta/test/output_files/'
from (
    select
        p.product_merch_classification1::varchar(50) as mc1,
        common_date_dttm ::date as date,
        sum(coalesce(olm.order_line_quantity, 0)) as value
    from edldb.chewybi.orders o
    inner join edldb.chewybi.order_line_cost_measures olm 
        using (order_key)
    inner join edldb.chewybi.products p
        on olm.product_key = p.product_key
    INNER JOIN edldb.chewybi.common_date AS financial_calendar
        ON financial_calendar.common_date_dttm::date = olm.order_placed_date::date
    join edldb.chewybi.business_channels b 
        on b.business_channel_key = olm.business_channel_key
    where true
        and lower(olm.PRODUCT_COMPANY_DESCRIPTION) not in ( 'chewy canada')
        and olm.order_placed_date::date between '2024-01-01' and '2024-01-31'
        AND common_date_dttm < current_date
        and p.product_merch_classification1 not in ('Gift Cards', 'Virtual Bundles')
    group by 1,2
)
-- partition by ('_mc1=' || "mc1")
file_format = (type = parquet binary_as_text = FALSE)
HEADER = TRUE
storage_integration = {{params.s3_integration}}
;
